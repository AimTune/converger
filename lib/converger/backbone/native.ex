defmodule Converger.Backbone.Native do
  @moduledoc """
  The default backbone: no service besides Postgres and Erlang distribution.

    * **Shared subscriptions** are Oban jobs (`Converger.Workers.BackboneEventWorker`,
      queue `backbone`): `publish/2` inserts one job per declared shared
      subscription that accepts the event (`Converger.Backbone.Dispatch.accept?/2`
      runs at publish time, so an unwanted event costs no job). Oban runs
      them on any node, retries them with backoff and rescues jobs of a
      crashed node (Lifeline). At least once; with the subscription's
      receipts, handled once.
    * **Broadcast subscriptions** receive the event over `Phoenix.PubSub`
      (topic `backbone:<topic>`) on every node. Best effort: a node that is
      down misses what was published meanwhile.

  `publish/2` can run inside a `Converger.Repo` transaction: the jobs then
  commit or roll back with it (a transactional outbox).

  Shared subscriptions are declared per node (`Converger.Backbone.Registry`):
  every node declares the same ones at boot, so whichever node publishes
  enqueues a job for each.
  """

  @behaviour Converger.Backbone

  alias Converger.Backbone.{Dispatch, Event, Registry, Subscription}
  alias Converger.Workers.BackboneEventWorker

  @impl true
  def guarantee, do: :at_least_once

  @impl true
  def child_specs, do: []

  @impl true
  def publish(topic, %Event{} = event) do
    Phoenix.PubSub.broadcast(Converger.PubSub, pubsub_topic(topic), {:backbone_event, event})

    jobs =
      for subscription <- Registry.shared_for(topic),
          Dispatch.accept?(subscription, event),
          do: job(subscription, event)

    case jobs do
      [] ->
        :ok

      jobs ->
        _ = Oban.insert_all(jobs)
        :ok
    end
  end

  @doc "The job of `event` for a shared `subscription`."
  def job(%Subscription{name: name}, %Event{} = event) do
    BackboneEventWorker.new(%{"subscription" => name, "event" => Event.to_map(event)})
  end

  @doc "The PubSub topic of broadcast subscriptions to `topic`."
  def pubsub_topic(topic), do: "backbone:#{topic}"

  @impl true
  def subscribe(%Subscription{mode: :shared} = subscription), do: {:ok, subscription}

  def subscribe(%Subscription{mode: :broadcast} = subscription) do
    case DynamicSupervisor.start_child(
           Converger.Backbone.Consumers,
           {Converger.Backbone.Native.Subscriber, subscription}
         ) do
      {:ok, pid} -> {:ok, %{subscription | ref: pid}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def unsubscribe(%Subscription{ref: pid}) when is_pid(pid) do
    _ = DynamicSupervisor.terminate_child(Converger.Backbone.Consumers, pid)
    :ok
  end

  def unsubscribe(_subscription), do: :ok
end
