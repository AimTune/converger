---
title: Configuration reference
description: Every environment variable Converger reads, with defaults and whether production requires it, plus the application config keys in config/*.exs.
sidebar_position: 1
---

This is the complete reference of what Converger reads from the environment and from `config/*.exs`. It was
compiled from every `System.get_env` / `System.fetch_env!` call in `config/` and `lib/` and from every
`Application.get_env` key. For a deployment-oriented walkthrough (which variables to set first, TLS behind a
proxy, compose secrets) see [Deployment](../deployment.md#environment-variables).

## How configuration is loaded

| File | When it is evaluated | What belongs there |
| --- | --- | --- |
| `config/config.exs` | At build time (`mix compile`, `mix release`) | Defaults for every environment: Oban, pipeline backend, uploads, rate limits, pagination, OpenTelemetry resource |
| `config/dev.exs`, `config/test.exs`, `config/prod.exs` | At build time, imported at the end of `config.exs` | Per-environment overrides (dev database, test sandbox, prod JSON logging) |
| `config/runtime.exs` | At **boot** of every environment, including releases | Everything read from environment variables |

Because releases evaluate `config/runtime.exs` on every boot, changing an environment variable only needs a
restart, never a rebuild. Almost all application code reads its settings with `Application.get_env/3` at call
time, so keys from `config.exs` can also be overridden in `runtime.exs`. The single compile-time key is
`:dev_routes` (read with `Application.compile_env/2` in the router).

Conventions used in the tables below:

- **Required (prod)**: the release refuses to boot without it.
- Boolean variables are parsed differently depending on the variable; the accepted "true" spellings are listed
  per variable. Anything else counts as false.
- Comma-separated lists are split on `,`, trimmed, and empty entries are dropped.

## Required in production

| Variable | Default | Meaning |
| --- | --- | --- |
| `DATABASE_URL` | none | Postgres URL, `ecto://USER:PASS@HOST/DATABASE`. Prod only. |
| `SECRET_KEY_BASE` | none | Signs and encrypts cookies, LiveView sessions and every JWT (`Converger.Auth.Signer`). At least 64 bytes; generate with `mix phx.gen.secret`. Values once published in the repository are rejected by SHA-256 fingerprint. Prod only (dev and test use fixed values from `dev.exs` / `test.exs`). |
| `CLOAK_KEY` | none | Base64-encoded 32-byte AES key for `Converger.Vault` (channel secrets and configs at rest). Generate with `openssl rand -base64 32`. The published demo key is rejected. Prod only; dev and test use fixed keys. See [Security model](../security/overview.md#secrets-at-rest). |

## HTTP server and endpoint

| Variable | Default | Required (prod) | Meaning |
| --- | --- | --- | --- |
| `PHX_SERVER` | unset | yes, for releases | When set to **any** value (even `false`), starts the HTTP endpoint. `bin/server` sets `PHX_SERVER=true`. Read in every environment. |
| `PHX_HOST` | `example.com` | effectively yes | Public host name. URLs are generated as `https://PHX_HOST:443`, `ForceSSL` redirects to it, and the default WebSocket origin check accepts only this host. Prod only. |
| `PORT` | `4000` | no | HTTP listen port. Prod binds all interfaces (`::`); dev binds `127.0.0.1`. Read in prod and dev. |
| `CHECK_ORIGIN` | host of `PHX_HOST` | no | Comma-separated origins allowed to open browser WebSockets (LiveView, `/socket`, `/socket/converger`), Phoenix syntax such as `//*.example.com`. Set but empty raises at boot. Prod only. |
| `CORS_ORIGINS` | `http://127.0.0.1:5500,http://localhost:5500` | no | Comma-separated CORS origins (`*` for any). Read per request by `ConvergerWeb.Endpoint.cors_origins/0`. All environments. |

## TLS and HSTS

All prod only. Boolean values accept `true`, `1`, `yes`, `on` (case-insensitive). See
[TLS, HSTS and WebSocket origins](../deployment.md#tls-hsts-and-websocket-origins).

| Variable | Default | Meaning |
| --- | --- | --- |
| `FORCE_SSL` | `true` | Enables `ConvergerWeb.Plugs.ForceSSL`: redirect plain HTTP to `https://PHX_HOST`, HSTS on HTTPS responses. `X-Forwarded-Proto` is trusted only from `TRUSTED_PROXIES`. |
| `HSTS` | `true` | Send `strict-transport-security`. |
| `HSTS_MAX_AGE` | `31536000` | HSTS `max-age` in seconds. |
| `HSTS_INCLUDE_SUBDOMAINS` | `false` | Add `includeSubDomains`. |
| `HSTS_PRELOAD` | `false` | Add `preload`. |
| `FORCE_SSL_EXCLUDE_PATHS` | empty | Comma-separated paths served over plain HTTP without redirect. Hosts `localhost` and `127.0.0.1` are always excluded. |

## Database

| Variable | Default | Environment | Meaning |
| --- | --- | --- | --- |
| `DATABASE_URL` | none | prod | See [Required in production](#required-in-production). |
| `POOL_SIZE` | `10` | prod | Ecto pool size per node. Dev uses 20, test `2 x schedulers`. |
| `ECTO_IPV6` | unset | prod | `true` or `1` connects over IPv6 (`socket_options: [:inet6]`). |
| `DB_USERNAME` | `postgres` | dev, test | Postgres user. |
| `DB_PASSWORD` | `postgres` | dev, test | Postgres password. |
| `DB_HOSTNAME` | `localhost` | dev, test | Postgres host. |
| `DB_NAME` | `converger_dev` / `converger_test` + `MIX_TEST_PARTITION` | dev, test | Database name. |
| `MIX_TEST_PARTITION` | unset | test | Suffix for the test database and the test upload directory, so several suites can run on one machine. |

## Secrets at rest

| Variable | Default | Environment | Meaning |
| --- | --- | --- | --- |
| `CLOAK_KEY` | none | prod (required) | Current encryption key. |
| `CLOAK_RETIRED_KEYS` | empty | prod | Comma-separated base64 keys that are still accepted for decryption during a rotation. Run `bin/converger eval "Converger.Release.reencrypt_secrets()"` after rotating, then remove them. |

## Network trust and admin access

| Variable | Default | Environment | Meaning |
| --- | --- | --- | --- |
| `TRUSTED_PROXIES` | empty (forwarding headers ignored) | all | Comma-separated IPs/CIDRs whose `X-Forwarded-For` / `X-Forwarded-Proto` are honoured. See [../security.md](../security.md). |
| `ADMIN_IP_WHITELIST` | `127.0.0.1,::1` | all | Comma-separated IPs/CIDRs allowed to reach `/admin`. |

## Outbound webhooks (SSRF guard)

| Variable | Default | Environment | Meaning |
| --- | --- | --- | --- |
| `WEBHOOK_ALLOWED_TARGETS` | empty (dev: `localhost,127.0.0.0/8,::1` from `dev.exs`) | all | Comma-separated host names (`*.svc.local` matches subdomains) or IP/CIDR ranges that webhooks may target although they are private. Replaces the dev default when set. |
| `WEBHOOK_ALLOW_PRIVATE_TARGETS` | unset | all | Exactly `true` or `1` disables the SSRF guard entirely. Development only. |

See [Outbound webhooks](../webhooks.md#ssrf-protection).

## Pagination

All environments. Values are integers; unset or empty variables keep the `config.exs` default. See
[ADR-0018](../adr/0018-keyset-pagination.md).

| Variable | Config key | Default | Meaning |
| --- | --- | --- | --- |
| `PAGINATION_DEFAULT_LIMIT` | `default_limit` | `50` | Page size for conversations, audit logs, deliveries, tenant users when `limit` is omitted or invalid. |
| `PAGINATION_MAX_LIMIT` | `max_limit` | `500` | Upper clamp for a requested `limit` on those lists. |
| `PAGINATION_ACTIVITY_DEFAULT_LIMIT` | `activity_default_limit` | `100` | Default page size for activities (REST and transcript views). |
| `PAGINATION_ACTIVITY_MAX_LIMIT` | `activity_max_limit` | `1000` | Upper clamp for activity pages. |
| `PAGINATION_WS_REPLAY_LIMIT` | `ws_replay_limit` | `100` | Maximum activities replayed on WebSocket join; the rest come over REST. |
| `PAGINATION_LOOKUP_LIMIT` | `lookup_limit` | `1000` | Hard cap for small operator tables listed whole (tenants, channels, routing rules, admin users). |

## Rate limiting

| Variable | Default | Environment | Meaning |
| --- | --- | --- | --- |
| `RATE_LIMIT_BACKEND` | `cluster` when `DNS_CLUSTER_QUERY` is non-empty, otherwise `local` | all except test | `local` or `cluster`; any other value raises at boot. |
| `RATE_LIMIT_SYNC_INTERVAL_MS` | `100` | all | How often the `cluster` backend broadcasts counter deltas. |

Limits themselves are not environment variables; see [Rate limiting](rate-limiting.md#tuning).

## WebSocket limits and draining

All environments. Integers; unset or empty variables keep the `config :converger, :websocket` default. See
[WebSocket limits and draining](websocket-limits.md#configuration) for what each one does.

| Variable | Config key | Default |
| --- | --- | --- |
| `WS_MAX_FRAME_BYTES` | `max_frame_bytes` | `131072` |
| `WS_MAX_MESSAGES_PER_WINDOW` | `max_messages` | `20` |
| `WS_RATE_WINDOW_MS` | `rate_window_ms` | `1000` |
| `WS_MAX_JOINS` | `max_joins` | `50` |
| `WS_MAX_IN_FLIGHT` | `max_in_flight` | `32` |
| `WS_EPHEMERAL_DROP_QUEUE_LEN` | `ephemeral_drop_queue_len` | `100` |
| `WS_SLOW_CONSUMER_QUEUE_LEN` | `slow_consumer_queue_len` | `1000` |
| `WS_RECONNECT_BASE_MS` | `reconnect_base_ms` | `1000` |
| `WS_RECONNECT_JITTER_MS` | `reconnect_jitter_ms` | `5000` |
| `WS_DRAIN_DELAY_MS` | `drain_delay_ms` | `5000` (`0` in test) |
| `WS_DRAIN_BATCH_SIZE` | `drain_batch_size` | `500` |
| `WS_DRAIN_BATCH_INTERVAL_MS` | `drain_batch_interval_ms` | `1000` |
| `WS_DRAIN_SHUTDOWN_MS` | `drain_shutdown_ms` | `30000` |

The hard frame cap, `config :converger, :websocket_max_frame_size` (`1_048_576`), is compile time.

## Clustering and metrics

| Variable | Default | Environment | Meaning |
| --- | --- | --- | --- |
| `DNS_CLUSTER_QUERY` | unset (clustering off) | prod | DNS name `DNSCluster` queries to find and connect other nodes. Also switches the default rate-limit backend to `cluster` (read in every environment for that purpose). |
| `PROMETHEUS_PORT` | `9568` (not started in test) | all | Port of the `TelemetryMetricsPrometheus` listener. Setting it in test forces the listener on. See [Observability](observability.md#prometheus-endpoint). |

Node naming and the distribution cookie use the standard Mix release variables (`RELEASE_COOKIE`,
`RELEASE_NODE`, `RELEASE_DISTRIBUTION`); Converger does not read them itself and ships no `rel/env.sh.eex`.
Clustering strategies and their documentation are Planned ([#29](https://github.com/AimTune/converger/issues/29)).

## OpenTelemetry tracing

`config/runtime.exs` enables the OTLP exporter only when one of the two endpoint variables is non-blank, and never
in test. The other variables are read by `opentelemetry_exporter` and the `opentelemetry` SDK themselves. See
[Observability](observability.md#tracing-with-opentelemetry).

| Variable | Default | Read by | Meaning |
| --- | --- | --- | --- |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | unset | runtime.exs, exporter | Full traces URL. Takes precedence; enables export. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | runtime.exs, exporter | Collector base URL (`/v1/traces` is appended). Enables export. |
| `OTEL_EXPORTER_OTLP_PROTOCOL`, `OTEL_EXPORTER_OTLP_TRACES_PROTOCOL` | `http_protobuf` | exporter | `http_protobuf` or `grpc`. |
| `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_TRACES_HEADERS` | unset | exporter | `key=value,key2=value2` headers for the collector. |
| `OTEL_EXPORTER_OTLP_COMPRESSION`, `OTEL_EXPORTER_OTLP_TRACES_COMPRESSION` | none | exporter | `gzip` to compress. |
| `OTEL_SERVICE_NAME` | `converger` (from `config.exs`) | SDK | Service name on every span. |
| `OTEL_RESOURCE_ATTRIBUTES` | unset | SDK | Extra resource attributes. |
| `OTEL_TRACES_EXPORTER` | derived | SDK | `none` forces export off. |
| `OTEL_SDK_DISABLED` | `false` | SDK | `true` disables the SDK. |

## File storage and CDN

Applied only when `UPLOAD_STORAGE` is set, and never in test. Otherwise the `config.exs` defaults (local disk in
`priv/uploads`, 10 MB) stay in effect. Backend details: [File storage and attachments](../storage.md).

| Variable | Default | Required | Meaning |
| --- | --- | --- | --- |
| `UPLOAD_STORAGE` | unset | no | `local`, `s3`, `minio`, `r2`, `gcs` or `azure`; anything else raises. |
| `UPLOAD_DIR` | `priv/uploads` | no | Directory for `local`. Use a persistent volume in releases. |
| `UPLOAD_MAX_BYTES` | `10485760` | no | Maximum upload size. |
| `UPLOAD_SIGNED_URL_TTL` | `300` | no | Lifetime of signed download URLs, seconds. |
| `UPLOAD_ALLOWED_TYPES` | built-in list | no | Comma-separated MIME allowlist (tenants can override with `allowed_upload_types`). |
| `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | none | yes for `s3`/`minio`/`r2` | Bucket and credentials (`System.fetch_env!`). |
| `S3_SESSION_TOKEN` | unset | no | STS session token. |
| `S3_REGION` | unset (backend default `us-east-1`) | no | Region; `auto` for R2. |
| `S3_ENDPOINT` | unset (AWS endpoint) | no | Custom endpoint for MinIO / R2. |
| `S3_PATH_STYLE` | `false` for `s3`, `true` for `minio`/`r2` | no | `true`, `1` or `yes` for path-style URLs. |
| `GCS_BUCKET`, `GCS_HMAC_ACCESS_ID`, `GCS_HMAC_SECRET` | none | yes for `gcs` | Bucket and HMAC key. |
| `GCS_ENDPOINT` | unset (`https://storage.googleapis.com`) | no | Custom endpoint. |
| `AZURE_STORAGE_ACCOUNT`, `AZURE_STORAGE_KEY`, `AZURE_STORAGE_CONTAINER` | none | yes for `azure` | Account, base64 account key, container. |
| `AZURE_STORAGE_ENDPOINT` | unset | no | Custom endpoint (Azurite). |
| `CDN_TYPE` | unset (no CDN) | no | `cloudfront`, `google_cdn` or `plain`; anything else raises. |
| `CDN_BASE_URL` | none | yes when `CDN_TYPE` is set | CDN base URL. |
| `CDN_PATH_PREFIX` | empty | no | Prefix prepended to the storage key in CDN URLs (`<base_url>/<path_prefix>/<storage_key>`). |
| `CLOUDFRONT_KEY_PAIR_ID` | none | yes for `cloudfront` | Key pair id. |
| `CLOUDFRONT_PRIVATE_KEY` / `CLOUDFRONT_PRIVATE_KEY_FILE` | none | one of them for `cloudfront` | PEM private key inline, or a path to it. |
| `GOOGLE_CDN_KEY_NAME`, `GOOGLE_CDN_KEY` | none | yes for `google_cdn` | Signed URL key name and key. |
| `CDN_SIGN_ORIGIN` | unset | no | `plain` CDN only: `true`, `1` or `yes` appends the backend's signed query string (for example an Azure SAS) to the CDN URL. |

## Data retention and archive

See [Data retention, partitions and archive](retention.md) (issue [#30](https://github.com/AimTune/converger/issues/30)). The
`ARCHIVE_BUCKET` / `ARCHIVE_CONTAINER` / `ARCHIVE_DIR` overrides are read together with `UPLOAD_STORAGE` (only when it is
set); without them the archive uses the attachment storage.

| Variable | Default | Required | Meaning |
| --- | --- | --- | --- |
| `RETENTION_MIN_DAYS` | `30` | no | Platform minimum for `tenants.retention_days`; months that ended less than this many days ago are never archived. |
| `HEALTH_CHECK_RETENTION_DAYS` | `7` | no | Delete `channel_health_checks` older than this (daily); `0` disables. |
| `AUDIT_LOG_RETENTION_DAYS` | `365` | no | Delete `audit_logs` older than this (daily); `0` disables. |
| `PARTITION_MONTHS_AHEAD` | `3` | no | Monthly partitions of `activities` / `deliveries` kept in place ahead of the current month. |
| `ARCHIVE_BUCKET` | unset (attachment bucket) | no | S3, MinIO, R2 or GCS bucket for the archive, with the `UPLOAD_STORAGE` credentials. |
| `ARCHIVE_CONTAINER` | unset (attachment container) | no | Azure container for the archive. |
| `ARCHIVE_DIR` | unset (attachment directory) | no | Directory for the archive with `UPLOAD_STORAGE=local`. |
| `ARCHIVE_PREFIX` | `archive` | no | First segment of archive object keys. |
| `ARCHIVE_PART_ROWS` | `50000` | no | Rows per archive object. |
| `PARTITION_MAX_INLINE_ROWS` | `1000000` | no | Read by the partitioning migration (`bin/migrate`): above this many activities it refuses to copy inline and asks for the online `Converger.Release.prepare_partitioning/0` first. See [Migrations](migrations.md#partitioning-activities-and-deliveries-20261010300100). |

## Release scripts and seeding

| Variable | Default | Read by | Meaning |
| --- | --- | --- | --- |
| `CREATE_DB` | `false` | `rel/overlays/bin/migrate` | Exactly `true` runs `Converger.Release.create_db/0` before migrating. |
| `ADMIN_EMAIL` | `admin@converger.local` | `Converger.Release.seed_admin/0`, `priv/repo/seeds.exs` | Email of the first `super_admin`. |
| `ADMIN_PASSWORD` | generated | same | Password of that account. When unset, a random one is printed once and `must_change_password` is set. |

## Docker compose only

These are read by `docker-compose.yml` (from `.env`, see `.env.example`), not by the application.

| Variable | Required | Meaning |
| --- | --- | --- |
| `POSTGRES_PASSWORD` | yes | Password of the compose Postgres; also embedded in the app's `DATABASE_URL`. Use URL-safe characters. |
| `SECRET_KEY_BASE`, `CLOAK_KEY` | yes | Passed through to the `migrate` and `app` services. |
| `GF_SECURITY_ADMIN_PASSWORD` | yes | Grafana admin password. |
| `PHX_HOST`, `FORCE_SSL`, `TRUSTED_PROXIES` | no | Passed through; compose defaults `PHX_HOST=localhost`, `FORCE_SSL=false`. |

Compose also sets `PORT=4000`, `PROMETHEUS_PORT=9568`, `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318`,
`CREATE_DB=true` for `migrate` and `PHX_SERVER=true` for `app`.

## Test-only variables

| Variable | Used by | Meaning |
| --- | --- | --- |
| `MINIO_ENDPOINT`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` | `test/converger/uploads/storage_integration_test.exs` (`--only minio`) | MinIO server for the S3 integration tests. |
| `AZURITE_ENDPOINT` | same file (`--only azurite`) | Azurite blob endpoint, e.g. `http://127.0.0.1:10000/devstoreaccount1`. |
| `CHECK_ORIGIN` | `test/converger_web/check_origin_config_test.exs` | Exercises the runtime parsing. |

## Application configuration (config/*.exs)

These keys are set in `config/config.exs` (or read with a default when absent). Override them in
`config/runtime.exs` or an environment file; none has an environment variable unless listed above.

### Oban

```elixir
config :converger, Oban,
  repo: Converger.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 3600 * 24},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", Converger.Workers.ConversationExpirationWorker},
       {"*/5 * * * *", Converger.Workers.ChannelHealthWorker},
       {"15 0 * * *", Converger.Workers.PartitionMaintenanceWorker},
       {"30 1 * * *", Converger.Workers.PruneWorker},
       {"0 2 1 * *", Converger.Workers.RetentionWorker}
     ]}
  ],
  queues: [default: 10, deliveries_high: 10, deliveries: 20, deliveries_bulk: 5, maintenance: 1]
