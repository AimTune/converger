# Changelog

## Unreleased

### Management API and scoped API keys (#51)

- **Scoped tenant API keys** (`api_keys`): a name, any of the scopes `read`, `write` and `manage`, an optional
  expiry, revocation, and `last_used_at`. A `read` key cannot post activities (`403 insufficient_scope`); changing
  configuration needs `manage`. The tenant's existing key is now its primary key and keeps every scope, so nothing
  changes for current integrations.
- **Management API** `/api/v1/manage` (scope `manage`): channels CRUD with `rotate_secret`, portal users, tenant
  settings (retention, alert webhook URL, upload types, rate-limit overrides) and API keys. Creating, changing and
  deleting routing rules and webhook subscriptions, and pausing and resuming channels, now need `manage` as well.
- **Admin API** `/api/v1/admin`: tenants CRUD, primary key rotation and scoped key issuance, authenticated with the
  new `ADMIN_API_TOKEN` (at least 32 characters) behind `ADMIN_IP_WHITELIST`. Off while the variable is unset.
- `ETag` on managed resources and `If-Match` on `PUT`/`PATCH`/`DELETE` (`412 precondition_failed`). Secret channel
  config values are returned as `[REDACTED]`, and sending them back keeps the stored value.
- Every management call is audited, with the API key's id as the actor (actor type `admin_api` for the admin token).
- New error codes `insufficient_scope` (403) and `precondition_failed` (412).
- Docs: management API, authentication, errors, security, configuration, tenants; ADR-0061.

### Admin and portal auth hardening (#52, part 2)

- Admin and tenant portal logins are **server-side sessions** (`user_sessions`; only a SHA-256 of the cookie's
  token is stored). They end after `SESSION_MAX_AGE_SECONDS` (12 h, also the cookie `max_age`) or
  `SESSION_IDLE_TIMEOUT_SECONDS` (30 min) without activity. `/admin/security` and `/portal/security` list the
  sessions with **Sign out** per session and **Log out everywhere**; a password change ends the other sessions, a
  reset, deactivation or deletion all of them; open LiveViews are disconnected. Expired rows are pruned every 10
  minutes. Upgrading logs everyone out once.
- **TOTP two-factor authentication** (`nimble_totp`) for admins and tenant users: enrollment with base32 secret
  and `otpauth://` URI, confirmed with a code; secret encrypted at rest; codes single use; wrong codes throttled.
  `ADMIN_REQUIRE_2FA_ROLES` (default `super_admin`) forces enrollment before any admin page. A `super_admin` (or a
  tenant `owner`/`admin`) can reset another user's 2FA; `Converger.Release.reset_admin_2fa/1` for lockouts.
- **Password reset by email** at `/admin/password/reset` and `/portal/password/reset`: single-use hashed tokens,
  valid one hour, same answer whether the account exists, rate limited per IP and per account; clears
  `must_change_password` and all sessions. `MAILER_FROM` and `SMTP_*` configure the mailer.
- **Password policy** for both account types: at least `PASSWORD_MIN_LENGTH` (default 12, was 8) characters, at
  most 72 bytes, must not contain the email. Existing passwords keep working.
- Audit log actions `enable_2fa`, `disable_2fa`, `reset_2fa`, `reset_password`, `revoke_sessions`.
- Docs: security model, configuration, rate limiting, upgrades, tenants; ADR-0058.

### Client token hardening (#52, part 1)

- Converger tokens are signed with dedicated keys (`TOKEN_SIGNING_KEYS`, `kid:secret` pairs, the first signs, all
  verify) and carry the key's `kid`: keys rotate without downtime, and rotating `SECRET_KEY_BASE` no longer
  disconnects WebSocket clients. Unset: `SECRET_KEY_BASE` under kid `default`. Tokens issued before the upgrade
  (no `kid`) are accepted while `TOKEN_ACCEPT_UNKEYED` is true (default).
- Revocation: `POST /api/v1/converger/tokens/revoke` revokes a token and its family (with the token itself, e.g. on
  logout, or with the channel secret and `{"token": ...}`) or every token of an end user (channel secret and
  `{"user": {"id": ...}}`). Revoked tokens get `401 token_revoked` (WebSocket close 4401) on every node within a
  second and the subject's sockets are disconnected. New table `revoked_tokens`, cached in ETS on each node and
  synced over PubSub (`Converger.Auth.RevocationCache`), pruned daily.
- Refresh rotation: a refreshed token stays valid for `TOKEN_ROTATION_GRACE_SECONDS` (30) and is then refused;
  refreshing it again after that revokes its whole family (reuse detection). Tokens returned by
  `POST /conversations` and `GET /conversations/:id` never outlive the token that asked for them.
- Permissions: `permissions` on `tokens/generate` (`read`, `write`, `typing`; the `perms` claim) restricts a
  token and everything derived from it, enforced on REST, the Phoenix socket and the native Protocol v1 / gRPC
  session. New error codes `insufficient_permission` (403, protocol 2004) and `token_revoked` (401, protocol 2005).
- Docs: [client tokens](docs/security/client-tokens.md), client API, protocol, errors, configuration; ADR-0059.

### Windows developer setup: pure-Elixir password hashing and a dev container (#53)

- Password hashing goes through `Converger.Accounts.PasswordHasher` (`config :converger, :password_hasher`, any
  `Comeonin` module). bcrypt stays the default; stored hashes are verified by their prefix, so bcrypt and PBKDF2
  hashes can coexist.
- `CONVERGER_PASSWORD_HASHER=pbkdf2` (compile time) leaves the `bcrypt_elixir` NIF out of the build and hashes with
  `pbkdf2_elixir` (pure Elixir, now always a dependency), so the project builds and tests on Windows without the MSVC
  build tools.
- `.devcontainer/` (VS Code Dev Containers, Codespaces, `devcontainer` CLI): the pinned Elixir/OTP image with the C
  tools and a Postgres 17 service; `deps/` and the build root live in volumes.
- Docs: getting started (Windows), contributing (dev container), configuration, security; ADR-0057.

