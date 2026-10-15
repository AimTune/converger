defmodule Converger.Backbone.Registry do
  @moduledoc """
  The subscriptions declared on this node (`Converger.Backbone.subscribe/3`),
  by name, in an ETS table owned by this process.

  Every node declares the same built-in and configured subscriptions at
  boot (`Converger.Backbone.Bootstrap`). The Native backbone reads the
  table when an event is published (which shared subscriptions get a job)
  and when a job runs (which handler handles it); the broker backbones
  find a subscription's consumer here.
  """

  use GenServer

  alias Converger.Backbone.Subscription

  @table :converger_backbone_subscriptions
  @state :converger_backbone_state

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@state, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc "Declare (or replace) a subscription."
  @spec put(Subscription.t()) :: :ok
  def put(%Subscription{name: name} = subscription) do
    true = :ets.insert(@table, {name, subscription})
    :ok
  end

  @doc "Remove a subscription."
  @spec delete(String.t()) :: :ok
  def delete(name) do
    :ets.delete(@table, name)
    :ok
  end

  @doc "A subscription by name, or nil."
  @spec get(String.t()) :: Subscription.t() | nil
  def get(name) do
    case :ets.lookup(@table, name) do
      [{^name, subscription}] -> subscription
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Every declared subscription."
  @spec all() :: [Subscription.t()]
  def all do
    for {_name, subscription} <- :ets.tab2list(@table), do: subscription
  rescue
    ArgumentError -> []
  end

  @doc """
  Remember that `backbone` failed a publish: until `ms` from now publishes
  to it are parked at once (`Converger.Backbone.publish_to/2`).
  """
  @spec mark_down(module(), non_neg_integer()) :: :ok
  def mark_down(backbone, ms) do
    :ets.insert(@state, {{:down_until, backbone}, System.monotonic_time(:millisecond) + ms})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Forget a failure of `backbone` (a publish to it succeeded)."
  @spec mark_up(module()) :: :ok
  def mark_up(backbone) do
    :ets.delete(@state, {:down_until, backbone})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Whether `backbone` failed a publish less than its down window ago."
  @spec down?(module()) :: boolean()
  def down?(backbone) do
    case :ets.lookup(@state, {:down_until, backbone}) do
      [{_, until}] -> System.monotonic_time(:millisecond) < until
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc "The shared subscriptions of `topic`."
  @spec shared_for(Converger.Backbone.topic()) :: [Subscription.t()]
  def shared_for(topic) do
    for %Subscription{mode: :shared} = subscription <- all(),
        Subscription.topic?(subscription, topic),
        do: subscription
  end
end
