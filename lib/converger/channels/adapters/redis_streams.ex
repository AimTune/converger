defmodule Converger.Channels.Adapters.RedisStreams do
  @moduledoc """
  Redis Streams as a channel (broker channel, see `Converger.Channels.Broker`).

  ## Outbound

  Every activity the pipeline delivers to the channel is appended to
  `stream_out` with `XADD` (trimmed with `MAXLEN ~ maxlen` when `maxlen` is
  set). The entry's fields: `payload` (the JSON envelope of
  `Converger.Channels.Broker.Envelope`), `content_type`
  (`application/json`), `event`, `activity_id`, `conversation_id`,
  `tenant_id`. The delivery's provider message id is `stream/entry id`.
  One stream keeps the order of the activities a conversation's deliveries
  produce.

  ## Inbound

  `Converger.Channels.Consumers` runs one consumer for the channel in the
  cluster: a Broadway pipeline with a
  `Converger.Channels.Broker.RedisStreamsProducer` in consumer group `group`
  (default `converger-<channel id>`, created on `stream_in` when missing) as
  a consumer named after the node. The entry's `payload` field is the
  envelope. An entry is acknowledged (`XACK`) after it is accepted or
  dead-lettered; without an envelope `idempotency_key` its key is
  `redis_streams:<stream>/<entry id>`, so a redelivery is recognised as a
  duplicate. On start, the consumer first claims (`XAUTOCLAIM`) the group's
  pending entries (delivered to an earlier consumer, on this node or
  another, and never acknowledged) and processes them, then reads new
  entries. Poison entries are appended to `dlq_stream` (default
  `<stream_in>.dlq`) with their original fields plus `x-converger-error`,
  `x-converger-source` and `x-converger-channel-id`.

  ## Config

  See `config_schema/0` and docs/channels/redis-streams.md.
  """

  use Converger.Channels.Adapter, type: "redis_streams"

  @behaviour Converger.Channels.Broker

  alias Converger.Channels.{Broker, DeliveryError}
  alias Converger.Channels.Broker.{Envelope, RedisPublisher, RedisStreamsProducer}
  alias Converger.Pipeline.RetryPolicy

  @max_key_bytes 512
  @max_concurrency 64
  @max_batch 1_000
  @max_maxlen 1_000_000_000
  @max_database 1_000
  @start_ids %{"earliest" => "0", "latest" => "$"}
  @default_port 6379

  # Errors no retry can fix until the channel or the server is reconfigured.
  @permanent_errors [:target_blocked, :invalid_config, :wrongtype, :noperm, :wrongpass]

  @impl true
  def capabilities, do: [:inbound, :outbound, :external_delivery, :lifecycle_events, :consumer]

  @impl true
  def config_schema do
    [
      %{
        name: "url",
        type: :string,
        required: true,
        label: "Redis URL",
        placeholder: "rediss://redis.example.com:6380/0",
        help: "redis:// or rediss:// (TLS) host, port and database; credentials go below",
        summary: true
      },
      %{name: "username", type: :string, label: "Username (ACL)"},
      %{name: "password", type: :string, secret: true, label: "Password"},
      %{
        name: "stream_in",
        type: :string,
        required: :inbound,
        label: "Inbound stream",
        placeholder: "crm.in",
        help: "Read with a consumer group for inbound messages (inbound and duplex mode)",
        summary: true
      },
      %{
        name: "stream_out",
        type: :string,
        required: :outbound,
        label: "Outbound stream",
        placeholder: "crm.out",
        help: "Activities are appended here (outbound and duplex mode)",
        summary: true
      },
      %{
        name: "group",
        type: :string,
        label: "Consumer group",
        placeholder: "converger-<channel id>"
      },
      %{
        name: "dlq_stream",
        type: :string,
        label: "Dead-letter stream",
        placeholder: "<stream_in>.dlq"
      },
      %{
        name: "maxlen",
        type: :integer,
        label: "Outbound MAXLEN",
        placeholder: "unlimited",
        help: "Trim stream_out to about this many entries (XADD MAXLEN ~)"
      },
      %{
        name: "start_id",
        type: :string,
        label: "Start position",
        placeholder: "earliest",
        help: "Where a new consumer group starts: earliest (default) or latest"
      },
      %{name: "batch_size", type: :integer, label: "Read batch size", placeholder: "10"},
      %{
        name: "concurrency",
        type: :integer,
        label: "Consumer concurrency",
        placeholder: "1",
        help: "Processors of the consumer; more than 1 gives up the stream order"
      },
      %{
        name: "tls_verify",
        type: :boolean,
        label: "Verify TLS certificate",
        help: "rediss:// only: verify the server certificate and host name (default true)"
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
         :ok <- Broker.check_host("redis_streams", "url", uri.host),
         :ok <- validate_keys(config),
         :ok <- validate_choice(config, "start_id", @start_ids),
         :ok <- validate_credentials(config),
         :ok <- validate_range(config, "maxlen", @max_maxlen),
         :ok <- validate_range(config, "batch_size", @max_batch),
         :ok <- validate_range(config, "concurrency", @max_concurrency) do
      Broker.validate_tls("redis_streams", config)
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

      blank?(config["stream_out"]) ->
        {:error, DeliveryError.permanent("redis_streams channel has no stream_out")}

      true ->
        stream = config["stream_out"]

        fields = [
          "payload",
          Envelope.encode(activity, channel),
          "content_type",
          "application/json",
          "event",
          "activity.created",
          "activity_id",
          activity.id,
          "conversation_id",
          activity.conversation_id,
          "tenant_id",
          activity.tenant_id || channel.tenant_id
        ]

        case RedisPublisher.xadd(channel, stream, fields,
               maxlen: Broker.positive_integer(config["maxlen"], nil),
               timeout: RetryPolicy.for_channel(channel).timeout_ms
             ) do
          {:ok, id} -> {:ok, %{provider_message_id: "#{stream}/#{id}"}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def normalize_error(%DeliveryError{} = error), do: error

  def normalize_error(reason) do
    message = "redis_streams XADD failed: #{inspect(reason)}"

    if Broker.contains_any?(reason, @permanent_errors) or permanent_redis_error?(reason),
      do: DeliveryError.permanent(message),
      else: %DeliveryError{reason: message}
  end

  # Redis error replies: WRONGTYPE (the key is not a stream), NOPERM (ACL),
  # WRONGPASS / NOAUTH (credentials).
  defp permanent_redis_error?(%Redix.Error{message: message}),
    do: String.starts_with?(message, ["WRONGTYPE", "NOPERM", "WRONGPASS", "NOAUTH"])

  defp permanent_redis_error?(_reason), do: false

  @impl true
  def parse_inbound(_channel, _params) do
    {:error,
     "redis_streams channels consume inbound messages from stream_in, not inbound webhooks"}
  end

  @impl true
  def health_probe(channel) do
    config = channel.config || %{}

    with {:ok, conn} <- connect(config, timeout: 5_000) do
      try do
        case Redix.command(conn, ["PING"], timeout: 5_000) do
          {:ok, "PONG"} -> :ok
          {:ok, other} -> {:error, {:unexpected_reply, other}}
          {:error, reason} -> {:error, reason}
        end
      after
        Redix.stop(conn)
      end
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  ## Inbound (Converger.Channels.Broker)

  @impl Converger.Channels.Broker
  def consumer_options(channel) do
    config = channel.config || %{}

    with {:ok, _options} <- connection_options(config),
         stream when is_binary(stream) and stream != "" <- config["stream_in"] do
      producer =
        {RedisStreamsProducer,
         [
           config: config,
           stream: stream,
           group: group(channel),
           consumer: consumer_name(),
           start_id: Map.fetch!(@start_ids, config["start_id"] || "earliest"),
           batch_size: Broker.positive_integer(config["batch_size"], 10)
         ]}

      {:ok,
       [
         producer: [module: producer, concurrency: 1],
         processors: [
           default: [concurrency: Broker.positive_integer(config["concurrency"], 1)]
         ]
       ]}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "redis_streams channel has no stream_in"}
    end
  end

  @impl Converger.Channels.Broker
  def message_info(_channel, %Broadway.Message{data: fields, metadata: metadata}) do
    id = "#{metadata.stream}/#{metadata.id}"
    {payload, others} = pop_field(fields, "payload")

    %{
      payload: payload,
      message_id: id,
      source: id,
      key: nil,
      headers: others
    }
  end

  defp pop_field(fields, name) do
    case List.keytake(fields, name, 0) do
      {{^name, value}, rest} -> {value, rest}
      nil -> {nil, fields}
    end
  end

  @impl Converger.Channels.Broker
  def dead_letter(channel, info, reason) do
    config = channel.config || %{}

    kept =
      for {name, value} <- info[:headers] || [],
          not String.starts_with?(name, "x-converger-"),
          do: [name, value]

    payload = if is_binary(info.payload), do: ["payload", info.payload], else: []

    fields =
      List.flatten([
        payload,
        kept,
        ["x-converger-error", reason],
        ["x-converger-source", info.source],
        ["x-converger-channel-id", channel.id]
      ])

    case RedisPublisher.xadd(channel, dlq_stream(config), fields, timeout: 10_000) do
      {:ok, _id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The consumer group of a channel: `group`, default `converger-<channel id>`."
  def group(channel) do
    case (channel.config || %{})["group"] do
      blank when blank in [nil, ""] -> "converger-#{channel.id}"
      group -> group
    end
  end

  @doc "The consumer name of this node in the group: the node name."
  def consumer_name, do: Atom.to_string(node())

  @doc "The dead-letter stream: `dlq_stream`, default `<stream_in>.dlq`."
  def dlq_stream(config) do
    case config["dlq_stream"] do
      blank when blank in [nil, ""] -> "#{config["stream_in"]}.dlq"
      stream -> stream
    end
  end

  ## Connection

  @doc """
  `Redix.start_link/1` options of a channel config: host, port and database
  from `url`, credentials, TLS for `rediss://`.
  """
  @spec connection_options(map(), keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def connection_options(config, opts \\ []) do
    with {:ok, uri} <- parse_url(config["url"]) do
      tls? = uri.scheme == "rediss"

      ssl =
        if tls?,
          do: [ssl: true, socket_opts: Broker.tls_options(Map.put(config, "tls", true), uri.host)],
          else: []

      credentials =
        cond do
          not blank?(config["username"]) ->
            [username: config["username"], password: config["password"] || ""]

          not blank?(config["password"]) ->
            [password: config["password"]]

          true ->
            []
        end

      inet6 = if String.contains?(uri.host, ":"), do: [socket_opts: [:inet6]], else: []

      {:ok,
       [
         host: uri.host,
         port: uri.port || @default_port,
         database: database(uri.path),
         timeout: Keyword.get(opts, :timeout, 10_000),
         sync_connect: true,
         exit_on_disconnection: true,
         backoff_max: 1_000
       ]
       |> Keyword.merge(credentials)
       |> merge_socket_opts(ssl, inet6)}
    end
  end

  defp merge_socket_opts(options, ssl, inet6) do
    socket_opts = Keyword.get(ssl, :socket_opts, []) ++ Keyword.get(inet6, :socket_opts, [])

    options
    |> Keyword.merge(Keyword.delete(ssl, :socket_opts))
    |> then(fn options ->
      if socket_opts == [], do: options, else: Keyword.put(options, :socket_opts, socket_opts)
    end)
  end

  @doc """
  Open a Redis connection (a `Redix` process, not linked to the caller)
  after checking the host with the SSRF guard. The caller links or
  monitors it.
  """
  @spec connect(map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(config, opts \\ []) do
    with {:ok, options} <- connection_options(config, opts),
         {:guard, :ok} <-
           {:guard, Broker.check_host("redis_streams", "url", Keyword.fetch!(options, :host))} do
      start_unlinked(fn -> Redix.start_link(options) end)
    else
      {:guard, {:error, message}} -> {:error, {:target_blocked, message}}
      {:error, message} -> {:error, {:invalid_config, message}}
    end
  end

  # Redix.start_link/1 links; a failed connect must not take the caller down.
  defp start_unlinked(start) do
    trap? = Process.flag(:trap_exit, true)

    try do
      case start.() do
        {:ok, pid} ->
          Process.unlink(pid)
          {:ok, pid}

        {:error, reason} ->
          receive do
            {:EXIT, _pid, _} -> :ok
          after
            0 -> :ok
          end

          {:error, reason}
      end
    after
      Process.flag(:trap_exit, trap?)
    end
  end

  defp database(path) when path in [nil, "", "/"], do: 0
  defp database("/" <> db), do: String.to_integer(db)

  defp parse_url(url) when is_binary(url) and url != "" do
    uri = URI.parse(url)

    case Enum.find(url_checks(), fn {valid?, _error} -> not valid?.(uri) end) do
      nil -> {:ok, uri}
      {_valid?, error} -> {:error, "redis_streams config 'url' #{error}"}
    end
  end

  defp parse_url(_),
    do: {:error, "redis_streams config 'url' must be a redis:// or rediss:// URL"}

  defp url_checks do
    [
      {&(&1.scheme in ["redis", "rediss"]), "must be a redis:// or rediss:// URL"},
      {&(not blank?(&1.host)), "must include a host"},
      {&is_nil(&1.userinfo), "must not contain credentials: set username and password"},
      {&(is_nil(&1.query) and is_nil(&1.fragment)), "must not have a query or fragment"},
      {&valid_database?(&1.path), "database must be a number (redis://host:6379/0)"}
    ]
  end

  defp valid_database?(path) when path in [nil, "", "/"], do: true

  defp valid_database?("/" <> db) do
    case Integer.parse(db) do
      {n, ""} -> n in 0..@max_database
      _ -> false
    end
  end

  defp valid_database?(_), do: false

  ## Validation

  defp validate_keys(config) do
    Enum.find_value(["stream_in", "stream_out", "dlq_stream", "group"], fn field ->
      validate_key(field, config[field])
    end) || validate_distinct_streams(config)
  end

  defp validate_key(_field, blank) when blank in [nil, ""], do: nil

  defp validate_key(field, value) when is_binary(value) and byte_size(value) <= @max_key_bytes do
    if Regex.match?(~r/\A[[:graph:]]+\z/u, value),
      do: nil,
      else: {:error, "redis_streams config '#{field}' must not contain whitespace"}
  end

  defp validate_key(field, _value),
    do:
      {:error,
       "redis_streams config '#{field}' must be a string of at most #{@max_key_bytes} bytes"}

  defp validate_distinct_streams(config) do
    stream_in = config["stream_in"]

    cond do
      not blank?(stream_in) and dlq_stream(config) == stream_in ->
        {:error, "redis_streams config 'dlq_stream' must differ from stream_in"}

      not blank?(stream_in) and config["stream_out"] == stream_in ->
        {:error, "redis_streams config 'stream_out' must differ from stream_in"}

      true ->
        :ok
    end
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
             "redis_streams config '#{field}' must be one of: #{Enum.join(Map.keys(choices), ", ")}"}
    end
  end

  defp validate_credentials(config) do
    if not blank?(config["username"]) and blank?(config["password"]),
      do: {:error, "redis_streams config 'username' needs a password"},
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
            {:error,
             "redis_streams config '#{field}' must be a positive integer of at most #{max}"}
        end
    end
  end

  defp blank?(value), do: value in [nil, ""]
end
