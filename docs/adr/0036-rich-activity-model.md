---
title: "ADR-0036: Rich activity model with a closed type vocabulary, validated attachments and append-only edits"
sidebar_label: "0036 Rich activity model"
description: Activity types are a closed, documented vocabulary; attachments are validated by an embedded schema on write; reactions, edits and deletes are new activities that reference the original through reply_to_id; adapters declare the types they deliver and the rest is downgraded or skipped per channel.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-09 |
| **Issue** | [#28](https://github.com/AimTune/converger/issues/28) |
| **Pull request** | [#125](https://github.com/AimTune/converger/pull/125) |
| **Related** | [ADR-0004](0004-single-canonical-activity-serializer.md), [ADR-0005](0005-separate-client-and-system-changesets.md), [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0007](0007-attachment-storage-with-hand-written-signing.md), [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md), [ADR-0032](0032-transient-conversation-signals.md), [ADR-0033](0033-websocket-channel-adapter-delivery.md), [ADR-0034](0034-monthly-partitioning-and-per-tenant-retention.md) |

## Context and problem statement

Every modern channel emits more than plain messages: WhatsApp sends reactions and replies with a
`context.id`, Slack and Telegram edit and delete messages, and media arrive as provider-specific
objects. Before [#28](https://github.com/AimTune/converger/issues/28), Converger had five activity
types, a WhatsApp reaction arrived as an `event` that pointed at a provider message id nobody could
resolve, and `attachments` was an unvalidated list of maps. Adapters put whatever they had into it
(`providerMediaId` at the top level, no `contentType` at all from some clients), so a WebSocket
client could not rely on any attachment field, and there was no way to say "this message edits,
deletes, reacts to or answers that one".

The model has to stay compatible with what is already stored (activities are immutable and ordered
by `seq`, [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md)), with the client and system
changesets ([ADR-0005](0005-separate-client-and-system-changesets.md)) and with the single
canonical serializer ([ADR-0004](0004-single-canonical-activity-serializer.md)).

## Decision drivers

- A WebSocket or REST client must be able to render any activity from documented fields only.
- No silent loss: an inbound provider event Converger cannot map is kept, not dropped.
- The activity log stays append-only and gap-free; an edit must not rewrite history behind a
  client's watermark.
- Existing rows (attachments without `contentType`, provider keys at the top level) must keep
  loading unchanged; the migration must be online-safe.
- Channels that cannot render a type (WhatsApp cannot show "message edited") must not receive empty
  or broken messages.

## Considered options

1. **Closed vocabulary, embedded-schema validation on write, edits and deletes as new activities
   referencing the original, adapter capabilities with downgrade** (chosen)
2. **Open, renderer-named types** stored opaquely (as sketched in the draft rich message
   vocabulary, [messages.md](../protocol/messages.md)), validated only when the type is known
3. **Edit and delete in place**: `PATCH` / `DELETE` endpoints that rewrite or remove the original row
4. **`embeds_many` attachments** instead of validating a list of maps

### Pros and cons of the options

#### Option 1

- Good, because every consumer can switch exhaustively over nine types, and an unknown type is a
  client error (`422`) instead of something a channel silently fails to deliver.
- Good, because the log stays append-only: a `messageUpdate` gets its own `seq` and reaches every
  client that is behind, through replay, like any other activity.
- Good, because validation only runs on new writes, so stored rows are untouched.
- Bad, because clients must fold updates and deletes into the original themselves.

#### Option 2

- Good, because it matches mekik/1's open renderer-named frames.
- Bad, because adapters, downgrade and storage cannot reason about types they do not know, and the
  issue's acceptance criterion requires unknown types to be rejected.

#### Option 3

- Good, because a single read shows the current state.
- Bad, because it rewrites rows behind clients' watermarks: a client that already received the
  original never learns about the change, and replay is no longer a faithful log.

#### Option 4

- Good, because Ecto validates and types every field on load.
- Bad, because loading drops unknown keys and so loses data in rows written before the schema; it
  also changes the column semantics for every existing reader.

## Decision

Chosen option: **"Option 1"**.

- **Vocabulary.** `Activity.types/0` is `message`, `event`, `typing`, `messageReaction`,
  `messageUpdate`, `messageDelete`, `conversationUpdate`, `endOfConversation` and the internal
  `deliveryReceipt`. Internal types are accepted only with `create_activity(attrs, internal: true)`;
  the client changeset rejects them. Any other type is a `422`.
- **Attachments.** `Converger.Activities.ActivityAttachment` is an embedded schema used to validate
  and normalise each attachment on write: `contentType` (a MIME type) is required, `contentUrl` and
  `thumbnailUrl` must be `http(s)` URLs or server paths, `size` is a non-negative integer,
  `application/vnd.converger.card.*` requires an object `content`, provider fields go in
  `channelData`, other keys are dropped. The column stays a list of maps, so old rows load as they
  are.
- **References.** A new nullable `activities.reply_to_id` names the activity an activity refers to,
  in the same conversation. It has **no foreign key**: `activities` is partitioned by month
  ([ADR-0034](0034-monthly-partitioning-and-per-tenant-retention.md)), its primary key is
  `(id, inserted_at)` so `reply_to_id` alone cannot reference it, and retention drops whole months.
  The same-conversation rule is enforced by `create_activity/2` under the conversation row lock, and
  readers must tolerate a dangling `reply_to_id` (the original was removed by retention or a purge).
  The reference is
  optional for `message` (a threaded reply), required for `messageReaction`, `messageUpdate` and
  `messageDelete`, whose target must be a `message`. Updates and deletes must come from the
  original's sender and cannot target a deleted message.
- **Edits and deletes are new activities.** Accepting a `messageUpdate` or `messageDelete` stamps
  `edited_at` or `deleted_at` on the original in the same transaction, under the conversation row
  lock that allocates the `seq`, so concurrent deletes are serialised. The original's content is not
  rewritten; SDKs apply the change.
- **Inbound.** Adapters name a referenced provider message as `"reply_to_provider_id"`. The inbound
  controller resolves it to an activity of the same conversation (an inbound message by idempotency
  key, an outbound one by its delivery's provider message id). An unresolvable reaction, edit or
  delete is stored as an `event` with its metadata, never dropped.
- **Capabilities and downgrade.** Adapters may add an `activity_types: [...]` entry to the
  `capabilities/0` list that #22 introduced for `:outbound` ([ADR-0033](0033-websocket-channel-adapter-delivery.md));
  without it every client type is delivered as before. For types the
  adapter does not list, the channel config key `unsupported_activities` decides: `downgrade`
  (default) delivers a `message` with a text rendering (`"user reacted with 👍"`), or skips types with
  nothing to say (typing, a removed reaction); `skip` does not deliver. `deliveryReceipt` is never
  delivered to channels. WebSocket clients always receive every type.

## Consequences

### Positive

- A WhatsApp reaction is a `messageReaction` whose `replyToId` is the reacted-to activity, whether
  the user reacted to their own message or to a bot reply.
- Clients get one documented attachment shape, published as a JSON Schema
  (`priv/protocol/v1/activity.schema.json`) and tested against the server's own validation.
- WhatsApp channels no longer receive empty messages for `typing` or text-less `event` activities.

### Negative and trade-offs

- The original row of an edited or deleted message keeps its content until retention drops its month
  ([ADR-0034](0034-monthly-partitioning-and-per-tenant-retention.md)); redacting a single deleted
  message earlier needs a separate mechanism.
- Without a foreign key, `reply_to_id` can dangle: retention drops the month holding an original while
  a later reply, reaction or edit referring to it lives on in a newer month. Clients render such a
  reference as "original unavailable"; a new activity cannot reference an activity that is gone (it
  gets `422`, "does not exist in this conversation").
- A REST reader that only fetches one page sees `editedAt` on the original but has to page on to
  find the `messageUpdate` itself.
- Attachments written before the schema are returned as stored and may lack `contentType`; the JSON
  Schema therefore types returned attachments loosely and the write shape strictly.
- The draft rich message vocabulary ([messages.md](../protocol/messages.md), #68) describes open
  renderer-named types; at the storage and REST level those become a closed type plus typed
  payloads (cards as `application/vnd.converger.card.*` attachments), and the frame-level mapping is
  left to #22 and #68.

### Follow-ups

- [#36](https://github.com/AimTune/converger/issues/36): adapter behaviour v2 extends `capabilities/0`.
- [#37](https://github.com/AimTune/converger/issues/37): native outbound WhatsApp reactions, media and
  interactive messages, which move those types from "downgrade" to "native".
- [#68](https://github.com/AimTune/converger/issues/68): rich message vocabulary and frame mapping.
- `deliveryReceipt` is reserved vocabulary: [#25](https://github.com/AimTune/converger/issues/25)
  made receipts and typing transient signals ([ADR-0032](0032-transient-conversation-signals.md)), so
  nothing emits it today. A future server-side use creates it with `internal: true`. Likewise the
  `typing` activity type stays only for clients that still store typing over REST; it is never
  delivered to messaging adapters, which get typing through `send_typing/2`.

## Implementation

- `Converger.Activities.Activity` (types, `reply_to_id`, `edited_at`, `deleted_at`, per-type rules),
  `Converger.Activities.ActivityAttachment`, `Converger.Activities.Downgrade`.
- `Converger.Activities.create_activity/2` checks references and stamps the original;
  `get_activity_by_provider_message_id/2` resolves provider ids.
- `Converger.Channels.Adapter.activity_types/1` and an `activity_types:` entry in the
  `capabilities/0` of the WhatsApp and echo adapters;
  `Converger.Pipeline` filters skipped channels and applies the downgrade at delivery time.
- Migration `20261010400000_add_reply_and_edit_columns_to_activities` (nullable columns on the
  partitioned table, no foreign key; the partial index on `reply_to_id` is created `ON ONLY` the parent,
  built `CONCURRENTLY` on every partition and attached; later partitions get it on attach). Stamping
  `edited_at` / `deleted_at` updates the original by `(id, inserted_at)`, so only its partition is
  touched.
- Tests: `test/converger/activities/rich_activity_test.exs`,
  `test/converger_web/controllers/rich_activity_api_test.exs`.

## Links

- [Activities](../concepts/activities.md)
- [Client API](../api/client-api.md)
- [Channels overview](../channels/overview.md), [WhatsApp](../channels/whatsapp.md),
  [Writing an adapter](../channels/writing-an-adapter.md)
- [Rich message vocabulary](../protocol/messages.md)
