defmodule Converger.Channels.Adapters.Mqtt do
  @moduledoc """
  An MQTT broker (MQTT 3.1.1: Mosquitto, EMQX, HiveMQ, VerneMQ, AWS IoT
  Core, ...) as a channel (broker channel, see `Converger.Channels.Broker`).

  ## Outbound

  Every activity the pipeline delivers to the channel is published to
  `topic_out`, a template in which `{conversation_id}`, `{channel_id}` and
  `{tenant_id}` are replaced (e.g. `converger/out/{conversation_id}`, so a
  device subscribes to its conversation), as the JSON envelope of
  `Converger.Channels.Broker.Envelope`, with QoS `qos` (default 1). A QoS 1
  publish waits for the broker's `PUBACK`. Each node keeps one publishing
  connection per channel (`Converger.Channels.Mqtt.Publisher`).

  ## Inbound

  `Converger.Channels.Consumers` runs one subscriber for the channel in the
  cluster (`Converger.Channels.Mqtt.Subscriber`), subscribed to the topic
  filter `topic_in` (wildcards allowed, e.g. `converger/in/+`) in a
  persistent session (`clean_session: false`), so QoS 1 messages published
  while it is disconnected or moving between nodes are queued by the broker.
  A message is acknowledged (`PUBACK`) only after it is accepted or
  dead-lettered. The idempotency key is the envelope's `idempotency_key`,
  else (`derive_idempotency_key`, default true) `mqtt:<SHA-256 of topic and
  payload>`: MQTT packet ids are reused, so they cannot identify a message.
  Poison messages are published to `topic_dlq` (default
  `converger/dlq/{channel_id}`) wrapped in a JSON object with the error.

  ## Config

  See `config_schema/0` and docs/channels/mqtt.md.
  """

  use Converger.Channels.Adapter, type: "mqtt"

  @behaviour Converger.Channels.Broker

  alias Converger.Channels.{Broker, DeliveryError}
  alias Converger.Channels.Broker.Envelope
  alias Converger.Channels.Mqtt.{Connection, Packet, Publisher, Subscriber}
  alias Converger.Pipeline.RetryPolicy

  @placeholders ~w(conversation_id channel_id tenant_id)
  @default_dlq "converger/dlq/{channel_id}"
  @default_client_id "converger"
  @client_id_pattern ~r/\A[A-Za-z0-9._-]{1,64}\z/
  @host_pattern ~r/\A[A-Za-z0-9.-]+\z|\A[0-9A-Fa-f:]+\z/
  @sample_id "00000000-0000-0000-0000-000000000000"

  # Errors no retry can fix until the channel or the broker is reconfigured.
  @permanent_errors [
    :bad_username_or_password,
    :not_authorized,
    :identifier_rejected,
    :unacceptable_protocol_version,
    :invalid_topic,
    :target_blocked,
    :invalid_config
  ]

  @impl true
  def capabilities, do: [:inbound, :outbound, :external_delivery, :lifecycle_events, :consumer]

  @impl true
  def config_schema do
    [
      %{
        name: "host",
        type: :string,
        required: true,
        label: "Broker host",
        placeholder: "mqtt.example.com",
        summary: true
      },
      %{name: "port", type: :integer, label: "Port", placeholder: "1883 (8883 with TLS)"},
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
      },
      %{name: "username", type: :string, label: "Username"},
      %{name: "password", type: :string, secret: true, label: "Password"},
      %{
        name: "client_id",
        type: :string,
        label: "Client id prefix",
        placeholder: @default_client_id,
        help: "MQTT client ids are <prefix>-<channel id>-<suffix>"
      },
      %{
        name: "topic_in",
        type: :string,
        required: :inbound,
        label: "Inbound topic filter",
        placeholder: "converger/in/+",
        help: "Subscribed for inbound messages (inbound and duplex mode); + and # allowed",
        summary: true
      },
      %{
        name: "topic_out",
        type: :string,
        required: :outbound,
        label: "Outbound topic",
        placeholder: "converger/out/{conversation_id}",
        help:
          "Activities are published here (outbound and duplex mode); {conversation_id}, {channel_id} and {tenant_id} are replaced",
        summary: true
      },
      %{
        name: "topic_dlq",
        type: :string,
        label: "Dead-letter topic",
        placeholder: @default_dlq
      },
      %{
        name: "qos",
        type: :integer,
        label: "QoS",
        placeholder: "1",
        help: "0 (at most once) or 1 (at least once, default)"
      },
      %{
        name: "keepalive",
        type: :integer,
        label: "Keepalive (seconds)",
        placeholder: "30"
      },
      %{
        name: "derive_idempotency_key",
        type: :boolean,
        label: "Deduplicate without an idempotency key",
        help:
          "Messages without an envelope idempotency_key are deduplicated by topic and payload (default true)"
      }
    ]
  end

  @impl true
  def validate_config(config) do
    with :ok <- validate_host(config["host"]),
         :ok <- validate_integer(config, "port", 1, 65_535),
         :ok <- validate_integer(config, "qos", 0, 1),
         :ok <- validate_integer(config, "keepalive", 5, 3_600),
         :ok <- validate_client_id(config["client_id"]),
         :ok <- validate_credentials(config),
         :ok <- validate_topics(config) do
      Broker.validate_tls("mqtt", config)
    end
  end

  defp validate_host(host) do
    with :ok <- host_format(host), do: Broker.check_host("mqtt", "host", host)
  end

  defp host_format(host) do
    if is_binary(host) and Regex.match?(@host_pattern, host),
      do: :ok,
      else: {:error, "mqtt config 'host' must be a host name or IP address (no scheme or port)"}
  end

  defp validate_integer(config, field, min, max) do
    case config[field] do
      blank when blank in [nil, ""] ->
        :ok

      value ->
        case integer(value) do
          int when is_integer(int) and int >= min and int <= max ->
            :ok

          _ ->
            {:error, "mqtt config '#{field}' must be an integer from #{min} to #{max}"}
        end
    end
  end

  defp validate_client_id(blank) when blank in [nil, ""], do: :ok

  defp validate_client_id(prefix) do
    if is_binary(prefix) and Regex.match?(@client_id_pattern, prefix),
      do: :ok,
      else:
        {:error,
         "mqtt config 'client_id' must be 1 to 64 letters, digits, '.', '_' or '-' characters"}
  end

  defp validate_credentials(config) do
    if blank?(config["username"]) and not blank?(config["password"]),
      do: {:error, "mqtt config 'password' needs a username"},
      else: :ok
  end

  defp validate_topics(config) do
    topic_in = config["topic_in"]

    cond do
      not blank?(topic_in) and not Packet.valid_filter?(topic_in) ->
        {:error,
         "mqtt config 'topic_in' must be a valid topic filter (+ and # only as whole levels, # last)"}

      error = template_error(config, "topic_out") ->
        error

      error = template_error(Map.put_new(config, "topic_dlq", @default_dlq), "topic_dlq") ->
        error

      true ->
        :ok
    end
  end

  # A template must render to a topic name without wildcards, and must not
  # match topic_in: what Converger publishes would be consumed back.
  defp template_error(config, field) do
    case config[field] do
      blank when blank in [nil, ""] ->
        nil

      template when is_binary(template) ->
        check_template(field, template, config["topic_in"])

      _ ->
        {:error, "mqtt config '#{field}' must be a string"}
    end
  end

  defp check_template(field, template, topic_in) do
    unknown =
      Regex.scan(~r/\{([^}]*)\}/, template, capture: :all_but_first)
      |> List.flatten()
      |> Enum.reject(&(&1 in @placeholders))

    sample = render(template, %{})

    cond do
      unknown != [] ->
        {:error,
         "mqtt config '#{field}' has unknown placeholders: #{Enum.join(unknown, ", ")} (allowed: {conversation_id}, {channel_id}, {tenant_id})"}

      not Packet.valid_topic?(sample) ->
        {:error, "mqtt config '#{field}' must be a topic name without + or # wildcards"}

      is_binary(topic_in) and Packet.valid_filter?(topic_in) and
          Packet.matches?(topic_in, sample) ->
        {:error,
         "mqtt config '#{field}' must not match topic_in: Converger would consume its own messages"}

      true ->
        nil
    end
  end

  @doc """
  Render a topic template: `{conversation_id}`, `{channel_id}` and
  `{tenant_id}` are replaced with `values` (missing values with a sample
  UUID, for validation).
  """
  @spec render(String.t(), map()) :: String.t()
  def render(template, values) do
    Regex.replace(~r/\{(conversation_id|channel_id|tenant_id)\}/, template, fn _, name ->
      to_string(Map.get(values, name) || @sample_id)
    end)
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
        {:error, DeliveryError.permanent("mqtt channel has no topic_out")}

      true ->
        topic =
          render(config["topic_out"], %{
            "conversation_id" => activity.conversation_id,
            "channel_id" => channel.id,
            "tenant_id" => activity.tenant_id || channel.tenant_id
          })

        timeout = RetryPolicy.for_channel(channel).timeout_ms

        case Publisher.publish(channel, topic, Envelope.encode(activity, channel), qos(config),
               timeout: timeout
             ) do
          :ok -> {:ok, %{provider_message_id: activity.id, mqtt_topic: topic}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def normalize_error(%DeliveryError{} = error), do: error

  def normalize_error(reason) do
    message = "mqtt publish failed: #{inspect(reason)}"

    if Broker.contains_any?(reason, @permanent_errors),
      do: DeliveryError.permanent(message),
      else: %DeliveryError{reason: message}
  end

  @impl true
  def parse_inbound(_channel, _params) do
    {:error, "mqtt channels consume inbound messages from their topic, not inbound webhooks"}
  end

  @doc """
  Connects with a throwaway client id (clean session, no subscription) and
  disconnects: checks the host, TLS and credentials.
  """
  @impl true
  def health_probe(channel) do
    with {:ok, options} <- connection_options(channel, :probe),
         {:ok, pid} <- Connection.start(Keyword.put(options, :connect_timeout, 5_000)) do
      Connection.stop(pid)
    end
  end

  ## Inbound (Converger.Channels.Broker)

  @impl Converger.Channels.Broker
  def consumer_child_spec(channel), do: {Subscriber, channel}

  @doc """
  What `Converger.Channels.Broker.handle/4` needs of an inbound `PUBLISH`:
  the payload, the source (the topic) and the message id the idempotency key
  is derived from (`mqtt:<id>`): the hex SHA-256 of the topic and the
  payload, or nil with `derive_idempotency_key: false`.
  """
  @spec packet_info(map(), map()) :: Broker.info()
  def packet_info(channel, %{topic: topic, payload: payload}) do
    derive? = Broker.boolean((channel.config || %{})["derive_idempotency_key"], true)

    %{
      payload: payload,
      message_id: if(derive?, do: derived_id(topic, payload)),
      source: topic,
      key: nil,
      headers: []
    }
  end

  @doc "The derived message id of a payload on a topic."
  def derived_id(topic, payload),
    do: :crypto.hash(:sha256, [topic, 0, payload]) |> Base.encode16(case: :lower)

  @doc """
  Publishes a message that cannot be accepted to `topic_dlq`, as JSON:
  `{"error", "source" (the topic), "channel_id", "message_id", "payload"}`,
  with the payload as a string, or base64 in `payload_base64` when it is not
  UTF-8.
  """
  @impl Converger.Channels.Broker
  def dead_letter(channel, info, reason) do
    config = channel.config || %{}

    topic =
      render(config["topic_dlq"] || @default_dlq, %{
        "channel_id" => channel.id,
        "tenant_id" => channel.tenant_id
      })

    payload =
      if String.valid?(info.payload),
        do: %{"payload" => info.payload},
        else: %{"payload_base64" => Base.encode64(info.payload)}

    body =
      Map.merge(payload, %{
        "error" => reason,
        "source" => info.source,
        "channel_id" => channel.id,
        "message_id" => info.message_id
      })

    Publisher.publish(channel, topic, Jason.encode!(body), 1, timeout: 10_000)
  end

  ## Config

  @doc """
  `Converger.Channels.Mqtt.Connection` options of the channel for `role`:

    * `:subscriber` - client id `<prefix>-<channel id>-s<hash of topic_in
      and qos>`, persistent session, subscribed to `topic_in`. The hash
      starts a new session when the filter changes, so the old filter's
      subscription is not kept.
    * `:publisher` - client id `<prefix>-<channel id>-p<node hash>` (one per
      node), clean session.
    * `:probe` - a random client id, clean session.
  """
  @spec connection_options(map(), :subscriber | :publisher | :probe) ::
          {:ok, keyword()} | {:error, term()}
  def connection_options(channel, role) do
    config = channel.config || %{}

    with {:format, :ok} <- {:format, host_format(config["host"])},
         {:guard, :ok} <- {:guard, Broker.check_host("mqtt", "host", config["host"])} do
      tls = Broker.tls_options(config, config["host"])
      prefix = if blank?(config["client_id"]), do: @default_client_id, else: config["client_id"]
      base = "#{prefix}-#{channel.id}"

      {:ok,
       [
         host: config["host"],
         port: integer(config["port"]) || if(tls, do: 8883, else: 1883),
         ssl: tls,
         username: if(blank?(config["username"]), do: nil, else: config["username"]),
         password: config["password"],
         keepalive: integer(config["keepalive"]) || 30
       ] ++ role_options(role, base, config)}
    else
      {:format, {:error, message}} -> {:error, {:invalid_config, message}}
      {:guard, {:error, message}} -> {:error, {:target_blocked, message}}
    end
  end

  defp role_options(:subscriber, base, config) do
    filter = config["topic_in"]
    qos = qos(config)
    suffix = :erlang.phash2({filter, qos}) |> Integer.to_string(36) |> String.downcase()

    [
      client_id: "#{base}-s#{suffix}",
      clean_session: false,
      subscriptions: [{filter, qos}]
    ]
  end

  defp role_options(:publisher, base, _config) do
    suffix = :erlang.phash2(node()) |> Integer.to_string(36) |> String.downcase()
    [client_id: "#{base}-p#{suffix}", clean_session: true]
  end

  defp role_options(:probe, base, _config) do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    [client_id: "#{base}-h#{suffix}", clean_session: true]
  end

  @doc "The QoS of the channel: `qos`, default 1."
  def qos(config) do
    case integer(config["qos"]) do
      0 -> 0
      _ -> 1
    end
  end

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp integer(_), do: nil

  defp blank?(value), do: value in [nil, ""]
end
