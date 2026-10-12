defmodule Converger.Channels.Adapters.Kafka do
  @moduledoc """
  Apache Kafka as a channel (broker channel, see `Converger.Channels.Broker`).

  ## Outbound

  Every activity the pipeline delivers to the channel is produced to
  `topic_out` as the JSON envelope of `Converger.Channels.Broker.Envelope`,
  keyed by `conversation_id`: the activities of a conversation land on one
  partition (`:erlang.phash2(conversation_id, partitions)`), in order. The
  delivery's provider message id is `topic/partition/offset`. Headers:
  `content-type: application/json`, `x-converger-event`,
  `x-converger-activity-id`, `x-converger-conversation-id`.

  ## Inbound

  `Converger.Channels.Consumers` runs one consumer for the channel in the
  cluster: a Broadway pipeline with a `BroadwayKafka.Producer` in consumer
  group `group_id` (default `converger-<channel id>`) on `topic_in`. Offsets
  are committed after each message is accepted or dead-lettered; a message
  without an envelope `idempotency_key` gets `kafka:topic/partition/offset`,
  so a redelivery after a restart is recognised as a duplicate. Poison
  messages are produced to `dlq_topic` (default `<topic_in>.dlq`) with the
  original key, value and headers plus `x-converger-error`,
  `x-converger-source` and `x-converger-channel-id`.

  ## Config

  See `config_schema/0` and docs/channels/kafka.md.

  `:brod` computes the Kafka record CRC32C with a NIF (`crc32cer`) that is
  not built on Windows: run Kafka channels on Linux or macOS (or in a
  container).
  """

  use Converger.Channels.Adapter, type: "kafka"

  @behaviour Converger.Channels.Broker

  alias Converger.Channels.{Broker, DeliveryError}
  alias Converger.Channels.Broker.{Envelope, KafkaPublisher}
  alias Converger.Pipeline.RetryPolicy

  @topic_pattern ~r/\A[A-Za-z0-9._-]{1,249}\z/
  @sasl_mechanisms %{
    "plain" => :plain,
    "scram_sha_256" => :scram_sha_256,
    "scram_sha_512" => :scram_sha_512
  }
  @start_offsets %{"earliest" => :earliest, "latest" => :latest}
  @max_concurrency 64

  # Errors no retry can fix until the channel or the cluster is reconfigured.
  @permanent_errors [
    :topic_authorization_failed,
    :cluster_authorization_failed,
    :group_authorization_failed,
    :sasl_authentication_failed,
    :illegal_sasl_state,
    :unsupported_sasl_mechanism,
    :invalid_topic_exception,
    :message_too_large,
    :record_list_too_large,
    :invalid_record,
    :target_blocked,
    :invalid_config
  ]

  @impl true
  def capabilities, do: [:inbound, :outbound, :external_delivery, :lifecycle_events, :consumer]

  @impl true
  def config_schema do
    [
      %{
        name: "brokers",
        type: :string,
        required: true,
        label: "Bootstrap brokers",
        placeholder: "kafka-1:9092,kafka-2:9092",
        summary: true
      },
      %{
        name: "topic_in",
        type: :string,
        required: :inbound,
        label: "Inbound topic",
        placeholder: "converger.inbound",
        help: "Consumed for inbound messages (inbound and duplex mode)",
        summary: true
      },
      %{
        name: "topic_out",
        type: :string,
        required: :outbound,
        label: "Outbound topic",
        placeholder: "converger.outbound",
        help: "Activities are produced here, keyed by conversation_id (outbound and duplex mode)",
        summary: true
      },
      %{
        name: "group_id",
        type: :string,
        label: "Consumer group",
        placeholder: "converger-<channel id>"
      },
      %{
        name: "dlq_topic",
        type: :string,
        label: "Dead-letter topic",
        placeholder: "<topic_in>.dlq"
      },
      %{
        name: "start_offset",
        type: :string,
        label: "Start offset",
        placeholder: "earliest",
        help: "Where a new consumer group starts: earliest (default) or latest"
      },
      %{
        name: "concurrency",
        type: :integer,
        label: "Consumer concurrency",
        placeholder: "4",
        help: "Processors of the consumer; messages of one partition stay in order"
      },
      %{
        name: "sasl_mechanism",
        type: :string,
        label: "SASL mechanism",
        placeholder: "plain, scram_sha_256 or scram_sha_512"
      },
      %{name: "sasl_username", type: :string, label: "SASL username"},
      %{name: "sasl_password", type: :string, secret: true, label: "SASL password"},
      %{name: "tls", type: :boolean, label: "TLS", help: "Connect with TLS (default false)"},
      %{
        name: "tls_verify",
        type: :boolean,
        label: "Verify TLS certificate",
        help: "Verify the broker certificate and host name (default true)"
      },
      %{
        name: "tls_ca_cert",
        type: :string,
        form: false,
        help: "PEM CA certificates; default: the OS trust store"
      }
    ]
  end

  @impl true
  def validate_config(config) do
    with {:ok, hosts} <- hosts(config),
         :ok <- check_hosts(hosts),
         :ok <- validate_topics(config),
         :ok <- validate_choice(config, "start_offset", @start_offsets),
         :ok <- validate_choice(config, "sasl_mechanism", @sasl_mechanisms),
         :ok <- validate_sasl(config),
         :ok <- validate_concurrency(config),
         :ok <- validate_group(config) do
      Broker.validate_tls("kafka", config)
    end
  end

  @impl true
  def retry_policy, do: %{timeout_ms: 10_000}

  ## Outbound

  @impl true
  def deliver_activity(channel, activity) do
    config = channel.config || %{}

    cond do
      Broker.echo?(channel, activity) ->
        {:ok, %{skipped: "consumed from this channel"}}

      blank?(config["topic_out"]) ->
        {:error, DeliveryError.permanent("kafka channel has no topic_out")}

      true ->
        topic = config["topic_out"]
        timeout = RetryPolicy.for_channel(channel).timeout_ms

        headers = [
          {"content-type", "application/json"},
          {"x-converger-event", "activity.created"},
          {"x-converger-activity-id", activity.id},
          {"x-converger-conversation-id", activity.conversation_id}
        ]

        case KafkaPublisher.produce(
               channel,
               topic,
               activity.conversation_id,
               Envelope.encode(activity, channel),
               headers: headers,
               timeout: timeout
             ) do
          {:ok, partition, offset} ->
            {:ok, %{provider_message_id: "#{topic}/#{partition}/#{offset}"}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  def normalize_error(%DeliveryError{} = error), do: error

  def normalize_error(reason) do
    message = "kafka produce failed: #{inspect(reason)}"

    if Broker.contains_any?(reason, @permanent_errors),
      do: DeliveryError.permanent(message),
      else: %DeliveryError{reason: message}
  end

  @impl true
  def parse_inbound(_channel, _params) do
    {:error, "kafka channels consume inbound messages from topic_in, not inbound webhooks"}
  end

  @impl true
  def health_probe(channel) do
    config = channel.config || %{}
    topics = Enum.reject([config["topic_out"], config["topic_in"]], &blank?/1)

    conn_config =
      config
      |> client_config()
      |> Keyword.take([:ssl, :sasl])
      |> Keyword.put(:connect_timeout, 5_000)
      |> Keyword.put(:request_timeout, 5_000)

    with {:ok, hosts} <- hosts(config),
         :ok <- check_hosts(hosts),
         {:ok, _metadata} <- :brod.get_metadata(hosts, topics, conn_config) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  ## Inbound (Converger.Channels.Broker)

  @impl Converger.Channels.Broker
  def consumer_options(channel) do
    config = channel.config || %{}

    with {:ok, hosts} <- hosts(config),
         :ok <- check_hosts(hosts),
         topic when is_binary(topic) and topic != "" <- config["topic_in"] do
      client_config =
        config
        |> client_config()
        |> Keyword.take([:sasl, :ssl, :connect_timeout])

      producer =
        {BroadwayKafka.Producer,
         [
           hosts: hosts,
           group_id: group_id(channel),
           topics: [topic],
           offset_reset_policy: Map.fetch!(@start_offsets, config["start_offset"] || "earliest"),
           offset_commit_on_ack: true,
           client_config: client_config
         ]}

      {:ok,
       [
         producer: [module: producer, concurrency: 1],
         processors: [
           default: [concurrency: Broker.positive_integer(config["concurrency"], 4)]
         ]
       ]}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "kafka channel has no topic_in"}
    end
  end

  @impl Converger.Channels.Broker
  def message_info(_channel, %Broadway.Message{data: data, metadata: metadata}) do
    id = "#{metadata.topic}/#{metadata.partition}/#{metadata.offset}"

    %{
      payload: data,
      message_id: id,
      source: id,
      key: Map.get(metadata, :key),
      headers: Map.get(metadata, :headers) || []
    }
  end

  @impl Converger.Channels.Broker
  def dead_letter(channel, info, reason) do
    config = channel.config || %{}

    headers =
      Enum.reject(info[:headers] || [], fn {name, _} ->
        String.starts_with?(name, "x-converger-")
      end) ++
        [
          {"x-converger-error", reason},
          {"x-converger-source", info.source},
          {"x-converger-channel-id", channel.id}
        ]

    case KafkaPublisher.produce(channel, dlq_topic(config), info[:key] || "", info.payload,
           headers: headers,
           timeout: 10_000
         ) do
      {:ok, _partition, _offset} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The consumer group of a channel: `group_id`, default `converger-<channel id>`."
  def group_id(channel) do
    case (channel.config || %{})["group_id"] do
      blank when blank in [nil, ""] -> "converger-#{channel.id}"
      group -> group
    end
  end

  @doc "The dead-letter topic: `dlq_topic`, default `<topic_in>.dlq`."
  def dlq_topic(config) do
    case config["dlq_topic"] do
      blank when blank in [nil, ""] -> "#{config["topic_in"]}.dlq"
      topic -> topic
    end
  end

  ## Config

  @doc """
  The bootstrap brokers of a config (`"host:port,host:port"`, IPv6 as
  `[::1]:9092`) as `[{host, port}]`.
  """
  @spec hosts(map()) :: {:ok, [{String.t(), pos_integer()}]} | {:error, String.t()}
  def hosts(config) do
    entries =
      (config["brokers"] || "")
      |> to_string()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    parsed = Enum.map(entries, &parse_host/1)

    cond do
      entries == [] ->
        {:error, "kafka config 'brokers' must list at least one host:port"}

      Enum.any?(parsed, &(&1 == :error)) ->
        {:error, "kafka config 'brokers' must be comma-separated host:port pairs"}

      true ->
        {:ok, Enum.map(parsed, fn {:ok, host} -> host end)}
    end
  end

  defp parse_host(entry) do
    {host, port} =
      case Regex.run(~r/\A\[([0-9A-Fa-f:.]+)\]:(\d+)\z/, entry) do
        [_, host, port] ->
          {host, port}

        nil ->
          case String.split(entry, ":") do
            [host, port] -> {host, port}
            _ -> {nil, nil}
          end
      end

    with true <- is_binary(host) and Regex.match?(~r/\A[A-Za-z0-9.\-_:]+\z/, host),
         {port, ""} when port in 1..65_535 <- Integer.parse(port) do
      {:ok, {host, port}}
    else
      _ -> :error
    end
  end

  @doc "Check the bootstrap hosts with the SSRF guard (`Converger.Channels.Broker.check_host/3`)."
  def check_hosts(hosts) do
    Enum.find_value(hosts, :ok, fn {host, _port} ->
      case Broker.check_host("kafka", "brokers", host) do
        :ok -> nil
        error -> error
      end
    end)
  end

  @doc "`:brod` client config (SASL, TLS, timeouts) of a channel config."
  @spec client_config(map()) :: keyword()
  def client_config(config) do
    first_host =
      case hosts(config) do
        {:ok, [{host, _} | _]} -> host
        _ -> ""
      end

    sasl =
      case Map.fetch(@sasl_mechanisms, config["sasl_mechanism"] || "") do
        {:ok, mechanism} -> {mechanism, config["sasl_username"], config["sasl_password"]}
        :error -> :undefined
      end

    [
      sasl: sasl,
      ssl: Broker.tls_options(config, first_host),
      connect_timeout: 5_000
    ]
  end

  defp validate_topics(config) do
    Enum.find_value(["topic_in", "topic_out", "dlq_topic"], fn field ->
      value = config[field]

      cond do
        blank?(value) ->
          nil

        not is_binary(value) or not Regex.match?(@topic_pattern, value) or value in [".", ".."] ->
          {:error,
           "kafka config '#{field}' must be a Kafka topic name (letters, digits, '.', '_', '-')"}

        true ->
          nil
      end
    end) || validate_dlq(config)
  end

  defp validate_dlq(config) do
    if not blank?(config["topic_in"]) and dlq_topic(config) == config["topic_in"],
      do: {:error, "kafka config 'dlq_topic' must differ from topic_in"},
      else: :ok
  end

  defp validate_choice(config, field, choices) do
    case config[field] do
      blank when blank in [nil, ""] ->
        :ok

      value ->
        if is_binary(value) and Map.has_key?(choices, value),
          do: :ok,
          else:
            {:error,
             "kafka config '#{field}' must be one of: #{Enum.join(Map.keys(choices), ", ")}"}
    end
  end

  defp validate_sasl(config) do
    mechanism? = not blank?(config["sasl_mechanism"])
    credentials? = not blank?(config["sasl_username"]) or not blank?(config["sasl_password"])

    cond do
      mechanism? and (blank?(config["sasl_username"]) or blank?(config["sasl_password"])) ->
        {:error, "kafka config 'sasl_mechanism' needs sasl_username and sasl_password"}

      credentials? and not mechanism? ->
        {:error, "kafka config 'sasl_username' / 'sasl_password' need a sasl_mechanism"}

      true ->
        :ok
    end
  end

  defp validate_concurrency(config) do
    case config["concurrency"] do
      blank when blank in [nil, ""] ->
        :ok

      value ->
        case Broker.positive_integer(value, nil) do
          int when is_integer(int) and int <= @max_concurrency ->
            :ok

          _ ->
            {:error,
             "kafka config 'concurrency' must be a positive integer of at most #{@max_concurrency}"}
        end
    end
  end

  defp validate_group(config) do
    case config["group_id"] do
      blank when blank in [nil, ""] -> :ok
      group when is_binary(group) and byte_size(group) <= 255 -> :ok
      _ -> {:error, "kafka config 'group_id' must be a string of at most 255 bytes"}
    end
  end

  defp blank?(value), do: value in [nil, ""]
end