```

| Setting | Value | Notes |
| --- | --- | --- |
| Queue `default` | 10 concurrent jobs per node | Conversation expiration (hourly) and channel health checks (every 5 minutes). |
| Queue `maintenance` | 1 concurrent job per node | Data lifecycle: partitions (daily 00:15 UTC), pruning (daily 01:30 UTC), retention (monthly, 1st at 02:00 UTC) and the `PurgeWorker` jobs enqueued by tenant, channel and conversation deletes. See [Data retention](retention.md). |
| Queues `deliveries_high`, `deliveries`, `deliveries_bulk` | 10 / 20 / 5 concurrent jobs per node | `Converger.Workers.ActivityDeliveryWorker` (unique per activity and channel), one queue per tenant tier (`tenants.tier`: `high`, `default`, `bulk`); see [flow control](../delivery.md#tenant-tiers-fair-queueing). |
| `Pruner` | completed/discarded jobs older than 24 h | Keeps `oban_jobs` small. |
| `Lifeline` | rescues jobs stuck in `executing` after 30 min | Recovers deliveries from a crashed node. |
| Test | `testing: :inline` | Jobs run synchronously in tests. |

The schema must be at Oban migration version 14 (migration `20261009131000`); Oban 2.24 refuses to start
otherwise. Jobs can be inspected at `/admin/oban`.

### Delivery pipeline

```elixir
config :converger, pipeline: [backend: Converger.Pipeline.Oban]
```

| Backend | Use |
| --- | --- |
| `Converger.Pipeline.Oban` | Default. Deliveries are Oban jobs inserted in the activity transaction (durable). See [ADR-0001](../adr/0001-transactional-outbox-with-oban.md). |
| `Converger.Pipeline.Broadway` | Throughput backend with `broadway: [producer: :memory, :kafka, :rabbitmq or :custom, ...]`. Not durable; the `:memory` producer refuses to start in prod unless `allow_memory_producer_in_prod: true`. Kafka/RabbitMQ need optional deps. See [ADR-0002](../adr/0002-broadway-for-throughput-oban-for-retries.md). |
| `Converger.Pipeline.Inline` | Synchronous; used by `config/test.exs`. |

Retry defaults for external deliveries come from `config :converger, :retry_policy` (keys `max_attempts` 5,
`backoff` `:exponential`, `base_ms` 10000, `max_ms` 1 h, `timeout_ms` 15000; the legacy `base_backoff_seconds` is
still honoured), merged with adapter defaults and each channel's `retry_policy`. See
[ADR-0019](../adr/0019-per-channel-retry-policy-delivery-error-and-lifeline.md).

### Uploads

```elixir
config :converger, Converger.Uploads,
  storage: Converger.Uploads.LocalStorage,
  storage_opts: [dir: "priv/uploads"],
  max_file_size: 10 * 1024 * 1024,
  signed_url_ttl: 300,
  cdn: nil
