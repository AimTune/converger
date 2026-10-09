defmodule ConvergerWeb.Drain do
  @moduledoc """
  Node draining on shutdown.

  Started as the last child of the application supervisor, so on shutdown it
  is stopped first, while the endpoint still serves every socket. Its
  `terminate/2` marks the node as draining and waits
  `:drain_delay_ms`; meanwhile `GET /health/ready` answers 503 (the load
  balancer stops routing here) and new client sockets are refused with 503
  (`ConvergerWeb.SocketGuard`). Then the endpoint stops and Phoenix's socket
  drainer closes the remaining sockets in batches of `:drain_batch_size`
  every `:drain_batch_interval_ms`, each with close code 1012 and a jittered
  `retryAfterMs` (`ConvergerWeb.SocketGuard`).
  """

  use GenServer

  require Logger

  @key {__MODULE__, :draining}

  @doc "Whether this node is draining (shutting down)."
  @spec draining?() :: boolean()
  def draining?, do: :persistent_term.get(@key, false)

  @doc "Marks the node as draining. Called on shutdown; exposed for tests."
  @spec start_draining() :: :ok
  def start_draining do
    if not draining?() do
      :persistent_term.put(@key, true)
      :telemetry.execute([:converger, :drain, :start], %{system_time: System.system_time()}, %{})
    end

    :ok
  end

  @doc false
  # Test helper: undo `start_draining/0`.
  def reset do
    _ = :persistent_term.erase(@key)
    :ok
  end

  @doc """
  Options for Phoenix's socket drainer (`drainer:` on each socket mount),
  read from `config :converger, :websocket` at startup.
  """
  @spec drainer_config() :: keyword()
  def drainer_config do
    [
      batch_size: config(:drain_batch_size),
      batch_interval: config(:drain_batch_interval_ms),
      shutdown: config(:drain_shutdown_ms)
    ]
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      # terminate/2 sleeps for the drain delay
      shutdown: config(:drain_delay_ms) + 5_000
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state) do
    delay = config(:drain_delay_ms)
    Logger.info("Draining: readiness is now 503, closing sockets in #{delay} ms")
    start_draining()
    Process.sleep(delay)
  end

  defp config(key), do: Application.fetch_env!(:converger, :websocket)[key]
end
