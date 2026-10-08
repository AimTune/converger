---
title: "ADR-0017: Conversation lifecycle enforced under the seq row lock"
sidebar_label: "0017 Conversation lifecycle"
description: Closed conversations reject new activities atomically, in the same UPDATE that allocates the activity seq, and every close or reopen emits a conversationUpdate activity.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#17](https://github.com/AimTune/converger/issues/17) |
| **Pull request** | [#84](https://github.com/AimTune/converger/pull/84) |
| **Related** | [ADR-0001](0001-transactional-outbox-with-oban.md), [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0016](0016-participant-based-conversation-resolution.md), [ADR-0018](0018-keyset-pagination.md), [ADR-0020](0020-per-subject-socket-ids-and-presence.md) |

A conversation has two states, `active` and `closed`. This ADR records where the "closed conversations accept no new activities" rule is enforced, how a close is announced to clients and channels, and how inactive conversations are expired.

## Context and problem statement

`ConversationExpirationWorker` set `status = "closed"` after 24 hours of inactivity, but nothing ever read `status`. The tenant REST API, the Converger client API, the upload endpoint, the WebSocket channels and the inbound webhook all kept accepting activities into closed conversations. A conversation that the platform considered finished could therefore keep growing, keep fanning out deliveries and keep billing provider messages, and the "closed" status was purely cosmetic.

Several secondary gaps came with it:

- There was no public way to close or reopen a conversation.
- Clients and downstream channels were never told that a conversation had closed.
- The expiration query was a `NOT EXISTS` over `activities` with no index on `conversations.status`, so the hourly job scanned the table.

The obvious fix, "load the conversation and check `status` before inserting", has a race: a close can commit between the check and the insert, which lets an activity land after the close event. On a multi-node deployment that race is real, because the close (manual or the expiration worker) and the insert usually run on different nodes.

## Decision drivers

- The rule must hold under concurrency, across nodes, without a distributed lock.
- One enforcement point for every entry path (REST, client API, WebSocket, upload, inbound webhook, internal callers).
- A rejected insert must not consume a `seq` number (the gap-free guarantee from [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md)).
- Clients need an in-band, ordered signal that the conversation closed or reopened.
- The expiration sweep must use an index and must not close a conversation that just received an activity.

## Considered options

1. **Check status in the seq-allocating UPDATE** - add `status = 'active'` to the `UPDATE conversations SET last_seq = last_seq + 1 ... RETURNING` statement that already runs inside the activity transaction.
2. **Check in each controller and channel** - call `Conversations.open?/1` before `create_activity`.
3. **`SELECT ... FOR UPDATE` on the conversation, then check and insert** - explicit pessimistic lock before the status check.
4. **Database trigger** - a `BEFORE INSERT` trigger on `activities` that raises when the parent conversation is closed.

### Pros and cons of the options

**Option 1: status in the seq UPDATE**

- Good: the row lock that serializes `seq` allocation also serializes the status check with a concurrent close. Either the close commits first and the UPDATE matches zero rows, or the insert holds the lock and the close waits for it.
- Good: no extra round trip; the statement already runs on every insert.
- Good: zero rows matched means no increment, so a rejected insert consumes no `seq`.
- Bad: "zero rows" is ambiguous (closed vs. nonexistent conversation) and needs a follow-up `exists?` query on the rejection path only.

**Option 2: check in callers**

- Good: trivial to write.
- Bad: racy (time-of-check to time-of-use), and every new entry path has to remember the check. Rejected as the enforcement mechanism, although `ensure_open/1` is still used as a cheap pre-check before expensive work such as storing an upload.

**Option 3: explicit `FOR UPDATE`**

- Good: correct.
- Bad: an extra statement per insert that duplicates the lock option 1 already takes.

**Option 4: trigger**

- Good: enforced even for raw SQL writers.
- Bad: business rules hidden in the schema, harder to test, errors surface as generic Postgrex exceptions, and lifecycle events (which must be written after the close) would need a bypass in SQL.

## Decision

Chosen option: **"Check status in the seq-allocating UPDATE"** (option 1), because it makes the lifecycle rule exactly as strong as the ordering rule at no extra cost. `Converger.Activities.create_activity/2` already allocates `seq` with an UPDATE that holds the conversation row lock until commit ([ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md)); adding `status == "active"` to its `WHERE` turns the same lock into the close/insert serialization point. The same statement also sets `updated_at`, so `conversations.updated_at` now means "last activity", which is what the expiration sweep needs.

Close and reopen are a conditional `UPDATE ... WHERE status = <from>` (`transition/4`), so they are idempotent: closing a closed conversation returns it unchanged and emits nothing. A successful transition emits a `conversationUpdate` activity with sender `system` and metadata `{"event": "conversation_closed" | "conversation_reopened", "status", "reason"}`. That activity is created with the `allow_closed: true` option, the only bypass of the rule, and because it takes the same lock after the status change it is always the last activity of a closed conversation. It is broadcast to WebSocket clients like any activity and delivered only to `webhook` channels; WhatsApp and echo adapters never receive it (`Pipeline` filters it with `Conversations.lifecycle_event?/1`).

Rejections surface as `{:error, :conversation_closed}`, mapped by `FallbackController` to **409** `{"error": "conversation_closed", "detail": "Conversation is closed"}`; the legacy `ConversationChannel` replies `{:error, %{reason: "conversation_closed"}}`.

Expiration closes `status = 'active' AND updated_at < threshold` in batches of 500. The conditions are repeated on the outer UPDATE so they are re-checked under the row lock: a conversation that received an activity after the batch was selected stays open.

## Consequences

### Positive

- No activity can commit after a close, on any node, and `seq` stays gap-free.
- Every entry path gets the rule without its own check, including future ones.
- Clients see the close in-band and in order, as the final activity in history and streams.
- The expiration sweep is an index range scan on `(status, updated_at)`, verified by an `EXPLAIN` test.

### Negative and trade-offs

- `updated_at` changed meaning: any conversation update, not only activity inserts, now postpones expiration. The deploy migration had to move `updated_at` forward to the latest activity first; otherwise the first sweep would have closed old conversations with recent activity.
- One global inactivity window (`config :converger, :conversation_inactivity_hours`, default 24, or the job arg `"inactivity_hours"`). Per-tenant or per-channel windows would break the single indexed query.
- `tenant.settings.auto_reopen` from the issue was not implemented; tenants have no settings field yet. Posting to a closed conversation always returns 409.
- Lifecycle events reach webhook channels only; providers such as WhatsApp have no equivalent message, so they are never notified.
- The echo adapter treats `:conversation_closed` as "nothing to reply to" so it does not retry forever.

### Follow-ups

- Per-tenant/per-channel inactivity windows and auto-reopen: not yet tracked by a dedicated issue (noted in [#84](https://github.com/AimTune/converger/pull/84)).
- `conversationUpdate` as a first-class Converger Protocol v1 frame: [#21](https://github.com/AimTune/converger/issues/21), [#63](https://github.com/AimTune/converger/issues/63), see [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md).
- Platform event webhooks for conversation events: [#49](https://github.com/AimTune/converger/issues/49).
- Retention and partitioning of closed conversations: [#30](https://github.com/AimTune/converger/issues/30).

## Implementation

- [`Converger.Activities`](https://github.com/AimTune/converger/blob/main/lib/converger/activities.ex): `create_activity/2` with the `:allow_closed` option; `next_seq/2` runs `Repo.update_all` with `inc: [last_seq: 1], set: [updated_at: ...]` and the status condition, then distinguishes closed from missing conversations.
- [`Converger.Conversations`](https://github.com/AimTune/converger/blob/main/lib/converger/conversations.ex): `open?/1`, `ensure_open/1`, `close_conversation/2`, `reopen_conversation/2` (`:reason` option, default `"manual"`), `inactive_conversations_query/1`, `expire_inactive_conversations/1`, `lifecycle_event?/1`, `inactivity_hours/0`.
- [`Converger.Workers.ConversationExpirationWorker`](https://github.com/AimTune/converger/blob/main/lib/converger/workers/conversation_expiration_worker.ex): hourly Oban cron (`"0 * * * *"` in [`config/config.exs`](https://github.com/AimTune/converger/blob/main/config/config.exs)), reason `"expired"`.
- [`Converger.Pipeline`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline.ex): lifecycle events are delivered only to `webhook` channels.
- [`Converger.Participants`](https://github.com/AimTune/converger/blob/main/lib/converger/participants.ex): inbound resolution only reuses `active` conversations ([ADR-0016](0016-participant-based-conversation-resolution.md)).
- [`ConvergerWeb.FallbackController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/fallback_controller.ex) (409), [`ConvergerWeb.ConversationChannel`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/conversation_channel.ex) (error reply), [`UploadController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/converger/upload_controller.ex) (`ensure_open/1` before storing the file).
- Routes in [`router.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/router.ex): `POST /api/v1/conversations/:id/close|reopen` (tenant API key) and `POST /api/v1/converger/conversations/:id/close|reopen` (Converger token). The portal conversation detail has Close/Reopen buttons.
- Migration [`20261009170000_add_conversation_lifecycle_index`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261009170000_add_conversation_lifecycle_index.exs): backfills `updated_at` from the latest activity, then creates the `(status, updated_at)` index. `Conversation.changeset/2` validates `status in ~w(active closed)`.

Tests: [`test/converger/conversation_lifecycle_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/conversation_lifecycle_test.exs) covers reject/accept, events and `seq`, idempotency, the `updated_at` bump and a real-concurrency race (a close plus 30 concurrent inserts: every accepted activity precedes the close event and `seq` is gap-free). [`test/converger_web/controllers/conversation_lifecycle_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/conversation_lifecycle_test.exs) covers the 409s on every HTTP path, tenant isolation, token scoping and delivery filtering. The expiration worker test asserts `conversations_status_updated_at_index` in an `EXPLAIN` with `enable_seqscan = off`.

## Links

- Issue [#17](https://github.com/AimTune/converger/issues/17), pull request [#84](https://github.com/AimTune/converger/pull/84)
- Epic [#57](https://github.com/AimTune/converger/issues/57) (v2.5 production hardening)
- [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md): the seq allocation this rule piggybacks on