```

`allowed_content_types: nil` (the default) means the built-in allowlist. In releases this block is rebuilt from
the [file storage variables](#file-storage-and-cdn). Test uses a temp directory and a 1 MB limit.

### Rate limiting

```elixir
config :converger, Converger.RateLimit,
  backend: :local,
  sync_interval_ms: 100,
  override_cache_ttl_ms: 30_000,
  limits: %{}
```

`limits` overrides built-in bucket defaults installation-wide, e.g. `%{inbound: {1_000, 1_000}}`
(`{limit, window_ms}`). `clean_period_ms` (default 60000) controls how often expired ETS counters are removed.
See [Rate limiting](rate-limiting.md).

### Retention, partitions and archive

```elixir
config :converger, Converger.Partitions,
  months_ahead: 3,            # PARTITION_MONTHS_AHEAD
  detach_concurrently: true,  # false in test (the SQL sandbox is one transaction)
  lock_timeout_ms: 5_000      # for creating, attaching and dropping partitions

config :converger, Converger.Retention,
  min_retention_days: 30,     # RETENTION_MIN_DAYS
  health_check_days: 7,       # HEALTH_CHECK_RETENTION_DAYS, 0 or nil disables
  audit_log_days: 365,        # AUDIT_LOG_RETENTION_DAYS, 0 or nil disables
  prune_batch_size: 10_000

