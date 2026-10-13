defmodule Converger.Channels.Broker.NatsPublisher do
  @moduledoc """
  Owns the NATS connection (a `Gnat` process) a `nats` channel publishes
  with on this node (see `Converger.Channels.Broker.Publishers`).
  Publishing runs in the caller (`publish/4`): the process only holds the
  connection, so concurrent deliveries do not queue behind each other.

  A publish is a JetStream publish: a request on the subject, answered by
  the stream that captures it with a publish acknowledgement
  (`{"stream": ..., "seq": ...}`) once the message is stored. The
  connection is opened with `no_responders`, so a subject no stream
  captures fails at once with `:no_responders` instead of timing out.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Converger.Channels.Adapters.Nats
  alias Converger.Channels.Broker.Publishers

  def start_link(channel),
    do: GenServer.start_link(__MODULE__, channel, name: Publishers.via(channel))

  @doc """
  Publish `payload` to `subject` (with `opts[:headers]`) and wait up to
  `opts[:timeout]` ms (default 10 s) for the stream's acknowledgement.
  Returns `{:ok, %{stream: name, seq: sequence, duplicate: boolean}}`.
  """
  @spec publish(map(), String.t(), iodata(), keyword()) ::
          {:ok, %{stream: String.t(), seq: non_neg_integer(), duplicate: boolean()}}
          | {:error, term()}
  def publish(channel, subject, payload, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    headers = Keyword.get(opts, :headers, [])

    with {:ok, pid} <- Publishers.ensure(__MODULE__, channel),
         {:ok, conn} <- conn(pid),
         {:ok, %{body: body}} <-
           Gnat.request(conn, subject, payload, headers: headers, receive_timeout: timeout) do
      publish_ack(body)
    end
  rescue
    # Gnat validates subjects in the caller.
    exception in ArgumentError -> {:error, {:invalid_config, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "Parse a JetStream publish acknowledgement."
  @spec publish_ack(binary()) ::
          {:ok, %{stream: String.t(), seq: non_neg_integer(), duplicate: boolean()}}
          | {:error, term()}
  def publish_ack(body) do
    case Jason.decode(body) do
      {:ok, %{"stream" => stream, "seq" => seq} = ack} ->
        {:ok, %{stream: stream, seq: seq, duplicate: ack["duplicate"] == true}}

      {:ok, %{"error" => %{"code" => 400} = error}} ->
        {:error, {:bad_request, error["description"]}}

      {:ok, %{"error" => error}} ->
        {:error, {:jetstream, error["code"], error["description"]}}

      _ ->
        {:error, {:unexpected_reply, body}}
    end
  end

  defp conn(pid) do
    {:ok, GenServer.call(pid, :conn)}
  catch
    :exit, reason -> {:error, {:publisher_down, reason}}
  end

  @impl true
  def init(channel) do
    Process.flag(:trap_exit, true)

    case Nats.connect(channel.config || %{}) do
      {:ok, conn} ->
        Process.link(conn)
        idle_ms = Publishers.idle_ms()
        {:ok, %{conn: conn, idle_ms: idle_ms}, idle_ms}

      # {:target_blocked, _} and {:invalid_config, _} are permanent, see
      # Nats.normalize_error/1.
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:conn, _from, state), do: {:reply, state.conn, state, state.idle_ms}

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}

  def handle_info({:EXIT, conn, reason}, %{conn: conn} = state) do
    Logger.warning("NATS publisher connection closed", reason: inspect(reason))
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state, state.idle_ms}

  @impl true
  def terminate(_reason, %{conn: conn}) do
    if Process.alive?(conn), do: Gnat.stop(conn)
    :ok
  catch
    :exit, _ -> :ok
  end
end
