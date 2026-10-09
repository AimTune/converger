import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/converger start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :converger, ConvergerWeb.Endpoint, server: true
end

# Prometheus metrics listener. Not started in test (see config/test.exs), so
# concurrent test runs on one machine don't fight over the port; set
# PROMETHEUS_PORT to force one anyway.
cond do
  port = System.get_env("PROMETHEUS_PORT") ->
    config :converger, :prometheus_port, String.to_integer(port)

  config_env() != :test ->
    config :converger, :prometheus_port, 9568

  true ->
    :ok
end

# Configurable CORS origins and admin IP whitelist.
# CORS origins are read per request by ConvergerWeb.Endpoint, so this takes
# effect on releases without recompiling.
if cors_origins = System.get_env("CORS_ORIGINS") do
  config :converger,
    cors_origins:
      cors_origins
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
end

if admin_ips = System.get_env("ADMIN_IP_WHITELIST") do
  config :converger,
    admin_ip_whitelist: admin_ips |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

# Pagination limits (defaults in config/config.exs), e.g. PAGINATION_MAX_LIMIT=200.
pagination_env = [
  default_limit: "PAGINATION_DEFAULT_LIMIT",
  max_limit: "PAGINATION_MAX_LIMIT",
  activity_default_limit: "PAGINATION_ACTIVITY_DEFAULT_LIMIT",
  activity_max_limit: "PAGINATION_ACTIVITY_MAX_LIMIT",
  ws_replay_limit: "PAGINATION_WS_REPLAY_LIMIT",
  lookup_limit: "PAGINATION_LOOKUP_LIMIT"
]

pagination_overrides =
  for {key, var} <- pagination_env, value = System.get_env(var), value not in [nil, ""] do
    {key, String.to_integer(value)}
  end

# Keyword values are deep-merged with the compile-time config.
if pagination_overrides != [] do
  config :converger, :pagination, pagination_overrides
end

# Client WebSocket limits and draining (defaults in config/config.exs), e.g.
# WS_MAX_MESSAGES_PER_WINDOW=50. See docs/operations/websocket-limits.md.
websocket_env = [
  max_frame_bytes: "WS_MAX_FRAME_BYTES",
  max_messages: "WS_MAX_MESSAGES_PER_WINDOW",
  rate_window_ms: "WS_RATE_WINDOW_MS",
  max_joins: "WS_MAX_JOINS",
  ephemeral_drop_queue_len: "WS_EPHEMERAL_DROP_QUEUE_LEN",
  slow_consumer_queue_len: "WS_SLOW_CONSUMER_QUEUE_LEN",
  reconnect_base_ms: "WS_RECONNECT_BASE_MS",
  reconnect_jitter_ms: "WS_RECONNECT_JITTER_MS",
  drain_delay_ms: "WS_DRAIN_DELAY_MS",
  drain_batch_size: "WS_DRAIN_BATCH_SIZE",
  drain_batch_interval_ms: "WS_DRAIN_BATCH_INTERVAL_MS",
  drain_shutdown_ms: "WS_DRAIN_SHUTDOWN_MS"
]

websocket_overrides =
  for {key, var} <- websocket_env, value = System.get_env(var), value not in [nil, ""] do
    {key, String.to_integer(value)}
  end

if websocket_overrides != [] do
  config :converger, :websocket, websocket_overrides
end

# Oban Lifeline: jobs left `executing` by a node that died (SIGKILL, OOM, lost
# host) are made available again after OBAN_LIFELINE_RESCUE_AFTER_SECONDS
# (default 30 minutes, config/config.exs), checked every
# OBAN_LIFELINE_INTERVAL_SECONDS (Oban default 60). Lower values deliver such
# jobs sooner after a crash, but must stay well above the longest job runtime
# (webhook deliveries time out after at most ~90 s), or a slow job that is
# still running is executed twice. See docs/chaos.md.
lifeline_overrides =
  for {key, var} <- [
        rescue_after: "OBAN_LIFELINE_RESCUE_AFTER_SECONDS",
        interval: "OBAN_LIFELINE_INTERVAL_SECONDS"
      ],
      value = System.get_env(var),
      value not in [nil, ""] do
    {key, :timer.seconds(String.to_integer(value))}
  end

if lifeline_overrides != [] do
  config :converger, :oban_lifeline, lifeline_overrides
end

# Reverse proxies / load balancers allowed to set X-Forwarded-For
# (comma-separated IPs or CIDR ranges, e.g. "10.0.0.0/8,fd00::/8").
# When unset, forwarding headers are ignored and conn.remote_ip is the TCP peer.
if trusted_proxies = System.get_env("TRUSTED_PROXIES") do
  config :converger,
    trusted_proxies: trusted_proxies |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

