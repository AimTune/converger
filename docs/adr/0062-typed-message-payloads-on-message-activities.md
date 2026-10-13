---
title: "ADR-0062: Typed message payloads stored losslessly on message activities"
sidebar_label: "0062 Typed message payloads"
description: Rich message frames and mekik-native frames are stored as message activities with a message type and the frame body, validated against the Protocol v1 schemas and downgraded to text per channel.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-14 |
| **Issue** | [#68](https://github.com/AimTune/converger/issues/68), [#63](https://github.com/AimTune/converger/issues/63) |
| **Pull request** | (this PR) |
| **Related** | [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md), [ADR-0036](0036-rich-activity-model.md), [ADR-0034](0034-monthly-partitioning-and-per-tenant-retention.md) |

## Context and problem statement

Converger Protocol v1 ([ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md)) carries rich
messages as typed frames: chativa's vocabulary (`buttons`, `card`, `carousel`, `image`, ...) and
mekik/1's agent-runtime frames (`tool_call`, `genui`, `interrupt`, `interrupt_resolved`, `skill`), plus
open renderer-named types. The activity model of [ADR-0036](0036-rich-activity-model.md) only had
`text`, `attachments` and `metadata`. A client that sent a `location` frame got `invalid_message`, and
nothing could persist what a mekik bot emits. #63 also promises that mekik's golden fixture frames
round-trip through Converger's storage byte-identically (canonical JSON), except `seq`.

## Decision drivers

- Lossless: a stored frame must re-serialise to what was received, including fields Converger
  does not know (open types, future mekik fields).
- `activities.type` stays the closed vocabulary of ADR-0036. A new message type must not be a new
  activity type, because every adapter, routing condition and downgrade rule keys on it.
- Channels that cannot render a type still get something sensible, with no change per adapter today.
- No rewrite of the partitioned `activities` table ([ADR-0034](0034-monthly-partitioning-and-per-tenant-retention.md)).

## Considered options

1. **Two nullable columns on `activities`: `message_type` and `payload` (JSONB)**, on `message`
   activities.
2. **One activity type per message type** (`card`, `tool_call`, ... in `activities.type`).
3. **Encode payloads as attachments** (`application/vnd.converger.card+json`), as the interim card mapping
   did.

### Pros and cons of the options

#### Option 1

- Good, because the activity vocabulary, routing and every adapter keep working unchanged, and a
  typed message without a renderer falls back to `text`.
- Good, because the payload is the frame body verbatim, so unknown fields survive.
- Bad, because there is one more place to look for content (`payload` next to `text` and `attachments`).

#### Option 2

- Good, because the type is visible in one column.
- Bad, because the closed vocabulary becomes open (renderer names are client-chosen), and every
  `type` check in adapters, routing and downgrade has to learn each new type.

#### Option 3

- Good, because there is no migration.
- Bad, because attachments are limited to 4 KiB each and 10 per activity, and they are validated
  and normalised (lossy). Frame-level fields (`actions`, a mekik `id`) have nowhere to go.

## Decision

Chosen option: **"Two nullable columns"**, because it keeps the activity model closed and stores the
frame losslessly.

- A persistent frame other than a plain text turn is a `message` activity with `message_type` (the
  frame type) and `payload`. For mekik-native frames the payload is every top-level field except
  `type` and `seq`. For message frames it is everything except `type`, `seq` and the envelope the
  server owns (`from`, `timestamp`, `sender`, `metadata`, `clientId`, `replyTo`, `meta`). A message
  frame's `id` is kept only when a bot names its messages; a client's `id` is its clientId.
- A `text` frame with only `data.text` (and `data.attachments`) keeps the plain columns
  (`message_type` nil), as before.
- Known types are validated against `priv/protocol/v1` on write (`jsv` becomes a runtime dependency).
  Failures are `invalid_message` with per-field details, for example `payload: ["data/buttons/0:
  property 'label' is required"]`. Open renderer-named types only need an object `data`; they are
  counted in `converger.activities.unknown_type.count`.
- `text` is filled from the payload when the sender gave none (`data.text`, caption, title, labels,
  `payload.title` of an interrupt), for search and channel fallbacks. A frame is at most 128 KiB.
- Adapters declare natively rendered types with a `message_types:` capability (a list or `:all`).
  Adapters that list `activity_types` (end-user messaging) default to none. All other adapters
  (WebSocket, webhook, brokers) default to `:all`. A channel without a native renderer gets a plain
  `message` with the text fallback, or nothing when there is none. `tool_call` reaches end-user
  channels only with `show_tool_traces: true`, as a `name: status` line.

## Consequences

### Positive

- Clients can send every type of the vocabulary; bots and agents can store mekik frames. The mekik
  fixture round trip of #63 is tested.
- No existing activity changes shape. REST adds `messageType` and `payload`, both null for plain
  messages.

### Negative and trade-offs

- Until adapters render types natively (the per-channel matrix of messages.md section 5), WhatsApp,
  Telegram, Slack, email and SMS get text only, so buttons arrive without buttons.
- Stored payloads are not re-validated when the schemas change. A schema tightening applies to new
  writes only.
- `tool_call` updates are stored as separate activities (one per status). Clients upsert them by
  `data.id`, as in mekik/1; storage does not merge them.

### Follow-ups

- [#68](https://github.com/AimTune/converger/issues/68): native rendering per adapter, answer
  normalisation (`metadata.action`), interrupt answers as `resume`, portal rendering.
- [#64](https://github.com/AimTune/converger/issues/64): the mekik relay and the channel-scoped socket write
  bot frames through this storage with `keep_id: true`.

## Implementation

- Migration `20261014100000_add_message_type_and_payload_to_activities.exs`: two nullable columns,
  metadata-only on the partitioned table.
- `Converger.Activities.MessagePayload`: frame split, validation, text fallback.
  `Converger.ProtocolSchemas` moved from `test/support` to `lib/` with cached roots and per-field details.
- `Converger.Activities.Activity`: `message_type`, `payload`, `max_payload_bytes`.
- `ConvergerWeb.Protocol.Send` / `Frames`: client sends of rich types on the native endpoint and the
  Phoenix binding, and typed frames rendered back.
- `Converger.Activities.Downgrade`, `Converger.Channels.Adapter.message_types/1`, channel config
  `show_tool_traces`.
- Tests: `test/converger/activities/typed_message_test.exs`,
  `test/protocol/mekik_storage_round_trip_test.exs`, the native socket, Phoenix binding and REST tests.

## Links

- [Rich message vocabulary](../protocol/messages.md), sections 4 and 5
- [Converger Protocol v1](../protocol/v1.md), sections 5 and 14
- [Activities](../concepts/activities.md)
