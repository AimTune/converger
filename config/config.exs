# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :converger,
  env: config_env(),
  ecto_repos: [Converger.Repo],
  generators: [timestamp_type: :utc_datetime],
  cors_origins: ["http://127.0.0.1:5500", "http://localhost:5500"],
  admin_ip_whitelist: ["127.0.0.1", "::1"],
  trusted_proxies: [],
  pipeline: [backend: Converger.Pipeline.Oban],
  # Allowed clock skew for timestamped `x-converger-signature` inbound signatures
  inbound_signature_tolerance_seconds: 300

# Page sizes for every list query (see Converger.Pagination). Request-supplied
# `limit` params are clamped to the max; omitted/invalid ones use the default.
config :converger, :pagination,
  # Conversations, audit logs, deliveries, tenant users (REST + admin tables)
  default_limit: 50,
  max_limit: 500,
  # Activities (REST `?limit=` and the admin/portal transcript views)
  activity_default_limit: 100,
  activity_max_limit: 1000,
  # Max activities replayed on WebSocket join; the rest come over REST
  ws_replay_limit: 100,
  # Hard cap for small operator-managed tables listed whole
  # (tenants, channels, routing rules, admin users)
  lookup_limit: 1000

# Converger Protocol v1 transports: the native WebSocket (/socket/converger/v1)
# and the Server-Sent Events stream (see ConvergerWeb.Protocol). The replay
# batch is :ws_replay_limit above.
config :converger, ConvergerWeb.Protocol,
  # outbound silence before the server sends a `heartbeat`
  heartbeat_interval_ms: 30_000,
  # inbound silence before the socket is closed with 4408
  idle_timeout_ms: 60_000,
  # larger frames get `payload_too_large`; above the hard cap the socket closes (1009)
  max_frame_bytes: 131_072,
  max_frame_hard_bytes: 1_048_576,
  # frames replayed per handshake or `sync`; beyond it `replayTruncated`
  replay_max: 10_000

# Tokens travel in query strings (`?token=` on sockets and the SSE stream):
# keep them out of request logs.
config :phoenix, :filter_parameters, ["password", "token", "secret"]

# Dead-letter replay and export (see Converger.Deliveries.retry_dead_letters/3
# and ConvergerWeb.DeliveryExportController).
config :converger, :dead_letters,
  # Max deliveries replayed by one bulk retry call
  bulk_retry_limit: 10_000,
  # Max rows in one CSV export
  export_limit: 10_000

# Serialize migration runs with a session-level Postgres advisory lock instead
# of the default table lock. Concurrent `Converger.Release.migrate/0` calls
# (e.g. several replicas or init containers starting at once) wait for the
# lock holder, then find nothing pending, so each migration runs exactly once.
# Unlike the table lock it also works with `@disable_ddl_transaction`
# migrations such as `create index(..., concurrently: true)`.
# Requires a session-mode connection (not PgBouncer transaction pooling).
config :converger, Converger.Repo,
  migration_lock: :pg_advisory_lock,
  migration_advisory_lock_retry_interval_ms: 1_000

# File uploads / attachments. Backends, CDN options and env vars are
# documented in docs/storage.md; production values come from runtime.exs.
config :converger, Converger.Uploads,
  storage: Converger.Uploads.LocalStorage,
  # Not under priv/static: files are only served through the authenticated
  # GET /api/v1/converger/attachments/:id endpoint.
  storage_opts: [dir: "priv/uploads"],
  max_file_size: 10 * 1024 * 1024,
  signed_url_ttl: 300,
  cdn: nil

# Configures the endpoint
config :converger, ConvergerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ConvergerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Converger.PubSub,
  live_view: [signing_salt: "a84R5GFm"],
  # An oversize WebSocket frame is answered with close code 1009 by Bandit and
  # reported by ConvergerWeb.SocketGuard; don't log it as a crash.
  http: [websocket_options: [log_protocol_errors: false]]

# Client WebSocket limits and draining (ConvergerWeb.SocketGuard,
# ConvergerWeb.Drain); WS_* env vars in config/runtime.exs. See
# docs/operations/websocket-limits.md.
config :converger, :websocket,
  # Frames above this are answered with `payload_too_large` and not processed.
  max_frame_bytes: 131_072,
  # Inbound frames per socket per window (heartbeats included); above it
  # every frame is answered with `rate_limited` and `retryAfterMs`.
  max_messages: 20,
  rate_window_ms: 1_000,
  # Channels one socket may have joined at the same time.
  max_joins: 50,
  # Socket process mailbox lengths: above the first, ephemeral frames
  # (typing, presence) are dropped; above the second the socket is closed
  # with 4503 `slow_consumer`.
  ephemeral_drop_queue_len: 100,
  slow_consumer_queue_len: 1_000,
  # `retryAfterMs` in drain and slow-consumer closes is this base plus a
  # random jitter in 0..reconnect_jitter_ms.
  reconnect_base_ms: 1_000,
  reconnect_jitter_ms: 5_000,
  # On shutdown, readiness reports "draining" and new sockets are refused for
  # drain_delay_ms (so the load balancer stops routing here) before the
  # sockets are closed in batches.
  drain_delay_ms: 5_000,
  drain_batch_size: 500,
  drain_batch_interval_ms: 1_000,
  drain_shutdown_ms: 30_000

# The hard frame cap is applied by Bandit when the socket is mounted, so it is
# read at compile time; frames above it close the socket with 1009.
config :converger, :websocket_max_frame_size, 1_048_576

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :converger, Converger.Mailer, adapter: Swoosh.Adapters.Local

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use LoggerJSON for structured logging in production/dev if desired,
# but usually we keep console logger for dev and structured for prod.
# However, user asked for "Setup structured logging".
# Let's add it but comment out or use env check?
# Or just replace the console logger?
# The user wants structured logging, so I will configure it as a second backend or replace default.
# For now, I'll add Oban config here.

config :converger, Oban,
  repo: Converger.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 3600 * 24},
    # Rescue jobs left `executing` by a crashed node (e.g. a delivery that was
    # mid-flight). Deliveries time out within seconds, so 30 minutes is safe.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", Converger.Workers.ConversationExpirationWorker},
       {"*/5 * * * *", Converger.Workers.ChannelHealthWorker}
     ]}
  ],
  # Delivery queues per tenant tier (tenants.tier), see Converger.Pipeline.Oban.
  queues: [default: 10, deliveries_high: 10, deliveries: 20, deliveries_bulk: 5]

# Rate limiting (Hammer 7, see Converger.RateLimit).
#   backend: :local   - per-node ETS counters (single node)
#            :cluster - ETS counters replicated between nodes over PubSub
#   limits:  overrides of the built-in defaults, e.g. %{inbound: {1_000, 1_000}}
# config/runtime.exs sets the backend from RATE_LIMIT_BACKEND (defaulting to
# :cluster when DNS_CLUSTER_QUERY is set).
config :converger, Converger.RateLimit,
  backend: :local,
  sync_interval_ms: 100,
  override_cache_ttl_ms: 30_000,
  limits: %{}

# Configure OpenTelemetry. Span export is disabled by default; config/runtime.exs
# enables the OTLP exporter when OTEL_EXPORTER_OTLP_ENDPOINT (or
# OTEL_EXPORTER_OTLP_TRACES_ENDPOINT) is set. OTEL_SERVICE_NAME overrides the
# service name below. See docs/deployment.md.
config :opentelemetry,
  resource: %{service: %{name: "converger"}},
  traces_exporter: :none

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