### MQTT channel and Discord Gateway inbound (#44)

- New channel type `mqtt` (MQTT 3.1.1 over TCP or TLS, QoS 0 and 1): a subscriber per channel in the cluster on the
  topic filter `topic_in` in a persistent session, so QoS 1 messages published while it is down or moving are
  queued; each message is acknowledged (`PUBACK`) only after its activity is committed or it was dead-lettered.
  Idempotency key: the envelope's `idempotency_key`, else `mqtt:<SHA-256 of topic and payload>`
  (`derive_idempotency_key`). Outbound: the canonical envelope published with QoS 1 to `topic_out`, a template with
  `{conversation_id}`, `{channel_id}` and `{tenant_id}`, waiting for the `PUBACK`. Poison messages go to `topic_dlq`
  as JSON. SSRF guard on the host, health probe, admin form from `config_schema/0`.
- The MQTT client is part of Converger (`Converger.Channels.Mqtt.Packet` / `Connection`): `emqtt` requires the
  `quicer` NIF (no Windows build) and `tortoise311` acknowledges QoS 1 messages before the handler runs.
- `discord` channels get an optional Gateway mode (`gateway: true`, `gateway_intents`): plain channel and direct
  messages (`MESSAGE_CREATE`) over the Discord Gateway WebSocket, one connection per channel in the cluster, with
  identify, jittered heartbeats, zombie detection, resume, op 7 / op 9 handling and close-code backoff; idempotency key
  `message:<id>`, the bot's own and other bots' messages ignored, attachments downloaded into Converger storage. The
  `public_key` is optional in Gateway mode. `mint_web_socket` is now a runtime dependency.
- `Converger.Channels.Broker` consumers are generic: optional `consumer_child_spec/1` (a consumer that is not a
  Broadway pipeline) and `consume?/1` (per-channel opt-in) callbacks, `Broker.handle_message/5` for consumers that
  parse messages themselves.
