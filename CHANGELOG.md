# Changelog

All notable changes to Converger are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). No release has been tagged yet, so everything merged so
far is under **Unreleased**; once releases are tagged, versions follow [Semantic Versioning](https://semver.org/).
Upgrade steps for operators are in [Upgrades](https://converger.aimtune.dev/operations/upgrades).

## Unreleased

### License and community health files (#48)

- Converger is now released under the **MIT License** (`LICENSE`). The README previously said "commercially
  licensed" and the repository had no license file. See ADR-0026.
- Added `SECURITY.md` (private vulnerability reporting via GitHub advisories or email, response targets),
  `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1) and issue forms in `.github/ISSUE_TEMPLATE/` (bug report, feature
  request, channel adapter request; blank issues disabled, security reports sent to advisories).
- `VERSIONS.md` is folded into this file under [Milestones before this changelog](#milestones-before-this-changelog)
  and removed.
- README: fixed the clone URL, removed the unverified in-process benchmark numbers (load testing is #34), replaced
  the architecture diagram with one showing channels, modes, routing and the delivery pipeline.

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

## Milestones before this changelog

Until #48 the feature history was kept in `VERSIONS.md` as planning milestones. They are not git tags or package
versions (`mix.exs` is still `0.1.0`). They are kept as written, so some items implemented later are still
unticked; channel config encryption at rest is ticked with its issue. Current planned work is on the
[roadmap](https://converger.aimtune.dev/roadmap).

### v1.0 — MVP (Completed)

- [x] Multi-tenant data model (tenants, channels, conversations, activities)
- [x] REST API for conversations and activities
- [x] Real-time WebSocket streaming via Phoenix Channels
- [x] JWT token authentication (conversation + channel tokens)
- [x] Tenant API key authentication
- [x] Activity idempotency (x-idempotency-key)
- [x] Admin panel (LiveView, IP-restricted)
- [x] Background jobs (Oban: conversation expiration)
- [x] Observability stack (OpenTelemetry, Prometheus, Grafana, Jaeger, Loki)
- [x] Echo channel type for testing
- [x] Rate limiting (IP + tenant scoped)
- [x] Activity ordering per conversation
- [x] JavaScript client library (converger_js)

### v1.1 — Bug Fixes & Foundation (Completed)

- [x] Fix IO.puts in workers — use Logger.info instead
- [x] Fix bare rescue in TenantAuth plug — catch only Ecto.NoResultsError
- [x] Configurable CORS origins (CORS_ORIGINS env variable)
- [x] Configurable admin IP whitelist (ADMIN_IP_WHITELIST env variable)
- [x] Channel status validation on conversation creation
- [x] Tenant status validation on token creation
- [x] Remove unused TokenCleanupWorker
- [x] Add `config` JSONB field to channels table
- [x] Channel Adapter behaviour (`Converger.Channels.Adapter`)
- [x] Echo adapter implementation
- [x] WebSocket adapter implementation
- [x] Expanded channel types: echo, webhook, websocket, whatsapp_meta, whatsapp_infobip
- [x] Channel config validation in changeset via adapter

### v1.2 — Webhook Channel (Completed)

- [x] Webhook adapter: outbound HTTP POST delivery via Req
- [x] Webhook adapter: config validation (url required, valid HTTP/HTTPS)
- [x] Webhook adapter: inbound payload parsing
- [x] Inbound webhook endpoint (POST /api/v1/channels/:id/inbound)
- [x] Webhook verification endpoint (GET /api/v1/channels/:id/inbound)
- [x] Auto-conversation creation for inbound messages
- [x] Webhook signature verification (HMAC-SHA256 via x-converger-signature)
- [x] Raw body caching for signature verification (CacheBodyReader)
- [x] Channel inactive error handler in FallbackController

### v1.3 — Delivery System (Completed)

- [x] Deliveries table (status tracking per activity per channel)
- [x] Delivery schema and context module (Converger.Deliveries)
- [x] ActivityDeliveryWorker (Oban, deliveries queue, max 5 attempts)
- [x] Exponential backoff for failed deliveries (3^attempt * 10 seconds)
- [x] Automatic delivery enqueue on activity creation for external channels
- [x] Delivery status counts in admin dashboard
- [x] Oban deliveries queue (20 concurrent workers)

### v2.0 — WhatsApp Integration (Completed)

- [x] WhatsApp Meta adapter (Cloud API v18.0)
  - [x] Config validation (phone_number_id, access_token, verify_token)
  - [x] Outbound text message delivery
  - [x] Inbound message parsing (webhook notification format)
  - [x] Webhook verification (hub.verify_token challenge)
- [x] WhatsApp Infobip adapter
  - [x] Config validation (base_url, api_key, sender)
  - [x] Outbound text message delivery
  - [x] Inbound message parsing
- [x] Admin panel: dynamic channel type dropdown from schema
- [x] Updated PRD for v2.0

### v2.1 — Parametric Pipeline (Completed)

- [x] Parametric activity processing pipeline (`Converger.Pipeline` behaviour)
- [x] Pipeline.Oban backend (default — persistent job queue with Oban)
- [x] Pipeline.Broadway backend (stream processing with configurable producers)
  - [x] In-memory GenStage producer (MemoryProducer)
  - [x] Kafka producer via :brod (optional dependency)
  - [x] RabbitMQ producer via :amqp (optional dependency)
  - [x] Custom producer support
- [x] Pipeline.Inline backend (synchronous — for testing/development)
- [x] Activities.create_activity refactored: broadcast+delivery moved outside DB transaction
- [x] Pipeline child_specs integrated into Application supervision tree
- [x] Config-driven backend selection (`config :converger, pipeline: [backend: ...]`)
- [x] Test env uses Pipeline.Inline for deterministic testing

### v2.2 — Message Routing & Fan-Out (Completed)

- [x] Routing rules data model (`routing_rules` table with UUID array targets)
- [x] RoutingRule schema + context with full CRUD
- [x] Tenant isolation validation (all channels must belong to same tenant)
- [x] Cycle detection (BFS-based write-time validation prevents routing loops)
- [x] Self-reference validation (source channel cannot be in targets)
- [x] Pipeline multi-channel fan-out (`resolve_delivery_channels` returns list)
- [x] All 3 pipeline backends updated (Oban, Broadway, Inline)
- [x] REST API: `GET/POST/PUT/DELETE /api/v1/routing_rules`
- [x] Admin LiveView: `/admin/routing_rules` (create, toggle, delete with tenant-filtered dropdowns)
- [x] Router updated with API + admin routes

### v2.3 — Future Enhancements (Planned)

- [ ] Media message support (images, documents, audio, video)
- [ ] Template message support (WhatsApp HSM templates)
- [x] Delivery receipts / read receipts
- [x] Channel health monitoring and alerting
- [ ] Webhook retry dashboard in admin panel
- [x] Message transformation pipeline (middleware)
- [ ] Per-channel rate limiting
- [ ] SDK updates (JS client for inbound webhooks, delivery status)
- [x] Channel config encryption at rest (#12, ADR-0012)

### v2.4 — User Management & Multi-Login (Completed)

- [x] Admin user accounts (`admin_users` table with bcrypt password hashing)
- [x] Tenant user accounts (`tenant_users` table with tenant-scoped email uniqueness)
- [x] Admin roles: super_admin, admin, viewer
- [x] Tenant roles: owner, admin, member, viewer
- [x] Session-based authentication (cookie sessions)
- [x] Admin login page (`/admin/login`) with IP whitelist protection
- [x] Tenant portal login page (`/portal/login`) with freetext tenant name (no tenant enumeration)
- [x] Dual-layer auth: Plug-level `require_admin_user`/`require_tenant_user` + LiveView `on_mount` hooks
- [x] Admin panel: Admin Users management (CRUD, role assignment, super_admin-only creation)
- [x] Admin panel: Tenant Users management (CRUD, tenant filter, role assignment)
- [x] Tenant portal (`/portal/*`) with tenant-scoped views
  - [x] Dashboard (channel, conversation, activity stats)
  - [x] Channels (view, toggle status)
  - [x] Conversations (list, detail with activity timeline)
  - [x] Routing Rules (view, toggle enabled)
  - [x] Users (owner/admin can manage team members)
- [x] Separate layouts: admin (blue theme) and portal (green theme) with user info + logout
- [x] Role-based authorization (viewer read-only, member CRUD, owner/admin user management)
- [x] Audit log integration: actor tracked by user email instead of IP address
- [x] Audit log resource types extended: `admin_user`, `tenant_user`
- [x] Seed data: default super_admin user (`admin@converger.local`)
- [x] `password_hash` and `password` added to audit log sensitive fields

### v3.0 — Enterprise (Planned)

- [ ] Tenant sharding for horizontal data scaling
- [ ] Multi-region replication
- [ ] Advanced analytics dashboards
- [ ] SLA tiers per tenant
- [x] Enterprise RBAC (role-based access control)
- [x] Audit logging
- [ ] API versioning strategy
- [ ] SMS channel adapters (Twilio, Vonage)
- [ ] Email channel adapter (SMTP/SendGrid)
- [ ] Telegram/Slack channel adapters
