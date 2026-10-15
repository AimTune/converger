defmodule Converger.Channels.Broker.AmqpPublisher do
  @moduledoc """
  Owns the AMQP connection a `rabbitmq` channel publishes with on this node
  (see `Converger.Channels.Broker.Publishers`). The AMQP channel is in
  confirm mode: `publish/6` returns once the broker has confirmed the
  message (written to the queues it was routed to, to disk for persistent
  messages on durable queues). Publishes of one Converger channel are
  serialised through this process.

  With `mandatory: true` (dead-lettering), a message the broker cannot route
  to any queue is returned and the publish fails with `:unroutable`, instead
  of being dropped.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Converger.Channels.Adapters.RabbitMQ
  alias Converger.Channels.Broker.Publishers

  def start_link(channel),
    do: GenServer.start_link(__MODULE__, channel, name: Publishers.via(channel))

  @doc """
  Publish `payload` to `exchange` with `routing_key` and wait for the
  broker's confirm (`opts[:timeout]`, default 10 s). Other `opts` are
  `AMQP.Basic.publish/5` options.
  """
  @spec publish(map(), String.t(), String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def publish(channel, exchange, routing_key, payload, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, 10_000)

    with {:ok, pid} <- Publishers.ensure(__MODULE__, channel) do
      GenServer.call(
        pid,
        {:publish, exchange, routing_key, payload, opts, timeout},
        timeout + 5_000
      )
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @impl true
  def init(channel) do
    Process.flag(:trap_exit, true)

    with {:config, {:ok, options}} <-
           {:config, RabbitMQ.connection_options(channel.config || %{})},
         {:guard, :ok} <- {:guard, RabbitMQ.check_host(options)},
         {:ok, conn} <- AMQP.Connection.open(options),
         {:ok, chan} <- open_channel(conn) do
      Process.monitor(conn.pid)
      idle_ms = Publishers.idle_ms()
      {:ok, %{conn: conn, chan: chan, idle_ms: idle_ms}, idle_ms}
    else
      # Permanent failures, see RabbitMQ.normalize_error/1.
      {:config, {:error, message}} -> {:stop, {:invalid_config, message}}
      {:guard, {:error, message}} -> {:stop, {:target_blocked, message}}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp open_channel(conn) do
    with {:ok, chan} <- AMQP.Channel.open(conn),
         :ok <- AMQP.Confirm.select(chan),
         :ok <- AMQP.Basic.return(chan, self()) do
      {:ok, chan}
    else
      error ->
        AMQP.Connection.close(conn)
        error
    end
  end

  @impl true
  def handle_call({:publish, exchange, routing_key, payload, opts, timeout}, _from, state) do
    message_id = Keyword.get(opts, :message_id)

    result =
      with :ok <- AMQP.Basic.publish(state.chan, exchange, routing_key, payload, opts) do
        case AMQP.Confirm.wait_for_confirms(state.chan, {timeout, :millisecond}) do
          true -> if returned?(message_id), do: {:error, :unroutable}, else: :ok
          false -> {:error, :nacked}
          :timeout -> {:error, :confirm_timeout}
        end
      end

    {:reply, result, state, state.idle_ms}
  catch
    :exit, reason ->
      {:stop, :normal, {:error, {:channel_closed, reason}}, state}
  end

  # The broker sends basic.return before the confirm of an unroutable
  # mandatory message, so it is in the mailbox when the confirm arrives.
  defp returned?(message_id) do
    receive do
      {:basic_return, _payload, %{message_id: ^message_id}} -> true
    after
      0 -> false
    end
  end

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{conn: %{pid: pid}} = state) do
    Logger.warning("RabbitMQ publisher connection closed", reason: inspect(reason))
    {:stop, :normal, state}
  end

  # Stale returns (a message returned after its publish timed out).
  def handle_info({:basic_return, _payload, _meta}, state), do: {:noreply, state, state.idle_ms}
  def handle_info(_message, state), do: {:noreply, state, state.idle_ms}

  @impl true
  def terminate(_reason, %{conn: conn}) do
    if Process.alive?(conn.pid), do: AMQP.Connection.close(conn)
    :ok
  catch
    :exit, _ -> :ok
  end
end
