---
title: "ADR-0004: A single canonical activity serializer for every payload"
sidebar_label: "0004 Canonical serializer"
description: Converger.Activities.Serializer.canonical/1 is the one activity representation behind the PubSub broadcast, REST responses, WebSocket frames and outbound webhooks.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#4](https://github.com/AimTune/converger/issues/4) |
| **Pull request** | [#72](https://github.com/AimTune/converger/pull/72) |
| **Related** | [ADR-0003](0003-pipeline-is-the-only-delivery-path.md), [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0007](0007-attachment-storage-with-hand-written-signing.md), [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md) |

An activity leaves Converger in at least five shapes: the PubSub `new_activity` broadcast, the `/api/v1` REST responses, the Converger client API REST responses, the Converger WebSocket `activitySet` frames, and outbound webhook bodies. This ADR records that all of them are derived from one function.

## Context and problem statement

`Converger.Pipeline.broadcast/1` published only `id`, `text`, `sender` and `inserted_at`. The map clause of `ConvergerWeb.ConvergerAPI.ActivityJSON.activity_data/1`, which turned that broadcast into a WebSocket frame, then filled in `attachments: []` and left out `channelData`. The concrete failure:

- An activity created through `POST /api/v1/converger/conversations/:conversation_id/upload` was persisted **with** its attachment, but the real-time `activitySet` frame told every connected client it had **none**. Clients saw the file only after reconnecting and replaying from a watermark, which goes through the REST serializer.
- `type` was always reported as `"message"` in real time, so `event` and `typing` activities were indistinguishable from messages.
- `metadata` (`channelData` on the client API) was missing from real-time frames.

The root cause was structural: each output had its own hand-written field list, and nothing forced them to agree.

## Decision drivers

- REST and WebSocket must return identical activity objects for the same activity.
- New activity fields (for example `seq` from [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md)) must reach every output by changing one place.
- Existing integrations must not break: payload changes must be additive.
- The broadcast payload must be cheap to build (no extra queries in `after_commit/1`).

## Considered options

1. **One canonical map, every output derived from it** - a `Serializer.canonical/1` function; the broadcast carries the canonical map; protocol-specific views (Converger API) are pure functions of it.
2. **Broadcast the activity struct and render per transport** - send `%Activity{}` over PubSub and let each channel render it.
3. **Fix the broadcast field list only** - add the missing fields to `Pipeline.broadcast/1`.
4. **Broadcast only the id and let subscribers re-read** - each channel process loads the activity from the database.

### Pros and cons of the options

#### Option 1: Canonical map

- Good: equality between REST and WebSocket holds by construction, because both go through the same clause.
- Good: one place to add a field; webhooks get it too.
- Good: the map is plain data with atom keys, safe to send across nodes and to `Jason.encode!/1`.
- Bad: the canonical shape becomes a contract; renaming a field there is a breaking change for webhooks and the legacy socket, which receive it unchanged.

#### Option 2: Broadcast the struct

- Good: no intermediate shape.
- Bad: Ecto structs carry `__meta__` and association placeholders across the wire, and each consumer still needs its own rendering, so drift remains possible.

#### Option 3: Patch the field list

- Good: smallest diff.
- Bad: fixes the symptom; the next field added to the schema drifts again.

#### Option 4: Id-only broadcast

- Good: smallest payload, always fresh data.
- Bad: one database read per connected subscriber per activity, which is exactly the fan-out load that PubSub exists to avoid.

## Decision

Chosen option: **"One canonical map, every output derived from it"** (option 1), because it removes the class of bug rather than the instance. Drift between outputs was possible only because there were several field lists; with one function there is nothing to drift.

`Converger.Activities.Serializer.canonical/1` returns `id`, `type`, `sender`, `text`, `attachments` (defaulting to `[]`), `metadata` (defaulting to `%{}`), `idempotency_key`, `seq`, `conversation_id`, `tenant_id` and `inserted_at`. It is used by:

- the PubSub `new_activity` broadcast (`Pipeline.broadcast/1`); legacy `ConversationChannel` clients receive it unchanged, including on `last_activity_id` replay;
- `/api/v1` REST (`ConvergerWeb.ActivityJSON`);
- the Converger client API: `ConvergerWeb.ConvergerAPI.ActivityJSON.activity_data/1` first converts an `%Activity{}` into the canonical map and then goes through the same clause as a broadcast payload, mapping it to the protocol shape (`from.id`, `timestamp`, `conversationId`, `channelData`);
- outbound webhook bodies, which add `timestamp` (equal to `inserted_at`) so existing integrations keep working.

All payload changes were additive; no field was removed or renamed.

## Consequences

### Positive

- Real-time frames for uploads carry the attachment list; `type` and metadata are correct in real time.
- REST `GET .../activities` and WebSocket `activitySet` produce identical activity objects.
- Adding `seq` in [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md) was a one-line change that reached the broadcast, `/api/v1` REST and webhooks at once.
- Webhook payloads gained `idempotency_key` and `inserted_at`, which receivers can use for de-duplication and ordering.

### Negative and trade-offs

- The canonical map is a public contract for webhook receivers and legacy socket clients, so it can only grow. Field renames need a versioning story.
- The Converger client API view intentionally exposes a subset in protocol naming. It does not include `seq`, `idempotency_key` or `tenant_id`; clients resume with an opaque watermark instead (see [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md)).
- `metadata` is passed through verbatim to every consumer, so anything a client stores there is visible to every subscriber of the conversation and every webhook target.

### Follow-ups

- Converger Protocol v1 (spec in progress, [#21](https://github.com/AimTune/converger/issues/21), [#63](https://github.com/AimTune/converger/issues/63)) defines the wire frame envelope; it should be produced from the canonical map, as the current client API view is.
- Rich activity model (typed attachments, reactions, edits, replies): [#28](https://github.com/AimTune/converger/issues/28) and the chativa-compatible vocabulary in [#68](https://github.com/AimTune/converger/issues/68) will extend the canonical map.
- OpenAPI schemas generated from the same shape: [#45](https://github.com/AimTune/converger/issues/45).

## Implementation

- [`Converger.Activities.Serializer`](https://github.com/AimTune/converger/blob/main/lib/converger/activities/serializer.ex): `canonical/1` and `fields/0`.
- [`Converger.Pipeline.broadcast/1`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline.ex): broadcasts `canonical(activity)` on `conversation:` plus the conversation id.
- [`ConvergerWeb.ActivityJSON`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/activity_json.ex) (`/api/v1`).
- [`ConvergerWeb.ConvergerAPI.ActivityJSON`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/converger/activity_json.ex) (Converger client API, struct and map clauses).
- [`ConvergerWeb.ConvergerChannel`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/converger_channel.ex) renders broadcasts and replays with `ActivityJSON.activity_data/1`; [`ConvergerWeb.ConversationChannel`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/conversation_channel.ex) pushes the canonical map on replay.
- [`Converger.Channels.Adapters.Webhook`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/webhook.ex): request body is `canonical(activity)` plus `timestamp`.

Tests: [`test/converger_web/channels/converger_channel_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/channels/converger_channel_test.exs) performs a real multipart upload against a temporary upload directory and asserts the pushed frame contains the attachment, compares REST and WebSocket activities in wire format, and checks the watermark replay shape. [`test/converger_web/channels/conversation_channel_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/channels/conversation_channel_test.exs) asserts that the legacy broadcast equals the canonical map, including `type`, `attachments` and `metadata`.

## Links

- Issue [#4](https://github.com/AimTune/converger/issues/4), pull request [#72](https://github.com/AimTune/converger/pull/72)
- Webhook payload reference: [webhooks](../webhooks.md)
