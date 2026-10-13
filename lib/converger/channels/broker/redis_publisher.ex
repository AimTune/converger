defmodule Converger.Channels.Broker.RedisPublisher do
  @moduledoc """
  Owns the Redis connection (a `Redix` process) a `redis_streams` channel
  appends with on this node (see `Converger.Channels.Broker.Publishers`).
  Commands run in the caller (`xadd/4`): Redix pipelines concurrent
  commands on the connection, so deliveries do not queue behind each other
  in this process.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Converger.Channels.Adapters.RedisStreams
  alias Converger.Channels.Broker.Publishers

  def start_link(channel),
    do: GenServer.start_link(__MODULE__, channel, name: Publishers.via(channel))

  @doc """
  `XADD stream [MAXLEN ~ maxlen] * field value ...` and return the entry id.
  Options: `:maxlen` (nil: no trimming), `:timeout` (default 10 s).
  """
  @spec xadd(map(), String.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def xadd(channel, stream, fields, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    with {:ok, pid} <- Publishers.ensure(__MODULE__, channel),
         {:ok, conn} <- conn(pid) do
      Redix.command(conn, xadd_command(stream, fields, opts[:maxlen]), timeout: timeout)
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "The `XADD` command of an entry."
  @spec xadd_command(String.t(), [String.t()], pos_integer() | nil) :: [String.t()]
  def xadd_command(stream, fields, nil), do: ["XADD", stream, "*" | fields]

  def xadd_command(stream, fields, maxlen),
    do: ["XADD", stream, "MAXLEN", "~", Integer.to_string(maxlen), "*" | fields]

  defp conn(pid) do
    {:ok, GenServer.call(pid, :conn)}
  catch
    :exit, reason -> {:error, {:publisher_down, reason}}
  end

  @impl true
  def init(channel) do
    Process.flag(:trap_exit, true)

    case RedisStreams.connect(channel.config || %{}) do
      {:ok, conn} ->
        Process.link(conn)
        idle_ms = Publishers.idle_ms()
        {:ok, %{conn: conn, idle_ms: idle_ms}, idle_ms}

      # {:target_blocked, _} and {:invalid_config, _} are permanent, see
      # RedisStreams.normalize_error/1.
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:conn, _from, state), do: {:reply, state.conn, state, state.idle_ms}

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}

  def handle_info({:EXIT, conn, reason}, %{conn: conn} = state) do
    Logger.warning("Redis publisher connection closed", reason: inspect(reason))
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state, state.idle_ms}

  @impl true
  def terminate(_reason, %{conn: conn}) do
    if Process.alive?(conn), do: Redix.stop(conn)
    :ok
  catch
    :exit, _ -> :ok
  end
end
