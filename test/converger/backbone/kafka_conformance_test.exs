defmodule Converger.Backbone.KafkaConformanceTest do
  @moduledoc """
  The backbone conformance suite against Kafka (issue #66). Excluded by
  default, like the broker channel suites (docs/channels/brokers.md):

      docker run -d --name kafka -p 9092:9092 apache/kafka:3.9.1
      KAFKA_BROKERS=localhost:9092 mix test --only kafka

  `:brod` needs its CRC32C NIF (`crc32cer`), which is not built on Windows:
  run this suite on Linux or macOS, or in a container.
  """

  use ExUnit.Case, async: false

  @moduletag :kafka
  @moduletag timeout: 600_000

  use Converger.BackboneConformance,
    backbone: Converger.Backbone.Kafka,
    ordered: true,
    timeout: 90_000

  import Converger.BackboneBrokerCase

  setup_all do
    start_backbone(Converger.Backbone.Kafka,
      brokers: System.get_env("KAFKA_BROKERS", "localhost:9092"),
      partitions: 3,
      replication_factor: 1,
      start_offset: "earliest",
      # A killed member is noticed within seconds, not the 45 s default.
      group_config: [session_timeout_seconds: 6, heartbeat_rate_seconds: 1]
    )
  end

  setup do
    await_ready(600)
    %{run: run_id()}
  end

  defp await_ready(0), do: flunk("Kafka backbone topics were not created")

  defp await_ready(tries) do
    unless Converger.Backbone.Kafka.Client.ready?() do
      Process.sleep(100)
      await_ready(tries - 1)
    end
  end

  def deliver(_context), do: :ok

  def crash_consumers(_context, subscription), do: kill_consumers(subscription)
end
