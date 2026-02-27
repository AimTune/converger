defmodule Converger.Pipeline.Broadway do
  @moduledoc """
  Broadway-based pipeline backend with configurable producer.

  Uses Broadway for stream processing with backpressure.
  Supports multiple producers: in-memory (default), Kafka, RabbitMQ.

  ## Configuration

      # In-memory producer (dev/staging - no external dependency):
      config :converger, :pipeline,
        backend: Converger.Pipeline.Broadway,
        broadway: [
          producer: :memory
        ]

      # Kafka producer (production - requires {:broadway_kafka, "~> 0.4"}):
      config :converger, :pipeline,
        backend: Converger.Pipeline.Broadway,
        broadway: [
          producer: :kafka,
          kafka: [
            hosts: [localhost: 9092],
            group_id: "converger_pipeline",
            topics: ["converger.activities"]
          ]
        ]

      # RabbitMQ producer (requires {:broadway_rabbitmq, "~> 0.8"}):
      config :converger, :pipeline,
        backend: Converger.Pipeline.Broadway,
        broadway: [
          producer: :rabbitmq,
          rabbitmq: [
            queue: "converger.activities",
            connection: [host: "localhost"]
          ]
        ]

      # Custom producer (any module implementing a push/1 function):
      config :converger, :pipeline,
        backend: Converger.Pipeline.Broadway,
        broadway: [
          producer: :custom,
          custom: [
            push_module: MyApp.CustomProducer,
            broadway_producer: {MyApp.BroadwayProducer, []}
          ]
        ]

  ## Optional Dependencies

  Kafka and RabbitMQ require additional packages:
  - Kafka:    `{:broadway_kafka, "~> 0.4"}`
  - RabbitMQ: `{:broadway_rabbitmq, "~> 0.8"}`

  These are NOT included by default. Add them to your mix.exs when needed.
  """

  @behaviour Converger.Pipeline

  require Logger

  @impl true
  def child_specs do
    config = pipeline_config()
    producer_config = build_producer_config(config)

    [
      {Converger.Pipeline.Broadway.Pipeline,
       name: Converger.Pipeline.Broadway.Pipeline,
       producer: producer_config,
       processors: [
         default: [concurrency: Keyword.get(config, :processor_concurrency, 10)]
       ],
       batchers: [
         delivery: [
           concurrency: Keyword.get(config, :delivery_concurrency, 5),
           batch_size: Keyword.get(config, :delivery_batch_size, 10),
           batch_timeout: Keyword.get(config, :delivery_batch_timeout, 1000)
         ]
       ]}
    ]
  end

  @impl true
  def process(activity) do
    # Broadcast inline (fast, no queuing needed)
    Converger.Pipeline.broadcast(activity)

    # Push to Broadway pipeline for delivery
    case Converger.Pipeline.resolve_delivery_channel(activity) do
      nil ->
        :ok

      channel ->
        message = %{
          activity_id: activity.id,
          channel_id: channel.id,
          channel_type: channel.type
        }

        push_message(message)
    end
  end

  defp push_message(message) do
    config = pipeline_config()

    case Keyword.get(config, :producer, :memory) do
      :memory ->
        Converger.Pipeline.Broadway.MemoryProducer.push(message)
        :ok

      :kafka ->
        push_module = resolve_push_module(:kafka, config)
        push_module.push(message, Keyword.get(config, :kafka, []))

      :rabbitmq ->
        push_module = resolve_push_module(:rabbitmq, config)
        push_module.push(message, Keyword.get(config, :rabbitmq, []))

      :custom ->
        custom_config = Keyword.get(config, :custom, [])
        push_module = Keyword.fetch!(custom_config, :push_module)
        push_module.push(message, custom_config)
    end
  end

  defp resolve_push_module(:kafka, config) do
    Keyword.get_lazy(config, :kafka_push_module, fn ->
      Converger.Pipeline.Broadway.KafkaPush
    end)
  end

  defp resolve_push_module(:rabbitmq, config) do
    Keyword.get_lazy(config, :rabbitmq_push_module, fn ->
      Converger.Pipeline.Broadway.RabbitmqPush
    end)
  end

  defp build_producer_config(config) do
    case Keyword.get(config, :producer, :memory) do
      :memory ->
        [module: {Converger.Pipeline.Broadway.MemoryProducer, []}]

      :kafka ->
        kafka_config = Keyword.get(config, :kafka, [])

        broadway_producer =
          Keyword.get_lazy(kafka_config, :broadway_producer, fn ->
            {Module.concat([:BroadwayKafka, :Producer]),
             [
               hosts: Keyword.get(kafka_config, :hosts, localhost: 9092),
               group_id: Keyword.get(kafka_config, :group_id, "converger_pipeline"),
               topics: Keyword.get(kafka_config, :topics, ["converger.activities"])
             ]}
          end)

        [module: broadway_producer]

      :rabbitmq ->
        rabbitmq_config = Keyword.get(config, :rabbitmq, [])

        broadway_producer =
          Keyword.get_lazy(rabbitmq_config, :broadway_producer, fn ->
            {Module.concat([:BroadwayRabbitMQ, :Producer]),
             [
               queue: Keyword.get(rabbitmq_config, :queue, "converger.activities"),
               connection: Keyword.get(rabbitmq_config, :connection, host: "localhost")
             ]}
          end)

        [module: broadway_producer]

      :custom ->
        custom_config = Keyword.get(config, :custom, [])
        [module: Keyword.fetch!(custom_config, :broadway_producer)]
    end
  end

  defp pipeline_config do
    Application.get_env(:converger, :pipeline, [])
    |> Keyword.get(:broadway, [])
  end
end
