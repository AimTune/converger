defmodule Converger.Backbone do
  @moduledoc """
  The event backbone (issue #66, ADR-0070): where Converger publishes what
  happened (activities, delivery status changes, conversation, channel and
  participant events) and where its own consumers and downstream systems
  subscribe to it.

  ## Topics

  | Topic | Broker name (prefix `converger`) | Events |
  | --- | --- | --- |
  | `:activities` | `converger.activities` | `activity.created` |
  | `:deliveries` | `converger.deliveries` | `delivery.sent`, `.delivered`, `.read`, `.failed` |
  | `:events` | `converger.events` | `conversation.*`, `channel.*`, `participant.*` |

  Events are keyed by conversation (`Converger.Backbone.Event`): a
  conversation's events keep their order on every backbone.

  ## Implementations

  The backbone is a behaviour; one implementation is selected per
  deployment, with a single config change:

      config :converger, :backbone, Converger.Backbone.Native   # default
      # config :converger, :backbone, Converger.Backbone.Kafka
      # config :converger, :backbone, Converger.Backbone.Nats
      # config :converger, :backbone, Converger.Backbone.RabbitMQ

  (`BACKBONE=native|kafka|nats|rabbitmq` in `config/runtime.exs`.)

  | Backbone | Shared subscriptions | Broadcast subscriptions | Extra services |
  | --- | --- | --- | --- |
  | `Native` | Oban jobs on Postgres | `Phoenix.PubSub` | none |
  | `Kafka` | one consumer group per subscription | a consumer group per node | Kafka / Redpanda |
  | `Nats` | a JetStream durable consumer per subscription | a durable consumer per node | NATS with JetStream |
  | `RabbitMQ` | a durable queue per subscription | an auto-delete queue per node | RabbitMQ |

  Every implementation declares `:at_least_once` for shared subscriptions;
  broadcast subscriptions are best effort everywhere. Subscriptions with
  `dedup: true` handle each event id once (`Converger.Backbone.Dispatch`).

  ## What is on the backbone, what is not

  Platform events (`Converger.Webhooks.emit/3`) are published here, and the
  platform event webhooks consume them (`Converger.Webhooks.BackboneHandler`).
  Channel deliveries stay on the delivery pipeline (`Converger.Pipeline`):
  their jobs are inserted in the transaction that stores the activity, which
  no broker can join. The WebSocket fan-out stays on `Phoenix.PubSub`
  (presence, signals and replies need Erlang distribution anyway, and a
  broker hop would add latency to the real-time path). See ADR-0070.

  ## Publishing never loses an acknowledged event

  `publish/2` returns `:ok` once the backbone accepted the event. When a
  broker is unreachable the event is parked in Postgres
  (`Converger.Workers.BackbonePublishWorker`) and published later, so
  callers never lose events to a broker outage; for `down_ms` (5 s) after a
  failure, publishes to that broker are parked without trying it. While
  migrating between backbones the events can also be published to
  `:mirror` backbones (dual publish, see docs/deployment.md).

  ## Configuration

      config :converger, Converger.Backbone,
        topic_prefix: "converger",
        mirror: [],              # e.g. [Converger.Backbone.Kafka] while migrating
        consumers: true,         # run this node's consumers (BACKBONE_CONSUMERS)
        subscriptions: []        # extra subscriptions: [{name, topics, handler, opts}]
  """

  require Logger

  alias Converger.Backbone.{Event, Native, Registry, Subscription}
  alias Converger.Workers.BackbonePublishWorker

  @type topic :: :activities | :deliveries | :events
  @type guarantee :: :at_least_once | :best_effort

  @topics [:activities, :deliveries, :events]

  @backbones %{
    "native" => Converger.Backbone.Native,
    "kafka" => Converger.Backbone.Kafka,
    "nats" => Converger.Backbone.Nats,
    "rabbitmq" => Converger.Backbone.RabbitMQ
  }

  @doc "Publish `event` to `topic`. Returns once the backbone has accepted it."
  @callback publish(topic(), Event.t()) :: :ok | {:error, term()}

  @doc """
  Start consuming for `subscription` on this node. Returns the subscription
  with its `ref` (the consumer process, if any).
  """
  @callback subscribe(Subscription.t()) :: {:ok, Subscription.t()} | {:error, term()}

  @doc "Stop this node's consumer of `subscription`."
  @callback unsubscribe(Subscription.t()) :: :ok

  @doc "The delivery guarantee of shared subscriptions."
  @callback guarantee() :: guarantee()

  @doc "Processes the implementation needs (clients, connections)."
  @callback child_specs() :: [Supervisor.child_spec() | {module(), term()} | module()]

  @doc "Every topic."
  @spec topics() :: [topic()]
  def topics, do: @topics

  @doc "Parse a topic name (`\"activities\"`)."
  @spec parse_topic(String.t() | atom()) :: {:ok, topic()} | {:error, :unknown_topic}
  def parse_topic(topic) when topic in @topics, do: {:ok, topic}

  def parse_topic(topic) when is_binary(topic) do
    case Enum.find(@topics, &(Atom.to_string(&1) == topic)) do
      nil -> {:error, :unknown_topic}
      found -> {:ok, found}
    end
  end

  def parse_topic(_topic), do: {:error, :unknown_topic}

  @doc "The broker name of `topic`: `<topic_prefix>.<topic>`."
  @spec topic_name(topic()) :: String.t()
  def topic_name(topic) when topic in @topics, do: "#{topic_prefix()}.#{topic}"

  @doc "The topic prefix (`config :converger, Converger.Backbone, topic_prefix:`)."
  def topic_prefix, do: config(:topic_prefix, "converger")

  @doc "The topic a platform event type is published to."
  @spec topic_for_type(String.t()) :: topic()
  def topic_for_type("activity." <> _), do: :activities
  def topic_for_type("delivery." <> _), do: :deliveries
  def topic_for_type(_type), do: :events

  @doc "The selected implementation (`config :converger, :backbone`)."
  @spec impl() :: module()
  def impl do
    case Application.get_env(:converger, :backbone, Converger.Backbone.Native) do
      module when is_atom(module) and not is_nil(module) -> module
      _ -> Converger.Backbone.Native
    end
  end

  @doc "The backbones events are also published to (dual publish)."
  @spec mirrors() :: [module()]
  def mirrors, do: config(:mirror, []) |> List.wrap() |> Enum.reject(&(&1 == impl()))

  @doc "The delivery guarantee of the selected backbone."
  @spec guarantee() :: guarantee()
  def guarantee, do: impl().guarantee()

  @doc "The implementation module of a backbone name (`kafka`), or nil."
  @spec module_for(String.t()) :: module() | nil
  def module_for(name), do: Map.get(@backbones, name)

  @doc "The name of a backbone implementation (`Converger.Backbone.Kafka` -> `kafka`)."
  @spec name_of(module()) :: String.t() | nil
  def name_of(module) do
    Enum.find_value(@backbones, fn {name, mod} -> if mod == module, do: name end)
  end

  @doc """
  Publish an event to `topic` on the selected backbone and its mirrors.

  `event` is an `Event` or the attributes of `Event.new/2` (`:type` and
  `:data` at least). Returns `:ok` when the backbone accepted it or it was
  parked for a later publish, `{:error, reason}` when neither worked.
  """
  @spec publish(topic(), Event.t() | map() | keyword()) :: :ok | {:error, term()}
  def publish(topic, %Event{} = event) when topic in @topics do
    event = %{event | topic: topic}
    result = publish_to(impl(), event)
    Enum.each(mirrors(), &publish_to(&1, event))
    result
  end

  def publish(topic, attrs) when topic in @topics, do: publish(topic, Event.new(topic, attrs))

  @doc """
  Publish `event` as part of the caller's `Converger.Repo` transaction: a
  transactional outbox. The event is stored with the transaction, so it is
  published exactly when the transaction commits, even when the node dies
  right after the commit.

    * Native: the shared subscriptions' jobs are inserted in the transaction.
    * A broker (and any mirror): a `Converger.Workers.BackbonePublishWorker`
      job is inserted in the transaction and publishes the event once the
      transaction committed (the broker cannot join the transaction). The
      event keeps its id, so a retried publish is a duplicate the
      subscriptions' receipts skip.

  Raises when the outbox insert fails, so the transaction rolls back rather
  than committing without its event. Call `after_commit/1` with the returned
  event once the transaction committed (broadcast subscriptions, best
  effort).
  """
  @spec publish_in_transaction(topic(), Event.t() | map() | keyword()) :: Event.t()
  def publish_in_transaction(topic, %Event{} = event) when topic in @topics do
    unless Converger.Repo.in_transaction?() do
      raise ArgumentError, "publish_in_transaction/2 must run inside a Repo transaction"
    end

    event = %{event | topic: topic}
    Enum.each([impl() | mirrors()], &outbox(&1, event))
    event
  end

  def publish_in_transaction(topic, attrs) when topic in @topics,
    do: publish_in_transaction(topic, Event.new(topic, attrs))

  @doc """
  After the transaction of `publish_in_transaction/2` committed: deliver the
  event to the Native broadcast subscriptions (they are not in the outbox).
  """
  @spec after_commit(Event.t() | nil) :: :ok
  def after_commit(%Event{} = event) do
    if Native in [impl() | mirrors()],
      do: Native.broadcast(event.topic, event)

    :ok
  end

  def after_commit(nil), do: :ok

  defp outbox(Native, event),
    do: Native.enqueue(event.topic, event)

  defp outbox(module, event) do
    %{"backbone" => name_of(module), "event" => Event.to_map(event)}
    |> BackbonePublishWorker.new()
    |> Oban.insert!()

    :ok
  end

  @doc """
  Publish `event` to one backbone `module`, parking it in Postgres when the
  backbone refuses it. Used by `publish/2` and the parked-publish worker.
  """
  @spec publish_to(module(), Event.t()) :: :ok | {:error, term()}
  def publish_to(module, %Event{} = event) do
    if Registry.down?(module) do
      # The broker failed a moment ago: park at once instead of making every
      # caller wait for the produce timeout again.
      park(module, event, :backbone_down)
    else
      case do_publish(module, event) do
        :ok ->
          :ok

        {:error, reason} ->
          if module != Converger.Backbone.Native,
            do: Registry.mark_down(module, config(:down_ms, 5_000))

          park(module, event, reason)
      end
    end
  end

  @doc false
  def do_publish(module, event) do
    metadata = %{
      backbone: name_of(module) || inspect(module),
      topic: event.topic,
      type: event.type
    }

    :telemetry.span([:converger, :backbone, :publish], metadata, fn ->
      result =
        try do
          module.publish(event.topic, event)
        rescue
          error -> {:error, error}
        catch
          :exit, reason -> {:error, {:exit, reason}}
        end

      if result == :ok, do: Registry.mark_up(module)
      {result, Map.put(metadata, :result, if(result == :ok, do: :ok, else: :error))}
    end)
  end

  defp park(Converger.Backbone.Native, event, reason) do
    # The Native backbone is Postgres: parking in Postgres cannot help.
    Logger.error("Backbone publish failed",
      backbone: "native",
      event_id: event.id,
      type: event.type,
      error: inspect(reason)
    )

    {:error, reason}
  end

  defp park(module, event, reason) do
    Logger.warning("Backbone publish failed; parked in Postgres for a later publish",
      backbone: name_of(module),
      event_id: event.id,
      type: event.type,
      error: inspect(reason)
    )

    %{"backbone" => name_of(module), "event" => Event.to_map(event)}
    |> BackbonePublishWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, park_error} -> {:error, {reason, park_error}}
    end
  rescue
    error -> {:error, {reason, error}}
  end

  @doc """
  Subscribe `handler` to `topics` on the selected backbone (see
  `Converger.Backbone.Subscription` for `opts`; `:name` is required).

  The subscription is declared on this node (`Converger.Backbone.Registry`)
  and its consumer started. Declare the same subscriptions on every node:
  the built-in and configured ones are (`Converger.Backbone.Bootstrap`).
  """
  @spec subscribe(topic() | [topic()], Subscription.handler(), keyword()) ::
          {:ok, Subscription.t()} | {:error, term()}
  def subscribe(topics, handler, opts) do
    {backbone, opts} = Keyword.pop(opts, :backbone, impl())

    with {:ok, subscription} <- Subscription.new(topics, handler, opts) do
      :ok = Registry.put(subscription)

      case backbone.subscribe(subscription) do
        {:ok, subscription} ->
          :ok = Registry.put(subscription)
          {:ok, subscription}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc "Stop and forget a subscription on this node."
  @spec unsubscribe(Subscription.t() | String.t(), keyword()) :: :ok
  def unsubscribe(subscription, opts \\ [])

  def unsubscribe(name, opts) when is_binary(name) do
    case Registry.get(name) do
      nil -> :ok
      subscription -> unsubscribe(subscription, opts)
    end
  end

  def unsubscribe(%Subscription{} = subscription, opts) do
    backbone = Keyword.get(opts, :backbone, impl())
    current = Registry.get(subscription.name) || subscription
    :ok = backbone.unsubscribe(current)
    Registry.delete(subscription.name)
  end

  @doc """
  The subscriptions every node declares at boot: the platform event
  webhooks, then `config :converger, Converger.Backbone, subscriptions:`
  entries `{name, topics, handler, opts}`.
  """
  @spec boot_subscriptions() :: [{String.t(), [topic()], Subscription.handler(), keyword()}]
  def boot_subscriptions do
    [{"webhooks", @topics, Converger.Webhooks.BackboneHandler, []}] ++ config(:subscriptions, [])
  end

  @doc "Whether this node runs consumers (`BACKBONE_CONSUMERS`)."
  def consumers?, do: config(:consumers, true) == true

  @doc """
  Children for the application supervisor: the subscription registry, the
  consumer supervisor, the selected backbone's and its mirrors' processes,
  and the bootstrap that declares the boot subscriptions.
  """
  def child_specs do
    [
      Registry,
      {DynamicSupervisor,
       name: Converger.Backbone.Consumers,
       strategy: :one_for_one,
       max_restarts: 20,
       max_seconds: 60}
    ] ++
      Enum.flat_map([impl() | mirrors()], & &1.child_specs()) ++
      [Converger.Backbone.Bootstrap]
  end

  @doc false
  def config(key, default) do
    :converger |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
