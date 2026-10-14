defmodule Converger.Backbone.Kafka do
  @moduledoc """
  Kafka as the event backbone (also Redpanda and other Kafka-compatible
  brokers).

    * **Topics** `<prefix>.activities`, `<prefix>.deliveries`,
      `<prefix>.events` (prefix `converger`), created at boot when missing
      (`create_topics`, `partitions`, `replication_factor`).
    * **Publish**: a `:brod` producer (client `:converger_backbone_kafka`),
      `acks=all`, keyed by the event key (the conversation id): a
      conversation's events land on one partition, in order. The value is
      the JSON event (`Converger.Backbone.Event`), with headers
      `x-converger-event-id` (the idempotency key), `x-converger-event`,
      `x-converger-tenant-id`. Returns once the broker acknowledged it.
    * **Shared subscriptions**: a Broadway pipeline with a
      `BroadwayKafka.Producer` in consumer group `<prefix>.<subscription>` on
      every node running consumers; Kafka balances the partitions between
      the nodes. Offsets are committed after each event is handled (or
      parked), so a crashed node's uncommitted events are consumed again by
      the node that takes over its partitions, and the subscription's
      receipts skip what was already handled: exactly once, the "-ish".
    * **Broadcast subscriptions**: a consumer group per node
      (`<prefix>.<subscription>.<node>`) starting at the latest offset.

  ## Configuration

      config :converger, Converger.Backbone.Kafka,
        brokers: "kafka-1:9092,kafka-2:9092",
        sasl_mechanism: nil,           # "plain", "scram_sha_256", "scram_sha_512"
        sasl_username: nil,
        sasl_password: nil,
        tls: false,
        tls_verify: true,
        tls_ca_cert: nil,              # PEM; default: the OS trust store
        create_topics: true,
        partitions: 12,
        replication_factor: 1,
        start_offset: "earliest",      # where a new consumer group starts
        produce_timeout_ms: 10_000,
        producer_concurrency: 2,       # consumer group members per node and subscription
        fetch_config: [max_wait_time: 10],
        receive_interval: 100,
        group_config: []               # BroadwayKafka group options

  Set from `BACKBONE_KAFKA_*` in `config/runtime.exs`. Broker hosts come from
  the operator, so the webhook SSRF guard does not apply to them.

  `:brod` computes the record CRC32C with a NIF (`crc32cer`) that is not
  built on Windows: run the Kafka backbone on Linux or macOS (or a container).
  """

  @behaviour Converger.Backbone

  alias Converger.Backbone
  alias Converger.Backbone.{Event, Pipeline, Subscription}
  alias Converger.Channels.Adapters.Kafka, as: KafkaAdapter

  @impl true
  def guarantee, do: :at_least_once

  @impl true
  def child_specs, do: [{Converger.Backbone.Kafka.Client, config()}]

  @impl true
  def publish(topic, %Event{} = event) do
    client = client()
    name = Backbone.topic_name(topic)
    key = event.key || event.id
    timeout = Keyword.get(config(), :produce_timeout_ms, 10_000)

    message = %{
      ts: System.system_time(:millisecond),
      value: Event.encode(event),
      headers: Event.headers(event)
    }

    produce(client, name, key, message, timeout, 1)
  end

  # A topic created a moment ago (or a partition whose leader moved) answers
  # with a transient metadata error for a short while: retried briefly here;
  # anything longer parks the event (Converger.Backbone.publish/2).
  @transient [:unknown_topic_or_partition, :leader_not_available, :not_leader_for_partition]
  @attempts 5

  defp produce(client, name, key, message, timeout, attempt) do
    result =
      with {:ok, count} <- partitions_count(client, name),
           {:ok, call_ref} <-
             :brod.produce(client, name, :erlang.phash2(key, count), key, message),
           {:ok, _offset} <- :brod.sync_produce_request_offset(call_ref, timeout) do
        :ok
      end

    case result do
      {:error, reason} when reason in @transient and attempt < @attempts ->
        Process.sleep(200 * attempt)
        produce(client, name, key, message, timeout, attempt + 1)

      other ->
        other
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp partitions_count(client, topic) do
    # `_safe`: never let a metadata request auto-create a topic with the
    # broker's default partition count.
    case :brod_client.get_partitions_count_safe(client, topic) do
      {:ok, count} when count > 0 -> {:ok, count}
      {:ok, _} -> {:error, :no_partitions}
      {:error, _} = error -> error
    end
  end

  @impl true
  def subscribe(%Subscription{} = subscription) do
    with {:ok, hosts} <- hosts() do
      client_config =
        config()
        |> channel_config()
        |> KafkaAdapter.client_config()
        |> Keyword.take([:sasl, :ssl, :connect_timeout])

      producer =
        {BroadwayKafka.Producer,
         [
           hosts: hosts,
           group_id: group_id(subscription),
           topics: Enum.map(subscription.topics, &Backbone.topic_name/1),
           offset_reset_policy: start_offset(subscription),
           offset_commit_on_ack: true,
           client_config: client_config,
           group_config: Keyword.get(config(), :group_config, []),
           # The producer fetches its partitions one after the other: an empty
           # partition must not hold the others up for BroadwayKafka's 1 s
           # default wait, and a drained producer polls again soon.
           fetch_config: Keyword.get(config(), :fetch_config, max_wait_time: 10),
           receive_interval: Keyword.get(config(), :receive_interval, 100)
         ]}

      # More producers per node are more group members, so more partitions
      # are fetched in parallel.
      opts = [producer_concurrency: Keyword.get(config(), :producer_concurrency, 2)]

      case DynamicSupervisor.start_child(
             Converger.Backbone.Consumers,
             {Pipeline, {subscription, producer, opts}}
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

  @doc "The consumer group of a subscription."
  def group_id(%Subscription{mode: :shared, name: name}), do: "#{Backbone.topic_prefix()}.#{name}"

  def group_id(%Subscription{mode: :broadcast, name: name}),
    do: "#{Backbone.topic_prefix()}.#{name}.#{node_slug()}"

  defp node_slug, do: node() |> Atom.to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "_")

  defp start_offset(%Subscription{mode: :broadcast}), do: :latest

  defp start_offset(_subscription) do
    case Keyword.get(config(), :start_offset, "earliest") do
      value when value in [:latest, "latest"] -> :latest
      _ -> :earliest
    end
  end

  @doc "The `:brod` client name."
  def client, do: Keyword.get(config(), :client, :converger_backbone_kafka)

  @doc "The bootstrap hosts as `[{host, port}]`."
  def hosts, do: config() |> channel_config() |> KafkaAdapter.hosts()

  @doc """
  The config as a Kafka channel config map (string keys), to reuse the
  channel adapter's parsing of brokers, SASL and TLS.
  """
  def channel_config(config) do
    %{
      "brokers" => Keyword.get(config, :brokers, "localhost:9092"),
      "sasl_mechanism" => Keyword.get(config, :sasl_mechanism),
      "sasl_username" => Keyword.get(config, :sasl_username),
      "sasl_password" => Keyword.get(config, :sasl_password),
      "tls" => Keyword.get(config, :tls, false),
      "tls_verify" => Keyword.get(config, :tls_verify, true),
      "tls_ca_cert" => Keyword.get(config, :tls_ca_cert)
    }
  end

  @doc false
  def config, do: Application.get_env(:converger, __MODULE__, [])
end
