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

### Channels, middleware and real time

| ADR | Decision | Status | Issue / PR |
| --- | --- | --- | --- |
| [0007](0007-attachment-storage-with-hand-written-signing.md) | Attachment storage with hand-written Req signing, CDN layer and authenticated downloads | Accepted | [#7](https://github.com/AimTune/converger/issues/7) / [#80](https://github.com/AimTune/converger/pull/80) |
| [0008](0008-middleware-receives-channel-and-crashes-are-contained.md) | Middleware receives the channel; middleware crashes are contained | Accepted | [#8](https://github.com/AimTune/converger/issues/8) / [#74](https://github.com/AimTune/converger/pull/74) |
| [0020](0020-per-subject-socket-ids-and-presence.md) | Per-subject socket ids and Presence | Accepted | [#20](https://github.com/AimTune/converger/issues/20) / [#81](https://github.com/AimTune/converger/pull/81) |
| [0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md) | Converger Protocol v1 is a superset profile of mekik/1 | Accepted | [#63](https://github.com/AimTune/converger/issues/63) |
| [0026](0026-one-client-socket-stack-and-shape-checked-legacy-tokens.md) | One client socket stack; the legacy socket and token family are deprecated | Accepted | [#23](https://github.com/AimTune/converger/issues/23) / [#115](https://github.com/AimTune/converger/pull/115) |
| [0027](0027-websocket-limits-backpressure-and-draining.md) | WebSocket limits in the socket transport, mailbox backpressure and readiness-gated draining | Accepted | [#27](https://github.com/AimTune/converger/issues/27) / [#117](https://github.com/AimTune/converger/pull/117) |
| [0030](0030-native-websocket-endpoint-and-fallback-transports.md) | Native v1 WebSocket on WebSock, MessagePack by subprotocol, SSE and long-poll fallbacks | Accepted | [#26](https://github.com/AimTune/converger/issues/26) / [#122](https://github.com/AimTune/converger/pull/122) |
| [0032](0032-transient-conversation-signals.md) | Transient conversation signals: receipts, typing and presence over dedicated topics, stored read watermarks, optional adapter callbacks | Accepted | [#25](https://github.com/AimTune/converger/issues/25) |
| [0033](0033-websocket-channel-adapter-delivery.md) | The `websocket` channel is a delivering adapter with pending receipts | Accepted | [#22](https://github.com/AimTune/converger/issues/22) / [#119](https://github.com/AimTune/converger/pull/119) |
| [0035](0035-native-transports-share-signals-limits-and-draining.md) | Native transports share the signals core, the client WebSocket limits and draining | Accepted | [#26](https://github.com/AimTune/converger/issues/26), [#25](https://github.com/AimTune/converger/issues/25), [#27](https://github.com/AimTune/converger/issues/27) / [#123](https://github.com/AimTune/converger/pull/123) |

### Security

| ADR | Decision | Status | Issue / PR |
| --- | --- | --- | --- |
| [0009](0009-inbound-signature-scheme-and-per-channel-enforcement.md) | Inbound signature scheme `t=,v1=` and per-channel `require_signature` | Accepted | [#9](https://github.com/AimTune/converger/issues/9) / [#77](https://github.com/AimTune/converger/pull/77) |
| [0011](0011-custom-trusted-proxies-plug.md) | A custom trusted-proxies plug instead of the `remote_ip` library | Accepted | [#11](https://github.com/AimTune/converger/issues/11) / [#75](https://github.com/AimTune/converger/pull/75) |
| [0012](0012-secrets-at-rest-and-audit-redaction.md) | Secrets at rest (Cloak AES-GCM), hashed tenant API keys, recursive audit redaction | Accepted | [#12](https://github.com/AimTune/converger/issues/12) / [#79](https://github.com/AimTune/converger/pull/79) |
| [0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md) | Cluster-wide rate limiting with Hammer 7 ETS and PubSub sync | Accepted | [#13](https://github.com/AimTune/converger/issues/13) / [#83](https://github.com/AimTune/converger/pull/83) |
| [0014](0014-webhook-ssrf-guard-and-outbound-signing.md) | Webhook SSRF guard with DNS pinning and outbound signing | Accepted | [#14](https://github.com/AimTune/converger/issues/14) / [#87](https://github.com/AimTune/converger/pull/87) |

### Platform, operations and process

| ADR | Decision | Status | Issue / PR |
| --- | --- | --- | --- |
| [0010](0010-runtime-cors-and-opentelemetry-configuration.md) | CORS origins and OpenTelemetry export configured at runtime | Accepted | [#10](https://github.com/AimTune/converger/issues/10) / [#76](https://github.com/AimTune/converger/pull/76) |
| [0021](0021-ci-quality-gates-and-lf-line-endings.md) | CI quality gates and LF line endings | Accepted | [#54](https://github.com/AimTune/converger/issues/54) / [#92](https://github.com/AimTune/converger/pull/92) |
| [0022](0022-deployment-hardening.md) | Deployment hardening: locked one-shot migrations, runtime ForceSSL/HSTS, fail-fast on leaked secrets | Accepted | [#55](https://github.com/AimTune/converger/issues/55) / [#90](https://github.com/AimTune/converger/pull/90) |
| [0023](0023-platform-and-dependency-baseline.md) | Platform and dependency baseline (OTP 28 / Elixir 1.19, Req 0.7, LoggerJSON, Oban 2.24) | Accepted | [#56](https://github.com/AimTune/converger/issues/56) / [#91](https://github.com/AimTune/converger/pull/91), [#93](https://github.com/AimTune/converger/pull/93), [#104](https://github.com/AimTune/converger/pull/104), [#105](https://github.com/AimTune/converger/pull/105) |
| [0025](0025-docusaurus-site-and-docs-with-every-change.md) | Docusaurus documentation site and documentation with every change | Accepted | [#48](https://github.com/AimTune/converger/issues/48) |
