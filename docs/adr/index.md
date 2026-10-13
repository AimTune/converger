---
title: Architecture decision records
sidebar_label: Overview
sidebar_position: 1
description: Index of Converger's Architecture Decision Records (ADRs) - the context, options, decision and consequences behind each architectural choice.
---

An Architecture Decision Record (ADR) captures one architecturally significant
decision: the problem and the forces at play, the options that were on the
table, what was chosen and why, and what it costs. Converger keeps its ADRs in
[`docs/adr/`](https://github.com/AimTune/converger/tree/main/docs/adr), next to
the code, in the [MADR](https://adr.github.io/madr/) format.

ADRs are immutable once accepted. When a decision changes, a new ADR
supersedes the old one and both are linked. Read
[How we write ADRs](how-we-write-adrs.md) before adding one, and start from the
[template](template.md).

## Status values

| Status | Meaning |
| --- | --- |
| **Proposed** | Under discussion in an issue or pull request. |
| **Accepted** | Decided and, unless noted, implemented on `main`. |
| **Deprecated** | No longer relevant (the feature was removed). |
| **Superseded by ADR-NNNN** | Replaced by a later decision. |

## Index

### Delivery and data integrity

| ADR | Decision | Status | Issue / PR |
| --- | --- | --- | --- |
| [0001](0001-transactional-outbox-with-oban.md) | Transactional outbox: Oban delivery jobs are inserted in the activity transaction | Accepted | [#1](https://github.com/AimTune/converger/issues/1) / [#69](https://github.com/AimTune/converger/pull/69) |
| [0002](0002-broadway-for-throughput-oban-for-retries.md) | Broadway for throughput, Oban for retries and dead letters | Accepted | [#2](https://github.com/AimTune/converger/issues/2) / [#70](https://github.com/AimTune/converger/pull/70) |
| [0003](0003-pipeline-is-the-only-delivery-path.md) | The pipeline is the only delivery path | Accepted | [#3](https://github.com/AimTune/converger/issues/3) / [#71](https://github.com/AimTune/converger/pull/71) |
| [0004](0004-single-canonical-activity-serializer.md) | One canonical activity serializer for REST, sockets and broadcasts | Accepted | [#4](https://github.com/AimTune/converger/issues/4) / [#72](https://github.com/AimTune/converger/pull/72) |
| [0005](0005-separate-client-and-system-changesets.md) | Separate client and system changesets for activities | Accepted | [#5](https://github.com/AimTune/converger/issues/5) / [#73](https://github.com/AimTune/converger/pull/73) |
| [0006](0006-per-conversation-seq-and-opaque-watermarks.md) | Per-conversation `seq` under a row lock and opaque seq watermarks | Accepted | [#6](https://github.com/AimTune/converger/issues/6) / [#78](https://github.com/AimTune/converger/pull/78) |
| [0015](0015-per-message-idempotent-inbound-batches.md) | Per-message idempotent processing of inbound batches | Accepted | [#15](https://github.com/AimTune/converger/issues/15) / [#82](https://github.com/AimTune/converger/pull/82) |
| [0016](0016-participant-based-conversation-resolution.md) | Participant-based conversation resolution for inbound messages | Accepted | [#16](https://github.com/AimTune/converger/issues/16) / [#88](https://github.com/AimTune/converger/pull/88) |
| [0017](0017-conversation-lifecycle-enforced-under-the-seq-lock.md) | Conversation lifecycle enforced under the seq lock | Accepted | [#17](https://github.com/AimTune/converger/issues/17) / [#84](https://github.com/AimTune/converger/pull/84) |
| [0018](0018-keyset-pagination.md) | Keyset pagination for every list query | Accepted | [#18](https://github.com/AimTune/converger/issues/18) / [#89](https://github.com/AimTune/converger/pull/89) |
| [0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md) | Per-channel retry policy, `DeliveryError` and Oban Lifeline | Accepted | [#19](https://github.com/AimTune/converger/issues/19) / [#85](https://github.com/AimTune/converger/pull/85) |
| [0028](0028-dead-letter-replay-in-place-through-oban.md) | Dead-letter replay resets the delivery in place and always goes through Oban | Accepted | [#32](https://github.com/AimTune/converger/issues/32) / [#121](https://github.com/AimTune/converger/pull/121) |
| [0031](0031-per-channel-circuit-breaker-rate-limit-and-tier-queues.md) | Per-channel circuit breaker on the channel row, priority-based parking, Hammer rate limits and tier queues | Accepted | [#31](https://github.com/AimTune/converger/issues/31) / [#120](https://github.com/AimTune/converger/pull/120) |
| [0034](0034-monthly-partitioning-and-per-tenant-retention.md) | Monthly partitioning of activities and deliveries, per-tenant retention and verified archives | Accepted | [#30](https://github.com/AimTune/converger/issues/30) / [#124](https://github.com/AimTune/converger/pull/124) |
| [0036](0036-rich-activity-model.md) | Rich activity model: closed type vocabulary, validated attachments, append-only edits and deletes, adapter capabilities with downgrade | Accepted | [#28](https://github.com/AimTune/converger/issues/28) / [#125](https://github.com/AimTune/converger/pull/125) |

### Channels, middleware and real time

| ADR | Decision | Status | Issue / PR |
| --- | --- | --- | --- |
| [0007](0007-attachment-storage-with-hand-written-signing.md) | Attachment storage with hand-written Req signing, CDN layer and authenticated downloads | Accepted | [#7](https://github.com/AimTune/converger/issues/7) / [#80](https://github.com/AimTune/converger/pull/80) |
| [0008](0008-middleware-receives-channel-and-crashes-are-contained.md) | Middleware receives the channel; middleware crashes are contained | Accepted | [#8](https://github.com/AimTune/converger/issues/8) / [#74](https://github.com/AimTune/converger/pull/74) |
| [0020](0020-per-subject-socket-ids-and-presence.md) | Per-subject socket ids and Presence | Accepted | [#20](https://github.com/AimTune/converger/issues/20) / [#81](https://github.com/AimTune/converger/pull/81) |
| [0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md) | Converger Protocol v1 is a superset profile of mekik/1 | Accepted | [#63](https://github.com/AimTune/converger/issues/63) |
| [0026](0026-one-client-socket-stack-and-shape-checked-legacy-tokens.md) | One client socket stack; the legacy socket and token family are deprecated | Accepted | [#23](https://github.com/AimTune/converger/issues/23) / [#115](https://github.com/AimTune/converger/pull/115) |
| [0027](0027-websocket-limits-backpressure-and-draining.md) | WebSocket limits in the socket transport, mailbox backpressure and readiness-gated draining | Accepted | [#27](https://github.com/AimTune/converger/issues/27) / [#117](https://github.com/AimTune/converger/pull/117) |
| [0029](0029-websocket-sends-acked-on-the-phoenix-binding.md) | Protocol v1 sends on the Phoenix binding are acked in the channel process, with an in-flight window counted from its mailbox | Accepted | [#24](https://github.com/AimTune/converger/issues/24) / [#127](https://github.com/AimTune/converger/pull/127) |
| [0030](0030-native-websocket-endpoint-and-fallback-transports.md) | Native v1 WebSocket on WebSock, MessagePack by subprotocol, SSE and long-poll fallbacks | Accepted | [#26](https://github.com/AimTune/converger/issues/26) / [#122](https://github.com/AimTune/converger/pull/122) |
| [0032](0032-transient-conversation-signals.md) | Transient conversation signals: receipts, typing and presence over dedicated topics, stored read watermarks, optional adapter callbacks | Accepted | [#25](https://github.com/AimTune/converger/issues/25) |
| [0033](0033-websocket-channel-adapter-delivery.md) | The `websocket` channel is a delivering adapter with pending receipts | Accepted | [#22](https://github.com/AimTune/converger/issues/22) / [#119](https://github.com/AimTune/converger/pull/119) |
| [0035](0035-native-transports-share-signals-limits-and-draining.md) | Native transports share the signals core, the client WebSocket limits and draining | Accepted | [#26](https://github.com/AimTune/converger/issues/26), [#25](https://github.com/AimTune/converger/issues/25), [#27](https://github.com/AimTune/converger/issues/27) / [#123](https://github.com/AimTune/converger/pull/123) |
| [0056](0056-grpc-streaming-transport.md) | Protocol v1 over a gRPC bidirectional stream on its own port; one transport-agnostic session for the WebSocket and gRPC, lossless JSON-protobuf frame mapping with a `raw` Struct fallback, a `Close` frame plus a matching gRPC status for endings | Accepted | [#44](https://github.com/AimTune/converger/issues/44) / [#156](https://github.com/AimTune/converger/pull/156) |
| [0038](0038-adapter-behaviour-v2-and-config-driven-registry.md) | Adapter behaviour v2: declared capabilities and config schemas, a registry from built-ins plus `config :converger, :adapters` | Accepted | [#36](https://github.com/AimTune/converger/issues/36) / [#130](https://github.com/AimTune/converger/pull/130) |
| [0039](0039-whatsapp-rich-outbound-and-inbound-media-download.md) | WhatsApp rich outbound messages through a shared planner, synchronous inbound media download into Converger storage, cached template listing | Accepted | [#37](https://github.com/AimTune/converger/issues/37) / [#134](https://github.com/AimTune/converger/pull/134) |
| [0040](0040-slack-adapter-message-refs-conversation-scopes-and-in-band-challenge.md) | Slack adapter: `<channel>:<ts>` message refs, `conversation_scope` thread / channel / user, an in-band `inbound_challenge/2` callback | Accepted | [#39](https://github.com/AimTune/converger/issues/39) / [#131](https://github.com/AimTune/converger/pull/131) |
| [0041](0041-telegram-adapter-chat-scoped-ids-and-stored-media.md) | Telegram adapter: chat-scoped message ids, a configured secret token is always enforced, inbound files stored as uploads, `register_webhook/2` behind an admin button | Accepted | [#38](https://github.com/AimTune/converger/issues/38) / [#132](https://github.com/AimTune/converger/pull/132) |
| [0042](0042-email-adapter-threading-by-message-id-and-provider-webhooks.md) | Email adapter: deterministic `Message-ID` per activity, thread-first conversation resolution (`thread_refs`), provider webhooks with per-provider authentication (SNS signature and topic, Mailgun HMAC, basic auth) | Accepted | [#40](https://github.com/AimTune/converger/issues/40) / [#133](https://github.com/AimTune/converger/pull/133) |
| [0045](0045-sms-adapters-opt-out-flag-and-twilio-signature-urls.md) | SMS adapters (Twilio, Vonage): a participant `opted_out_at` flag the pipeline checks before every delivery, Twilio signatures checked against candidate public URLs, an optional `inbound_response/1` callback (TwiML) | Accepted | [#41](https://github.com/AimTune/converger/issues/41) / [#136](https://github.com/AimTune/converger/pull/136) |
| [0046](0046-conditional-routing-rules-and-reply-back-routing.md) | Conditional routing rules (JSON conditions validated on save, priority with first-match stop, per-rule middleware), reply-back routing by the activity's source channel, conversations spanning channels, and a dry-run on the real planner | Accepted | [#43](https://github.com/AimTune/converger/issues/43) / [#138](https://github.com/AimTune/converger/pull/138) |
| [0047](0047-broker-channels-kafka-and-rabbitmq.md) | Broker channels: `kafka` and `rabbitmq` channel types, one Broadway consumer per channel in the cluster (`:global` plus a reconciling manager), broker-message-id idempotency, per-channel dead-letter topic / queue; the Broadway pipeline transport stays internal | Accepted | [#42](https://github.com/AimTune/converger/issues/42) / [#141](https://github.com/AimTune/converger/pull/141) |
| [0048](0048-additional-adapters-shared-meta-code-bot-framework-jwt-and-pull-outbox.md) | Discord, Teams, Messenger, Instagram, Viber and HTTP pull: shared Meta Graph code, cached Bot Framework JWT validation with a service URL allowlist, users as participants with reply targets in metadata, `inbound_response/2`, a pull outbox acknowledged by served-only watermarks | Accepted | [#44](https://github.com/AimTune/converger/issues/44) / [#139](https://github.com/AimTune/converger/pull/139) |
| [0054](0054-nats-and-redis-streams-channels.md) | NATS JetStream and Redis Streams broker channels on the ADR-0047 machinery: `gnat` and `redix` with small Broadway producers of our own (a durable pull consumer; a consumer group with `XAUTOCLAIM` recovery on start), stream sequence / entry id as the broker message id, per-channel dead-letter subject / stream | Accepted | [#42](https://github.com/AimTune/converger/issues/42) / [#155](https://github.com/AimTune/converger/pull/155) |
| [0053](0053-platform-event-webhooks.md) | Platform event webhooks: tenant subscriptions to a fixed event catalog emitted from the existing broadcast hooks, one `webhook_events` row and Oban job per subscription, outbound signing and SSRF guard, shared retry policy, per-subscription dead letters and redelivery, 7-day log; `alert_webhook_url` becomes a managed subscription | Accepted | [#49](https://github.com/AimTune/converger/issues/49) / [#143](https://github.com/AimTune/converger/pull/143) |
| [0055](0055-mqtt-channel-and-discord-gateway.md) | MQTT channel on an in-house MQTT 3.1.1 client that acknowledges QoS 1 messages after the commit, persistent session per channel, idempotency key from the envelope or a SHA-256 of topic and payload; Discord Gateway inbound as an optional mode run by the broker consumer infrastructure, which gets a per-adapter child spec and a per-channel `consume?/1` | Accepted | [#44](https://github.com/AimTune/converger/issues/44) / [#157](https://github.com/AimTune/converger/pull/157) |

### Clients and SDKs

| ADR | Decision | Status | Issue / PR |
| --- | --- | --- | --- |
| [0052](0052-server-side-sdks-in-the-monorepo-with-a-shared-conformance-suite.md) | Server-side SDKs (Python, Go, Elixir) in `packages/` of this repository, a shared conformance suite (REST, errors, protocol resume state machine, webhook signature vectors generated from the server signer), generator-shaped hand-written models until #45, per-language tag releases | Accepted | [#47](https://github.com/AimTune/converger/issues/47) / [#144](https://github.com/AimTune/converger/pull/144) |
| [0051](0051-typescript-sdk-transport-abstraction-and-outbox.md) | TypeScript SDK `@converger/client`: one session core over native / Phoenix / SSE transports, a persistent clientId outbox resent once after the replay, hand-written types in a generator-compatible shape until #45 | Accepted | [#46](https://github.com/AimTune/converger/issues/46) / [#142](https://github.com/AimTune/converger/pull/142) |

### Security

| ADR | Decision | Status | Issue / PR |
| --- | --- | --- | --- |
| [0009](0009-inbound-signature-scheme-and-per-channel-enforcement.md) | Inbound signature scheme `t=,v1=` and per-channel `require_signature` | Accepted | [#9](https://github.com/AimTune/converger/issues/9) / [#77](https://github.com/AimTune/converger/pull/77) |
| [0011](0011-custom-trusted-proxies-plug.md) | A custom trusted-proxies plug instead of the `remote_ip` library | Accepted | [#11](https://github.com/AimTune/converger/issues/11) / [#75](https://github.com/AimTune/converger/pull/75) |
| [0012](0012-secrets-at-rest-and-audit-redaction.md) | Secrets at rest (Cloak AES-GCM), hashed tenant API keys, recursive audit redaction | Accepted | [#12](https://github.com/AimTune/converger/issues/12) / [#79](https://github.com/AimTune/converger/pull/79) |
| [0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md) | Cluster-wide rate limiting with Hammer 7 ETS and PubSub sync | Accepted | [#13](https://github.com/AimTune/converger/issues/13) / [#83](https://github.com/AimTune/converger/pull/83) |
| [0014](0014-webhook-ssrf-guard-and-outbound-signing.md) | Webhook SSRF guard with DNS pinning and outbound signing | Accepted | [#14](https://github.com/AimTune/converger/issues/14) / [#87](https://github.com/AimTune/converger/pull/87) |
| [0057](0057-client-token-keys-revocation-rotation-and-permissions.md) | Client tokens: dedicated signing keys with `kid`, Postgres revocation list cached in ETS per node and fanned out over PubSub (rejected cluster-wide within 1 s), refresh rotation with a grace period and family-wide reuse detection, `perms` claim (`read`, `write`, `typing`) | Accepted | [#52](https://github.com/AimTune/converger/issues/52) |

### Platform, operations and process

| ADR | Decision | Status | Issue / PR |
| --- | --- | --- | --- |
| [0010](0010-runtime-cors-and-opentelemetry-configuration.md) | CORS origins and OpenTelemetry export configured at runtime | Accepted | [#10](https://github.com/AimTune/converger/issues/10) / [#76](https://github.com/AimTune/converger/pull/76) |
| [0021](0021-ci-quality-gates-and-lf-line-endings.md) | CI quality gates and LF line endings | Accepted | [#54](https://github.com/AimTune/converger/issues/54) / [#92](https://github.com/AimTune/converger/pull/92) |
| [0022](0022-deployment-hardening.md) | Deployment hardening: locked one-shot migrations, runtime ForceSSL/HSTS, fail-fast on leaked secrets | Accepted | [#55](https://github.com/AimTune/converger/issues/55) / [#90](https://github.com/AimTune/converger/pull/90) |
| [0023](0023-platform-and-dependency-baseline.md) | Platform and dependency baseline (OTP 28 / Elixir 1.19, Req 0.7, LoggerJSON, Oban 2.24) | Accepted | [#56](https://github.com/AimTune/converger/issues/56) / [#91](https://github.com/AimTune/converger/pull/91), [#93](https://github.com/AimTune/converger/pull/93), [#104](https://github.com/AimTune/converger/pull/104), [#105](https://github.com/AimTune/converger/pull/105) |
| [0025](0025-docusaurus-site-and-docs-with-every-change.md) | Docusaurus documentation site and documentation with every change | Accepted | [#48](https://github.com/AimTune/converger/issues/48) |
| [0037](0037-libcluster-clustering-health-endpoints-and-metrics-on-the-main-port.md) | libcluster clustering (runtime strategy), `/health/live` and `/health/ready`, metrics on the main port behind a token, two-node `:peer` suite | Accepted | [#29](https://github.com/AimTune/converger/issues/29) / [#129](https://github.com/AimTune/converger/pull/129) |
| [0043](0043-delivery-slo-telemetry-dashboards-and-alert-rules.md) | Delivery SLO telemetry on the adapter call, polled database gauges, and alert rules as tested Prometheus rules | Accepted | [#33](https://github.com/AimTune/converger/issues/33) / [#135](https://github.com/AimTune/converger/pull/135) |
| [0044](0044-bulkheaded-pools-and-graceful-degradation-under-database-pressure.md) | Oban on a second (background) pool of the same repo; retryable 503 / `unavailable` / `replay_unavailable` instead of crashes under database pressure; readiness `degraded` on pool wait | Accepted | [#35](https://github.com/AimTune/converger/issues/35) / [#137](https://github.com/AimTune/converger/pull/137) |
| [0049](0049-k6-load-harness-on-the-release-image-with-seq-based-loss-checks.md) | k6 load harness on the release image (1 or 3 nodes), seq-based lost-message checks, results in `docs/benchmarks/`, nightly 15 % p95 regression gate | Accepted | [#34](https://github.com/AimTune/converger/issues/34) / [#140](https://github.com/AimTune/converger/pull/140) |
| [0050](0050-openapi-spec-error-envelope-and-api-versioning.md) | OpenAPI 3.1 generated from open_api_spex annotations and committed (CI fails on drift), Swagger UI at `/api/docs`, one error envelope `{code, message, details, request_id}` with Protocol v1 codes, URL versioning with `Deprecation` / `Sunset` and a 12-month window | Accepted | [#45](https://github.com/AimTune/converger/issues/45) / [#145](https://github.com/AimTune/converger/pull/145) |
