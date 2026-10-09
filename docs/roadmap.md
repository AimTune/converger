---
title: Roadmap
description: Converger's roadmap from production hardening to WebSocket-first, scale, channel expansion and developer experience, with the status of every issue.
sidebar_position: 90
---

The roadmap lives on GitHub. The umbrella issue is [#62 Roadmap: from idle prototype to production-grade channel hub](https://github.com/AimTune/converger/issues/62), and it is split into five epics. This page summarizes them and lists every issue with its state as of October 2026. GitHub is the source of truth: when an issue and this page disagree, the issue wins.

## Vision

Converger connects communication channels to each other. Every channel is inbound, outbound or duplex. Messages are persisted once, ordered per conversation, and routed to any number of target channels with transformations, retries, receipts and full observability. WebSocket is the first-class channel, with its own documented protocol, and webhooks, WhatsApp, Telegram, Slack, Email, SMS and message brokers follow. The system scales horizontally, never loses an acknowledged message, and should be easy to integrate with.

| Phase | Epic | Focus | Status |
| --- | --- | --- | --- |
| 1 | [#57 v2.5 Production Hardening](https://github.com/AimTune/converger/issues/57) | No data loss, security baseline, CI | All 23 tasks closed. The epic stays open for its exit criteria (chaos test). |
| 2 | [#58 v3.0 WebSocket-first & Converger Protocol v1](https://github.com/AimTune/converger/issues/58) | Duplex WS adapter, acks, receipts, spec, one socket stack | Open |
| 3 | [#59 v3.1 Scale & Reliability](https://github.com/AimTune/converger/issues/59) | Clustering, partitioning, breakers, DLQ, SLO telemetry | Open |
| 4 | [#60 v3.2 Channel Expansion](https://github.com/AimTune/converger/issues/60) | Adapter v2, conditional routing, new channels | Open |
| 5 | [#61 v3.3 Developer Experience](https://github.com/AimTune/converger/issues/61) | OpenAPI, SDKs, docs, management API, UI | Open |

Phases 3 to 5 can overlap now that phase 1 is done. Phase 2 should land before the SDKs in phase 5, because the SDKs implement the protocol.

## Done: v2.5 Production Hardening (#57)

Every task of the hardening epic is closed. The goal was that no message can be lost, no tenant can read another tenant's secrets, and the hot paths are bounded. The decisions behind these fixes are recorded as [ADRs](adr/index.md).

### Data loss

| Issue | What changed |
| --- | --- |
| [#1](https://github.com/AimTune/converger/issues/1) | Delivery jobs are enqueued in the activity's transaction (transactional outbox, [ADR-0001](adr/0001-transactional-outbox-with-oban.md)). |
| [#2](https://github.com/AimTune/converger/issues/2) | The Broadway backend no longer drops failed deliveries: retries and dead letters go through Oban ([ADR-0002](adr/0002-broadway-for-throughput-oban-for-retries.md)). |
| [#3](https://github.com/AimTune/converger/issues/3) | The WebSocket `new_activity` path no longer double-delivers or bypasses the pipeline ([ADR-0003](adr/0003-pipeline-is-the-only-delivery-path.md)). |
| [#15](https://github.com/AimTune/converger/issues/15) | The WhatsApp adapters parse every message and status in a webhook batch ([ADR-0015](adr/0015-per-message-idempotent-inbound-batches.md)). |
| [#19](https://github.com/AimTune/converger/issues/19) | Per-channel retry policy, consistent with Oban, plus unique jobs and Lifeline ([ADR-0019](adr/0019-per-channel-retry-policy-delivery-error-and-lifeline.md)). |

### Real-time contract and correctness

| Issue | What changed |
| --- | --- |
| [#4](https://github.com/AimTune/converger/issues/4) | The PubSub broadcast carries the full canonical activity ([ADR-0004](adr/0004-single-canonical-activity-serializer.md)). |
| [#5](https://github.com/AimTune/converger/issues/5) | Clients can no longer set `inserted_at`, `idempotency_key` or other server fields ([ADR-0005](adr/0005-separate-client-and-system-changesets.md)). |
| [#6](https://github.com/AimTune/converger/issues/6) | Monotonic per-conversation `seq` and opaque watermarks ([ADR-0006](adr/0006-per-conversation-seq-and-opaque-watermarks.md)). |
| [#8](https://github.com/AimTune/converger/issues/8) | Middleware receives the channel, and middleware crashes are contained ([ADR-0008](adr/0008-middleware-receives-channel-and-crashes-are-contained.md)). |
| [#18](https://github.com/AimTune/converger/issues/18) | Every list query is bounded and keyset-paginated ([ADR-0018](adr/0018-keyset-pagination.md)). |
| [#20](https://github.com/AimTune/converger/issues/20) | Socket ids are per end user or conversation, not per channel ([ADR-0020](adr/0020-per-subject-socket-ids-and-presence.md)). |

### Security baseline

| Issue | What changed |
| --- | --- |
| [#9](https://github.com/AimTune/converger/issues/9) | Inbound signature verification with per-channel enforcement, including `/status` ([ADR-0009](adr/0009-inbound-signature-scheme-and-per-channel-enforcement.md)). |
| [#10](https://github.com/AimTune/converger/issues/10) | `CORS_ORIGINS` and the OpenTelemetry endpoint are read at runtime ([ADR-0010](adr/0010-runtime-cors-and-opentelemetry-configuration.md)). |
| [#11](https://github.com/AimTune/converger/issues/11) | The admin IP allowlist is proxy-aware through `TRUSTED_PROXIES` ([ADR-0011](adr/0011-custom-trusted-proxies-plug.md)). |
| [#12](https://github.com/AimTune/converger/issues/12) | Channel secrets and configs are encrypted at rest, API keys are hashed, and audit logs are redacted ([ADR-0012](adr/0012-secrets-at-rest-and-audit-redaction.md)). |
| [#13](https://github.com/AimTune/converger/issues/13) | Rate limiting on the hot paths, cluster-wide when clustered ([ADR-0013](adr/0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md)). |
| [#14](https://github.com/AimTune/converger/issues/14) | Webhook hardening: SSRF guard, outbound signing, timeouts and response limits ([ADR-0014](adr/0014-webhook-ssrf-guard-and-outbound-signing.md)). |
| [#55](https://github.com/AimTune/converger/issues/55) | Deployment hardening: no committed secrets, `FORCE_SSL`/HSTS, migrations as a separate step, backups, runbook ([ADR-0022](adr/0022-deployment-hardening.md)). |

### Product gaps

| Issue | What changed |
| --- | --- |
| [#7](https://github.com/AimTune/converger/issues/7) | Uploaded files are served through an authenticated endpoint, with S3, GCS and Azure storage ([ADR-0007](adr/0007-attachment-storage-with-hand-written-signing.md), [storage](storage.md)). |
| [#16](https://github.com/AimTune/converger/issues/16) | Participant-based conversation resolution for inbound messages ([ADR-0016](adr/0016-participant-based-conversation-resolution.md)). |
| [#17](https://github.com/AimTune/converger/issues/17) | Conversation lifecycle (close, reopen, expiry) enforced under the `seq` lock ([ADR-0017](adr/0017-conversation-lifecycle-enforced-under-the-seq-lock.md)). |

### Tooling

| Issue | What changed |
| --- | --- |
| [#54](https://github.com/AimTune/converger/issues/54) | CI with format, warnings-as-errors, Credo, Dialyzer, Sobelow, dependency audit, tests on Postgres and coverage ([ADR-0021](adr/0021-ci-quality-gates-and-lf-line-endings.md)). |
| [#56](https://github.com/AimTune/converger/issues/56) | Dependency and platform upgrades: LiveView, Hammer 7, Graph API version, Oban Web, OTEL config, Elixir/OTP alignment ([ADR-0023](adr/0023-platform-and-dependency-baseline.md)). |

The remaining exit criterion is a chaos test (killing a node under load) that shows zero acknowledged messages lost across REST and WebSocket.

## Next: v3.0 WebSocket-first & Converger Protocol v1 (#58)

WebSocket becomes the primary channel, with a documented wire protocol that any language can implement. A WebSocket channel can be the source or target of routing rules, delivers with acks, resumes exactly from a watermark, and exposes receipts, typing and presence. The two existing socket stacks collapse into one. The design principles: persist first, then push; client ids plus acks give at-least-once send with exactly-once persistence; the protocol comes before the SDKs; and everything is bounded.

| Issue | Title | State |
| --- | --- | --- |
| [#63](https://github.com/AimTune/converger/issues/63) | Converger Protocol v1 must be wire-compatible with mekik/1 (hello/welcome, seq envelope, chativa frame vocabulary) | Open ([ADR-0024](adr/0024-converger-protocol-v1-as-superset-of-mekik-1.md)) |
| [#21](https://github.com/AimTune/converger/issues/21) | Specify the Converger Protocol v1 (WebSocket wire protocol) | Open |
| [#22](https://github.com/AimTune/converger/issues/22) | Make `websocket` a first-class duplex channel adapter (deliver to sockets, offline buffering, fan-out target) | Open (implemented, pending merge; [ADR-0033](adr/0033-websocket-channel-adapter-delivery.md)) |
| [#23](https://github.com/AimTune/converger/issues/23) | Unify `UserSocket`/`ConversationChannel` and `ConvergerSocket`/`ConvergerChannel` into one protocol implementation | In review ([ADR-0026](adr/0026-one-client-socket-stack-and-shape-checked-legacy-tokens.md)) |
| [#24](https://github.com/AimTune/converger/issues/24) | Client-side message ids with server acks over WebSocket (at-least-once send, exactly-once persistence) | Open |
| [#25](https://github.com/AimTune/converger/issues/25) | Push delivery/read receipts, typing indicators and presence to WebSocket clients | Done (Phoenix channel binding; v1 framing with #22) |
| [#26](https://github.com/AimTune/converger/issues/26) | Raw WebSocket endpoint (non-Phoenix framing), optional MessagePack encoding, and SSE/long-poll fallback | Open |
| [#27](https://github.com/AimTune/converger/issues/27) | WebSocket connection limits, backpressure, socket draining and graceful shutdown | Open |
| [#28](https://github.com/AimTune/converger/issues/28) | Rich activity model: activity types, attachment schema, reactions, edits/deletes, reply threading | Open |
| [#68](https://github.com/AimTune/converger/issues/68) | Rich message vocabulary compatible with chativa: buttons, quick-reply, cards, carousel, image/file, GenUI and tool traces as first-class activity payloads with per-channel downgrade | Open |
| [#64](https://github.com/AimTune/converger/issues/64) | mekik integration: agent-side multiplexed socket, `mekik` channel adapter, and seq authority between Converger and mekik | Open |
| [#65](https://github.com/AimTune/converger/issues/65) | Chativa as the reference WebSocket client: verify `connector-mekik` against Converger, add hub extras (delivery status, upload, history, multi-conversation) | Open |
| [#67](https://github.com/AimTune/converger/issues/67) | Agent SDK and bot-side adapters: channel-scoped agent sockets, `@converger/agent` SDKs in several languages, first-party LangServe/LangChain and mekik adapters | Open |

Suggested order: #63 and #68 feed the spec, then #21, then #22 with #23, #24, #25, #27, #28, and finally #26. Exit criteria: a WhatsApp to WebSocket agent console bridge works end to end with receipts; a Python client written only from the spec passes the conformance suite; a rolling restart under 10k connections loses no acknowledged message.

## v3.1 Scale & Reliability (#59)

Run Converger as a cluster that meets the PRD targets (10M messages per day, 1k+ concurrent sockets per node, p95 below 250 ms end to end), and keep it healthy when a provider or the database misbehaves.

| Issue | Title | State |
| --- | --- | --- |
| [#29](https://github.com/AimTune/converger/issues/29) | Multi-node clustering: libcluster strategies, cross-node verification, health/readiness endpoints, k8s manifests | Open |
| [#33](https://github.com/AimTune/converger/issues/33) | Delivery and pipeline telemetry, Grafana dashboards and alert rules (SLO instrumentation) | Open |
| [#31](https://github.com/AimTune/converger/issues/31) | Per-channel circuit breaker, provider rate limiting and tenant-fair queueing | Done |
| [#32](https://github.com/AimTune/converger/issues/32) | Dead-letter queue with inspection and replay (API + admin UI) | Done (optional automatic replay on breaker close not implemented) |
| [#30](https://github.com/AimTune/converger/issues/30) | Table partitioning and retention for `activities` and `deliveries`; archival to object storage | Open |
| [#35](https://github.com/AimTune/converger/issues/35) | Graceful degradation under database pressure: pool sizing, timeouts, bulkheads, readiness flip | Open |
| [#66](https://github.com/AimTune/converger/issues/66) | Pluggable event backbone: Elixir-native (PubSub + Oban) by default, Kafka/NATS/RabbitMQ selectable, with a published benchmark matrix | Open |
| [#34](https://github.com/AimTune/converger/issues/34) | Load testing harness (k6 WebSocket + REST scenarios) with nightly CI run and published baselines | Open |

Exit criteria: a nightly load test publishes p95 latency and connection counts with enforced thresholds; one dead channel does not degrade other tenants; partition drop and archive are verified on a 100M-row dataset.

## v3.2 Channel Expansion (#60)

Turn the adapter layer into a real plugin system and ship the channels integrators ask for most. Conditional routing with reply-back makes multi-channel conversations usable.

| Issue | Title | State |
| --- | --- | --- |
| [#36](https://github.com/AimTune/converger/issues/36) | Adapter behaviour v2: `capabilities/0`, `config_schema/0`, provider signature verification, typing, health probe | Open |
| [#43](https://github.com/AimTune/converger/issues/43) | Conditional routing rules: filters, priority, reply-back routing, per-rule transformations, dry-run | Open |
| [#37](https://github.com/AimTune/converger/issues/37) | WhatsApp: media messages, template (HSM) messages, interactive messages and inbound media download | Open |
| [#38](https://github.com/AimTune/converger/issues/38) | Telegram Bot adapter (duplex) | Open |
| [#39](https://github.com/AimTune/converger/issues/39) | Slack adapter (Events API inbound, Web API outbound, signing secret verification) | Open |
| [#40](https://github.com/AimTune/converger/issues/40) | Email adapter (outbound via Swoosh, inbound via provider parse webhooks) | Open |
| [#41](https://github.com/AimTune/converger/issues/41) | SMS adapters (Twilio, Vonage) with delivery receipts | Open |
| [#42](https://github.com/AimTune/converger/issues/42) | Message broker channel adapters: Kafka, RabbitMQ, NATS, Redis Streams as first-class channels | Open |
| [#44](https://github.com/AimTune/converger/issues/44) | Backlog of additional adapters: Discord, Microsoft Teams (Bot Framework), Facebook Messenger, Instagram, Viber, MQTT, gRPC streaming | Open |

Exit criteria: adding an adapter touches only the adapter module and one config line, and at least three new duplex channels reach production quality with fixture-based tests. Adapter requests go to [#44](https://github.com/AimTune/converger/issues/44).

## v3.3 Developer Experience (#61)

Make Converger adoptable by someone who has never read its source: a license, a five-minute getting-started, an OpenAPI spec with a playground, typed SDKs with reconnect built in, a management API, event webhooks, and a modern admin and portal UI.

| Issue | Title | State |
| --- | --- | --- |
| [#48](https://github.com/AimTune/converger/issues/48) | Documentation site and OSS hygiene: guides, adapter authoring, deployment, LICENSE, CONTRIBUTING, SECURITY, templates, CHANGELOG | Open (this site, [ADR-0025](adr/0025-docusaurus-site-and-docs-with-every-change.md)) |
| [#45](https://github.com/AimTune/converger/issues/45) | OpenAPI 3.1 specification, Swagger UI, consistent error envelope and API versioning policy | Open |
| [#46](https://github.com/AimTune/converger/issues/46) | TypeScript SDK (`@converger/client`) implementing Protocol v1 with reconnect, watermark resume, outbox and token refresh | Open |
| [#47](https://github.com/AimTune/converger/issues/47) | Server-side SDKs: Python and Go (REST + WebSocket), Elixir client library, signature verification helpers | Open |
| [#51](https://github.com/AimTune/converger/issues/51) | Management API: tenants, channels, routing rules, users and secret rotation via REST with scoped API keys | Open |
| [#52](https://github.com/AimTune/converger/issues/52) | Auth hardening: token revocation, refresh rotation, scoped tokens, admin 2FA, password reset, session expiry | Open |
| [#49](https://github.com/AimTune/converger/issues/49) | Platform event webhooks: tenant-level subscriptions for activity, delivery, conversation and channel events (signed, retried) | Open |
| [#50](https://github.com/AimTune/converger/issues/50) | Admin panel and tenant portal modernization: Tailwind/daisyUI, pagination and search, channel test-send, key rotation, deliveries view, live tail | Open |
| [#53](https://github.com/AimTune/converger/issues/53) | Windows developer setup: `bcrypt_elixir` requires MSVC `nmake`; document or offer a pure-Elixir hashing option | Open (workaround in [Getting started](getting-started.md#per-os-notes)) |

Exit criteria: a new integrator provisions a tenant and a channel through the API, embeds the TypeScript SDK and exchanges messages using only the docs; the docs site is published from CI; the GitHub community profile is complete.

## How to contribute

Pick an unassigned issue in the current epic, comment to claim it, read the [contributing guide](contributing.md), and run `mix precommit` before opening a pull request. Changes that alter behavior update the docs in the same pull request ([ADR-0025](adr/0025-docusaurus-site-and-docs-with-every-change.md)).