- The optional "Broker channel suites" CI job also runs the MQTT end-to-end suite (`--only mqtt`) against Mosquitto.
- Docs: [MQTT](docs/channels/mqtt.md), [Discord Gateway mode](docs/channels/discord.md#gateway-mode), broker channels,
  channels overview, configuration; ADR-0055.

### Protocol v1 over gRPC (#44)

- New transport for backend clients: the gRPC service `converger.v1.ChannelStream`,
  `rpc Connect(stream ClientFrame) returns (stream ServerFrame)`, one stream per Protocol v1 connection to one
  conversation, on its own port. Off by default: `GRPC_ENABLED=true`, `GRPC_PORT` (default 50051), TLS with
  `GRPC_TLS_CERTFILE` / `GRPC_TLS_KEYFILE`. Credentials: `authorization: Bearer <converger token>` metadata or
  `Hello.token`.
- `priv/protos/converger/v1/protocol.proto` defines the v1 frames as protobuf messages (typed `oneof` cases plus a
  lossless `raw` Struct fallback); the generated modules are committed (`priv/protos/generate.sh`).
- Same semantics as the native WebSocket: the session logic moved into `ConvergerWeb.Protocol.Session`, which both
  transports run (handshake, replay from a watermark, acks and `clientId` idempotency, receipts, typing, presence,
  token refresh, limits, slow consumers, draining). A stream ends with a `Close` frame carrying the WebSocket close
  code and a matching gRPC status (`UNAVAILABLE` on drain, `UNAUTHENTICATED` for 4401, ...).
- Connection metrics with `transport="grpc"`; Helm `grpc.*` values (container and Service port, NetworkPolicy
  `grpcFrom`), docker compose maps 50051.
- New dependencies: `grpc_server` and `grpc` 1.0.5, `protobuf` 0.17.1 (patch-level pins).
- Docs: [Protocol v1 over gRPC](docs/protocol/grpc.md); ADR-0056.

### Broker channels: NATS JetStream and Redis Streams (#42)

- New channel types `nats` and `redis_streams` on the broker channel machinery of the Kafka and RabbitMQ channels
  (one consumer per channel in the cluster, `Converger.Inbound`, idempotency, dead letters, retries, echo
  suppression, health probes).
- `nats`: outbound JetStream publish to `subject_out` (optionally `…{conversation_id}`) with `Nats-Msg-Id` = activity
  id; inbound from a durable pull consumer (`stream`, `subject_in`, `durable_name`), `+ACK` after accepted or
  dead-lettered, idempotency key `nats:<stream>/<sequence>`, dead letters to `<subject_in>.dlq`. Authentication by
  user/password, token, NKey seed or `.creds`; TLS; optional stream creation (`declare`).
- `redis_streams`: outbound `XADD` to `stream_out` (optional `MAXLEN ~`); inbound with a consumer group (consumer
  named after the node), `XACK` after accepted or dead-lettered, pending entries of earlier or dead consumers
  recovered with `XAUTOCLAIM` on every start, idempotency key `redis_streams:<stream>/<entry id>`, dead letters to
  `<stream_in>.dlq`. Password or ACL user; TLS with `rediss://`.
- New dependencies: `gnat` and `redix` (pure Elixir). Config keys `nkey_seed` and `creds` are redacted in audit logs.
- Tests: unit suites and end-to-end suites tagged `:nats` and `:redis_streams` (`NATS_URL`, `REDIS_URL`), run in the
  optional "Broker channel suites" CI job.
- Docs: [NATS JetStream](docs/channels/nats.md), [Redis Streams](docs/channels/redis-streams.md), broker channels
  overview; ADR-0054.

### Platform event webhooks (#49)

- Tenant-level webhook subscriptions (`webhook_subscriptions`: url, events, signing secret and headers encrypted at
  rest, enabled) for `activity.created`, `delivery.sent|delivered|read|failed`,
  `conversation.created|closed|reopened`, `channel.health_changed|circuit_opened|circuit_closed` and
  `participant.opted_out`, or `"*"`. Events come from the existing broadcast hooks, after commit.
- Delivery through Oban (queue `webhooks`) with the shared retry policy and `Retry-After`, the outbound
  `x-converger-signature` scheme and the SSRF guard of webhook channels; `x-converger-event`,
  `x-converger-event-id` and `x-converger-delivery-id` headers. Permanent failures and exhausted retries are
  dead-lettered per subscription and can be redelivered.
- Event log `webhook_events`, kept 7 days (`WEBHOOK_EVENT_RETENTION_DAYS`, pruned by `PruneWorker`).
- API: `/api/v1/webhook_subscriptions` (CRUD, `rotate_secret`), `/api/v1/webhook_events` (list, show,
  `redeliver`), `/api/v1/webhook_event_types`. Portal and admin **Webhooks** pages with recent events and a
  redeliver button. Audit log: resource types `webhook_subscription` and `webhook_event`, action `redeliver`.
  Errors use the API error envelope (`409 not_failed` for redelivering an event that is not `failed`); every
  endpoint is in `priv/static/openapi.json` (tag `Webhooks`).
- `tenants.alert_webhook_url` is migrated to a managed subscription on the channel health and circuit events,
  kept in sync with the tenant form; it keeps the legacy body but is now signed, retried and logged. The
  fire-and-forget `Health.send_alert_webhook/3` and circuit alert are removed.
- `Converger.Channels.OutboundRequest` holds the IP pinning, bounded response body and header rules shared with the
  webhook adapter.
- Docs: [Platform event webhooks](docs/platform-webhooks.md), tenant API reference; ADR-0053.

### Server-side SDKs: Python, Go, Elixir (#47)

- `packages/client-python` (PyPI `converger`): `httpx` REST client (sync and async) for the client and tenant APIs,
  Pydantic v2 models, an async Protocol v1 socket client with resume, `verify_signature` for webhooks.
- `packages/client-go` (`github.com/AimTune/converger/packages/client-go`): REST client, Protocol v1 socket client
  on `github.com/coder/websocket`, `VerifySignature`.
- `packages/client-elixir` (Hex `converger_client`): `Req` REST client, a `Mint.WebSocket` socket process,
  `ConvergerClient.Webhook.verify_signature/4`.
- `packages/conformance`: a shared, language-neutral conformance suite every SDK runs (REST requests, error
  normalization for the legacy shapes and the #45 envelope, the protocol resume state machine, webhook signature
  vectors). The vectors are generated from `Converger.Channels.InboundSignature.sign/3`; a new server test fails
  when signer and vectors disagree. `integration/run.sh` runs every SDK against a real server, including a signed
  webhook delivery.
- CI workflow `SDKs` and tag-triggered release workflows (`client-python/v*` to PyPI with trusted publishing,
  `packages/client-go/v*`, `client-elixir/v*` to Hex).
- Docs: [Client SDKs](docs/sdk/server-sdks.md) with pages per language, signature verification details and test
  vectors in [webhooks](docs/webhooks.md); ADR-0052.

### OpenAPI 3.1, Swagger UI, one error envelope, versioning policy (#45)

- **Breaking for error bodies (statuses unchanged):** every HTTP API error is now
  `{"error": {"code", "message", "details", "request_id"}}`, from controllers, auth and rate-limit plugs, the
  database-pressure plug, refused socket connections and the exception handlers. Field errors move to `details`;
  client-API auth codes are now `unauthorized`, `token_expired` (new) and `channel_inactive`; the admin IP allowlist
  answers JSON instead of plain text. Code list and migration table: [errors](docs/api/errors.md).
- OpenAPI 3.1 document generated from `open_api_spex` controller annotations, committed as
  `priv/static/openapi.json` (`mix openapi.spec.json`; CI fails on drift and lints it), served at `/api/openapi.json`
  with Swagger UI at `/api/docs` (dev/test; prod with `API_DOCS_ENABLED=true`).
- Versioning and deprecation policy: URL versions for breaking changes, `Deprecation` / `Sunset` headers
  (`ConvergerWeb.Plugs.Deprecated`), 12-month support window ([versioning](docs/api/versioning.md)).
- New dependency: `open_api_spex`. ADR-0050.

### TypeScript SDK `@converger/client` (#46)

- New pnpm workspace (`pnpm-workspace.yaml`) with `packages/client-ts`: a headless, dependency-free TypeScript client
  for Protocol v1 (ESM + CJS, strict types). `ConvergerClient.connect({tokenProvider})`, `conversation.start()` /
  `resume(watermark)`, `send()` resolved on `ack`, a persistent outbox (localStorage or memory, pluggable) resent once
  per reconnect after the replay, jittered exponential reconnects honouring `retryAfterMs`, token refresh before expiry
  (`auth` on the native endpoint), gap fill with `sync`, typed events, REST helpers (history paging, uploads).
- Transports: native `/socket/converger/v1` (default), the Phoenix binding (own V2 framing, `activitySet` mapped to v1
  frames) and the SSE fallback; `["native", "sse"]` by default.
- Tests: vitest against a mocked native endpoint, and an e2e test that kills `mix phx.server` mid-session (reconnect,
  resend once, replay of missed activities) and checks the Phoenix and SSE transports. CI workflow `client-ts.yml`;
  npm publish on `client-ts-v*` tags (`client-ts-publish.yml`). Examples: React widget and Node bot in
  `examples/typescript/`.
- `converger_js/` is removed; Dependabot watches the pnpm workspace instead.
- Docs: [TypeScript SDK](docs/sdk/typescript.md), ADR-0051.

### Broker channels: Kafka and RabbitMQ (#42)

- New channel types `kafka` and `rabbitmq`: a broker as a first-class channel. Outbound, the pipeline produces the
  canonical activity JSON plus `channel_id` (Kafka: to `topic_out`, keyed by `conversation_id`; RabbitMQ: to
  `exchange` / `routing_key` with publisher confirms). Inbound, a Broadway consumer per channel reads `topic_in` /
  `queue` and passes each message to `Converger.Inbound`, so routing rules, middleware and deliveries apply.
- Consumers run under `Converger.Channels.Consumers` (a `DynamicSupervisor`), one per channel in the cluster
  (`:global`), spread over the nodes, started, restarted and stopped as channels change, and reconciled every 30 s.
  `BROKER_CONSUMERS=false` keeps them off a node; `BROKER_RECONCILE_INTERVAL_MS` sets the interval.
- At-least-once inbound with idempotent activity creation: the idempotency key is the envelope's `idempotency_key`
  or the broker message id (`kafka:topic/partition/offset`, `rabbitmq:<message_id>`). Poison messages go to a
  per-channel dead-letter topic / queue; transient failures are retried in place, then dead-lettered.
- Adapter behaviour: new `:consumer` capability and `Converger.Channels.Broker` behaviour; config fields can be
  `required: :inbound` / `required: :outbound` (required only in a matching channel mode).
- New metrics `converger.broker.dead_lettered.count` and `converger.broker.retry.count`.
- Config keys ending in `_password` are redacted in audit logs.
- New dependencies: `broadway_kafka`, `brod`, `broadway_rabbitmq`, `amqp` (and `ranch` moves to 2.2.0, required by
  `rabbit_common`). The Docker build stage installs `cmake` (for the Kafka client's CRC32C NIF). Kafka channels do
  not work on Windows hosts (the NIF is not built there).
- Docs: [Broker channels](docs/channels/brokers.md) (pipeline transport versus broker channel), Kafka and RabbitMQ
  pages; ADR-0047. NATS JetStream and Redis Streams channels followed (see above).

### Load testing harness and published benchmarks (#34)

- `load/`: k6 scenarios against the release image in Docker Compose, on 1 or 3 nodes: REST → WebSocket fan-out
  (`e2e.js`), inbound webhook burst routed to three channels (`webhook_burst.js`), 10 000 idle sockets
  (`idle.js`), reconnect storm, rolling restart and node kill with watermark resume (`reconnect.js`). A Node.js
  mock provider with configurable latency and error rate measures delivery latency.
- Zero-loss check: every subscriber must see every `seq` of its conversation exactly once up to the head; burst
  messages must be stored and delivered to every target. Any lost acknowledged message fails the run.
- `load/run.sh` samples CPU and RSS per node, Oban queue depth and DB pool wait, records the hardware, and writes
  `results.json` and a markdown report; `load/report.js` merges runs and compares them with a baseline.
- Nightly `Load` workflow (1 and 3 nodes) fails on lost messages, failed thresholds, or a p95 regression above 15 %.
- `mix converger.loadtest` replaces `test/load/performance_test.exs` (in-process write-path benchmark). The README's
  hardcoded throughput figures are replaced by the published results in `docs/benchmarks/`. ADR-0049.
### Conditional routing rules, reply-back routing and dry-run (#43)

- Routing rules have `conditions` (JSON predicates over `type`, `sender`, `text`, `metadata.*`,
  `conversation.metadata.*`, `participant.*` and `time.*` with `eq`, `neq`, `in`, `contains`, `regex`, `exists`,
  `gt`, `lt` and `all` / `any` / `not` groups, validated on save; regexes at most 256 bytes, compiled on save, run
  under a PCRE match limit), `transformations` (run after the target channel's middleware, for that rule's targets),
  `priority` (default 100, lowest first) and `stop_processing` (first match). Existing rules keep matching everything.
- **Reply-back routing (behaviour change):** activities record the channel they came in on and conversations their
  origin channel. An activity written from another channel (for example an agent on a routed `websocket` console)
  goes back to the origin channel and its participant, plus the replying websocket hub, and no longer to the origin
  channel's other rule targets. Add a rule with the replying channel as source to copy replies elsewhere. Activities
  posted with the tenant API have no source channel and fan out as before.
- Conversations span channels: new `conversation_channels` table (`origin`, `target`, `member`), shown with
  `origin_channel_id` on `GET /api/v1/conversations/:id`.
- Dry-run: `POST /api/v1/routing_rules/dry_run` and the admin page `/admin/routing_rules/dry_run` show the matched
  rules and the payload per target without storing or sending anything. The admin rule form can edit rules,
  conditions, transformations, priority and stop processing.
- Migrations `20261012200000`, `20261012200100` (metadata-only) and `20261012200200` (new table, batched backfill);
  all safe for a rolling deploy. Docs: [Routing rules](docs/concepts/routing-rules.md). ADR-0046.

### Graceful degradation under database pressure (#35)

- **Two pools.** Oban (its own queries and every job) runs on a background pool of the same repo
  (`Converger.Repo.Background`, `BACKGROUND_POOL_SIZE`, default 10), so background work cannot starve requests.
  **Upgrade note:** each node now opens up to `POOL_SIZE + BACKGROUND_POOL_SIZE + 1` connections (21 instead of 11
  with the defaults); check Postgres `max_connections`, or set `BACKGROUND_POOL_SIZE=0` to keep one shared pool.
- Per-pool `queue_target`, `queue_interval` and `timeout`: `DB_QUEUE_TARGET_MS`, `DB_QUEUE_INTERVAL_MS`,
  `DB_TIMEOUT_MS` and their `BACKGROUND_DB_*` counterparts.
- A request that cannot reach the database (pool saturated, query timed out, connection lost) is answered
  `503` with `Retry-After` and the code `database_unavailable` instead of `500` and a crash report. WebSocket
  upgrades get `503` + `Retry-After` too.
- WebSockets: a join or event answers `{"reason": "unavailable", "retry_after_ms": N}`; a **replay that fails no
  longer fails the join**: the socket pushes `error {code: "replay_unavailable", watermark}`. Protocol v1: new
  retryable error `replay_unavailable` (9002, `details.watermark`, then `sync`), `unavailable` for frames, close
  1013 for a `hello` that cannot be served. SSE streams end with `unavailable` and reconnect.
- `GET /health/ready` has a `pool` check and answers `503 degraded` while the interactive pool's average wait is
  above `READY_DB_QUEUE_MS` (200 ms; `0` disables).
- Metrics `converger_repo_pool_queue_time_ms`, `converger_background_repo_query_queue_time`,
  `converger_db_unavailable_count{source}`.
- Chaos harness: `CHAOS_MODE=db_pause` pauses Postgres for 10 s under load (nightly next to the kill mode).
- Docs: [Database pools and pressure](docs/operations/database.md). ADR-0044.

### Delivery SLO telemetry, dashboards and alert rules (#33)

- New telemetry (`Converger.Telemetry`): `[:converger, :delivery, :attempt | :stop | :exception]` around the
  adapter call of every delivery attempt (`status`: `sent`, `pending`, `failed`, `dead`), `[:converger, :pipeline,
  :lag]`, `[:converger, :inbound, :received]`, `[:converger, :ws, :connected | :disconnected | :frame]` and
  `[:converger, :circuit, :state_change]`. Adapter calls run in an OpenTelemetry span `converger.delivery`.
- New Prometheus metrics: delivery latency and pipeline lag histograms, attempts and retries, dead-letter size,
  open client connections per socket and transport (`ConvergerWeb.ClientConnections`), frames per second, Oban
  queue depth and job duration, open circuit breakers, inbound messages, Broadway batches.
- Grafana dashboards "Delivery SLO", "Realtime" and "Pipeline"; Prometheus alert rules
  (`docker/prometheus/alerts.yml`) with `promtool` tests and an alert chaos test (`test/chaos/alerts.sh`).
- `METRICS_TENANT_LABEL` (opt-in `tenant_id` label) and `METRICS_POLL_INTERVAL_MS`; ADR-0043.
- **Changed:** `phoenix.endpoint.stop.duration`, `phoenix.router_dispatch.stop.duration` / `.exception.duration`,
  `phoenix.channel_handled_in.duration`, `converger.repo.query.total_time` / `.queue_time` and
  `oban.job.exception.duration` are histograms instead of last-value gauges: query `<name>_bucket` with
  `histogram_quantile`. `phoenix.http.request_count` is now actually counted by `status`. The Grafana Prometheus
  data source has the fixed uid `Prometheus`.

### Adapter behaviour v2: capabilities, config schemas, registry (#36)

- Adapters `use Converger.Channels.Adapter, type: "..."` and declare `capabilities/0` and `config_schema/0`.
  New capabilities: `:external_delivery`, `:receipts`, `:typing`, `:lifecycle_events`, `:provider_ack`
  (plus `:media`, `:templates`, `:reactions`, `:edits`). New optional callbacks: `verify_subscription/2`,
  `health_probe/1`, `normalize_error/1`.
- Registry: the built-in adapters plus `config :converger, :adapters, [...]`; a configured adapter with a
  built-in type replaces it. Checked at boot. Nothing in `lib/` lists channel types any more: accepted
  types, health checks, the dashboard, the admin config form, lifecycle-event delivery, the inbound `200`
  policy and the Meta verification handshake all come from the adapters.
- Config is validated against the schema before the adapter's own checks. `required: :with_signature`
  replaces the hardcoded Meta `app_secret` rule. The webhook's missing-URL error is now
  `webhook config missing: url`.
- The admin channel form is generated from the schema (secrets as password inputs, booleans as selects);
  the channel list summary and masking use it too.
- Health checks: idle `whatsapp_meta` channels are probed on the Graph API (`healthy`, or `degraded` on
  failure). Disable with `config :converger, :channel_health, probe_idle_channels: false`.
- `deliver_activity/2` may return `provider_message_id`; `Pipeline.deliver/2` now returns retryable failures
  as `{:error, %DeliveryError{}}`.
- `docs/channels/writing-an-adapter.md` rewritten around the new behaviour. ADR-0038.

### Rich activity model (#28)

- Activity types are a closed, documented vocabulary: `message`, `event`, `typing`,
  `messageReaction`, `messageUpdate`, `messageDelete`, `conversationUpdate`, `endOfConversation`
  and the internal `deliveryReceipt` (server only). Unknown types are rejected with `422`.
- Attachments are validated on write by `Converger.Activities.ActivityAttachment`
  (`contentType` required; `contentUrl`, `name`, `size`, `thumbnailUrl`, `content`,
  `channelData`). Card attachments (`application/vnd.converger.card.*`) need an object `content`.
  Stored attachments are returned unchanged.
- New `activities.reply_to_id`, `edited_at`, `deleted_at` (migration
  `20261010400000`, online-safe; no foreign key on the partitioned table). Replies, reactions, edits and deletes reference the original;
  edits and deletes are new activities and stamp `edited_at` / `deleted_at` on it. The client API
  adds `replyToId`, `editedAt`, `deletedAt`; the canonical map adds the snake_case fields.
- WhatsApp reactions arrive as `messageReaction` referencing the reacted-to activity (inbound or
  outbound); unresolvable ones stay `event`. WhatsApp replies get `reply_to_id`.
- **Changed:** WhatsApp (Meta and Infobip) media attachment stubs move provider fields
  (`provider`, `providerMediaId`, `sha256`, `voice`, `animated`, `providerMediaUrl`) under
  `channelData`.
- Adapters declare `capabilities/0` (an `activity_types: [...]` entry in its capabilities list); types an adapter cannot deliver
  are downgraded to text or skipped, per channel config `unsupported_activities`
  (`downgrade` | `skip`). **Changed:** `typing` and text-less `event` activities are no longer sent
  to WhatsApp or echo channels as empty messages.
- JSON Schema `priv/protocol/v1/activity.schema.json`; ADR-0036.

### Protocol v1 sends with acks on the Phoenix binding (#24)

- `converger:conversation:*` accepts Converger Protocol v1 `text` frames with the event
  `frame`. A send is stored like `postActivity` (same Inbound path, rate limit and
  `ws:<sender>:<clientId>` key; a mekik/1 `id` is used when there is no `clientId`) and
  answered with an `ack {clientId, id, seq, timestamp}` frame, pushed before the sender's
  own `activitySet`, or an `error` frame with the `clientId`. A resent `clientId` stores
  nothing and gets the original ack with `duplicate: true`.
- At most `max_in_flight` (default 32, `WS_MAX_IN_FLIGHT`) unacked sends per connection;
  the newest beyond it get the retryable `too_many_in_flight`. `welcome.data.limits.maxInFlight`
  announces the configured value.
- `postActivity` replies `duplicate: true` for a resent `clientId`, also on non-`websocket`
  channels.
- Send parsing is shared by both bindings (`ConvergerWeb.Protocol.Send`). ADR-0029.

### Receipts, typing, presence, limits and draining on the native transports (#26 follow-up, #25, #27)

- The native endpoint (`/socket/converger/v1`) accepts `typing` and `read` and pushes `deliveryStatus`,
  `typing` and `presence`, as the Phoenix binding does; `welcome.data.capabilities` now reports `receipts`,
  `typing` and `presence` (per channel config). The SSE stream delivers the same frames and counts an
  identified viewer as online.
- The #25 logic moved from `ConvergerWeb.ConvergerChannel` into `ConvergerWeb.ConversationSignals`, shared by
  the channel, the native socket and the SSE stream (no behaviour change on the Phoenix binding).
- The client WebSocket limits (`config :converger, :websocket`, `WS_*`) apply to the native endpoint: frame
  size, frames per window (`rate_limited` error with `retryAfterMs`), ephemeral frames dropped and close 4503
  for slow consumers. The unreleased `max_frame_bytes` / `max_frame_hard_bytes` keys of
  `config :converger, ConvergerWeb.Protocol` are removed in favour of these.
- Draining: while the node drains, new native connections and SSE streams get 503 with `Retry-After`; on
  shutdown open ones are closed in paced batches (`ConvergerWeb.ProtocolConnections`) with 1012, or an
  `unavailable` error event on SSE. The `ConvergerWeb.Drain` shutdown timeout grows by `drain_shutdown_ms`.
- ADR-0035.

### Partitioning, retention and archive for activities and deliveries (#30)

**Maintenance window** on existing installations (migration `20261010300100`); see
`docs/operations/migrations.md`. Design: `docs/adr/0034-monthly-partitioning-and-per-tenant-retention.md`.

- `activities` (by `inserted_at`) and `deliveries` (by the new `activity_inserted_at`) are monthly range
  partitioned tables, with no foreign keys. `deliveries` gains `tenant_id`. Partitions are created three months
  ahead (migration, boot, daily `PartitionMaintenanceWorker`).
- Existing installations convert with shadow tables, batched copy and swap; above 1,000,000 activities run
  `Converger.Release.prepare_partitioning/0` online first.
- Per-tenant retention: `tenants.retention_days` (default 365, minimum `RETENTION_MIN_DAYS`=30). The monthly
  `RetentionWorker` archives expired months as verified JSONL.gz to the attachment storage
  (`archive/<tenant>/<YYYY-MM>/`, manifest `archive_parts`), then detaches and drops the partitions, or deletes
  only the expired tenant's rows. `mix converger.archive.import` / `Converger.Release.import_archive/1`
  re-import archives.
- Daily `PruneWorker`: `channel_health_checks` (7 days) and `audit_logs` (365 days), configurable with
  `HEALTH_CHECK_RETENTION_DAYS` / `AUDIT_LOG_RETENTION_DAYS`.
- Deleting a tenant, channel or conversation purges its activities and deliveries in batches
  (`PurgeWorker`) instead of one cascading delete.
- Idempotency keys are now also honoured when the first copy is in an older month.
- Benchmark `test/load/partition_drop_benchmark_test.exs` (`--include benchmark`).

### `websocket` is a first-class duplex channel adapter (#22)

- The `websocket` adapter delivers: it broadcasts each activity (after the channel's
  middleware) to the channel's sockets and records a delivery. With no connected client,
  or with `require_ack: true` in the channel config, the delivery stays `pending` (new
  adapter result `{:pending, meta}`, not retried) until a client replays or sends
  `ack {watermark}`.
- `websocket` channels can be routing rule targets: e.g. WhatsApp to an agent console.
  The hardcoded `@delivery_types` list is replaced by an optional adapter
  `capabilities/0` callback (`:outbound`).
- `/socket/converger`: on a `websocket` channel, `postActivity` goes through the new
  `Converger.Inbound` context (the same path as inbound webhooks; requires mode `inbound`
  or `duplex`). New `ack {watermark}` event. Tokens issued with `{"scope": "channel"}`
  (role `agent`) join `converger:channel:<id>` (every delivery to the channel, with
  `conversation_id`; `postActivity` and `ack` name it) and the conversations owned by or
  routed to their channel. Conversation topics drop duplicate frames and fill `seq` gaps
  from the database. The native endpoint (`/socket/converger/v1`, #26) also receives sends on a
  `websocket` channel through `Converger.Inbound`.
- `websocket` channels support all three modes; existing ones (necessarily `outbound`)
  become `duplex` (migration `20261010200000_make_websocket_channels_duplex`).
- Lifecycle events are delivered to `websocket` channels too, and the participant echo
  rule does not apply to them.
- `docs/adr/0033-websocket-channel-adapter-delivery.md` records the design.

### Native Protocol v1 WebSocket, MessagePack, SSE and long-poll fallbacks (#26)

- `GET /socket/converger/v1`: the native Converger Protocol v1 endpoint (`ConvergerWeb.ProtocolSocket`, a
  `WebSock` handler). Raw frames, no Phoenix framing: `hello`/`welcome`, replay after an integer `seq`
  watermark (legacy opaque watermarks accepted), `text` sends with `clientId`, `ack` (`duplicate: true` on
  retransmission), `sync`, `ping`/`heartbeat`, in-band token refresh with `auth`/`tokenRefreshed`, error
  frames with stable codes, close codes 4400/4401/4403/4408/1008, idle timeout and frame size limits. Works
  with unmodified mekik/1 clients (no subprotocol, `id` used as `clientId`).
- Encodings by subprotocol: `converger.v1` / `converger.v1+json` (JSON) and `converger.v1+msgpack`
  (MessagePack, binary messages). Adds `msgpax` as a dependency and `mint_web_socket` as a test-only one.
- `GET /api/v1/converger/conversations/:id/events`: Server-Sent Events fallback with the same v1 frames; the
  `seq` is the event `id`, so `EventSource` resumes through `Last-Event-ID`. Accepts `?token=`.
- Long-polling enabled on `/socket/converger` as the last-resort fallback for the Phoenix binding.
- `GET /api/v1/converger/conversations/:id/activities` also accepts the integer `seq` as `?watermark=`.
- New config `config :converger, ConvergerWeb.Protocol` (heartbeat, idle timeout, frame caps,
  `replay_max`); `token` and `secret` query parameters are filtered from request logs.
- `examples/python/converger_ws.py`: a client using only the `websockets` library.
- ADR-0030; `docs/protocol/v1.md` statuses updated; `docs/websocket.md`, `docs/api/client-api.md`,
  `docs/architecture/realtime.md` and `docs/operations/configuration.md` document the new transports.

### One client socket stack; legacy socket and tokens deprecated (#23)

- The Converger API socket (`/socket/converger`, topic
  `converger:conversation:<id>`) now accepts sends: push `postActivity` with an
  activity (`type`, `text`, `attachments`, `channelData`, optional `clientId`);
  the reply carries `id`, `seq` and `watermark`. The sender is the token's
  `user_id` (else `from.id`, else `"user"`), a repeated `clientId` returns the
  stored activity, and sends share the tenant's `activity_create` rate limit
  with REST. It is the single implementation of the client protocol.
- **Deprecated**, removed no earlier than two minor releases and 6 months from
  now: the legacy socket `/socket` (`UserSocket`, `conversation:<id>`,
  `new_activity`, `last_activity_id`), `POST /api/v1/tokens`, and channel tokens
  in `x-channel-token` (`POST /api/v1/conversations` and the tenant API). The
  tenant API with `x-api-key` is not deprecated. Every use logs a warning
  (per connection or per request), emits `[:converger, :deprecated, :use]`, and
  HTTP responses carry `Deprecation` (RFC 9745) and
  `Link: <...>; rel="deprecation"` headers. Migration guide:
  `docs/api/migrating-from-legacy.md`; decision: ADR-0026.
- `converger_js` and the chaos harness use the Converger API socket.

### Receipts, typing indicators and presence on the WebSocket (#25)

- The Converger API socket (`converger:conversation:<id>`) pushes `deliveryStatus` frames for
  every delivery status change, including WhatsApp `delivered` / `read` receipts, which it used
  to drop. End users with a `user_id` receive them only for their own activities.
- Clients can push `typing {isTyping}` (relayed to the other connections, never stored,
  rate-limited to one state change per 2 s) and `read {watermark}` (stored per reader in the new
  `conversation_reads` table, never moving backwards; the other participants get a
  `deliveryStatus` read receipt).
- `presence` frames per conversation (Phoenix Presence), configurable per channel with the config
  key `presence` (`identified` by default, `all`, `off`); anonymous end users are not announced by
  default.
- New optional adapter callbacks `send_typing/2` and `send_read_receipt/2`; `whatsapp_meta`
  implements both (Cloud API typing indicator and mark as read).
- The `delivery_status` PubSub payload (also pushed to the legacy socket) gains `seq`, `sender`,
  `attempts`, `last_error` and `updated_at`.
- Migration: `20261010100000_create_conversation_reads`. ADR-0032.

### Security fixes

- Tenant API (`x-channel-token`) accepts only channel tokens (`typ: "channel"`, or the legacy
  channel-token shape). Conversation tokens and Converger client tokens, which share the signing
  key and carry a `tenant_id`, were accepted before and unlocked the whole tenant API, including
  routing-rule CRUD.
- Converger client tokens are bound to their channel for every conversation endpoint (activities,
  uploads, resume, attachments); unscoped tokens previously reached every conversation of the
  tenant. WebSocket joins now require a conversation-bound token.
- Routing-rule updates can no longer change `tenant_id`.
- Delivery status updates by `delivery_id` are scoped to the reporting channel.
- The SSRF guard now also covers the tenant `alert_webhook_url` and the WhatsApp Infobip
  `base_url`, at save time and at request time.
- `POST /api/v1/tokens` and `POST /api/v1/conversations` also accept only channel tokens (#23):
  an end user's token could mint legacy conversation tokens for other conversations of its
  channel under any user id. The legacy socket accepts only conversation tokens, and legacy
  verifiers reject Converger client tokens.
### Multi-node clustering, health endpoints, metrics on the main port (#29)

- Clustering with `libcluster` (replaces `dns_cluster`): `CLUSTER_STRATEGY` =
  `kubernetes_dns` | `dns` | `gossip` | `epmd` | `none`. `rel/env.sh.eex` names
  nodes `converger@<ip>` and **requires `RELEASE_COOKIE`** when clustering.
  `DNS_CLUSTER_QUERY` still works (implies `dns`).
- `GET /health/ready` now checks the database, Oban, migrations and the
  draining state of `ConvergerWeb.Drain` (#27); 503 with `reasons` and a
  per-check `checks` map (`status` stays `ready` / `draining`, plus `unavailable`).
- **Breaking:** Prometheus metrics moved to `GET /metrics` on the main port,
  behind `METRICS_TOKEN` (bearer) or `METRICS_ALLOWED_IPS`; 404 when neither
  is set. The unauthenticated listener on 9568 only starts when
  `PROMETHEUS_PORT` is set. `plug_cowboy`/`cowboy`/`cowlib` are gone (and the
  two acknowledged `cowlib` advisories with them).
- Two-node test suite (`test/cluster`, `mix test --only cluster`, own CI job):
  cross-node WebSocket broadcast, shared rate limits, exactly-once deliveries.
- `deploy/k8s` (kustomize), `deploy/fly/fly.toml` and `docker-compose.cluster.yml`.
- Helm chart `deploy/helm/converger`: migration hook, values schema,
  `helm test`, optional Ingress, `PodMonitor`, `NetworkPolicy` and
  chart-managed Secret. Published to `oci://ghcr.io/aimtune/charts/converger`
  on every `v*` tag; the new `Deploy manifests` workflow lints and
  kubeconform-validates the chart and `deploy/k8s`.
- `CLUSTER_DIST_PORT` pins the server's Erlang distribution port (start only,
  so `bin/converger rpc` still works). ADR-0037.

### Converger Protocol v1 specification (#21, refs #63 #68)

Documentation and schemas only; no server behaviour changes.

- `docs/protocol/v1.md`: the WebSocket wire protocol, a superset profile of mekik/1
  (handshake, frame envelope, replay and watermark semantics, acks, receipts, typing,
  presence, channel-scoped sockets, limits, error and close codes, deprecation policy,
  mekik/1 compatibility table). Every feature is marked implemented or planned with
  its issue.
- `docs/protocol/messages.md`: the rich message vocabulary (chativa-compatible) and
  the per-channel downgrade matrix.
- `docs/adr/0024-converger-protocol-v1-as-superset-of-mekik-1.md`: the decisions behind the spec (merged with the ADR from the docs site).
- JSON Schemas (draft 2020-12) for every frame and message type in `priv/protocol/v1/`,
  with example sessions.
- `test/protocol/`: conformance suite validating the schemas, the examples in the
  docs and mekik's golden fixtures (vendored, MIT). Adds `jsv` 0.26 as a test-only
  dependency (with `abnf_parsec`, `texture`, `nimble_parsec`).
- Announced change: from v3.0 (#22) the watermark becomes the integer `seq` in v1 frames
  and in the REST `activitySet`; the opaque base64url watermarks stay accepted for one
  more release (`docs/protocol/v1.md`, section 6.5).

### Chaos test: kill the node during load (#57)

- New chaos harness (`test/chaos/run.sh`, docs/chaos.md, manual/nightly
  `Chaos` workflow): SIGKILLs the app container while REST and WebSocket
  clients send, then verifies zero acked messages lost, no duplicates,
  gap-free `seq` and complete webhook delivery.
- Fixed: re-pushing a legacy WebSocket `new_activity` after a lost reply
  stored the message twice. The push now takes an optional `idempotency_key`
  (stored as `ws:<sender>:<key>`, unique per conversation) and the `ok` reply
  carries the activity `id` and `seq`.
- Added `OBAN_LIFELINE_RESCUE_AFTER_SECONDS` / `OBAN_LIFELINE_INTERVAL_SECONDS`
  to re-deliver jobs orphaned by a crashed node sooner than the 30 minute
  default (unchanged).

### Dependency and platform upgrades (#56)

Toolchain:

- Elixir 1.19.5 / Erlang/OTP 28.5.0.5, pinned in `.tool-versions` and used by
  the `Dockerfile` (`hexpm/elixir:1.19.5-erlang-28.5.0.5-debian-bookworm-20260824-slim`,
  previously 1.18.4 / OTP 27.2). `mix.exs` now requires Elixir `~> 1.18`.

Upgraded:

| Package | From | To | Notes |
| --- | --- | --- | --- |
| `hammer` | 6.2.1 | 7.5.0 | New API, done in #13 (rate limiting). |
| `phoenix_live_view` | 1.0.18 | 1.1.33 | CDN `phoenix_live_view.js` in the layouts was still 0.20.17; it is now pinned to the locked version and a test fails if they drift. `LiveViewTest` now uses `lazy_html`; `floki` was removed (unused). |
| `phoenix` | 1.8.3 | 1.8.15 | CDN `phoenix.js` bumped from 1.7.14 to match. |
| `oban` | 2.20.3 | 2.24.1 | Required by `oban_web` 2.13. Needs the `oban_jobs` schema at v14 (migration `20261009131000`). |
| `bandit` | 1.10.2 | 1.12.5 | Latest minor. |
| `broadway` | 1.2.1 | 1.3.0 | Latest minor. |
| transitive | | | `ecto`/`ecto_sql` 3.14, `plug` 1.20, `phoenix_pubsub` 2.4, `postgrex` 0.22.4, `decimal` 3.1 (not used directly), `websock_adapter` 0.6, `cowboy` 2.19. |

Added:

- `oban_web` 2.13 (Apache-2.0, free on hex.pm since Oban 2.19), mounted at
  `/admin/oban` behind the admin IP whitelist and admin session.
  `super_admin`/`admin` get full access and `viewer` gets read-only access
  (`ConvergerWeb.ObanResolver`).
- `opentelemetry_oban` 1.2: a span for every job execution
  (`OpentelemetryOban.setup/0`).
- `opentelemetry_req` 1.0 via `Converger.HTTP`, used by tenant alert
  webhooks. The channel adapters move to it once the open adapter PRs
  (#82, #85, #87) land.

Deferred in #56, applied afterwards (Dependabot #95, #97, #98, #99, #101, #103):

| Package | From | To | Notes |
| --- | --- | --- | --- |
| `phoenix_live_view` | 1.1.33 | 1.2.12 | Only breaking change is the trimmed global-attributes list (none used). Layout CDN scripts bumped to 1.2.12 (the version-drift test covers them). |
| `req` | 0.5.17 | 0.7.5 | Upgraded to 0.7.5 (`~> 0.7`) for the decompression-bomb fix (only in >= 0.6.1), via #92. The webhook adapter and its `Req.Test` stubs pass on 0.7; custom methods are limited to POST/PUT/PATCH (#87). |
| `gettext` | 0.26.2 | 1.0.2 | No breaking changes; the backend already uses `use Gettext.Backend`. |
| `logger_json` | 6.2.1 | 7.0.4 | The `{LoggerJSON.Formatters.Basic, opts}` handler config and `RedactKeys` are unchanged; JSON output and redaction re-verified. |
| `dns_cluster` | 0.2.0 | 0.3.1 | Adds SRV queries; the `query:` option used here is unchanged. |
| `joken`, `telemetry_metrics` | 2.6.2, 1.1.0 | 2.7.0, 1.2.0 | Compatible minor updates. |

Already handled elsewhere:

- OpenTelemetry exporter configuration is read at runtime from the standard
  `OTEL_*` variables (#76). Verified unchanged.
- WhatsApp Graph API version (`v18.0`) is made configurable in #82.
