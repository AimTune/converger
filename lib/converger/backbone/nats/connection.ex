defmodule Converger.Backbone.Nats.Connection do
  @moduledoc """
  Owns the NATS connection the NATS backbone publishes with and creates the
  backbone streams when they are missing. A server that is unreachable (at
  boot or later) does not stop the node: the connection is retried every
  5 s, and publishes fail meanwhile, which parks the events in Postgres
  (`Converger.Workers.BackbonePublishWorker`).
  """

  use GenServer

  require Logger

  alias Converger.Backbone
  alias Converger.Backbone.Nats
  alias Converger.Channels.Adapters.Nats, as: NatsAdapter
  alias Gnat.Jetstream.API.Stream

  @retry_ms 5_000

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @doc "The connection, or `{:error, :not_connected}`."
  @spec conn() :: {:ok, pid()} | {:error, term()}
  def conn do
    case GenServer.call(__MODULE__, :conn) do
      nil -> {:error, :not_connected}
      pid -> {:ok, pid}
    end
  catch
    :exit, reason -> {:error, {:connection_down, reason}}
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    {:ok, %{config: config, conn: nil}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case NatsAdapter.connect(Nats.channel_config(state.config), guard: false) do
      {:ok, conn} ->
        Process.link(conn)

        case ensure_streams(conn, state.config) do
          :ok ->
            {:noreply, %{state | conn: conn}}

          {:error, reason} ->
            Logger.warning("NATS backbone streams not ready; retrying", error: inspect(reason))
            stop_quietly(conn)
            retry(state)
        end

      {:error, reason} ->
        Logger.warning("NATS backbone not connected; retrying", error: inspect(reason))
        retry(state)
    end
  end

  defp retry(state) do
    Process.send_after(self(), :connect, @retry_ms)
    {:noreply, %{state | conn: nil}}
  end

  @impl true
  def handle_call(:conn, _from, state), do: {:reply, state.conn, state}

  @impl true
  def handle_info(:connect, state), do: {:noreply, state, {:continue, :connect}}

  def handle_info({:EXIT, conn, reason}, %{conn: conn} = state) do
    Logger.warning("NATS backbone connection closed; reconnecting", reason: inspect(reason))
    retry(state)
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn}) do
    if is_pid(conn), do: stop_quietly(conn)
    :ok
  end

  defp stop_quietly(conn) do
    if Process.alive?(conn), do: Gnat.stop(conn)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp ensure_streams(conn, config) do
    Enum.reduce_while(Backbone.topics(), :ok, fn topic, :ok ->
      case ensure_stream(conn, topic, config) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp ensure_stream(conn, topic, config) do
    name = Nats.stream(topic)

    case Stream.info(conn, name) do
      {:ok, _info} ->
        :ok

      {:error, %{"code" => 404}} ->
        stream = %Stream{
          name: name,
          subjects: [Nats.subject(topic)],
          storage: :file,
          num_replicas: Keyword.get(config, :replicas, 1),
          max_age: Keyword.get(config, :max_age_seconds, 604_800) * 1_000_000_000,
          duplicate_window: Keyword.get(config, :duplicate_window_seconds, 120) * 1_000_000_000
        }

        case Stream.create(conn, stream) do
          {:ok, _info} -> :ok
          {:error, reason} -> {:error, {:stream_create_failed, name, reason}}
        end

      {:error, reason} ->
        {:error, {:stream_info_failed, name, reason}}
    end
  end
end
