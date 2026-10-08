---
title: "ADR-0015: Inbound webhook batches are processed per message, idempotently, not all-or-nothing"
sidebar_label: "0015 Idempotent inbound batches"
description: Every message in a provider webhook batch becomes its own activity in its own transaction, keyed by the provider message id, and processing stops at the first transient failure so a re-delivery completes the batch in order.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#15](https://github.com/AimTune/converger/issues/15) |
| **Pull request** | [#82](https://github.com/AimTune/converger/pull/82) |
| **Related** | [ADR-0001](0001-transactional-outbox-with-oban.md), [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0009](0009-inbound-signature-scheme-and-per-channel-enforcement.md), [ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md), [ADR-0016](0016-participant-based-conversation-resolution.md), [ADR-0017](0017-conversation-lifecycle-enforced-under-the-seq-lock.md) |

Messaging providers do not send one message per HTTP request. Meta's WhatsApp Cloud API groups several `entry` / `changes` / `messages` into one webhook call, and Infobip groups inbound messages and delivery reports in `results`. This ADR records how `POST /api/v1/channels/:channel_id/inbound` turns such a batch into activities, what happens when part of the batch fails, and which HTTP status the provider gets back.

## Context and problem statement

Before [#82](https://github.com/AimTune/converger/pull/82), the adapters assumed one message per request:

- `WhatsAppMeta.parse_inbound/2` and `WhatsAppInfobip.parse_inbound/2` matched `[message | _]` / `[result | _]` and returned a **single** parsed message. Every other message in the batch was discarded. `WhatsAppInfobip.parse_status_update/2` had the same pattern for delivery reports. This was **silent message loss**: the provider got a success response, so it never retried.
- `InboundController` assumed exactly one activity per request and ignored messages when the same webhook also carried statuses.
- Non-text message types (image, audio, document, location, contacts, interactive replies, reactions) became activities with empty text.
- A status-only Meta payload (or an `account_update`) got a 400, so Meta kept retrying it for days.
- The Graph API version was pinned to `v18.0`.

Fixing the parsing raised the real design question: once a request can carry N messages, what does the response mean when message 3 of 5 fails?

## Decision drivers

- Zero message loss: every message in a batch must either be stored or cause the provider to retry.
- Provider retries must never create duplicates.
- Per-conversation order (`seq`, [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md)) must follow the provider's order, even across retries.
- A message that can never succeed (for example over the size limits) must not block the rest of the batch forever.
- Providers retry any non-200 response (Meta for days), so the status code is part of the contract.
- Each stored activity must still commit atomically with its delivery jobs ([ADR-0001](0001-transactional-outbox-with-oban.md)).

## Considered options

1. **Per message, idempotent, stop at the first transient failure** - each message in its own transaction with the provider message id as idempotency key; permanent rejections are skipped; a transient failure stops processing and fails the request so the provider re-delivers.
2. **All-or-nothing** - the whole batch in one transaction; any failure rolls everything back and fails the request.
3. **Per message, best effort, always acknowledge** - store what succeeds, log the rest, always return 200.
4. **Accept the raw batch and process it asynchronously** - persist the webhook body, return 200, and expand it in a background job.

### Pros and cons of the options

**Option 1: per message, idempotent, stop at first transient failure**

- Good: no loss: anything not stored causes a retry, and anything stored is recognized as a duplicate on the retry.
- Good: order is preserved because processing stops instead of skipping ahead.
- Good: a poison message (permanently invalid) is acknowledged and does not block the batch.
- Good: each message reuses the normal activity transaction and outbox.
- Bad: a batch may be partially committed when the request fails; correctness relies on idempotency keys.
- Bad: needs a channel-wide lookup by idempotency key (and an index for it).

**Option 2: all-or-nothing**

- Good: simple mental model.
- Bad: one permanently invalid message makes the whole batch fail forever, and the provider retries it for days. Valid messages in that batch are never stored.
- Bad: one long transaction across many conversations holds many conversation row locks at once.

**Option 3: best effort, always 200**

- Good: providers never retry.
- Bad: a transient failure (for example the delivery jobs could not be enqueued) loses that message silently, which is the bug being fixed.

**Option 4: async expansion**

- Good: fastest acknowledgment; isolates provider latency.
- Bad: needs a new durable inbox table and worker; errors are no longer visible to the sender.
- Bad: signature and rate-limit decisions still happen synchronously, so the complexity buys little at current volumes. Could be revisited with the pluggable event backbone.

## Decision

Chosen option: **"Per message, idempotent, stop at the first transient failure"**, because it is the only option that guarantees no loss and no duplicates while letting permanently bad messages through and keeping provider order.

**Adapter contract.** `parse_inbound/2` returns `{:ok, [message]}`, possibly empty. Each message may carry `"idempotency_key"` (the provider message id). `Converger.Channels.Adapter.parse_inbound/2` still wraps an adapter that returns a single map, for compatibility.

**Controller semantics.** For each message, in order:

1. Look up `Activities.get_activity_by_channel_idempotency_key(channel.id, key)`. A hit is a **duplicate**: counted as handled, nothing written. The lookup is channel-wide, because without a `conversation_id` in the request the conversation is not known yet.
2. Otherwise resolve the conversation and create the activity in its own transaction (activity plus delivery jobs).
3. A changeset error is a **permanent rejection**: logged and skipped, the batch continues.
4. Any other error (for example `:delivery_enqueue_failed`) is **transient**: processing stops at that message and the request fails, so the provider re-delivers the whole batch. Messages committed earlier are recognized as duplicates on the retry, and the remaining ones are created in their original order.

Status updates in the same webhook are applied best-effort before the messages. The `(conversation_id, idempotency_key)` unique index remains the final guard: a concurrent insert that loses the race returns the existing activity.

**Response codes.**

| Channel type | Response |
| --- | --- |
| `whatsapp_meta`, `whatsapp_infobip` | **200** whenever the request was handled, including duplicates and permanently rejected messages |
| `webhook` (generic) | **201** when an activity was created, **200** for a pure duplicate, **422** for a single invalid message |
| any | an error status on a transient failure, so the sender retries |

The JSON body is `{status, activity_id, activity_ids, duplicates, rejected, receipts_processed}`; `activity_id` (the first accepted activity) is kept for backward compatibility.

**Adapter mapping.** WhatsApp Meta parses every message in every entry and change and uses the `wamid` as idempotency key. Media types (image, audio, video, document, sticker) become attachment stubs with `contentType`, `provider`, `providerMediaId`, `sha256` and `name`; location and contacts become `application/vnd.converger.location` / `application/vnd.converger.contacts` attachments; interactive and button replies set `text` to the title plus `metadata.interactive_reply`; reactions become `event` activities with `metadata.reaction`; unknown types are kept. Metadata carries `whatsapp_type`, `reply_to` (from `context.id`), `profile_name` and `forwarded`. Infobip uses `messageId` with equivalent mapping and parses every delivery report. The generic webhook accepts an optional `"idempotency_key"` in the body. The Graph API version is configurable per channel (`config["graph_api_version"]`) or globally; the default has since been raised to `v26.0`.

## Consequences

### Positive

- A webhook with 3 messages creates 3 activities; a re-delivery creates none; a partially processed batch is completed by the re-delivery.
- Poison messages no longer cause endless provider retries.
- Status-only payloads are acknowledged with 200, which stops Meta's retry storm.
- Non-text messages are preserved with enough metadata to fetch the media later.

### Negative and trade-offs

- **Response change**: WhatsApp channels get 200 instead of 201 from `/inbound`, and the JSON gained fields.
- Permanently rejected messages are only logged, not stored anywhere for inspection.
- Media is not downloaded; attachments are stubs that reference the provider media id.
- The channel-wide lookup needs the new partial index on `activities(idempotency_key)`. The migration uses a plain `create index`; large tables should build it `CONCURRENTLY`.
- When this landed, two **concurrent** deliveries of the same batch without `conversation_id` could both miss the channel-wide check and land in two new conversations. [ADR-0016](0016-participant-based-conversation-resolution.md) closed that: both resolve the participant's conversation, and the `(conversation_id, idempotency_key)` unique index dedupes them.
- Idempotency keys are only as good as the provider's ids; a generic webhook client that omits `"idempotency_key"` gets no deduplication.

### Follow-ups

- [#37](https://github.com/AimTune/converger/issues/37): WhatsApp media download into Converger storage, templates and interactive messages.
- [#28](https://github.com/AimTune/converger/issues/28): rich activity model (attachment schema, reactions, reply threading) to replace the ad hoc metadata keys.
- [#32](https://github.com/AimTune/converger/issues/32): dead-letter queue with inspection and replay. It targets failed deliveries; extending it to permanently rejected inbound messages would make them inspectable instead of log-only (not part of the issue as written).
- [#24](https://github.com/AimTune/converger/issues/24): the equivalent client-id idempotency for WebSocket sends.

## Implementation

- Controller: [`lib/converger_web/controllers/inbound_controller.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/inbound_controller.ex) (`create/2`, `process_inbound_message/3`, `respond_to_inbound/4`, `@provider_ack_types`).
- Adapter contract: [`lib/converger/channels/adapter.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapter.ex) (`parse_inbound/2` wrapper; optional `parse_status_update/2` dispatched with `apply/3`).
- Adapters: [`lib/converger/channels/adapters/whatsapp_meta.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/whatsapp_meta.ex), [`lib/converger/channels/adapters/whatsapp_infobip.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/whatsapp_infobip.ex), [`lib/converger/channels/adapters/webhook.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/webhook.ex).
- Lookup and duplicate handling: [`lib/converger/activities.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/activities.ex) (`get_activity_by_channel_idempotency_key/2`; `create_client_activity/2` returns the existing activity on an idempotency conflict).
- Migration: [`priv/repo/migrations/20261009150000_add_idempotency_key_index_to_activities.exs`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261009150000_add_idempotency_key_index_to_activities.exs) (partial index `WHERE idempotency_key IS NOT NULL`). The `(conversation_id, idempotency_key)` unique index dates from the core schema.

Example response for a Meta batch where one message was a re-delivery:

```json
{
  "status": "accepted",
  "activity_id": "<uuid>",
  "activity_ids": ["<uuid>", "<uuid>", "<uuid>"],
  "duplicates": 1,
  "rejected": 0,
  "receipts_processed": 2
}
```

Tests: [`test/converger_web/controllers/inbound_batch_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/inbound_batch_test.exs) runs end to end with real Meta signatures and the generic signature for Infobip: a 3-message batch, re-delivery, partial batch completion, the image stub, a permanent rejection acknowledged, an empty webhook acknowledged, mixed messages and statuses, an Infobip batch and re-delivery, the generic webhook idempotency key, and 422 for an invalid generic message. Adapter unit tests in `test/converger/channels/adapters/` cover batch parsing and type mapping.

## Links

- Issue [#15](https://github.com/AimTune/converger/issues/15), pull request [#82](https://github.com/AimTune/converger/pull/82)
- [Inbound requests](../webhooks.md)
