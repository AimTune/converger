---
title: "ADR-0053: Platform event webhooks as per-subscription event rows delivered through Oban"
sidebar_label: "0053 Platform event webhooks"
description: Tenant subscriptions to a fixed event catalog; events are emitted from the existing broadcast hooks into one webhook_events row and one Oban job per subscription, signed with the outbound webhook scheme, retried under the shared retry policy, dead-lettered per subscription and pruned after 7 days; the legacy alert_webhook_url becomes a managed subscription.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-12 |
| **Issue** | [#49](https://github.com/AimTune/converger/issues/49) |
| **Pull request** | To be linked when merged |
| **Related** | [ADR-0001](0001-transactional-outbox-with-oban.md), [ADR-0012](0012-secrets-at-rest-and-audit-redaction.md), [ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md), [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md), [ADR-0028](0028-dead-letter-replay-in-place-through-oban.md), [ADR-0031](0031-per-channel-circuit-breaker-rate-limit-and-tier-queues.md), [ADR-0034](0034-monthly-partitioning-and-per-tenant-retention.md) |

## Context and problem statement

Besides channel deliveries, the only outbound notification was `tenants.alert_webhook_url`: health changes
(`Channels.Health.send_alert_webhook/3`) and circuit breaker transitions were POSTed from a fire-and-forget
`Task.start`, unsigned, never retried and invisible once sent. Integrators also need to learn about
`delivery.failed`, `conversation.closed` or `channel.circuit_opened`, and to mirror every `activity.created` into
their own systems, without creating a `webhook` channel per conversation (a channel only receives the activities
routed to it).

Issue [#49](https://github.com/AimTune/converger/issues/49) asks for tenant-level subscriptions to an event
catalog, delivered through Oban with the shared retry policy and the outbound signing scheme of the webhook
adapter ([ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md)), with a per-subscription dead-letter queue,
a redeliver action, a 7-day event log, and `alert_webhook_url` migrated onto it.

## Decision drivers

- An event that was recorded must not be lost: a crashed node, a receiver outage or a deploy must only delay it.
- The receiver must be able to verify origin and freshness with the same code it uses for webhook channels.
- Operators and tenants must see what was sent, what failed and why, and be able to send it again.
- No new infrastructure; no second retry implementation next to `Converger.Pipeline.RetryPolicy`.
- Emitting must not slow down or break the operations that produce events (activity creation, receipts, the
  health worker).
- Existing `alert_webhook_url` receivers must keep working.

## Considered options

1. **One `webhook_events` row and one Oban job per (event, subscription), emitted from the existing broadcast
   hooks** - the event log is the source of truth, the job only carries its id.
2. **Oban jobs only** (the payload in the job args, no event table) - the Oban table is the log.
3. **Telemetry handlers** - attach to `:telemetry` events and emit from there.
4. **A PubSub subscriber process** - listen to the existing `conversation:*` and `channel_health` broadcasts and
   turn them into webhooks.
5. **An external broker** (Kafka, SNS, a hosted webhook service) as the fan-out layer.

### Pros and cons of the options

#### Option 1: event rows plus Oban jobs, emitted from the broadcast hooks

- Good, because the row and its job are inserted in one transaction: a recorded event always has a job, and the
  job survives restarts like every other Oban job ([ADR-0001](0001-transactional-outbox-with-oban.md)).
- Good, because status, attempts, last error and HTTP status live on a row the API and UI can page through, and
  that stays after the job is pruned by `Oban.Plugins.Pruner` (24 h).
- Good, because redelivery is the dead-letter replay pattern of
  [ADR-0028](0028-dead-letter-replay-in-place-through-oban.md): flip the row `failed -> pending` with a conditional
  `UPDATE` and insert a job, in one transaction.
- Good, because the broadcast hooks (`Pipeline.broadcast/1`, `Deliveries` status broadcasts, the conversation
  lifecycle, `Health.broadcast_health_change/3`, the circuit breaker's transition side effects) already run once
  per change, after commit, in every pipeline backend.
- Bad, because an event costs one subscription lookup, and per matching subscription one row and one job.

#### Option 2: Oban jobs only

- Good, because there is nothing new to migrate.
- Bad, because completed jobs are pruned after 24 h and the job table is not a tenant-facing, filterable log; a
  7-day history and a per-subscription DLQ would mean keeping jobs much longer than every other worker.

#### Option 3: telemetry handlers

- Good, because sources would not reference the webhooks module.
- Bad, because handlers run synchronously in the emitting process and are detached on the first crash; telemetry
  events are metrics, emitted for things that are not events (retries, parking) and without the data a payload
  needs. Writing rows from them would turn observability into a delivery path.

#### Option 4: a PubSub subscriber

- Good, because it reuses the broadcasts as they are.
- Bad, because PubSub is at-most-once: a subscriber that is restarting, or a node that dies after the broadcast,
  loses events; in a cluster every node would receive every broadcast, so exactly one node must claim each one.
  Some broadcasts (conversation topics) are per conversation, so a subscriber would have to listen to all of them.

#### Option 5: an external broker

- Good, because fan-out and retries would be someone else's problem.
- Bad, because it adds infrastructure that small deployments do not have, and the signing, SSRF guard and the
  tenant-facing log would still be needed.

## Decision

Chosen option: **"One `webhook_events` row and one Oban job per (event, subscription), emitted from the existing
broadcast hooks"**, because it gives durable, observable, replayable delivery with the outbox and replay patterns the
code base already uses, and no new infrastructure.

**Catalog and sources.** `Converger.Webhooks.Catalog` lists the 12 types; each has a source today, so none is
marked planned:

| Type | Emitted from |
| --- | --- |
| `activity.created` | `Converger.Pipeline.broadcast/1` (after commit, every backend), data = canonical activity |
| `delivery.sent`, `delivery.delivered`, `delivery.read`, `delivery.failed` | the private status broadcast of `Converger.Deliveries` (every status change; `pending` and `paused` are not events) |
| `conversation.created` | `Conversations.insert_conversation/1`, after its transaction |
| `conversation.closed`, `conversation.reopened` | the conversation lifecycle (manual transitions and inactivity expiry) |
| `channel.health_changed` | `Health.broadcast_health_change/3` |
| `channel.circuit_opened`, `channel.circuit_closed` | the breaker's automatic transitions (`Channels.Circuit`), not manual pause/resume |
| `participant.opted_out` | `Participants.set_opted_out/3`, only the transition to opted out |

**Emitting.** `Converger.Webhooks.emit(tenant_id, type, data)` looks up the tenant's enabled subscriptions whose
`events` contain the type or `"*"` (one indexed query), and in one transaction inserts a `webhook_events` row per
subscription (shared `event_id`, the JSON-normalized `data` as `payload`, `status: pending`) and a
`WebhookEventWorker` job per row. It never raises: an error is logged, so a webhook problem cannot fail an activity,
a receipt or the health worker. `config :converger, :platform_webhooks, enabled: false` turns emitting off.

**Request.** `Converger.Webhooks.Sender` POSTs the envelope `{id, type, created_at, tenant_id, data}` with
`x-converger-event`, `x-converger-event-id` (the occurrence), `x-converger-delivery-id` (the row, stable across
retries and redeliveries) and `x-converger-signature: t=<unix>,v1=<hex HMAC-SHA256(secret, "<t>.<body>")>`, the
scheme of [ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md) through
`Channels.InboundSignature.sign/3`. The target goes through `Channels.UrlGuard` at save time and before every
request, the connection is pinned to the checked IP, redirects are not followed, and timeouts and the response size
are bounded. The pinning, bounded body and header rules moved from the webhook adapter into
`Converger.Channels.OutboundRequest`, shared by both.

**Retries and dead letters.** `WebhookEventWorker` (queue `webhooks`) counts attempts on the row and applies the
shared `RetryPolicy.default/0` (`config :converger, :retry_policy`) like channel deliveries
([ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md)): `DeliveryError.from_http/4` classifies
responses, a `Retry-After` wins over the backoff, a permanent error or the last allowed attempt sets `failed` and
cancels the job. Events of a disabled subscription are dead-lettered when their job runs. `Webhooks.redeliver/2`
flips `failed -> pending` with `attempts = 0`, writes an audit entry (`action: "redeliver"`) and inserts a job, in one
transaction.

**Storage and security.** `webhook_subscriptions.secret` (`Encrypted.Binary`) and `headers` (`Encrypted.Map`) are
encrypted at rest like channel secrets ([ADR-0012](0012-secrets-at-rest-and-audit-redaction.md)) and re-encrypted by
`Release.reencrypt_secrets/0`. The API returns the secret only on create and `rotate_secret`, and header names only;
audit entries redact the secret and every header value. The API requires the tenant API key, and the portal lets
owners and admins change subscriptions.

**Retention.** `webhook_events` rows older than `:webhook_event_days` (default 7, `WEBHOOK_EVENT_RETENTION_DAYS`) are
deleted in batches by the daily `PruneWorker` (`Converger.Retention.prune/1`). The table is not partitioned: at a
7-day window, batched deletes are enough.

**Legacy alert URL.** A data migration turns every `tenants.alert_webhook_url` into a subscription with
`managed_by = 'alert_webhook_url'` on `channel.health_changed`, `channel.circuit_opened` and
`channel.circuit_closed`, with a generated secret. `Tenants.create_tenant/2` and `update_tenant/3` keep it in sync
with the column (create, change the URL, delete when cleared). Its requests keep the legacy body, and a breaker
re-opened by a failed probe is skipped for it as before. The fire-and-forget senders in `Health` and `Circuit` are
removed.

## Consequences

### Positive

- `delivery.failed`, conversation, channel and opt-out events reach integrators durably, signed, retried and with a
  visible history; the alert URL gains signing, retries and SSRF re-checks at request time.
- Receivers verify platform events, webhook channel deliveries and Converger-signed inbound requests with one
  snippet.
- A receiver outage only delays events (up to the retry policy), and dead letters can be redelivered from the API,
  the portal or the admin panel.

### Negative and trade-offs

- Every event costs one subscription query, even for tenants without subscriptions; `activity.created` and the
  delivery events are on the hot path. The query is index-backed and selects two columns; a per-node cache was left
  out to avoid cross-node invalidation.
- An event emitted inside a caller's transaction is rolled back with it (correct), but a database error while
  inserting the rows would abort that transaction even though `emit/3` rescues it. Sources emit after commit where
  they can.
- Events can be delivered more than once (a timeout after the receiver processed it) and out of order (parallel
  jobs, retries). Receivers must deduplicate on `x-converger-delivery-id` and order by the timestamps in `data`.
- The managed subscription keeps the legacy body, so it is the one subscription whose payload is not the envelope;
  its secret is generated and only visible through `rotate_secret`.
- The event log stores payloads (activity text, metadata) for 7 days in a table that is not encrypted by the
  application, like activities themselves.

### Follow-ups

- [#45](https://github.com/AimTune/converger/issues/45): the standard error envelope and OpenAPI annotations for the
  new controllers.
- [#47](https://github.com/AimTune/converger/issues/47): SDK helpers to verify platform event signatures.
- [#51](https://github.com/AimTune/converger/issues/51): the management API may expose subscriptions across tenants
  for operators.
- A `participant.opted_in` event and per-subscription retry policies, if integrators ask for them.

## Implementation

- Context and catalog: [`lib/converger/webhooks.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/webhooks.ex),
  [`lib/converger/webhooks/catalog.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/webhooks/catalog.ex),
  schemas `Webhooks.Subscription` and `Webhooks.Event`, request building in
  [`lib/converger/webhooks/sender.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/webhooks/sender.ex).
- Worker: [`lib/converger/workers/webhook_event_worker.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/workers/webhook_event_worker.ex), queue `webhooks` in `config/config.exs`.
- Shared request rules: [`lib/converger/channels/outbound_request.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/outbound_request.ex).
- Sources: `Pipeline.broadcast/1`, `Deliveries` (status broadcast), `Conversations` (`insert_conversation/1`,
  lifecycle), `Channels.Health.broadcast_health_change/3`, `Channels.Circuit` (transition side effects),
  `Participants.set_opted_out/3`.
- Migrations: `20261012300000_create_webhook_subscriptions_and_events` and
  `20261012300100_migrate_alert_webhook_url_to_subscriptions`.
- API: `ConvergerWeb.WebhookSubscriptionController`, `ConvergerWeb.WebhookEventController`; UI:
  `ConvergerWeb.Live.WebhooksPage` behind `/portal/webhooks` and `/admin/webhooks`.
- Retention: `Converger.Retention.prune/1` (`webhook_events`), `WEBHOOK_EVENT_RETENTION_DAYS`.

Tests: `test/converger/webhooks_test.exs` (signed POST on a dead-lettered delivery verified with
`InboundSignature.verify/3`, the documented test vector, matching by tenant, type, `*` and `enabled`, retries until
the shared policy is exhausted, permanent failures, disabled subscriptions, backoff and `Retry-After`, redelivery
and its audit entry, every event source, the managed alert subscription and its legacy body, re-encryption, pruning);
`test/converger_web/controllers/webhook_controller_test.exs` (CRUD, secret only on create and rotation, validation,
catalog, event list filters, redeliver and `409`, tenant isolation); `test/converger_web/live/webhook_live_test.exs`
(create with the one-time secret, recent events and redeliver, member read-only, cross-tenant refusal, admin view).

## Links

- [Platform event webhooks](../platform-webhooks.md)
- [Tenant API: platform event webhooks](../api/tenant-api.md#platform-event-webhooks)
- [Outbound webhooks (channel adapter)](../webhooks.md)
- [Data retention](../operations/retention.md#pruning-other-tables)