config :converger, Converger.Archive,
  storage: nil,               # nil: the attachment storage (Converger.Uploads)
  storage_opts: [],
  prefix: "archive",          # ARCHIVE_PREFIX
  part_rows: 50_000           # ARCHIVE_PART_ROWS
```

Per-tenant retention is the `tenants.retention_days` column (default 365). See
[Data retention, partitions and archive](retention.md).

### Protocol v1 transports

```elixir
config :converger, ConvergerWeb.Protocol,
  heartbeat_interval_ms: 30_000,
  idle_timeout_ms: 60_000,
  replay_max: 10_000
```

Settings of the native WebSocket (`/socket/converger/v1`) and the Server-Sent Events stream, announced to
clients in `welcome.data.limits` ([Protocol v1](../protocol/v1.md), section 11). `heartbeat_interval_ms`: outbound
silence before a `heartbeat` frame (also the SSE heartbeat period). `idle_timeout_ms`: inbound silence before the
socket is closed with 4408. `replay_max`: frames replayed per handshake, `sync`
or SSE connection before `replayTruncated`. The replay batch size is `ws_replay_limit` under
[Pagination](#pagination). Keep the heartbeat below any proxy idle timeout in front of Converger. Frame size,
message rate, slow-consumer and draining limits are the shared client WebSocket limits (`config :converger,
:websocket`, `WS_*` variables), see [WebSocket limits and draining](websocket-limits.md).

Tokens passed as `?token=` (sockets, SSE) are filtered from request logs by
`config :phoenix, :filter_parameters, ["password", "token", "secret"]`.

### Repo and migrations

```elixir
config :converger, Converger.Repo,
  migration_lock: :pg_advisory_lock,
  migration_advisory_lock_retry_interval_ms: 1_000
