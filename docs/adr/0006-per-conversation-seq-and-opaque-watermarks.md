---
title: "ADR-0006: Per-conversation seq under a row lock, and opaque watermarks"
sidebar_label: "0006 Per-conversation seq"
description: Activities are ordered by a gap-free per-conversation seq allocated under the conversation row lock, and the client API resumes from an opaque watermark that encodes it.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#6](https://github.com/AimTune/converger/issues/6) |
| **Pull request** | [#78](https://github.com/AimTune/converger/pull/78) |
| **Related** | [ADR-0001](0001-transactional-outbox-with-oban.md), [ADR-0004](0004-single-canonical-activity-serializer.md), [ADR-0005](0005-separate-client-and-system-changesets.md), [ADR-0017](0017-conversation-lifecycle-enforced-under-the-seq-lock.md), [ADR-0018](0018-keyset-pagination.md), [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md) |

Clients that reconnect resume a conversation "after the last activity I saw". This ADR records how Converger defines activity order inside a conversation, how that order is assigned safely across nodes, and how clients refer to a position in it.

## Context and problem statement

Ordering and resume relied on `(inserted_at, id)`, where `id` is a random UUIDv4:

- Two inserts in the same microsecond, on different nodes, had no deterministic order. The random UUID tiebreaker could make `list_activities_after_watermark/2` **skip or duplicate messages** on resume, depending on where the tie fell relative to the watermark.
- `list_activities_after/2` (legacy `ConversationChannel` replay) compared `inserted_at >` only, so an activity sharing the watermark's timestamp was **lost**.
- `inserted_at` comes from each node's clock, so clock skew between nodes broke ordering entirely: a message written later on a lagging node sorted before earlier ones.
- The watermark was a Base64 activity id, which cost an extra `Repo.get` on every join to turn it into a position.

For a hub whose core promise is zero message loss, "resume after watermark" must return exactly the activities the client has not seen.

## Decision drivers

- Strict, total order per conversation, independent of node clocks.
- Gap-free numbering, so a client can detect a missed activity.
- Correct under concurrent writers on any node, without a global coordinator.
- Resuming must not need a lookup.
- Existing rows and already-issued watermarks must keep working.
- The client-facing position format must be changeable later without breaking clients.

## Considered options

1. **Counter on the conversation row, incremented in the insert transaction** - `UPDATE conversations SET last_seq = last_seq + 1 ... RETURNING last_seq`; the row lock serializes inserts per conversation.
2. **A Postgres sequence (or identity column) for all activities** - one global `bigserial`.
3. **UUIDv7 ids, ordered by id** - time-ordered ids as both key and order.
4. **`MAX(seq) + 1` at insert time with a unique index and retry** - optimistic allocation.

### Pros and cons of the options

#### Option 1: Conversation row counter

- Good: strict and gap-free per conversation. A rolled-back insert (for example an idempotency conflict) rolls the increment back too.
- Good: works across nodes, because the lock is in the database.
- Good: the same statement can check conversation state (later used for lifecycle, [ADR-0017](0017-conversation-lifecycle-enforced-under-the-seq-lock.md)).
- Bad: writes to one conversation are serialized for the rest of the transaction. Converger conversations are human-scale chats, so this is acceptable, but a very hot conversation is bounded by transaction latency.

#### Option 2: Global sequence

- Good: no lock contention.
- Bad: sequences are not transactional, so rolled-back inserts leave gaps, and a gap is indistinguishable from a lost message. Values are also only roughly ordered across concurrent transactions (a later commit can carry a smaller number), which is exactly the skip-on-resume bug.

#### Option 3: UUIDv7

- Good: better index locality as a side benefit.
- Bad: still clock-derived per node, so skew and same-millisecond ties remain. Does not give gap detection.

#### Option 4: `MAX + 1` with retry

- Good: no extra column on conversations.
- Bad: under concurrency it relies on unique-violation retries, which abort the whole Postgres transaction (including the outbox jobs from [ADR-0001](0001-transactional-outbox-with-oban.md)) and need retry loops in application code.

## Decision

Chosen option: **"Counter on the conversation row, incremented in the insert transaction"** (option 1). It is the only option that is strict, gap-free and clock-independent at once, and it reuses the transaction that already persists the activity and its delivery jobs. The serialization cost lands on a single conversation, where concurrent writers are rare.

Details:

- **Schema**: `conversations.last_seq` (`bigint`, default 0) and `activities.seq` (`bigint NOT NULL`), with a unique index on `(conversation_id, seq)`. The index is a safety net; the lock guarantees it is never violated.
- **Allocation**: inside the create transaction, `insert_with_seq/2` validates the changeset first (so invalid input never consumes a number), then runs one `update_all` that increments `last_seq`, bumps `updated_at` and returns the new value. The row lock is held until commit.
- **Queries** order and paginate by `seq`. Positions are `nil` (start), `{:seq, n}` or `{:activity_id, id}`; an activity id is resolved to its `seq` scoped to the conversation, and a malformed or unknown id starts from the beginning instead of crashing.
- **Watermarks are opaque**. `Converger.ConvergerAPI.Watermark.encode/1` produces URL-safe Base64 (no padding) of the string `seq:` followed by the number. `decode/1` returns `{:ok, {:seq, n}}`, `{:ok, nil}` for an empty watermark, `{:ok, {:activity_id, id}}` for a legacy Base64 activity-id watermark (accepted for one release), or `{:error, :invalid_watermark}`. Resuming needs no lookup for new watermarks.
- **Payload**: `seq` is part of the canonical activity ([ADR-0004](0004-single-canonical-activity-serializer.md)), so it is in the PubSub broadcast, `/api/v1` REST and webhook bodies. The Converger client API view does not expose `seq` directly; it returns the opaque `watermark` with each activity set.

Why opaque rather than the bare integer: clients are told to treat the watermark as a token, which leaves the server free to change what it encodes (as it just did, from activity id to `seq`) while still accepting older tokens during a transition.

### Relation to Converger Protocol v1 (issue #63)

Issue [#63](https://github.com/AimTune/converger/issues/63) (open, recorded as [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md)) defines Converger Protocol v1 as a superset of mekik/1, whose persistent frames carry a 1-based, strictly monotonic, gap-free per-conversation `seq`, and whose resume uses that integer as the watermark. The `seq` defined here is exactly that number, so the ordering half of this ADR is what Protocol v1 builds on.

The two differ only in the **encoding** of the client-facing watermark. #63 proposes that, in Protocol v1, the watermark becomes the integer `seq` itself, superseding the opaque Base64 watermark in the Converger API, with old watermarks accepted for one release. When that lands, the opaque-watermark part of this ADR is superseded for Protocol v1 clients; `seq` allocation, ordering and the legacy-watermark transition rule stay. Until then, the current Converger client API and `ConvergerChannel` use the opaque format described above.

## Consequences

### Positive

- Watermark replay returns exactly the activities after the watermark, including same-microsecond inserts and inserts from nodes with skewed clocks.
- Clients can detect gaps, because numbering is contiguous per conversation.
- No `Repo.get` per resume for new watermarks.
- Keyset pagination on `(conversation_id, seq)` became straightforward ([ADR-0018](0018-keyset-pagination.md)).

### Negative and trade-offs

- Inserts into one conversation are serialized for the duration of the create transaction, which also resolves delivery channels and inserts Oban jobs.
- The migration rewrites every `activities` row once to backfill `seq`. On a large table it must run in a quiet window.
- During the transition there are two watermark formats; legacy watermarks still cost a lookup.
- The legacy `ConversationChannel` still resumes by `last_activity_id` (resolved to `seq` internally), not by watermark.

### Follow-ups

- Converger Protocol v1 (spec in progress, [#21](https://github.com/AimTune/converger/issues/21), [#63](https://github.com/AimTune/converger/issues/63)): integer `seq` watermark on the wire.
- `seq` authority when mekik sits behind Converger: [#64](https://github.com/AimTune/converger/issues/64).
- Client-side message ids and acks carrying `seq`: [#24](https://github.com/AimTune/converger/issues/24).
- Partitioning and retention of `activities`, which must preserve per-conversation `seq`: [#30](https://github.com/AimTune/converger/issues/30).
- UUIDv7 ids, listed as optional in #6, were not done.

## Implementation

- Migration [`20261008150000_add_seq_to_activities.exs`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261008150000_add_seq_to_activities.exs): adds the columns, backfills `seq` with `row_number() OVER (PARTITION BY conversation_id ORDER BY inserted_at, id)`, sets `last_seq` to the per-conversation max, then makes `seq` `NOT NULL` and creates the unique index. `backfill_statements/0` is public so it can be tested.
- [`Converger.Activities`](https://github.com/AimTune/converger/blob/main/lib/converger/activities.ex): `insert_with_seq/2` and `next_seq/2` (private), `page_activities_since/3`, `list_activities_after_seq/3`, `list_activities_since/3`, `list_activities_after/3`, and the deprecated `list_activities_after_watermark/2`.
- [`Converger.Activities.Activity`](https://github.com/AimTune/converger/blob/main/lib/converger/activities/activity.ex) and [`Converger.Conversations.Conversation`](https://github.com/AimTune/converger/blob/main/lib/converger/conversations/conversation.ex): `seq` and `last_seq` fields, neither castable.
- [`Converger.ConvergerAPI.Watermark`](https://github.com/AimTune/converger/blob/main/lib/converger/converger_api/watermark.ex).
- Consumers: [`ConvergerWeb.ConvergerAPI.ActivityController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/converger/activity_controller.ex) (`GET .../activities?watermark=`; an invalid watermark starts from the beginning) and [`ConvergerWeb.ConvergerChannel`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/converger_channel.ex) (join with `watermark`; no watermark or an invalid one means no replay).

Tests: [`test/converger/activities_seq_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/activities_seq_test.exs) uses real, non-sandboxed connections to check that N concurrent inserts (N = 1, 7, 25) get `seq` 1..N with no gaps or duplicates; that numbering is per conversation; that a rejected insert does not burn a number; that replay from every possible watermark position returns exactly the following activities, including same-microsecond inserts; legacy and invalid watermarks; and the migration backfill against simulated pre-migration rows.

## Links

- Issue [#6](https://github.com/AimTune/converger/issues/6), pull request [#78](https://github.com/AimTune/converger/pull/78)
- Issue [#63](https://github.com/AimTune/converger/issues/63) (Protocol v1 and mekik/1 compatibility)
