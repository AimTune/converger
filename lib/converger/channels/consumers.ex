defmodule Converger.Channels.Consumers do
  @moduledoc """
  The `DynamicSupervisor` of broker channel consumers
  (`Converger.Channels.Broker.Consumer`, one per active `inbound` or
  `duplex` broker channel, exactly one in the cluster), and the functions to
  start, stop and find them.

  `Converger.Channels.Consumers.Manager` keeps the running consumers in line
  with the channels: it starts and stops them as channels are created,
  updated, enabled, disabled or deleted (`notify_changed/1`, called by
  `Converger.Channels`), and reconciles periodically.

  ## Configuration

      config :converger, :broker_channels,
        # Run the consumer manager on this node (BROKER_CONSUMERS=false to
        # keep consumers off a node, e.g. web-only nodes).
        consumers: true,
        reconcile_interval_ms: 30_000
  """

  use DynamicSupervisor

  require Logger

  alias Converger.Channels.Broker
  alias Converger.Channels.Broker.Consumer

  @topic "broker_consumers"

  def start_link(arg), do: DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Children for the application supervisor: the consumer supervisor, and the
  manager when consumers are enabled on this node.
  """
  def child_specs do
    if enabled?(),
      do: [__MODULE__, Converger.Channels.Consumers.Manager],
      else: [__MODULE__]
  end

  @doc "Whether this node runs broker consumers (`config :converger, :broker_channels, consumers:`)."
  def enabled? do
    Keyword.get(Application.get_env(:converger, :broker_channels, []), :consumers, true) == true
  end

  @doc "The PubSub topic of channel change notifications."
  def topic, do: @topic

  @doc """
  Tell the consumer managers of every node that a channel was created,
  updated or deleted, so its consumer is started, restarted or stopped.
  """
  @spec notify_changed(String.t()) :: :ok
  def notify_changed(channel_id) do
    Phoenix.PubSub.broadcast(Converger.PubSub, @topic, {:channel_changed, channel_id})
  end

  @doc """
  Start the consumer of `channel` on this node. Returns `{:ok, pid}`,
  `{:error, {:already_started, pid}}` when it runs on any node, or
  `{:error, reason}`.
  """
  @spec start_consumer(Converger.Channels.Channel.t()) :: {:ok, pid()} | {:error, term()}
  def start_consumer(channel) do
    if Broker.consumes?(channel) do
      DynamicSupervisor.start_child(__MODULE__, {Consumer, channel})
    else
      {:error, :not_a_consumer_channel}
    end
  end

  @doc "Stop the consumer of `channel_id` if it runs on this node."
  @spec stop_consumer(String.t()) :: :ok
  def stop_consumer(channel_id) do
    case local(channel_id) do
      {pid, _fingerprint} -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      nil -> :ok
    end

    :ok
  end

  @doc "The consumer of `channel_id` on this node as `{pid, fingerprint}`, or nil."
  @spec local(String.t()) :: {pid(), integer()} | nil
  def local(channel_id) do
    # The registry drops a dead process asynchronously.
    case Registry.lookup(Converger.Channels.Broker.Registry, {:consumer, channel_id}) do
      [{pid, fingerprint}] -> if Process.alive?(pid), do: {pid, fingerprint}
      [] -> nil
    end
  end

  @doc "The channel ids of the consumers running on this node."
  @spec local_channel_ids() :: [String.t()]
  def local_channel_ids do
    Registry.select(Converger.Channels.Broker.Registry, [
      {{{:consumer, :"$1"}, :_, :_}, [], [:"$1"]}
    ])
  end

  @doc "The node the consumer of `channel_id` runs on, or nil."
  @spec node_of(String.t()) :: node() | nil
  def node_of(channel_id) do
    case Consumer.whereis(channel_id) do
      nil -> nil
      pid -> node(pid)
    end
  end
end