# Webhook SSRF guard escape hatches (see Converger.Channels.UrlGuard).
# WEBHOOK_ALLOWED_TARGETS: comma-separated host names ("*.svc.local" matches
# subdomains) or IP/CIDR ranges that webhooks may target even though they are
# private. WEBHOOK_ALLOW_PRIVATE_TARGETS=true disables the guard entirely.
if allowed_targets = System.get_env("WEBHOOK_ALLOWED_TARGETS") do
  config :converger, :webhook,
    allowed_targets:
      allowed_targets
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
end

if System.get_env("WEBHOOK_ALLOW_PRIVATE_TARGETS") in ~w(true 1) do
  config :converger, :webhook, allow_private_targets: true
end

# Rate-limit backend: "local" (per-node counters) or "cluster" (counters
# replicated between nodes over PubSub). Defaults to "cluster" when node
# discovery is configured through DNS_CLUSTER_QUERY, otherwise "local".
rate_limit_backend =
  case System.get_env("RATE_LIMIT_BACKEND") do
    nil -> if System.get_env("DNS_CLUSTER_QUERY") in [nil, ""], do: nil, else: :cluster
    "local" -> :local
    "cluster" -> :cluster
    other -> raise "RATE_LIMIT_BACKEND must be \"local\" or \"cluster\", got: #{inspect(other)}"
  end

if rate_limit_backend && config_env() != :test do
  config :converger, Converger.RateLimit, backend: rate_limit_backend
end

if sync_interval = System.get_env("RATE_LIMIT_SYNC_INTERVAL_MS") do
  config :converger, Converger.RateLimit, sync_interval_ms: String.to_integer(sync_interval)
end

