---
title: "ADR-0032: Transient conversation signals: receipts, typing and presence"
sidebar_label: "0032 Receipts, typing, presence"
description: Delivery and read receipts, typing indicators and presence reach WebSocket clients as transient frames over dedicated PubSub topics; only read watermarks are stored, and external channels get them through optional adapter callbacks.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-09 |
| **Issue** | [#25](https://github.com/AimTune/converger/issues/25) |
| **Pull request** | to be added on merge |
| **Related** | [ADR-0020](0020-per-subject-socket-ids-and-presence.md), [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md), [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md) |

## Context and problem statement

`Converger.Deliveries` already broadcast a `delivery_status` event for every delivery status
change, including WhatsApp "delivered" and "read" receipts, but `ConvergerChannel` dropped it.
End users never saw delivered/read for their WhatsApp-bridged messages, and agent consoles could
not show typing or online state. Protocol v1 ([ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md))
specifies the frames (`deliveryStatus`, `typing`, `presence`, client `typing` and `read`, section 8)
but not how the server produces them. We had to decide what is stored, how the signals fan out
across nodes, who counts as a participant, and how external channels take part.

## Decision drivers

- Receipts and typing must reach the other connections of a conversation quickly (typing from one
  client visible to another within 100 ms locally) and across nodes.
- "Persist first, then push" applies to activities. Typing and presence are ephemeral and must not
  grow the activity log or consume `seq` numbers.
- A read position must survive reconnects and never move backwards, even with several tabs and
  out-of-order frames.
- External channels (WhatsApp) should show typing and blue ticks where the provider supports it,
  without blocking the WebSocket process on a provider call or making every adapter implement it.
- Anonymous widget users must not be announced to others by default.
- The legacy socket is being retired ([#23](https://github.com/AimTune/converger/issues/23)) and must
  not receive new events by accident.

## Considered options

1. **Transient frames over dedicated PubSub topics, stored read watermarks, optional adapter
   callbacks** (chosen).
2. **Typing, read receipts and presence as activities** (as typing is today): stored, numbered and
   replayed like messages.
3. **Everything on the existing `conversation:<id>` topic.**
4. **A participants table per conversation (`conversation_participants.read_seq`)**, as sketched in
   the issue.

### Pros and cons of the options

#### Option 1

- Good, because ephemeral signals cost no writes and no `seq`, and only the read watermark, which
  must survive, is stored.
- Good, because separate topics (`conversation:<id>:signals`, `conversation:<id>:presence`) reach
  only `ConvergerChannel` processes: the legacy channel and the admin LiveView, which are joined
  to `conversation:<id>`, are unaffected.
- Good, because PubSub and Phoenix Presence are already cluster-wide.
- Bad, because a client that was disconnected misses typing and presence changes (acceptable: they
  describe the present, and presence sends a snapshot on join).

#### Option 2

- Good, because replay would include them.
- Bad, because every keystroke burst would be a database write and a `seq`, and replayed typing is
  meaningless; Protocol v1 already moved typing to a transient frame.

#### Option 3

- Good, because no new subscriptions.
- Bad, because the legacy channel forwards every event on that topic to its clients unfiltered, so
  they would receive frames they do not understand, and the admin LiveView would have to ignore them.

#### Option 4

- Good, because it would model membership explicitly.
- Bad, because there is no such table: `participants` are external parties per channel, and
  WebSocket users are identified only by token claims. A `conversation_reads` table keyed by
  `(conversation_id, reader_id)` stores exactly what is needed without inventing membership.

## Decision

Chosen option: **"Option 1"**.

- **Participants.** A connection's participant is derived from its conversation token: id = the
  token's `user_id`, or `"anonymous"`; role `user`. Only conversation tokens can join since
  [#114](https://github.com/AimTune/converger/pull/114); the `agent` role arrives with channel-scoped
  sockets ([#64](https://github.com/AimTune/converger/issues/64)). A connection never receives
  signals of its own participant.
- **deliveryStatus.** The existing `delivery_status` broadcast gains `seq`, `sender`, `attempts`,
  `last_error` and `updated_at`; each `ConvergerChannel` turns it into a `deliveryStatus` frame.
  Identified end users only receive it for activities they sent.
- **read.** `Converger.Receipts.mark_read/3` upserts `conversation_reads` with
  `ON CONFLICT ... DO UPDATE ... WHERE read_seq < new`, so the position is monotonic without a lock,
  and caps it at `conversations.last_seq`. Only a moving position is broadcast as a read receipt.
- **typing.** Relayed with `broadcast_from` on the signals topic, rate-limited in the channel
  process (same state within 2 s dropped), cleared on disconnect, never stored.
- **presence.** A second Phoenix Presence, `ConvergerWeb.ConversationPresence`, keyed by participant
  per conversation, separate from the per-channel `SocketPresence` of
  [ADR-0020](0020-per-subject-socket-ids-and-presence.md). Per-channel config key `presence`:
  `"identified"` (default), `"all"` or `"off"`.
- **External channels.** Optional adapter callbacks `send_typing/2` and `send_read_receipt/2`,
  called by `Converger.Channels.Signals` for the channels an activity would be delivered to, in a
  supervised task, best effort (logged, never retried). WhatsApp Cloud API implements both against
  the participant's latest inbound `wamid`.

## Consequences

### Positive

- The issue's acceptance criteria hold: a WhatsApp "read" DLR reaches the WebSocket client as
  `deliveryStatus`, and typing crosses connections within 100 ms locally (tested).
- No new infrastructure; one small table.
- Adapters opt in; channels without support are skipped silently.

### Negative and trade-offs

- Signals are at-most-once (PubSub across nodes, no replay). Clients expire typing after 6 s and get
  a presence snapshot on join, which bounds the damage.
- Anonymous end users share one participant id per conversation, so their tabs cannot be told apart.
- A WhatsApp typing indicator also marks the participant's latest message as read (Cloud API
  behaviour).
- Typing activities posted over REST are still stored, for existing clients.

### Follow-ups

- [#22](https://github.com/AimTune/converger/issues/22): emit the same frames on the raw v1 socket.
- [#64](https://github.com/AimTune/converger/issues/64) / [#67](https://github.com/AimTune/converger/issues/67): `agent` role for channel-scoped sockets.
- Read receipts and typing for WhatsApp via Infobip, and `away` presence, are not implemented.

## Implementation

- `ConvergerWeb.ConvergerChannel` (client `typing` / `read`, pushes), `ConvergerWeb.ConvergerFrames`
  (frame builders), `ConvergerWeb.ConversationPresence`.
- `Converger.Receipts` and `Converger.Receipts.ReadPosition`, migration
  `20261010100000_create_conversation_reads`.
- `Converger.Channels.Signals`, `Converger.Channels.Adapter` (`send_typing/2`,
  `send_read_receipt/2`), `Converger.Channels.Adapters.WhatsAppMeta`.
- `Converger.TaskSupervisor`; `config :converger, :channel_signals_async` (`false` in tests).
- Tests: `test/converger_web/channels/converger_channel_signals_test.exs` (every frame validated
  against its JSON Schema), `test/converger/receipts_test.exs`,
  `test/converger/channels/signals_test.exs`.

## Links

- [WebSocket](../websocket.md#5a-receipts-typing-and-presence)
- [Real-time](../architecture/realtime.md#receipts-typing-and-presence)
- [Protocol v1](../protocol/v1.md), section 8
- [Writing an adapter](../channels/writing-an-adapter.md)
- [WhatsApp](../channels/whatsapp.md)
