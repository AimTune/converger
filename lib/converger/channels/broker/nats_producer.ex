defmodule Converger.Channels.Broker.NatsProducer do
  @moduledoc """
  Broadway producer of a `nats` channel: pulls messages from a JetStream
  durable pull consumer.

  On start it opens a NATS connection (`Converger.Channels.Adapters.Nats.connect/2`),
  creates the stream when `declare` is set and it does not exist, creates
  the durable consumer (explicit acks, filtered on the inbound subject)
  when it does not exist, and subscribes to a private inbox. Demand is
  served with pull requests (`$JS.API.CONSUMER.MSG.NEXT`) of at most
  `batch_size` messages that expire after 5 s, so a pull is always open
  while there is demand and messages arrive as soon as they are published.

  Each message is acknowledged on its own reply subject: `+ACK` once
  `Converger.Channels.Broker.Pipeline` handled it (accepted or
  dead-lettered), `-NAK` (redeliver now) if it failed or arrived while the
  pipeline drains. A message that is never acknowledged (the node died) is
  redelivered by the server after the consumer's `ack_wait`. The durable
  consumer keeps the acknowledged position, so a restarted consumer resumes
  where it left off.

  The connection is linked: when it closes the producer exits and the
  pipeline restarts (see `Converger.Channels.Broker.Consumer`).

  Options: `:config` (the channel config), `:stream`, `:subject`,
  `:durable_name`, `:dlq_subject`, `:declare`, `:deliver_policy`,
  `:ack_wait_ms`, `:batch_size`, `:connect_opts` (`Nats.connect/2` options;
  the NATS backbone, `Converger.Backbone.Nats`, passes `guard: false`).
  """

  use GenStage

  @behaviour Broadway.Producer
  @behaviour Broadway.Acknowledger

  require Logger

  alias Converger.Channels.Adapters.Nats
  alias Gnat.Jetstream.API.{Consumer, Message, Stream}

  @pull_expires_ms 5_000
  # A pull the server never answers (lost on a reconnect) is given up after this.
  @pull_guard_ms @pull_expires_ms + 5_000
  @retry_pull_ms 1_000

  @impl GenStage
  def init(opts) do
    config = Keyword.fetch!(opts, :config)

    case Nats.connect(config, Keyword.get(opts, :connect_opts, [])) do
      {:ok, conn} ->
        Process.link(conn)

        with :ok <- ensure_stream(conn, opts),
             :ok <- ensure_consumer(conn, opts) do
          inbox = "_INBOX." <> Gnat.Jetstream.API.Util.nuid()
          {:ok, sid} = Gnat.sub(conn, self(), inbox)

          {:producer,
           %{
             conn: conn,
             sid: sid,
             inbox: inbox,
             stream: Keyword.fetch!(opts, :stream),
             durable: Keyword.fetch!(opts, :durable_name),
             batch_size: Keyword.fetch!(opts, :batch_size),
             demand: 0,
             pull: nil,
             retry_timer: nil,
             draining: false
           }}
        else
          {:error, reason} ->
            Gnat.stop(conn)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp ensure_stream(conn, opts) do
    stream = Keyword.fetch!(opts, :stream)

    case Stream.info(conn, stream) do
      {:ok, _info} ->
        :ok

      {:error, %{"code" => 404}} ->
        if Keyword.get(opts, :declare, false) do
          subjects =
            Enum.uniq([Keyword.fetch!(opts, :subject), Keyword.fetch!(opts, :dlq_subject)])

          case Stream.create(conn, %Stream{name: stream, subjects: subjects}) do
            {:ok, _info} -> :ok
            {:error, reason} -> {:error, {:stream_create_failed, stream, reason}}
          end
        else
          {:error, {:stream_not_found, stream}}
        end

      {:error, reason} ->
        {:error, {:stream_info_failed, stream, reason}}
    end
  end

  defp ensure_consumer(conn, opts) do
    stream = Keyword.fetch!(opts, :stream)
    durable = Keyword.fetch!(opts, :durable_name)

    case Consumer.info(conn, stream, durable) do
      {:ok, _info} ->
        :ok

      {:error, %{"code" => 404}} ->
        consumer = %Consumer{
          stream_name: stream,
          durable_name: durable,
          filter_subject: Keyword.fetch!(opts, :subject),
          ack_policy: :explicit,
          ack_wait: Keyword.fetch!(opts, :ack_wait_ms) * 1_000_000,
          deliver_policy: Keyword.get(opts, :deliver_policy, :all),
          max_ack_pending: 1_000
        }

        case Consumer.create(conn, consumer) do
          {:ok, _info} -> :ok
          {:error, reason} -> {:error, {:consumer_create_failed, durable, reason}}
        end

      {:error, reason} ->
        {:error, {:consumer_info_failed, durable, reason}}
    end
  end

  @impl GenStage
  def handle_demand(incoming, state) do
    {:noreply, [], maybe_pull(%{state | demand: state.demand + incoming})}
  end

  @impl GenStage
  # A message of the open pull.
  def handle_info({:msg, %{sid: sid, reply_to: "$JS.ACK." <> _} = msg}, %{sid: sid} = state) do
    state = count_delivered(state)

    if state.draining do
      nak(state.conn, msg.reply_to)
      {:noreply, [], state}
    else
      state = %{state | demand: max(state.demand - 1, 0)}
      {:noreply, [to_broadway_message(msg, state)], maybe_pull(state)}
    end
  end

  # Status messages end a pull: 408 (expired), 404 (no messages), 409
  # (e.g. max waiting exceeded, consumer deleted). 100 is a heartbeat.
  def handle_info({:msg, %{sid: sid, status: "100"}}, %{sid: sid} = state),
    do: {:noreply, [], state}

  def handle_info({:msg, %{sid: sid, status: status} = msg}, %{sid: sid} = state)
      when is_binary(status) do
    state = %{state | pull: nil}

    case status do
      "408" ->
        {:noreply, [], maybe_pull(state)}

      "409" ->
        Logger.warning("NATS pull request ended",
          status: status,
          reason: msg[:description],
          source: "#{state.stream}/#{state.durable}"
        )

        # The durable consumer was deleted: restart, which recreates it.
        if String.contains?(msg[:description] || "", "Consumer Deleted"),
          do: {:stop, :consumer_deleted, state},
          else: {:noreply, [], schedule_pull(state)}

      _ ->
        {:noreply, [], schedule_pull(state)}
    end
  end

  def handle_info({:pull_guard, ref}, %{pull: %{ref: ref}} = state),
    do: {:noreply, [], maybe_pull(%{state | pull: nil})}

  def handle_info({:pull_guard, _stale}, state), do: {:noreply, [], state}

  def handle_info(:pull, state), do: {:noreply, [], maybe_pull(%{state | retry_timer: nil})}

  def handle_info(_message, state), do: {:noreply, [], state}

  @impl Broadway.Producer
  def prepare_for_draining(state), do: {:noreply, [], %{state | draining: true}}

  @impl GenStage
  def terminate(_reason, %{conn: conn}) do
    if Process.alive?(conn), do: Gnat.stop(conn)
    :ok
  catch
    :exit, _ -> :ok
  end

  ## Pulls

  defp maybe_pull(%{pull: nil, retry_timer: nil, draining: false, demand: demand} = state)
       when demand > 0 do
    batch = min(demand, state.batch_size)

    :ok =
      Consumer.request_next_message(state.conn, state.stream, state.durable, state.inbox, nil,
        batch: batch,
        expires: @pull_expires_ms * 1_000_000
      )

    ref = make_ref()
    Process.send_after(self(), {:pull_guard, ref}, @pull_guard_ms)
    %{state | pull: %{ref: ref, remaining: batch}}
  end

  defp maybe_pull(state), do: state

  defp schedule_pull(%{retry_timer: nil} = state),
    do: %{state | retry_timer: Process.send_after(self(), :pull, @retry_pull_ms)}

  defp schedule_pull(state), do: state

  defp count_delivered(%{pull: %{remaining: remaining} = pull} = state) when remaining > 1,
    do: %{state | pull: %{pull | remaining: remaining - 1}}

  defp count_delivered(state), do: %{state | pull: nil}

  ## Messages

  @doc false
  def to_broadway_message(msg, state) do
    metadata =
      case Message.metadata(msg) do
        {:ok, meta} ->
          %{stream: meta.stream, stream_seq: meta.stream_seq, num_delivered: meta.num_delivered}

        {:error, _} ->
          %{stream: state.stream, stream_seq: nil, num_delivered: nil}
      end

    %Broadway.Message{
      data: msg.body,
      metadata:
        Map.merge(metadata, %{
          subject: msg.topic,
          headers: headers(Map.get(msg, :headers))
        }),
      acknowledger: {__MODULE__, state.conn, msg.reply_to}
    }
  end

  defp headers(headers) when is_list(headers) do
    for {name, value} <- headers, is_binary(name), do: {name, IO.iodata_to_binary(value)}
  end

  defp headers(_), do: []

  @impl Broadway.Acknowledger
  def ack(conn, successful, failed) do
    Enum.each(successful, fn %{acknowledger: {_, _, reply_to}} ->
      reply(conn, reply_to, "+ACK")
    end)

    Enum.each(failed, fn %{acknowledger: {_, _, reply_to}} -> nak(conn, reply_to) end)
  end

  defp nak(conn, reply_to), do: reply(conn, reply_to, "-NAK")

  # An acknowledgement that cannot be sent (the connection closed) is not
  # fatal: the server redelivers the message after ack_wait, and the
  # idempotency key makes the redelivery a duplicate.
  defp reply(conn, reply_to, body) do
    Gnat.pub(conn, reply_to, body)
  catch
    :exit, reason ->
      Logger.warning("NATS acknowledgement not sent", reason: inspect(reason))
      :ok
  end
end
