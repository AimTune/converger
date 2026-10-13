defmodule Converger.Channels.Adapters.Nats do
  @moduledoc """
  NATS JetStream as a channel (broker channel, see
  `Converger.Channels.Broker`).

  ## Outbound

  Every activity the pipeline delivers to the channel is published to
  `subject_out` with a JetStream publish (a request answered by the stream
  with a publish acknowledgement), as the JSON envelope of
  `Converger.Channels.Broker.Envelope`. The token `{conversation_id}` in
  `subject_out` is replaced with the activity's conversation id
  (`crm.out.{conversation_id}`), so subscribers can filter one
  conversation. Headers: `Nats-Msg-Id` (the activity id: JetStream drops a
  retried publish of the same activity within the stream's duplicate
  window), `Content-Type: application/json`, `X-Converger-Event`,
  `X-Converger-Activity-Id`, `X-Converger-Conversation-Id`,
  `X-Converger-Tenant-Id`. The delivery's provider message id is
  `stream/sequence` from the publish acknowledgement. A subject no stream
  captures fails the delivery (`no_responders`), it is retried.

  ## Inbound

  `Converger.Channels.Consumers` runs one consumer for the channel in the
  cluster: a Broadway pipeline with a
  `Converger.Channels.Broker.NatsProducer`, which pulls from the durable
  pull consumer `durable_name` (default `converger-<channel id>`) of
  `stream`, filtered on `subject_in`. A message is acknowledged (`+ACK`)
  after it is accepted or dead-lettered; without an envelope
  `idempotency_key` its key is `nats:<stream>/<stream sequence>`, so a
  redelivery after a restart is recognised as a duplicate. Poison messages
  are published, with a JetStream publish, to `dlq_subject` (default
  `<subject_in>.dlq`) with the original headers plus `X-Converger-Error`,
  `X-Converger-Source` and `X-Converger-Channel-Id`. With `declare: true`
  the consumer creates `stream` (subjects `subject_in` and `dlq_subject`)
  when it does not exist; the durable consumer is always created when
  missing.

  ## Config

  See `config_schema/0` and docs/channels/nats.md.
  """

  use Converger.Channels.Adapter, type: "nats"

  @behaviour Converger.Channels.Broker

  alias Converger.Channels.{Broker, DeliveryError}
  alias Converger.Channels.Broker.{Envelope, NatsProducer, NatsPublisher}
  alias Converger.Pipeline.RetryPolicy

  @name_pattern ~r/\A[A-Za-z0-9_-]{1,255}\z/
  @deliver_policies %{"all" => :all, "new" => :new}
  @max_concurrency 64
  @max_batch 256
  @max_ack_wait_seconds 86_400
  @default_port 4222
  @conversation_token "{conversation_id}"

  # Errors no retry can fix until the channel or the server is reconfigured.
  @permanent_errors [:max_payload_exceeded, :target_blocked, :invalid_config, :bad_request]

  @impl true
  def capabilities, do: [:inbound, :outbound, :external_delivery, :lifecycle_events, :consumer]

  @impl true
  def config_schema do
    [
      %{
        name: "servers",
        type: :string,
        required: true,
        label: "Servers",
        placeholder: "nats://nats-1:4222,nats://nats-2:4222",
        help: "nats:// or tls:// URLs (or host:port), tried in order",
        summary: true
      },
      %{
        name: "stream",
        type: :string,
        required: :inbound,
        label: "Stream",
        placeholder: "CRM",
        help: "The JetStream stream consumed for inbound messages (inbound and duplex mode)",
        summary: true
      },
      %{
        name: "subject_in",
        type: :string,
        required: :inbound,
        label: "Inbound subject",
        placeholder: "crm.in",
        help: "The consumer's filter subject in the stream",
        summary: true
      },
      %{
        name: "subject_out",
        type: :string,
        required: :outbound,
        label: "Outbound subject",
        placeholder: "crm.out or crm.out.{conversation_id}",
        help:
          "Activities are published here (outbound and duplex mode); a stream must capture it",
        summary: true
      },
      %{
        name: "durable_name",
        type: :string,
        label: "Durable consumer",
        placeholder: "converger-<channel id>"
      },
      %{
        name: "dlq_subject",
        type: :string,
        label: "Dead-letter subject",
        placeholder: "<subject_in>.dlq"
      },
      %{
        name: "declare",
        type: :boolean,
        label: "Create the stream",
        help: "Create stream (subjects subject_in and dlq_subject) when missing (default false)"
      },
      %{
        name: "deliver_policy",
        type: :string,
        label: "Deliver policy",
        placeholder: "all",
        help: "Where a new durable consumer starts: all (default) or new"
      },
      %{name: "batch_size", type: :integer, label: "Pull batch size", placeholder: "10"},
      %{
        name: "ack_wait_seconds",
        type: :integer,
        label: "Ack wait (seconds)",
        placeholder: "300",
        help: "Redelivery timeout of an unacknowledged message; covers the in-place retries"
      },
      %{
        name: "concurrency",
        type: :integer,
        label: "Consumer concurrency",
        placeholder: "1",
        help: "Processors of the consumer; more than 1 gives up the stream order"
      },
      %{name: "username", type: :string, label: "Username"},
      %{name: "password", type: :string, secret: true, label: "Password"},
      %{name: "token", type: :string, secret: true, label: "Token"},
      %{name: "nkey_seed", type: :string, secret: true, label: "NKey seed"},
      %{
        name: "creds",
        type: :string,
        form: false,
        help: "Contents of a .creds file (user JWT and NKey seed), for decentralized auth"
      },
      %{name: "tls", type: :boolean, label: "TLS", help: "Connect with TLS (default false)"},
      %{
        name: "tls_verify",
        type: :boolean,
        label: "Verify TLS certificate",
        help: "Verify the server certificate and host name (default true)"
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
    with {:ok, servers} <- servers(config),
         :ok <- check_hosts(servers),
         :ok <- validate_names(config),
         :ok <- validate_subjects(config),
         :ok <- validate_choice(config, "deliver_policy", @deliver_policies),
         :ok <- validate_auth(config),
         :ok <- validate_range(config, "batch_size", @max_batch),
         :ok <- validate_range(config, "ack_wait_seconds", @max_ack_wait_seconds),
         :ok <- validate_range(config, "concurrency", @max_concurrency) do
      Broker.validate_tls("nats", config)
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

      blank?(config["subject_out"]) ->
        {:error, DeliveryError.permanent("nats channel has no subject_out")}

      true ->
        headers = [
          {"Nats-Msg-Id", activity.id},
          {"Content-Type", "application/json"},
          {"X-Converger-Event", "activity.created"},
          {"X-Converger-Activity-Id", activity.id},
          {"X-Converger-Conversation-Id", activity.conversation_id},
          {"X-Converger-Tenant-Id", activity.tenant_id || channel.tenant_id}
        ]

        case NatsPublisher.publish(
               channel,
               subject_out(config, activity.conversation_id),
               Envelope.encode(activity, channel),
               headers: headers,
               timeout: RetryPolicy.for_channel(channel).timeout_ms
             ) do
          {:ok, %{stream: stream, seq: seq}} -> {:ok, %{provider_message_id: "#{stream}/#{seq}"}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "The outbound subject of a conversation: `subject_out` with `{conversation_id}` replaced."
  @spec subject_out(map(), String.t() | nil) :: String.t()
  def subject_out(config, conversation_id),
    do: String.replace(config["subject_out"] || "", @conversation_token, conversation_id || "_")

  @impl true
  def normalize_error(%DeliveryError{} = error), do: error

  def normalize_error(reason) do
    message = "nats publish failed: #{inspect(reason)}"

    if Broker.contains_any?(reason, @permanent_errors),
      do: DeliveryError.permanent(message),
      else: %DeliveryError{reason: message}
  end

  @impl true
  def parse_inbound(_channel, _params) do
    {:error, "nats channels consume inbound messages from their stream, not inbound webhooks"}
  end

  @impl true
  def health_probe(channel) do
    config = channel.config || %{}

    with {:ok, conn} <- connect(config, connection_timeout: 5_000) do
      try do
        case config["stream"] do
          blank when blank in [nil, ""] ->
            :ok

          stream ->
            case Gnat.Jetstream.API.Stream.info(conn, stream) do
              {:ok, _info} -> :ok
              {:error, reason} -> {:error, {:stream, stream, reason}}
            end
        end
      after
        Gnat.stop(conn)
      end
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  ## Inbound (Converger.Channels.Broker)

  @impl Converger.Channels.Broker
  def consumer_options(channel) do
    config = channel.config || %{}

    with {:ok, servers} <- servers(config),
         :ok <- check_hosts(servers),
         stream when is_binary(stream) and stream != "" <- config["stream"],
         subject when is_binary(subject) and subject != "" <- config["subject_in"] do
      producer =
        {NatsProducer,
         [
           config: config,
           stream: stream,
           subject: subject,
           durable_name: durable_name(channel),
           dlq_subject: dlq_subject(config),
           declare: Broker.boolean(config["declare"]),
           deliver_policy: Map.fetch!(@deliver_policies, config["deliver_policy"] || "all"),
           ack_wait_ms: Broker.positive_integer(config["ack_wait_seconds"], 300) * 1_000,
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
      _ -> {:error, "nats channel has no stream or subject_in"}
    end
  end

  @impl Converger.Channels.Broker
  def message_info(_channel, %Broadway.Message{data: data, metadata: metadata}) do
    id = "#{metadata.stream}/#{metadata.stream_seq}"

    %{
      payload: data,
      message_id: id,
      source: id,
      key: metadata.subject,
      headers: Map.get(metadata, :headers) || []
    }
  end

  @impl Converger.Channels.Broker
  def dead_letter(channel, info, reason) do
    config = channel.config || %{}

    headers =
      Enum.reject(info[:headers] || [], fn {name, _} ->
        name |> String.downcase() |> String.starts_with?(["x-converger-", "nats-"])
      end) ++
        [
          # A repeated dead-letter write of the same message is dropped by
          # the stream's duplicate window.
          {"Nats-Msg-Id", "dlq:#{info.message_id}"},
          {"X-Converger-Error", single_line(reason)},
          {"X-Converger-Source", info.source},
          {"X-Converger-Channel-Id", channel.id}
        ]

    case NatsPublisher.publish(channel, dlq_subject(config), info.payload || "",
           headers: headers,
           timeout: 10_000
         ) do
      {:ok, _ack} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # NATS header values end at a line break.
  defp single_line(value), do: String.replace(value, ~r/[\r\n]+/, " ")

  @doc "The durable consumer of a channel: `durable_name`, default `converger-<channel id>`."
  def durable_name(channel) do
    case (channel.config || %{})["durable_name"] do
      blank when blank in [nil, ""] -> "converger-#{channel.id}"
      name -> name
    end
  end

  @doc "The dead-letter subject: `dlq_subject`, default `<subject_in>.dlq`."
  def dlq_subject(config) do
    case config["dlq_subject"] do
      blank when blank in [nil, ""] -> "#{config["subject_in"]}.dlq"
      subject -> subject
    end
  end

  ## Connection

  @doc """
  The servers of a config (`"nats://host:port,tls://host:port"`, `host:port`,
  IPv6 as `[::1]:4222`) as `[%{host, port, tls}]`.
  """
  @spec servers(map()) :: {:ok, [map()]} | {:error, String.t()}
  def servers(config) do
    entries =
      (config["servers"] || "")
      |> to_string()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    parsed = Enum.map(entries, &parse_server/1)

    cond do
      entries == [] ->
        {:error, "nats config 'servers' must list at least one server"}

      error = Enum.find(parsed, &match?({:error, _}, &1)) ->
        error

      true ->
        {:ok, Enum.map(parsed, fn {:ok, server} -> server end)}
    end
  end

  defp parse_server(entry) do
    uri = URI.parse(if String.contains?(entry, "://"), do: entry, else: "nats://" <> entry)

    case Enum.find(server_checks(), fn {valid?, _error} -> not valid?.(uri) end) do
      nil -> {:ok, %{host: uri.host, port: uri.port || @default_port, tls: uri.scheme == "tls"}}
      {_valid?, error} -> {:error, "nats config 'servers' #{error}"}
    end
  end

  defp server_checks do
    [
      {&(&1.scheme in ["nats", "tls"]), "must be nats:// or tls:// URLs"},
      {&(is_binary(&1.host) and Regex.match?(~r/\A[A-Za-z0-9.\-_:]+\z/, &1.host)),
       "must be comma-separated URLs with a host"},
      {&is_nil(&1.userinfo), "must not contain credentials: set username and password"},
      {&(&1.path in [nil, "", "/"] and is_nil(&1.query) and is_nil(&1.fragment)),
       "must be host and port only"}
    ]
  end

  @doc "Check the server hosts with the SSRF guard (`Converger.Channels.Broker.check_host/3`)."
  def check_hosts(servers) do
    Enum.find_value(servers, :ok, fn %{host: host} ->
      case Broker.check_host("nats", "servers", host) do
        :ok -> nil
        error -> error
      end
    end)
  end

  @doc """
  The `Gnat` connection settings of a config for `server`: TLS, credentials
  (as functions, so they stay out of crash reports), headers and
  `no_responders` (a publish no stream captures fails at once).
  """
  @spec connection_settings(map(), map(), keyword()) :: map()
  def connection_settings(config, server, opts \\ []) do
    tls? = server.tls or Broker.boolean(config["tls"])
    inet6 = if String.contains?(server.host, ":"), do: [:inet6], else: []

    %{
      host: server.host,
      port: server.port,
      tcp_opts: [:binary | inet6],
      tls: tls?,
      ssl_opts:
        if(tls?, do: Broker.tls_options(Map.put(config, "tls", true), server.host), else: []),
      connection_timeout: Keyword.get(opts, :connection_timeout, 10_000),
      no_responders: true,
      name: "converger"
    }
    |> Map.merge(auth_settings(config))
  end

  defp auth_settings(config) do
    cond do
      not blank?(config["creds"]) ->
        {:ok, jwt, seed} = parse_creds(config["creds"])
        %{jwt: jwt, nkey_seed: fn -> seed end}

      not blank?(config["nkey_seed"]) ->
        seed = String.trim(config["nkey_seed"])
        %{nkey_seed: fn -> seed end}

      not blank?(config["token"]) ->
        token = config["token"]
        %{token: fn -> token end}

      not blank?(config["username"]) ->
        password = config["password"] || ""
        %{username: config["username"], password: fn -> password end}

      true ->
        %{}
    end
  end

  @doc """
  Open a NATS connection (a `Gnat` process, not linked to the caller) to the
  first server of `config` that accepts it, after checking its host with
  the SSRF guard. The caller links or monitors it.
  """
  @spec connect(map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(config, opts \\ []) do
    with {:ok, servers} <- servers(config),
         {:guard, :ok} <- {:guard, check_hosts(servers)} do
      timeout = Keyword.get(opts, :connection_timeout, 10_000)

      Enum.reduce_while(servers, {:error, :no_servers}, fn server, _acc ->
        with {:ok, pid} <- GenServer.start(Gnat, connection_settings(config, server, opts)),
             :ok <- verify(pid, timeout) do
          {:halt, {:ok, pid}}
        else
          {:error, reason} -> {:cont, {:error, reason}}
        end
      end)
    else
      {:guard, {:error, message}} -> {:error, {:target_blocked, message}}
      {:error, message} -> {:error, {:invalid_config, message}}
    end
  end

  # The handshake does not wait for the server to accept the credentials: a
  # JetStream account info request proves the connection is authorised and
  # JetStream is enabled. A server that rejects the credentials closes the
  # connection (Authorization Violation).
  defp verify(conn, timeout) do
    result =
      case Gnat.request(conn, "$JS.API.INFO", "", receive_timeout: timeout) do
        {:ok, %{body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"error" => error}} ->
              {:error, {:jetstream, error["code"], error["description"]}}

            {:ok, %{}} ->
              :ok

            _ ->
              {:error, {:unexpected_reply, body}}
          end

        {:error, :no_responders} ->
          {:error, :jetstream_not_enabled}

        {:error, reason} ->
          {:error, if(Process.alive?(conn), do: reason, else: :connection_rejected)}
      end

    if result != :ok, do: stop_quietly(conn)
    result
  catch
    :exit, _ -> {:error, :connection_rejected}
  end

  defp stop_quietly(conn) do
    if Process.alive?(conn), do: Gnat.stop(conn)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  The user JWT and NKey seed of a `.creds` file. Returns `{:ok, jwt, seed}`
  or `:error`.
  """
  @spec parse_creds(String.t()) :: {:ok, String.t(), String.t()} | :error
  def parse_creds(creds) when is_binary(creds) do
    with [_, jwt] <- Regex.run(~r/-{3,}BEGIN NATS USER JWT-{3,}\s+(\S+)\s+-{3,}END/, creds),
         [_, seed] <- Regex.run(~r/-{3,}BEGIN USER NKEY SEED-{3,}\s+(\S+)\s+-{3,}END/, creds),
         true <- valid_seed?(seed) do
      {:ok, jwt, seed}
    else
      _ -> :error
    end
  end

  def parse_creds(_), do: :error

  defp valid_seed?(seed) do
    match?({:ok, _}, NKEYS.from_seed(seed))
  rescue
    _ -> false
  end

  ## Subjects

  @doc """
  Whether `subject` is a valid NATS subject: dot-separated non-empty tokens
  without whitespace; with `wildcards?`, `*` tokens and a final `>` token.
  """
  @spec valid_subject?(term(), boolean()) :: boolean()
  def valid_subject?(subject, wildcards?) when is_binary(subject) do
    tokens = String.split(subject, ".")
    last = length(tokens) - 1

    byte_size(subject) <= 1_024 and not Regex.match?(~r/[\s]/u, subject) and
      tokens
      |> Enum.with_index()
      |> Enum.all?(fn {token, index} ->
        cond do
          token == "" -> false
          token == "*" -> wildcards?
          token == ">" -> wildcards? and index == last
          true -> not String.contains?(token, ["*", ">"])
        end
      end)
  end

  def valid_subject?(_subject, _wildcards?), do: false

  @doc "Whether the subject filter `pattern` (with `*` / `>` wildcards) matches `subject`."
  @spec subject_matches?(String.t(), String.t()) :: boolean()
  def subject_matches?(pattern, subject),
    do: match_tokens(String.split(pattern, "."), String.split(subject, "."))

  defp match_tokens([">"], [_ | _]), do: true
  defp match_tokens(["*" | pattern], [_ | subject]), do: match_tokens(pattern, subject)
  defp match_tokens([token | pattern], [token | subject]), do: match_tokens(pattern, subject)
  defp match_tokens([], []), do: true
  defp match_tokens(_pattern, _subject), do: false

  ## Validation

  defp validate_names(config) do
    Enum.find_value(["stream", "durable_name"], :ok, fn field ->
      value = config[field]

      if blank?(value) or (is_binary(value) and Regex.match?(@name_pattern, value)),
        do: nil,
        else:
          {:error,
           "nats config '#{field}' must be a name of letters, digits, '_' and '-' (at most 255)"}
    end)
  end

  defp validate_subjects(config) do
    subject_in = config["subject_in"]
    subject_out = config["subject_out"]

    checks = [
      {"subject_in", subject_in, true},
      {"subject_out",
       is_binary(subject_out) && String.replace(subject_out, @conversation_token, "c"), false},
      {"dlq_subject", config["dlq_subject"], false}
    ]

    invalid =
      Enum.find_value(checks, fn {field, value, wildcards?} ->
        cond do
          blank?(config[field]) -> nil
          valid_subject?(value, wildcards?) -> nil
          wildcards? -> {:error, "nats config '#{field}' must be a NATS subject"}
          true -> {:error, "nats config '#{field}' must be a NATS subject without wildcards"}
        end
      end)

    invalid || validate_subject_loops(config, subject_in, subject_out)
  end

  defp validate_subject_loops(_config, subject_in, _subject_out) when subject_in in [nil, ""],
    do: :ok

  defp validate_subject_loops(config, subject_in, subject_out) do
    dlq = dlq_subject(config)
    sample_out = is_binary(subject_out) && subject_out(config, Ecto.UUID.generate())

    cond do
      not valid_subject?(dlq, false) ->
        {:error, "nats config 'dlq_subject' is required when subject_in has wildcards"}

      subject_matches?(subject_in, dlq) ->
        {:error, "nats config 'dlq_subject' must not match subject_in"}

      is_binary(sample_out) and sample_out != "" and subject_matches?(subject_in, sample_out) ->
        {:error, "nats config 'subject_out' must not match subject_in"}

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
             "nats config '#{field}' must be one of: #{Enum.join(Map.keys(choices), ", ")}"}
    end
  end

  defp validate_auth(config) do
    methods =
      Enum.filter(
        [
          {"username", "username"},
          {"token", "token"},
          {"nkey_seed", "nkey_seed"},
          {"creds", "creds"}
        ],
        fn {_name, field} -> not blank?(config[field]) end
      )

    cond do
      length(methods) > 1 ->
        {:error,
         "nats config must use one authentication method: username/password, token, nkey_seed or creds"}

      blank?(config["username"]) and not blank?(config["password"]) ->
        {:error, "nats config 'password' needs a username"}

      not blank?(config["nkey_seed"]) and not valid_seed_value?(config["nkey_seed"]) ->
        {:error, "nats config 'nkey_seed' must be an NKey user seed (SU...)"}

      not blank?(config["creds"]) and parse_creds(config["creds"]) == :error ->
        {:error, "nats config 'creds' must be the contents of a NATS .creds file"}

      true ->
        :ok
    end
  end

  defp valid_seed_value?(seed) when is_binary(seed), do: valid_seed?(String.trim(seed))
  defp valid_seed_value?(_seed), do: false

  defp validate_range(config, field, max) do
    case config[field] do
      blank when blank in [nil, ""] ->
        :ok

      value ->
        case Broker.positive_integer(value, nil) do
          int when is_integer(int) and int <= max ->
            :ok

          _ ->
            {:error, "nats config '#{field}' must be a positive integer of at most #{max}"}
        end
    end
  end

  defp blank?(value), do: value in [nil, ""]
end
