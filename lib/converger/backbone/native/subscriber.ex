defmodule Converger.Backbone.Native.Subscriber do
  @moduledoc """
  A broadcast subscription on the Native backbone: subscribes to the
  `Phoenix.PubSub` topics of the subscription's topics on this node and
  hands every event to the handler, in this process (so in publish order
  per publishing node). Best effort.
  """

  use GenServer, restart: :transient

  alias Converger.Backbone.{Dispatch, Native, Subscription}

  def start_link(%Subscription{} = subscription),
    do: GenServer.start_link(__MODULE__, subscription)

  @impl true
  def init(subscription) do
    for topic <- subscription.topics do
      :ok = Phoenix.PubSub.subscribe(Converger.PubSub, Native.pubsub_topic(topic))
    end

    {:ok, subscription}
  end

  @impl true
  def handle_info({:backbone_event, event}, subscription) do
    _ = Dispatch.consume(subscription, event)
    {:noreply, subscription}
  end

  def handle_info(_message, subscription), do: {:noreply, subscription}
end
