defmodule Converger.Channels.Adapters.RabbitMQ do
  @moduledoc """
  RabbitMQ (AMQP 0-9-1) as a channel (broker channel, see
  `Converger.Channels.Broker`).

  ## Outbound

  Every activity the pipeline delivers to the channel is published to
  `exchange` (default: the default exchange `""`) with `routing_key`, as the
  JSON envelope of `Converger.Channels.Broker.Envelope`: persistent,
  `content_type: application/json`, `message_id` = the activity id, `type` =
  the activity type, `app_id: converger`, headers
  `x-converger-conversation-id`, `x-converger-tenant-id`,
  `x-converger-event`. The publish waits for the broker's publisher confirm.
  A message no queue is bound for is dropped by RabbitMQ (pub/sub semantics);
  bind a queue before sending.

  ## Inbound

  `Converger.Channels.Consumers` runs one consumer for the channel in the
  cluster: a Broadway pipeline with a `BroadwayRabbitMQ.Producer` on `queue`.
  A message is acknowledged after it is accepted or dead-lettered. Without an
  envelope `idempotency_key`, the AMQP `message_id` property is the
  idempotency key (`rabbitmq:<message_id>`): publishers should set it, a
  message without either is accepted again when it is redelivered.
  Poison messages are published, with confirms and `mandatory`, through the
  default exchange to `dlq_queue` (default `<queue>.dlq`) with the
  `x-converger-error`, `x-converger-source` and `x-converger-channel-id`
  headers. With `declare: true` the consumer declares `queue` and `dlq_queue`
  (durable, classic, no arguments); otherwise they must exist.

  ## Config

  See `config_schema/0` and docs/channels/rabbitmq.md.
  """

  use Converger.Channels.Adapter, type: "rabbitmq"

  @behaviour Converger.Channels.Broker

  alias Converger.Channels.{Broker, DeliveryError}
  alias Converger.Channels.Broker.{AmqpPublisher, Envelope}
  alias Converger.Pipeline.RetryPolicy

  @max_name_bytes 255
  @max_concurrency 64
  @max_prefetch 1_000

  @permanent_errors [
    :access_refused,
    :not_allowed,
    :auth_failure,
    :unroutable,
    :target_blocked,
    :invalid_config
  ]

  @impl true
  def capabilities, do: [:inbound, :outbound, :external_delivery, :lifecycle_events, :consumer]

  @impl true
  def config_schema do
    [
      %{
        name: "url",
        type: :string,
        required: true,
        label: "Broker URL",
        placeholder: "amqps://rabbitmq.example.com:5671/%2F",
        help: "amqp:// or amqps:// host, port and virtual host; credentials go below",
        summary: true
      },
      %{name: "username", type: :string, label: "Username"},
      %{name: "password", type: :string, secret: true, label: "Password"},
      %{
        name: "queue",
        type: :string,
        required: :inbound,
        label: "Inbound queue",
        placeholder: "converger.inbound",
        help: "Consumed for inbound messages (inbound and duplex mode)",
        summary: true
      },
      %{
        name: "exchange",
        type: :string,
        label: "Outbound exchange",
        placeholder: "converger (empty: the default exchange)"
      },
      %{
        name: "routing_key",
        type: :string,
        required: :outbound,
        label: "Outbound routing key",
        placeholder: "converger.outbound",
        help: "Activities are published with it (outbound and duplex mode)",
        summary: true
      },
      %{
        name: "dlq_queue",
        type: :string,
        label: "Dead-letter queue",
        placeholder: "<queue>.dlq"
      },
      %{
        name: "declare",
        type: :boolean,
        label: "Declare queues",
        help: "Declare queue and dlq_queue as durable queues (default false)"
      },
      %{name: "prefetch_count", type: :integer, label: "Prefetch count", placeholder: "10"},
      %{
        name: "concurrency",
        type: :integer,
        label: "Consumer concurrency",
        placeholder: "1",
        help: "Processors of the consumer; more than 1 gives up the queue order"
      },
      %{
        name: "tls_verify",
        type: :boolean,
        label: "Verify TLS certificate",
        help: "amqps:// only: verify the broker certificate and host name (default true)"
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
    with {:ok, uri} <- parse_url(config["url"]),
         :ok <- Broker.check_host("rabbitmq", "url", uri.host),
         :ok <- validate_names(config),
         :ok <- validate_credentials(config),
         :ok <- validate_range(config, "prefetch_count", @max_prefetch),
         :ok <- validate_range(config, "concurrency", @max_concurrency) do
      Broker.validate_tls("rabbitmq", config)
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

      blank?(config["routing_key"]) ->
        {:error, DeliveryError.permanent("rabbitmq channel has no routing_key")}

      true ->
        options = [
          persistent: true,
          content_type: "application/json",
          message_id: activity.id,
          type: activity.type,
          app_id: "converger",
          timestamp: System.system_time(:second),
          headers: [
            {"x-converger-event", :longstr, "activity.created"},
            {"x-converger-conversation-id", :longstr, activity.conversation_id},
            {"x-converger-tenant-id", :longstr, activity.tenant_id || channel.tenant_id}
          ],
          timeout: RetryPolicy.for_channel(channel).timeout_ms
        ]

        case AmqpPublisher.publish(
               channel,
               config["exchange"] || "",
               config["routing_key"],
               Envelope.encode(activity, channel),
               options
             ) do
          :ok -> {:ok, %{provider_message_id: activity.id}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def normalize_error(%DeliveryError{} = error), do: error

  def normalize_error(reason) do
    message = "rabbitmq publish failed: #{inspect(reason)}"

    if Broker.contains_any?(reason, @permanent_errors),
      do: DeliveryError.permanent(message),
      else: %DeliveryError{reason: message}
  end

  @impl true
  def parse_inbound(_channel, _params) do
    {:error, "rabbitmq channels consume inbound messages from their queue, not inbound webhooks"}
  end

  @impl true
  def health_probe(channel) do
    with {:ok, options} <- connection_options(channel.config || %{}),
         :ok <- check_host(options),
         {:ok, conn} <- AMQP.Connection.open(Keyword.put(options, :connection_timeout, 5_000)) do
      AMQP.Connection.close(conn)
      :ok
    end
  end

  ## Inbound (Converger.Channels.Broker)

  @impl Converger.Channels.Broker
  def consumer_options(channel) do
    config = channel.config || %{}

    with {:ok, connection} <- connection_options(config),
         :ok <- check_host(connection),
         queue when is_binary(queue) and queue != "" <- config["queue"] do
      declare? = Broker.boolean(config["declare"])
      dlq = dlq_queue(config)

      producer_options =
        [
          queue: queue,
          connection: connection,
          qos: [prefetch_count: Broker.positive_integer(config["prefetch_count"], 10)],
          metadata: [:message_id, :headers, :routing_key, :exchange, :redelivered],
          on_failure: :reject_and_requeue,
          after_connect: fn chan -> declare_dead_letter_queue(chan, dlq, declare?) end
        ] ++ if(declare?, do: [declare: [durable: true]], else: [])

      {:ok,
       [
         producer: [module: {BroadwayRabbitMQ.Producer, producer_options}, concurrency: 1],
         processors: [
           default: [concurrency: Broker.positive_integer(config["concurrency"], 1)]
         ]
       ]}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "rabbitmq channel has no queue"}
    end
  end

  defp declare_dead_letter_queue(_chan, _dlq, false), do: :ok

  defp declare_dead_letter_queue(chan, dlq, true) do
    case AMQP.Queue.declare(chan, dlq, durable: true) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Converger.Channels.Broker
  def message_info(channel, %Broadway.Message{data: data, metadata: metadata}) do
    message_id =
      case Map.get(metadata, :message_id) do
        id when is_binary(id) and id != "" -> id
        _ -> nil
      end

    queue = (channel.config || %{})["queue"]

    %{
      payload: data,
      message_id: message_id,
      source: if(message_id, do: "#{queue}/#{message_id}", else: queue),
      key: Map.get(metadata, :routing_key),
      headers: headers(Map.get(metadata, :headers))
    }
  end

  defp headers(headers) when is_list(headers) do
    for {name, _type, value} <- headers, is_binary(name), is_binary(value), do: {name, value}
  end

  defp headers(_), do: []

  @impl Converger.Channels.Broker
  def dead_letter(channel, info, reason) do
    config = channel.config || %{}

    headers =
      for {name, value} <- info[:headers] || [],
          not String.starts_with?(name, "x-converger-"),
          do: {name, :longstr, value}

    options = [
      persistent: true,
      mandatory: true,
      content_type: "application/json",
      message_id: info.message_id || Ecto.UUID.generate(),
      app_id: "converger",
      headers:
        headers ++
          [
            {"x-converger-error", :longstr, reason},
            {"x-converger-source", :longstr, info.source || ""},
            {"x-converger-channel-id", :longstr, channel.id}
          ],
      timeout: 10_000
    ]

    AmqpPublisher.publish(channel, "", dlq_queue(config), info.payload, options)
  end

  @doc "The dead-letter queue: `dlq_queue`, default `<queue>.dlq`."
  def dlq_queue(config) do
    case config["dlq_queue"] do
      blank when blank in [nil, ""] -> "#{config["queue"]}.dlq"
      queue -> queue
    end
  end

  ## Config

  @doc """
  `AMQP.Connection.open/1` options of a channel config: host, port and
  virtual host from `url`, credentials, TLS for `amqps://`.
  """
  @spec connection_options(map()) :: {:ok, keyword()} | {:error, String.t()}
  def connection_options(config) do
    with {:ok, uri} <- parse_url(config["url"]) do
      tls? = uri.scheme == "amqps"

      ssl =
        if tls?,
          do: [ssl_options: Broker.tls_options(Map.put(config, "tls", true), uri.host)],
          else: []

      credentials =
        if blank?(config["username"]),
          do: [],
          else: [username: config["username"], password: config["password"] || ""]

      {:ok,
       [
         host: uri.host,
         port: uri.port || if(tls?, do: 5671, else: 5672),
         virtual_host: virtual_host(uri.path),
         heartbeat: 30,
         connection_timeout: 10_000
       ] ++ credentials ++ ssl}
    end
  end

  @doc "Check the host of `connection_options/1` with the SSRF guard."
  def check_host(options),
    do: Broker.check_host("rabbitmq", "url", Keyword.fetch!(options, :host))

  defp virtual_host(path) when path in [nil, "", "/"], do: "/"
  defp virtual_host("/" <> vhost), do: URI.decode(vhost)

  defp parse_url(url) when is_binary(url) and url != "" do
    uri = URI.parse(url)

    case Enum.find(url_checks(), fn {valid?, _error} -> not valid?.(uri) end) do
      nil -> {:ok, uri}
      {_valid?, error} -> {:error, "rabbitmq config 'url' #{error}"}
    end
  end

  defp parse_url(_), do: {:error, "rabbitmq config 'url' must be an amqp:// or amqps:// URL"}

  defp url_checks do
    [
      {&(&1.scheme in ["amqp", "amqps"]), "must be an amqp:// or amqps:// URL"},
      {&(not blank?(&1.host)), "must include a host"},
      {&is_nil(&1.userinfo), "must not contain credentials: set username and password"},
      {&(is_nil(&1.query) and is_nil(&1.fragment)), "must not have a query or fragment"},
      {&(not String.contains?(String.trim_leading(&1.path || "", "/"), "/")),
       "virtual host must be URL-encoded (%2F for /)"}
    ]
  end

  defp validate_names(config) do
    error =
      Enum.find_value(["queue", "exchange", "routing_key", "dlq_queue"], fn field ->
        case config[field] do
          nil -> nil
          value when is_binary(value) and byte_size(value) <= @max_name_bytes -> nil
          _ -> {:error, "rabbitmq config '#{field}' must be a string of at most 255 bytes"}
        end
      end)

    cond do
      error ->
        error

      not blank?(config["queue"]) and dlq_queue(config) == config["queue"] ->
        {:error, "rabbitmq config 'dlq_queue' must differ from queue"}

      true ->
        :ok
    end
  end

  defp validate_credentials(config) do
    if blank?(config["username"]) and not blank?(config["password"]),
      do: {:error, "rabbitmq config 'password' needs a username"},
      else: :ok
  end

  defp validate_range(config, field, max) do
    case config[field] do
      blank when blank in [nil, ""] ->
        :ok

      value ->
        case Broker.positive_integer(value, nil) do
          int when is_integer(int) and int <= max ->
            :ok

          _ ->
            {:error, "rabbitmq config '#{field}' must be a positive integer of at most #{max}"}
        end
    end
  end

  defp blank?(value), do: value in [nil, ""]
end
