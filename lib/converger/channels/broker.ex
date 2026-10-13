defmodule Converger.Channels.Broker do
  @moduledoc """
  Broker channels: message brokers (Kafka, RabbitMQ, NATS JetStream, Redis
  Streams, MQTT) as first-class channels, and the consumers of every channel
  whose inbound messages Converger pulls instead of receiving webhooks (the
  Discord Gateway).

  A broker channel produces the activities the pipeline delivers to it to a
  topic or exchange (`deliver_activity/2`), and consumes a topic or queue for
  inbound messages. The consumer is run for each active `inbound` or
  `duplex` channel by `Converger.Channels.Consumers`, exactly once in the
  cluster: a Broadway pipeline (`Converger.Channels.Broker.Pipeline`, Kafka
  and RabbitMQ), or the process the adapter names with
  `c:consumer_child_spec/1` (an MQTT subscriber, a Discord Gateway
  connection). Broker messages use the JSON envelope of
  `Converger.Channels.Broker.Envelope`.

  This module is the behaviour broker adapters implement on top of
  `Converger.Channels.Adapter` (they declare the `:consumer` capability), and
  the broker-independent handling of a consumed message:

    1. decode the envelope (`Envelope.decode/2`);
    2. take the idempotency key: the envelope's `idempotency_key`, else the
       broker message id (`idempotency_key/3`), so a message redelivered
       after a restart or a rebalance never creates a second activity;
    3. `Converger.Inbound.receive_message/3`, the path of every inbound
       message (routing rules, middleware, deliveries).

  A message that can never be accepted (invalid JSON or envelope, a
  conversation that does not exist or is closed, a rejected activity) is a
  **poison message**: it is moved to the channel's dead-letter topic or
  queue (`c:dead_letter/3`) and acknowledged. A transient failure (database
  unavailable, an exception) is retried in place with exponential backoff,
  `inbound_max_attempts` times, and then dead-lettered as well. Writing to
  the dead-letter destination is retried until it succeeds: the message is
  only acknowledged once it is either accepted or dead-lettered.

  ## Configuration

      config :converger, :broker_channels,
        inbound_max_attempts: 8,
        inbound_backoff_ms: 500,
        inbound_max_backoff_ms: 30_000,
        dead_letter_max_backoff_ms: 30_000

  See docs/channels/brokers.md.
  """

  require Logger

  alias Converger.Activities.Activity
  alias Converger.Channels.{Adapter, UrlGuard}
  alias Converger.Channels.Broker.Envelope
  alias Converger.Inbound

  @type channel :: Converger.Channels.Channel.t()

  @typedoc """
  What a broker adapter extracts from a consumed `Broadway.Message`:

    * `:payload` - the message body (nil when the message has none, e.g. a
      Redis stream entry without a `payload` field)
    * `:message_id` - the broker message id: a stable id of this message,
      the same on every redelivery (Kafka `topic/partition/offset`, the AMQP
      `message_id` property, the JetStream `stream/sequence`, the Redis
      `stream/entry id`), or nil when the broker has none
    * `:source` - where it was consumed from, for logs and dead-letter
      headers (`"topic/partition/offset"`, the queue name)
    * `:key` - the broker's message key (Kafka), kept on dead-lettering
    * `:headers` - the message headers (`[{name, value}]`)
  """
  @type info :: %{
          required(:payload) => binary() | nil,
          required(:message_id) => String.t() | nil,
          required(:source) => String.t(),
          optional(:key) => binary() | nil,
          optional(:headers) => [{String.t(), String.t()}]
        }

  @typedoc """
  Outcome of `handle/4` and `handle_message/5`. `:dropped` is a message that
  could not be accepted on a channel without a dead-letter destination (an
  adapter without `c:dead_letter/3`): it is logged and counted, not stored.
  """
  @type outcome ::
          {:ok, :created | :duplicate, Activity.t()}
          | {:dead_lettered | :dropped, :poison | :retries_exhausted, String.t()}

  @doc """
  Broadway options of the channel's consumer: `:producer` (the Broadway
  producer spec for the channel's topic or queue), `:processors` and
  optionally `:partition_by`. `Converger.Channels.Broker.Pipeline` adds the
  name and the context. Needed unless the adapter implements
  `c:consumer_child_spec/1`.
  """
  @callback consumer_options(channel) :: {:ok, keyword()} | {:error, String.t()}

  @doc """
  Extract the payload and the broker message id of a consumed message
  (Broadway consumers).
  """
  @callback message_info(channel, Broadway.Message.t()) :: info()

  @doc """
  Move a message to the channel's dead-letter topic or queue, with `reason`.
  Called until it returns `:ok`; the consumed message is acknowledged after.
  Without it, messages that cannot be accepted are logged and dropped.
  """
  @callback dead_letter(channel, info(), reason :: String.t()) :: :ok | {:error, term()}

  @doc """
  The consumer process of the channel, as a child spec, when it is not a
  Broadway pipeline (an MQTT subscriber, a Discord Gateway connection). It
  is started under `Converger.Channels.Broker.Consumer`, so it gets the same
  cluster-wide single instance, restarts and reconciliation. Its
  `start_link` returns `{:error, reason}` for a channel it cannot consume.
  """
  @callback consumer_child_spec(channel) :: Supervisor.child_spec() | {module(), term()}

  @doc """
  Whether this particular channel needs a consumer, for adapters where it
  depends on the config (a Discord channel only with `gateway: true`).
  Without it, every active `inbound` or `duplex` channel of the type does.
  """
  @callback consume?(channel) :: boolean()

  @optional_callbacks consumer_options: 1,
                      message_info: 2,
                      dead_letter: 3,
                      consumer_child_spec: 1,
                      consume?: 1

  @doc "The broker adapter (a module with the `:consumer` capability) of `channel`."
  @spec adapter(channel) :: {:ok, module()} | :error
  def adapter(%{type: type}) do
    with true <- Adapter.capability?(type, :consumer),
         {:ok, mod} <- Adapter.adapter_for(type) do
      {:ok, mod}
    else
      _ -> :error
    end
  end

  @doc """
  Whether `channel` needs a consumer: an active `inbound` or `duplex`
  channel of a type with the `:consumer` capability (whose adapter's
  `c:consume?/1`, when it has one, agrees).
  """
  @spec consumes?(channel) :: boolean()
  def consumes?(%{status: "active", mode: mode} = channel) when mode in ["inbound", "duplex"] do
    case adapter(channel) do
      {:ok, mod} -> not exported?(mod, :consume?, 1) or mod.consume?(channel) == true
      :error -> false
    end
  end

  def consumes?(_channel), do: false

  @doc """
  The child spec of the consumer of `channel`: the adapter's
  `c:consumer_child_spec/1`, else the Broadway pipeline.
  """
  @spec consumer_child_spec(channel) :: Supervisor.child_spec() | {module(), term()}
  def consumer_child_spec(channel) do
    case adapter(channel) do
      {:ok, mod} ->
        if exported?(mod, :consumer_child_spec, 1),
          do: mod.consumer_child_spec(channel),
          else: {Converger.Channels.Broker.Pipeline, channel}

      :error ->
        {Converger.Channels.Broker.Pipeline, channel}
    end
  end

  defp exported?(mod, name, arity),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, name, arity)

  @doc """
  Handle one consumed message: accept it, or dead-letter it (see the module
  doc). Never raises.

  Options (defaults from `config :converger, :broker_channels`):
  `:max_attempts`, `:backoff_ms`, `:max_backoff_ms`, `:dead_letter_max_backoff_ms`,
  `:sleep` (a 1-arity function, for tests).
  """
  @spec handle(channel, module(), info(), keyword()) :: outcome()
  def handle(channel, adapter, info, opts \\ []) do
    run(channel, adapter, info, fn -> process(channel, info) end, opts)
  end

  @doc """
  Like `handle/4`, for a consumer that parsed the message itself (the
  Discord Gateway): `message` is passed to
  `Converger.Inbound.receive_message/3` as it is (it carries its own
  `idempotency_key`), with the same retries and dead-lettering. `info`
  names the message in logs (`:source`) and, when the adapter has a
  dead-letter destination, is what is written there.
  """
  @spec handle_message(channel, module(), map(), info(), keyword()) :: outcome()
  def handle_message(channel, adapter, message, info, opts \\ []) do
    run(channel, adapter, info, fn -> process_message(channel, message) end, opts)
  end

  defp run(channel, adapter, info, process, opts) do
    opts = Keyword.merge(settings(), opts)

    case process_with_retries(channel, info, process, opts, 1) do
      {:ok, _outcome, _activity} = ok ->
        ok

      {:dead_letter, kind, reason} ->
        if exported?(adapter, :dead_letter, 3) do
          dead_letter!(channel, adapter, info, reason, opts, 1)
          emit_dead_lettered(channel, kind)

          Logger.warning("Broker message dead-lettered",
            channel_id: channel.id,
            source: info.source,
            reason: reason
          )

          {:dead_lettered, kind, reason}
        else
          emit_dead_lettered(channel, kind)

          Logger.error("Inbound message dropped: the channel has no dead-letter destination",
            channel_id: channel.id,
            source: info.source,
            reason: reason
          )

          {:dropped, kind, reason}
        end
    end
  end

  @doc """
  Process a message parsed by the consumer once, see `process/2`.
  """
  @spec process_message(channel, map()) ::
          {:ok, :created | :duplicate, Activity.t()}
          | {:poison, String.t()}
          | {:retry, String.t()}
  def process_message(channel, message) do
    channel
    |> Inbound.receive_message(message)
    |> classify()
  rescue
    exception -> {:retry, Exception.message(exception)}
  catch
    kind, reason -> {:retry, Exception.format_banner(kind, reason)}
  end

  @doc """
  Process one consumed message once: `{:ok, :created | :duplicate, activity}`,
  `{:poison, reason}` (never accepted, dead-letter it) or `{:retry, reason}`
  (transient).
  """
  @spec process(channel, info()) ::
          {:ok, :created | :duplicate, Activity.t()}
          | {:poison, String.t()}
          | {:retry, String.t()}
  def process(channel, info) do
    case Envelope.decode(info.payload, channel) do
      {:error, reason} ->
        {:poison, reason}

      {:ok, envelope} ->
        message =
          envelope.message
          |> Map.put("idempotency_key", idempotency_key(channel, envelope, info))
          |> put_broker_metadata(channel, info)

        channel
        |> Inbound.receive_message(message, conversation_id: envelope.conversation_id)
        |> classify()
    end
  rescue
    exception -> {:retry, Exception.message(exception)}
  catch
    kind, reason -> {:retry, Exception.format_banner(kind, reason)}
  end

  defp classify({:created, activity}), do: {:ok, :created, activity}
  defp classify({:duplicate, activity}), do: {:ok, :duplicate, activity}

  defp classify({:rejected, %Ecto.Changeset{} = changeset}),
    do: {:poison, "rejected: #{format_errors(changeset)}"}

  defp classify({:error, :not_found}), do: {:poison, "conversation not found"}
  defp classify({:error, :conversation_closed}), do: {:poison, "conversation is closed"}

  defp classify({:error, :inbound_not_supported}),
    do: {:poison, "channel does not accept inbound messages"}

  defp classify({:error, reason}), do: {:retry, inspect(reason)}

  defp format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(inspect_value(value)))
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{inspect(messages)}" end)
  end

  defp inspect_value(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: value

  defp inspect_value(value), do: inspect(value)

  @doc """
  The idempotency key of a consumed message: the envelope's
  `idempotency_key`, else `"<channel type>:<broker message id>"`, else nil
  (no broker id: redeliveries are not recognised).
  """
  @spec idempotency_key(map(), map(), info()) :: String.t() | nil
  def idempotency_key(_channel, %{idempotency_key: key}, _info) when is_binary(key), do: key

  def idempotency_key(%{type: type}, _envelope, %{message_id: id}) when is_binary(id),
    do: "#{type}:#{id}"

  def idempotency_key(_channel, _envelope, _info), do: nil

  # The consumed message is marked as coming from this channel, so it is not
  # produced back to the same channel (see echo?/2), and keeps where it came
  # from. Set server-side: overrides any client value of the key.
  defp put_broker_metadata(message, channel, info) do
    broker = %{
      "channel_id" => channel.id,
      "message_id" => info.message_id,
      "source" => info.source
    }

    Map.update(message, "metadata", %{"converger_broker" => broker}, fn metadata ->
      Map.put(metadata || %{}, "converger_broker", broker)
    end)
  end

  @doc """
  Whether `activity` was consumed from `channel` itself. Such an activity is
  not produced back to the channel's outbound topic (its conversation's
  primary channel is the broker channel, so the pipeline would otherwise
  deliver it there).
  """
  @spec echo?(map(), Activity.t()) :: boolean()
  def echo?(%{id: channel_id}, %Activity{metadata: %{"converger_broker" => %{"channel_id" => id}}})
      when is_binary(channel_id),
      do: id == channel_id

  def echo?(_channel, _activity), do: false

  ## Retries

  defp process_with_retries(channel, info, process, opts, attempt) do
    case process.() do
      {:ok, _outcome, _activity} = ok ->
        ok

      {:poison, reason} ->
        {:dead_letter, :poison, reason}

      {:retry, reason} ->
        max_attempts = Keyword.fetch!(opts, :max_attempts)

        if attempt >= max_attempts do
          {:dead_letter, :retries_exhausted,
           "failed after #{attempt} attempts, last error: #{reason}"}
        else
          :telemetry.execute([:converger, :broker, :retry], %{count: 1}, %{
            channel_id: channel.id,
            channel_type: channel.type
          })

          Logger.warning("Broker message failed, retrying",
            channel_id: channel.id,
            source: info.source,
            attempts: attempt,
            reason: reason
          )

          sleep(opts, backoff(opts, :backoff_ms, :max_backoff_ms, attempt))
          process_with_retries(channel, info, process, opts, attempt + 1)
        end
    end
  end

  # The dead-letter write is retried until it succeeds: the consumed message
  # is acknowledged (its offset committed) only afterwards, so a message is
  # never lost. When the consumer is stopped meanwhile, the message is not
  # acknowledged and is consumed again after the restart.
  defp dead_letter!(channel, adapter, info, reason, opts, attempt) do
    result =
      try do
        adapter.dead_letter(channel, info, reason)
      rescue
        exception -> {:error, Exception.message(exception)}
      catch
        kind, error -> {:error, Exception.format_banner(kind, error)}
      end

    case result do
      :ok ->
        :ok

      {:error, error} ->
        Logger.error("Broker dead-letter write failed, retrying",
          channel_id: channel.id,
          source: info.source,
          attempts: attempt,
          error: inspect(error)
        )

        sleep(opts, backoff(opts, :backoff_ms, :dead_letter_max_backoff_ms, attempt))
        dead_letter!(channel, adapter, info, reason, opts, attempt + 1)
    end
  end

  @doc false
  def backoff(opts, base_key, max_key, attempt) do
    base = Keyword.fetch!(opts, base_key)
    max = Keyword.fetch!(opts, max_key)
    min(base * Integer.pow(2, min(attempt - 1, 20)), max)
  end

  defp sleep(opts, ms) do
    case Keyword.get(opts, :sleep) do
      fun when is_function(fun, 1) -> fun.(ms)
      _ -> Process.sleep(ms)
    end
  end

  defp emit_dead_lettered(channel, kind) do
    :telemetry.execute([:converger, :broker, :dead_lettered], %{count: 1}, %{
      channel_id: channel.id,
      channel_type: channel.type,
      tenant_id: channel.tenant_id,
      reason: kind
    })
  end

  @defaults [
    max_attempts: 8,
    backoff_ms: 500,
    max_backoff_ms: 30_000,
    dead_letter_max_backoff_ms: 30_000
  ]

  @app_keys [
    max_attempts: :inbound_max_attempts,
    backoff_ms: :inbound_backoff_ms,
    max_backoff_ms: :inbound_max_backoff_ms,
    dead_letter_max_backoff_ms: :dead_letter_max_backoff_ms
  ]

  @doc "Retry settings from `config :converger, :broker_channels`."
  def settings do
    config = Application.get_env(:converger, :broker_channels, [])

    for {key, default} <- @defaults do
      {key, Keyword.get(config, Keyword.fetch!(@app_keys, key), default)}
    end
  end

  ## Helpers shared by the broker adapters

  @doc """
  Whether any of `atoms` occurs in `term` (nested in tuples, lists and
  maps). Broker client errors nest their reason codes, e.g.
  `{:error, [{{"kafka", 9092}, {:sasl_authentication_failed, _}}]}`.
  """
  @spec contains_any?(term(), [atom()]) :: boolean()
  def contains_any?(term, atoms) when is_atom(term), do: term in atoms

  def contains_any?(term, atoms) when is_tuple(term),
    do: contains_any?(Tuple.to_list(term), atoms)

  def contains_any?(term, atoms) when is_list(term),
    do: Enum.any?(term, &contains_any?(&1, atoms))

  def contains_any?(%{} = term, atoms) when not is_struct(term),
    do: contains_any?(Map.values(term), atoms)

  def contains_any?(_term, _atoms), do: false

  @doc "Parse a boolean config value (`true`, `\"true\"`), with a default for blanks."
  def boolean(value, default \\ false)
  def boolean(value, _default) when value in [true, "true"], do: true
  def boolean(value, _default) when value in [false, "false"], do: false
  def boolean(_value, default), do: default

  @doc "Parse a positive integer config value, with a default for blanks and invalid values."
  def positive_integer(value, default) do
    case value do
      int when is_integer(int) and int > 0 ->
        int

      string when is_binary(string) ->
        case Integer.parse(String.trim(string)) do
          {int, ""} when int > 0 -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  @doc """
  Check that a broker host is an allowed target, with the SSRF guard of
  outbound webhooks (`Converger.Channels.UrlGuard`, configured by
  `WEBHOOK_ALLOW_PRIVATE_TARGETS` / `WEBHOOK_ALLOWED_TARGETS`).
  """
  @spec check_host(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def check_host(type, field, host) do
    url = "http://#{host_for_url(host)}/"

    case UrlGuard.check(url) do
      :ok ->
        :ok

      {:error, message} ->
        {:error, "#{type} config '#{field}' host #{host} is not allowed: #{message}"}
    end
  end

  defp host_for_url(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  @doc """
  TLS options from the channel config: `tls` (default false), `tls_verify`
  (default true, verifies the server certificate against `tls_ca_cert` or
  the OS trust store) and `tls_ca_cert` (PEM). Returns `false` or a keyword
  list of `:ssl` client options.
  """
  @spec tls_options(map(), String.t()) :: false | keyword()
  def tls_options(config, server_name) do
    if boolean(config["tls"]) do
      if boolean(config["tls_verify"], true) do
        [
          verify: :verify_peer,
          cacerts: cacerts(config["tls_ca_cert"]),
          server_name_indication: String.to_charlist(server_name),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ],
          depth: 10
        ]
      else
        [verify: :verify_none]
      end
    else
      false
    end
  end

  defp cacerts(pem) when is_binary(pem) and pem != "" do
    case pem_certificates(pem) do
      {:ok, ders} -> ders
      :error -> :public_key.cacerts_get()
    end
  end

  defp cacerts(_), do: :public_key.cacerts_get()

  @doc "Validate the TLS config keys. Returns `:ok` or `{:error, message}`."
  def validate_tls(type, config) do
    case config["tls_ca_cert"] do
      blank when blank in [nil, ""] ->
        :ok

      pem when is_binary(pem) ->
        case pem_certificates(pem) do
          {:ok, _} -> :ok
          :error -> {:error, "#{type} config 'tls_ca_cert' must be PEM-encoded certificates"}
        end

      _ ->
        {:error, "#{type} config 'tls_ca_cert' must be PEM-encoded certificates"}
    end
  end

  defp pem_certificates(pem) do
    case :public_key.pem_decode(pem) do
      [] ->
        :error

      entries ->
        ders = for {:Certificate, der, :not_encrypted} <- entries, do: der
        if ders == [], do: :error, else: {:ok, ders}
    end
  rescue
    _ -> :error
  end
end