# OpenTelemetry trace export.
#
# Spans are exported over OTLP only when an endpoint is configured through the
# standard OTEL_EXPORTER_OTLP_ENDPOINT or OTEL_EXPORTER_OTLP_TRACES_ENDPOINT env
# vars; otherwise export is disabled (`traces_exporter: :none`) so no requests
# are attempted. The exporter itself reads the remaining standard OTLP vars
# (OTEL_EXPORTER_OTLP_PROTOCOL, OTEL_EXPORTER_OTLP_HEADERS,
# OTEL_EXPORTER_OTLP_COMPRESSION and their *_TRACES_* variants), and the SDK
# honours OTEL_SERVICE_NAME, OTEL_RESOURCE_ATTRIBUTES and OTEL_SDK_DISABLED.
# Export is always disabled in the test environment.
otel_endpoint =
  Enum.find_value(
    ["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "OTEL_EXPORTER_OTLP_ENDPOINT"],
    fn var ->
      case System.get_env(var) do
        nil -> nil
        value -> if String.trim(value) == "", do: nil, else: value
      end
    end
  )

if otel_endpoint && config_env() != :test do
  config :opentelemetry, traces_exporter: {:opentelemetry_exporter, %{}}
else
  config :opentelemetry, traces_exporter: :none
end

# File storage for attachments (see docs/storage.md). Only applied when
# UPLOAD_STORAGE is set, and never in the test environment.
if config_env() != :test and System.get_env("UPLOAD_STORAGE") do
  env = &System.get_env/1
  blank_to_nil = fn v -> if v in [nil, ""], do: nil, else: v end
  truthy? = fn v -> v in ~w(true 1 yes) end

  {storage, storage_opts} =
    case System.get_env("UPLOAD_STORAGE") do
      "local" ->
        {Converger.Uploads.LocalStorage, [dir: env.("UPLOAD_DIR") || "priv/uploads"]}

      s3 when s3 in ["s3", "minio", "r2"] ->
        {Converger.Uploads.S3Storage,
         [
           bucket: System.fetch_env!("S3_BUCKET"),
           access_key_id: System.fetch_env!("S3_ACCESS_KEY_ID"),
           secret_access_key: System.fetch_env!("S3_SECRET_ACCESS_KEY"),
           session_token: blank_to_nil.(env.("S3_SESSION_TOKEN")),
           region: blank_to_nil.(env.("S3_REGION")),
           endpoint: blank_to_nil.(env.("S3_ENDPOINT")),
           path_style:
             truthy?.(env.("S3_PATH_STYLE") || if(s3 == "s3", do: "false", else: "true"))
         ]}

      "gcs" ->
        {Converger.Uploads.GCSStorage,
         [
           bucket: System.fetch_env!("GCS_BUCKET"),
           access_key_id: System.fetch_env!("GCS_HMAC_ACCESS_ID"),
           secret_access_key: System.fetch_env!("GCS_HMAC_SECRET"),
           endpoint: blank_to_nil.(env.("GCS_ENDPOINT"))
         ]}

      "azure" ->
        {Converger.Uploads.AzureBlobStorage,
         [
           account: System.fetch_env!("AZURE_STORAGE_ACCOUNT"),
           account_key: System.fetch_env!("AZURE_STORAGE_KEY"),
           container: System.fetch_env!("AZURE_STORAGE_CONTAINER"),
           endpoint: blank_to_nil.(env.("AZURE_STORAGE_ENDPOINT"))
         ]}

      other ->
        raise "UPLOAD_STORAGE must be one of local, s3, minio, r2, gcs, azure (got #{inspect(other)})"
    end

  cdn =
    case blank_to_nil.(env.("CDN_TYPE")) do
      nil ->
        nil

      "cloudfront" ->
        private_key =
          blank_to_nil.(env.("CLOUDFRONT_PRIVATE_KEY")) ||
            File.read!(System.fetch_env!("CLOUDFRONT_PRIVATE_KEY_FILE"))

        [
          type: :cloudfront,
          base_url: System.fetch_env!("CDN_BASE_URL"),
          path_prefix: env.("CDN_PATH_PREFIX") || "",
          key_pair_id: System.fetch_env!("CLOUDFRONT_KEY_PAIR_ID"),
          private_key: private_key
        ]

      "google_cdn" ->
        [
          type: :google_cdn,
          base_url: System.fetch_env!("CDN_BASE_URL"),
          path_prefix: env.("CDN_PATH_PREFIX") || "",
          key_name: System.fetch_env!("GOOGLE_CDN_KEY_NAME"),
          key: System.fetch_env!("GOOGLE_CDN_KEY")
        ]

      "plain" ->
        [
          type: :plain,
          base_url: System.fetch_env!("CDN_BASE_URL"),
          path_prefix: env.("CDN_PATH_PREFIX") || "",
          sign_origin: truthy?.(env.("CDN_SIGN_ORIGIN"))
        ]

      other ->
        raise "CDN_TYPE must be one of cloudfront, google_cdn, plain (got #{inspect(other)})"
    end

  allowed =
    case blank_to_nil.(env.("UPLOAD_ALLOWED_TYPES")) do
      nil -> nil
      types -> String.split(types, ",", trim: true) |> Enum.map(&String.trim/1)
    end

  config :converger, Converger.Uploads,
    storage: storage,
    storage_opts: Enum.reject(storage_opts, fn {_k, v} -> is_nil(v) end),
    max_file_size: String.to_integer(env.("UPLOAD_MAX_BYTES") || "#{10 * 1024 * 1024}"),
    signed_url_ttl: String.to_integer(env.("UPLOAD_SIGNED_URL_TTL") || "300"),
    allowed_content_types: allowed,
    cdn: cdn

  # Archive of expired activities/deliveries (docs/operations/retention.md).
  # Same backend and credentials as attachments; ARCHIVE_BUCKET (S3, MinIO,
  # R2, GCS), ARCHIVE_CONTAINER (Azure) or ARCHIVE_DIR (local) put it in a
  # separate bucket/container/directory.
  archive_override =
    case storage do
      Converger.Uploads.AzureBlobStorage -> {:container, blank_to_nil.(env.("ARCHIVE_CONTAINER"))}
      Converger.Uploads.LocalStorage -> {:dir, blank_to_nil.(env.("ARCHIVE_DIR"))}
      _ -> {:bucket, blank_to_nil.(env.("ARCHIVE_BUCKET"))}
    end

  case archive_override do
    {_key, nil} ->
      :ok

    {key, value} ->
      config :converger, Converger.Archive,
        storage: storage,
        storage_opts:
          storage_opts |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Keyword.put(key, value)
  end
end

# Retention and archive tuning (defaults in config/config.exs).
retention_env = [
  min_retention_days: "RETENTION_MIN_DAYS",
  health_check_days: "HEALTH_CHECK_RETENTION_DAYS",
  audit_log_days: "AUDIT_LOG_RETENTION_DAYS"
]

retention_overrides =
  for {key, var} <- retention_env, value = System.get_env(var), value not in [nil, ""] do
    {key, String.to_integer(value)}
  end

if retention_overrides != [] do
  config :converger, Converger.Retention, retention_overrides
end

archive_overrides =
  [
    prefix: System.get_env("ARCHIVE_PREFIX"),
    part_rows:
      case System.get_env("ARCHIVE_PART_ROWS") do
        value when value in [nil, ""] -> nil
        value -> String.to_integer(value)
      end
  ]
  |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

if archive_overrides != [] do
  config :converger, Converger.Archive, archive_overrides
end

if months_ahead = System.get_env("PARTITION_MONTHS_AHEAD") do
  config :converger, Converger.Partitions, months_ahead: String.to_integer(months_ahead)
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :converger, Converger.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  if byte_size(secret_key_base) < 64 do
    raise """
    environment variable SECRET_KEY_BASE is too short (#{byte_size(secret_key_base)} bytes).
    It must be at least 64 bytes. Generate one with: mix phx.gen.secret
    """
  end

  # SHA-256 fingerprints of secrets that were published in this repository
  # (the SECRET_KEY_BASE formerly hardcoded in docker-compose.yml
  # and the demo CLOAK_KEY proposed alongside it). They are public knowledge,
  # so refuse to boot with them. See docs/security.md.
  leaked_secret_fingerprints = [
    "d759ffb9f77efdcea1576616cc59e9b9834eed3e84c1a67f95c265dd9d06ab5b",
    "43cf796f773e59d3e3729463263820ec49ca51bf04431344a7803931ee46d16c"
  ]

  for {var, value} <- [
        {"SECRET_KEY_BASE", secret_key_base},
        {"CLOAK_KEY", System.get_env("CLOAK_KEY")}
      ],
      is_binary(value),
      Base.encode16(:crypto.hash(:sha256, value), case: :lower) in leaked_secret_fingerprints do
    raise """
    environment variable #{var} is set to a value that was published in the
    Converger git repository and must be considered compromised.
    Generate a new secret and rotate it (see docs/security.md).
    """
  end

  # Key used to encrypt channel secrets and configs at rest (base64, 32 bytes).
  # Generate one with: mix run -e 'IO.puts(Converger.Vault.generate_key())'
  # For key rotation, put the previous key(s) in CLOAK_RETIRED_KEYS
  # (comma-separated) and run Converger.Release.reencrypt_secrets/0.
  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise """
      environment variable CLOAK_KEY is missing.
      It must be a base64-encoded 32 byte key, e.g. generated with:
      mix run -e 'IO.puts(Converger.Vault.generate_key())'
      """

  config :converger, Converger.Vault,
    key: cloak_key,
    retired_keys: String.split(System.get_env("CLOAK_RETIRED_KEYS") || "", ",", trim: true)

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :converger, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :converger, ConvergerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # Allowed origins for browser WebSocket connections (LiveView and the
  # Phoenix sockets). Comma-separated, e.g.
  # "https://converger.example.com,//*.example.com". When unset, Phoenix only
  # accepts the host of the endpoint `url` (PHX_HOST). Non-browser clients
  # that send no Origin header are not affected.
  if check_origin = System.get_env("CHECK_ORIGIN") do
    origins =
      check_origin
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if origins == [] do
      raise "environment variable CHECK_ORIGIN is set but contains no origins"
    end

    config :converger, ConvergerWeb.Endpoint, check_origin: origins
  end

  # HTTPS enforcement (ConvergerWeb.Plugs.ForceSSL). Enabled by default in
  # production: plain HTTP requests are redirected to https://PHX_HOST and
  # HTTPS responses carry an HSTS header. Behind a TLS-terminating proxy, set
  # TRUSTED_PROXIES so its X-Forwarded-Proto header is honoured; the header is
  # ignored from any other peer. Set FORCE_SSL=false only when TLS is
  # enforced elsewhere and the app never receives plain HTTP from clients.
  truthy? = fn var, default ->
    case System.get_env(var) do
      nil -> default
      value -> String.downcase(String.trim(value)) in ~w(true 1 yes on)
    end
  end

  if truthy?.("FORCE_SSL", true) do
    exclude_paths =
      (System.get_env("FORCE_SSL_EXCLUDE_PATHS") || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    config :converger, :force_ssl,
      hsts: truthy?.("HSTS", true),
      expires: String.to_integer(System.get_env("HSTS_MAX_AGE") || "31536000"),
      subdomains: truthy?.("HSTS_INCLUDE_SUBDOMAINS", false),
      preload: truthy?.("HSTS_PRELOAD", false),
      exclude: [hosts: ["localhost", "127.0.0.1"], paths: exclude_paths]
  else
    config :converger, :force_ssl, false
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :converger, ConvergerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # HTTP -> HTTPS redirects and HSTS are handled by the FORCE_SSL settings
  # above (ConvergerWeb.Plugs.ForceSSL), not by the endpoint's compile-time
  # `force_ssl` option.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :converger, Converger.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