```

Concurrent migration runners serialize on a Postgres advisory lock. Requires a session-mode connection (not
PgBouncer transaction pooling). See [Migrations and maintenance windows](migrations.md).

### Other application keys

| Key | Default | Meaning |
| --- | --- | --- |
| `:cors_origins` | `["http://127.0.0.1:5500", "http://localhost:5500"]` | See `CORS_ORIGINS`. |
| `:admin_ip_whitelist` | `["127.0.0.1", "::1"]` | See `ADMIN_IP_WHITELIST`. |
| `:trusted_proxies` | `[]` | See `TRUSTED_PROXIES`. |
| `:inbound_signature_tolerance_seconds` | `300` | Allowed clock skew for `x-converger-signature` timestamps. |
| `:pagination` | see [Pagination](#pagination) | Page size defaults and caps. |
| `:dead_letters` | `bulk_retry_limit: 10_000`, `export_limit: 10_000` | Max deliveries replayed by one bulk retry call, and max rows in one Deliveries CSV export. See [Replaying dead letters](../delivery.md#replaying-dead-letters). |
| `:circuit_breaker` | `failure_threshold: 5`, `cooldown_ms: 30_000`, `park_seconds: 600`, `replay_dead_letters_on_close: false`, `replay_window_ms: 3_600_000` | Per-channel delivery circuit breaker and opt-in dead-letter replay on close. See [Circuit breaker](../delivery.md#circuit-breaker). |
| `:prometheus_port` | `9568`; `false` in test | `false` disables the metrics listener. |
| `:force_ssl` | unset outside prod | Keyword list of `Plug.SSL` options, built from the TLS variables in prod; `false` disables. |
| `:webhook` | `[]` | `allowed_targets`, `allow_private_targets`, `resolver` (SSRF guard), and installation defaults for `connect_timeout` (5000 ms), `receive_timeout` (10000 ms), `max_response_bytes` (1 MiB). |
| `:channel_signals_async` | `true`; `false` in test | Forward typing indicators and read receipts to external channels (`Converger.Channels.Signals`) in a task under `Converger.TaskSupervisor`. `false` runs them inline in the WebSocket channel process. |
| `:webhook_req_options`, `:whatsapp_req_options` | `[]` | Extra `Req` options merged into adapter requests (tests use them for `Req.Test` plugs). |
| `Converger.Channels.Adapters.WhatsappMeta`, `graph_api_version:` | `"v26.0"` | Default Graph API version when the channel config has none. |
| `:activity_limits` | `max_text_bytes: 65_536`, `max_attachments: 10`, `max_attachment_bytes: 4_096`, `max_metadata_bytes: 16_384` | Activity size limits (attachment and metadata sizes measured as JSON). |
| `:conversation_inactivity_hours` | `24` | Open conversations idle longer than this are closed by the hourly expiration job. |
| `:inbound_conversation_idle_timeout_seconds` | unset (no idle timeout) | Global default for starting a new conversation for an inbound participant after inactivity; channels override it with `conversation_idle_timeout_seconds` in their config. |
| `:api_key_rotation_grace_period` | `86400` (seconds) | How long the previous tenant API key keeps working after a rotation. |
| `:extra_middleware` | `%{}` | Map of middleware type string to module, merged into the built-in middleware registry. |
| `:dns_cluster_query` | from `DNS_CLUSTER_QUERY` | Prod only. |
| `:dev_routes` | `true` in dev | Compile-time. Mounts the Swoosh mailbox preview at `/dev/mailbox`. |
| `:env` | `config_env()` | Used for environment-specific guards (for example the Broadway memory producer). |

### Logging

`config/config.exs` uses the console formatter with `request_id` metadata. `config/prod.exs` sets the level to
`:info` and installs LoggerJSON on the default handler with key redaction; `config/test.exs` logs warnings and
above. See [Observability](observability.md#logging).

### Mailer

`Converger.Mailer` uses `Swoosh.Adapters.Local` (dev mailbox) and `Swoosh.Adapters.Test` in test. Production sets
the Req API client but configures no delivery adapter; no feature sends email yet.
