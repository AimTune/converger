---
title: "ADR-0016: Participant-based conversation resolution for inbound messages"
sidebar_label: "0016 Participants"
description: Inbound messages without a conversation_id join the active conversation of a per-channel participant identified by the provider's external id, resolved under a participant row lock, and replies are routed to that participant.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#16](https://github.com/AimTune/converger/issues/16) |
| **Pull request** | [#88](https://github.com/AimTune/converger/pull/88) |
| **Related** | [ADR-0003](0003-pipeline-is-the-only-delivery-path.md), [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0015](0015-per-message-idempotent-inbound-batches.md), [ADR-0017](0017-conversation-lifecycle-enforced-under-the-seq-lock.md), [ADR-0018](0018-keyset-pagination.md) |

A Converger conversation groups the activities exchanged with one external party. Providers such as WhatsApp identify that party by a phone number and never send a Converger conversation id. This ADR records how inbound messages are attached to the right conversation, how concurrent messages from one sender are kept in one conversation, and how a bot reply finds its way back to the sender without extra metadata.

## Context and problem statement

`InboundController.resolve_or_create_conversation/2` created a **new conversation for every inbound request** that lacked a `conversation_id`. Since WhatsApp and most providers never send one, every message from the same phone number became its own one-message conversation. Transcripts were fragmented, per-conversation ordering ([ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md)) was meaningless across a dialogue, and bots saw each message without context.

Replies had a second problem: the sender's phone number was not stored on the conversation. A bot reply posted with `POST /api/v1/conversations/:id/activities` could only be delivered if the caller repeated `metadata.recipient_phone` (or `to`) on every activity.

Two more defects surfaced while fixing this:

- On a duplex WhatsApp channel, each inbound message also enqueued a delivery **back to the same channel**. It failed on the missing recipient; once the recipient became known, it would have echoed the user's own message back to them.
- The channel-wide idempotency check from [ADR-0015](0015-per-message-idempotent-inbound-batches.md) dedupes sequential re-deliveries, but two **concurrent** deliveries of one batch could each create a fresh conversation and both insert the message.

## Decision drivers

- Messages from one external party on one channel belong to one ongoing conversation.
- Resolution must be race-free across concurrent requests and nodes.
- Replies must be routable from the conversation alone.
- Inbound messages must never be echoed back to their sender.
- The conversation lifecycle (close, expire, reopen; [ADR-0017](0017-conversation-lifecycle-enforced-under-the-seq-lock.md)) must stay in control of when a conversation ends.
- Existing generic-webhook integrations must keep their behavior unless they opt in.

## Considered options

1. **A `participants` table keyed by `(channel_id, external_id)`, with `conversations.participant_id`, resolved in one transaction under the participant row lock** - reuse the participant's most recent active conversation, otherwise create one.
2. **Store the external id directly on the conversation** (`conversations.external_id`) and look up the open conversation by it.
3. **A partial unique index "one active conversation per participant"** to enforce uniqueness in the database.
4. **Keep one conversation per request** and let integrators group messages themselves.

### Pros and cons of the options

**Option 1: participants table, row-lock resolution**

- Good: the participant is a stable entity that can carry a display name and metadata and outlive individual conversations.
- Good: `INSERT ... ON CONFLICT (channel_id, external_id) DO UPDATE` is race-free and, because it updates the row, locks it until commit, so concurrent resolutions for one sender serialize and end up in the same conversation.
- Good: no constraint on how many active conversations a participant may have, so the lifecycle can reopen old conversations freely.
- Good: outbound adapters get the recipient by joining conversation to participant.
- Bad: one more table and a write (the upsert) on every inbound message.
- Bad: correctness of "one open conversation" depends on the lock discipline, not on a constraint.

**Option 2: external id on the conversation**

- Good: no new table.
- Bad: no place for participant attributes; every new conversation copies the identity.
- Bad: no natural row to lock before the conversation exists, so concurrent first messages race to create two conversations.

**Option 3: partial unique index on active conversations**

- Good: the database enforces the invariant.
- Bad: conflicts with reopening a closed conversation while a newer one is active, which the lifecycle work needed to keep possible.
- Bad: turns a concurrent race into a constraint error the controller has to retry.

**Option 4: one conversation per request**

- Good: no change.
- Bad: is the bug.

## Decision

Chosen option: **"A per-channel `participants` table, resolved under the participant row lock"**, because it gives replies a recipient, keeps concurrent messages in one conversation without a database constraint that would fight the conversation lifecycle, and models the external party as an entity the API can expose.

**Data model.** `participants` (`tenant_id`, `channel_id`, `external_id`, `display_name`, `metadata`, timestamps) with a unique index on `(channel_id, external_id)`. `conversations.participant_id` references it with `on_delete: :nilify_all`, indexed with `status` as `(participant_id, status)`. `participant_id` is never cast from input; it is set programmatically. `external_id` and `display_name` are limited to 255 characters.

**Resolution order** in `InboundController` for each message:

1. an explicit `conversation_id` in the request (tenant-scoped);
2. participant resolution, when the parsed message carries `"participant" => %{"external_id", "display_name"}`;
3. a new participant-less conversation (adapters without an external id).

**`Participants.resolve_conversation/2`** runs in one transaction: upsert the participant (keeping the latest non-nil display name), then reuse its most recent conversation on that channel **with status `"active"`**, or create a new one. An optional idle timeout starts a new conversation when the active one has had no activity for longer than `conversation_idle_timeout_seconds` (channel config) or `config :converger, :inbound_conversation_idle_timeout_seconds`. The default is `nil`: the active conversation is reused until the lifecycle closes or expires it. The idle timeout does not close the old conversation.

**Adapters** populate the participant: WhatsApp Meta from `from` plus `contacts[].profile.name`, Infobip from `from` plus `contact.name`. The generic webhook opts in with `"external_id"` / `"display_name"` in the body; without it, behavior is unchanged.

**Outbound.** `WhatsAppMeta` and `WhatsAppInfobip` `deliver_activity/2` use `metadata.recipient_phone`, then `metadata.to`, then `Participants.recipient_for/2`, which returns the participant's `external_id` only if the participant belongs to the delivering channel.

**No echo.** `Pipeline.resolve_delivery_channels/1` drops the participant's own channel when `activity.sender == participant.external_id`.

**API.** `GET /api/v1/conversations` accepts `external_id`, `channel_id` and `status` filters, embeds the participant, and requires the tenant **API key**. A channel token gets 403, because the endpoint exposes other end users' conversations. Conversation JSON includes `participant_id` and `participant` (`id`, `external_id`, `display_name`). The endpoint has since moved to keyset pagination ([ADR-0018](0018-keyset-pagination.md)).

An invalid participant (for example an over-long external id) is a permanent per-message rejection under the batch rules of [ADR-0015](0015-per-message-idempotent-inbound-batches.md).

## Consequences

### Positive

- Two WhatsApp messages from the same number land in the same conversation, with `seq` 1 and 2.
- A bot reply posted to that conversation with no metadata is delivered to the right number.
- Concurrent deliveries of the same batch resolve the same conversation, so the `(conversation_id, idempotency_key)` unique index dedupes them; this closes the gap left by [ADR-0015](0015-per-message-idempotent-inbound-batches.md).
- Inbound messages are no longer delivered back to their sender.
- Integrators can find a user's conversations by phone number.

### Negative and trade-offs

- A participant is **per channel**. The same phone number on two channels is two participants, and a reply routed through a different channel (routing rules) does not use the participant's number; cross-channel sends must pass `recipient_phone` explicitly.
- Echo suppression keys on `activity.sender == participant.external_id`. A REST caller that names the user's phone number as `sender` will not be delivered to WhatsApp, which is intended but can surprise.
- "One open conversation per participant" rests on the `ON CONFLICT DO UPDATE` row lock, not on a constraint. The SQL sandbox serializes connections, so there is no real-concurrency test.
- Remaining race with the lifecycle: the expiry worker can close a conversation between resolution and the activity insert. Since [ADR-0017](0017-conversation-lifecycle-enforced-under-the-seq-lock.md), the insert then fails with `:conversation_closed`, the request returns an error, the provider retries, and the retry resolves a fresh conversation.
- Every inbound message with a participant costs an upsert, and the idle-timeout check adds a `max(inserted_at)` query when enabled.
- Group chats are out of scope: a conversation has at most one participant.

### Follow-ups

- [#43](https://github.com/AimTune/converger/issues/43): conditional routing rules with reply-back routing, which interacts with per-channel participants.
- [#49](https://github.com/AimTune/converger/issues/49): platform event webhooks, whose event catalog includes `participant.opted_out`.
- Group chats (many-to-many between conversations and participants) were named as "later" in the issue and are not tracked separately yet.

## Implementation

- Context: [`lib/converger/participants.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/participants.ex) (`upsert_participant/2`, `resolve_conversation/2`, `idle_timeout_seconds/1`, `recipient_for/2`).
- Schema: [`lib/converger/participants/participant.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/participants/participant.ex); `belongs_to :participant` on [`lib/converger/conversations/conversation.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/conversations/conversation.ex).
- Controller: [`lib/converger_web/controllers/inbound_controller.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/inbound_controller.ex) (`resolve_or_create_conversation/3`).
- Echo suppression: [`lib/converger/pipeline.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline.ex) (`participant_echo_channel_id/2`).
- Outbound recipient: [`lib/converger/channels/adapters/whatsapp_meta.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/whatsapp_meta.ex), [`lib/converger/channels/adapters/whatsapp_infobip.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/whatsapp_infobip.ex). Both accept `config :converger, :whatsapp_req_options` (used for `Req.Test` stubs).
- API: [`lib/converger_web/controllers/conversation_controller.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/conversation_controller.ex) (`index/2`, `require_api_key/1`), [`lib/converger_web/controllers/conversation_json.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/conversation_json.ex); filtering in [`lib/converger/conversations.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/conversations.ex).
- Migration: [`priv/repo/migrations/20261009150100_create_participants.exs`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261009150100_create_participants.exs).

Example lookup:

```bash
curl -H "x-api-key: <tenant api key>" \
  "https://converger.example.com/api/v1/conversations?external_id=15551234567&status=active"
```

Tests: [`test/converger_web/controllers/inbound_participant_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/inbound_participant_test.exs) covers same number into the same conversation, different numbers into different conversations, no echo, a closed conversation not reused, the idle timeout, re-delivery after close creating no duplicate, a bot reply delivered to the participant's number (through a `Req.Test` stub), the conversation lookup (match, tenant scoping, 403 with a channel token, 400 for a malformed `channel_id`), the generic webhook opt-in and the unchanged behavior without it, and `Participants` upsert and resolve unit tests.

## Links

- Issue [#16](https://github.com/AimTune/converger/issues/16), pull request [#88](https://github.com/AimTune/converger/pull/88)
- Builds on [#82](https://github.com/AimTune/converger/pull/82) ([ADR-0015](0015-per-message-idempotent-inbound-batches.md))
