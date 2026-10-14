defmodule Converger.Backbone.RabbitMQ do
  @moduledoc """
  RabbitMQ as the event backbone.

    * **Exchange**: one durable `topic` exchange named after the topic
      prefix (`converger`); an event is published with the routing key
      `<prefix>.<topic>` (`converger.activities`).
    * **Publish**: persistent message (`delivery_mode: 2`), `message_id` =
      the event id, headers `x-converger-event-id`, `x-converger-event`,
      `x-converger-tenant-id`, on a channel in confirm mode: returns once the
      broker confirmed it.
    * **Shared subscriptions**: a durable queue per subscription
      (`<prefix>.<subscription>`) bound to its topics' routing keys,
      consumed by a Broadway pipeline (`BroadwayRabbitMQ.Producer`) on every
      node running consumers (competing consumers). Messages are acked after
      the event is handled or parked; a node that dies with unacked messages
      has them requeued, and the subscription's receipts skip those already
      handled.
    * **Broadcast subscriptions**: an auto-delete queue per node
      (`<prefix>.<subscription>.<node>`).

  A queue receives the events published after it was first declared: the
  boot subscriptions are declared before the node publishes anything.

  Ordering: with consumer `concurrency` above 1, events of a conversation may
  be handled out of order. Set the subscription's `concurrency: 1` when
  order matters.

  ## Configuration

      config :converger, Converger.Backbone.RabbitMQ,
        url: "amqp://rabbitmq:5672/%2f",   # amqps:// for TLS
        username: nil,
        password: nil,
        tls_verify: true,
        tls_ca_cert: nil,
        prefetch_count: 20,
        publish_timeout_ms: 10_000

  Set from `BACKBONE_RABBITMQ_*` in `config/runtime.exs`. The host comes from
  the operator, so the webhook SSRF guard does not apply to it.
  """

  @behaviour Converger.Backbone

  alias Converger.Backbone
  alias Converger.Backbone.{Event, Pipeline, Subscription}
  alias Converger.Backbone.RabbitMQ.Connection
  alias Converger.Channels.Adapters.RabbitMQ, as: RabbitMQAdapter

  @impl true
  def guarantee, do: :at_least_once

  @impl true
  def child_specs, do: [{Connection, config()}]

  @impl true
  def publish(topic, %Event{} = event) do
    Connection.publish(
      exchange(),
      Backbone.topic_name(topic),
      Event.encode(event),
      [
        persistent: true,
        content_type: "application/json",
        message_id: event.id,
        type: event.type,
        headers: for({name, value} <- Event.headers(event), do: {name, :longstr, value})
      ],
      Keyword.get(config(), :publish_timeout_ms, 10_000)
    )
  end

  @impl true
  def subscribe(%Subscription{} = subscription) do
    # The queue exists (and is bound) before this returns, so no event
    # published afterwards misses it; the consumer connects on its own.
    with {:ok, connection} <- connection_options(),
         :ok <- Connection.declare(subscription) do
      exchange = exchange()
      declare = queue_options(subscription)

      producer =
        {BroadwayRabbitMQ.Producer,
         [
           queue: queue(subscription),
           connection: connection,
           qos: [prefetch_count: Keyword.get(config(), :prefetch_count, 20)],
           declare: declare,
           bindings:
             for(
               topic <- subscription.topics,
               do: {exchange, [routing_key: Backbone.topic_name(topic)]}
             ),
           after_connect: fn chan -> declare_exchange(chan, exchange) end,
           on_failure: :reject_and_requeue,
           metadata: [:message_id, :redelivered]
         ]}

      case DynamicSupervisor.start_child(
             Converger.Backbone.Consumers,
             {Pipeline, {subscription, producer, []}}
           ) do
        {:ok, _pid} ->
          {:ok, %{subscription | ref: [Pipeline.name(subscription)]}}

        {:error, {:already_started, _pid}} ->
          {:ok, %{subscription | ref: [Pipeline.name(subscription)]}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def unsubscribe(%Subscription{ref: names}) when is_list(names),
    do: Pipeline.stop(names)

  def unsubscribe(_subscription), do: :ok

  @doc false
  def queue_options(%Subscription{mode: :broadcast}), do: [durable: false, auto_delete: true]
  def queue_options(_subscription), do: [durable: true]

  @doc "Declare the queue of `subscription` on `chan` and bind it to its topics."
  def declare_queue(chan, %Subscription{} = subscription) do
    queue = queue(subscription)

    with {:ok, _} <- AMQP.Queue.declare(chan, queue, queue_options(subscription)) do
      Enum.reduce_while(subscription.topics, :ok, fn topic, :ok ->
        case AMQP.Queue.bind(chan, queue, exchange(), routing_key: Backbone.topic_name(topic)) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc false
  def declare_exchange(chan, exchange) do
    AMQP.Exchange.declare(chan, exchange, :topic, durable: true)
  end

  @doc "The exchange (the topic prefix)."
  def exchange, do: Backbone.topic_prefix()

  @doc "The queue of a subscription."
  def queue(%Subscription{mode: :shared, name: name}), do: "#{Backbone.topic_prefix()}.#{name}"

  def queue(%Subscription{mode: :broadcast, name: name}),
    do: "#{Backbone.topic_prefix()}.#{name}.#{node()}"

  @doc "`AMQP.Connection.open/1` options, reusing the RabbitMQ channel adapter's parsing."
  def connection_options do
    config = config()

    RabbitMQAdapter.connection_options(%{
      "url" => Keyword.get(config, :url, "amqp://localhost:5672"),
      "username" => Keyword.get(config, :username),
      "password" => Keyword.get(config, :password),
      "tls_verify" => Keyword.get(config, :tls_verify, true),
      "tls_ca_cert" => Keyword.get(config, :tls_ca_cert)
    })
  end

  @doc false
  def config, do: Application.get_env(:converger, __MODULE__, [])
end
