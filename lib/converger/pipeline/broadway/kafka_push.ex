defmodule Converger.Pipeline.Broadway.KafkaPush do
  @moduledoc """
  Kafka message push module.

  Requires `{:brod, "~> 3.16"}` or `{:broadway_kafka, "~> 0.4"}` in your deps.

  ## Configuration

      config :converger, :pipeline,
        backend: Converger.Pipeline.Broadway,
        broadway: [
          producer: :kafka,
          kafka: [
            hosts: [localhost: 9092],
            group_id: "converger_pipeline",
            topics: ["converger.activities"],
            topic: "converger.activities",
            client_id: :converger_kafka_client
          ]
        ]
  """

  @behaviour Converger.Pipeline.Broadway.PushBehaviour

  @impl true
  def push(message, config) do
    topic = Keyword.get(config, :topic, "converger.activities")
    client_id = Keyword.get(config, :client_id, :converger_kafka_client)

    case Code.ensure_loaded(:brod) do
      {:module, :brod} ->
        apply(:brod, :produce_sync, [
          client_id,
          topic,
          :hash,
          message.activity_id,
          Jason.encode!(message)
        ])

        :ok

      {:error, _} ->
        raise """
        Kafka push requires the :brod library.
        Add {:brod, "~> 3.16"} to your mix.exs dependencies.
        """
    end
  end
end
