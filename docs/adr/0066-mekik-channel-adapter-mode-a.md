---
title: "ADR-0066: The mekik channel adapter (Mode A)"
sidebar_label: "0066 mekik channel adapter"
description: A mekik channel dials its mekik/1 server with one supervised, globally registered WebSocket per conversation, records the mekik conversation and watermark to resume, stores persistent frames exactly once and relays the rest.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-14 |
| **Issue** | [#64](https://github.com/AimTune/converger/issues/64) |
| **Pull request** | (this PR) |
| **Related** | [ADR-0063](0063-channel-scoped-agent-sockets-and-the-bot-relay.md), [ADR-0062](0062-typed-message-payloads-on-message-activities.md), [ADR-0055](0055-mqtt-channel-and-discord-gateway.md), [ADR-0047](0047-broker-channels-kafka-and-rabbitmq.md), [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md) |

## Context and problem statement

[#64](https://github.com/AimTune/converger/issues/64) connects Converger to
[mekik](https://github.com/AimTune/mekik), the realtime serving layer of ilmek agent graphs, in two
modes. In Mode B mekik dials Converger's channel-scoped socket (ADR-0063); that needs a mekik
transport that does not exist yet. Mode A must work with **today's** mekik servers, unchanged: a
`mekik` channel through which Converger itself dials the server, so a WhatsApp or web-widget
conversation routed to the channel is answered by the graph, an approval `interrupt` renders as
buttons and a tapped button resumes the graph.

mekik/1 is a per-conversation protocol: one WebSocket serves one mekik conversation, the server mints
the `conversationId` on the first connect and adopts an asserted one only when it exists and belongs
to the connecting user, persistent frames carry a per-conversation `seq`, and a reconnect with
`hello.watermark` replays the frames above it. The bot relay of ADR-0063 already broadcasts the end
users' bot-only frames and per-turn `meta` to a conversation's bot channels on PubSub and renders a
turn answering an open interrupt as `resume`; ADR-0062 stores mekik's persistent frames losslessly.

## Decision drivers

- Work with a stock mekik/1 server: speak the client side of mekik/1, nothing more.
- No frame lost or stored twice across disconnects, restarts and node failures.
- One upstream connection per conversation in a cluster; no duplicate turns sent to the graph.
- Reuse the bot relay, the typed payloads and the supervision patterns we already run (the Discord
  Gateway's Mint WebSocket client, the broker consumers' `:global` registration).
- Bounded cost for idle conversations.

## Considered options

1. **One upstream WebSocket per conversation, supervised and globally registered, with the mekik
   conversation and watermark recorded in a table** (chosen).
2. **One multiplexed connection per channel** - mekik/1 has no multiplexing; it would need a mekik
   change (that is Mode B).
3. **Stateless delivery (connect, send, wait for the run to end, disconnect)** - simple, but frames
   produced after the run (a later resume, a long-running tool) and the replay on reconnect would be
   lost, and every turn pays a handshake.
4. **Keep the mekik conversation id in conversation metadata, the watermark derived from stored
   activities** - no new table, but conversation metadata is client-writable (a `PATCH` replaces it)
   and the watermark query scans the transcript.

### Pros and cons of the options

#### Option 1

- Good, because it is exactly a mekik/1 client: welcome, replay above the watermark, resume.
- Good, because `:global` plus a rendezvous-hashed starter keeps one connection per conversation in
  the cluster, as the broker consumers do.
- Bad, because many concurrent conversations hold many sockets (bounded by the idle timeout).

#### Option 2

- Good, because one socket per channel.
- Bad, because a stock mekik server cannot serve it.

#### Option 3

- Good, because there is no long-lived state.
- Bad, because frames outside the request window are lost and every turn pays a handshake.

#### Option 4

- Good, because no migration.
- Bad, because the mapping can be overwritten by a client and the watermark costs a scan.

## Decision

Chosen option: **"One upstream WebSocket per conversation"**.

- **Adapter.** `Converger.Channels.Adapters.Mekik`, type `mekik`, mode `duplex` only (the bot's frames
  are inbound activities of the channel), capabilities `:inbound`, `:outbound`, `:external_delivery`,
  the new `:bot_relay` (which makes the channel a bot channel for ADR-0063) and `message_types: :all`.
  Config `url` (ws/wss, SSRF-checked on save), `token` (secret; `hello.token` and `Authorization:
  Bearer`), `meta`, `bot_id`, `idle_timeout_seconds`.
- **Delivery.** A delivered activity is rendered as the bot sees it (`Frames.activity/3` with an
  `{:agent, bot_id, origin_channel_id}` viewer); only `from: "user"` turns go upstream. A turn
  answering an open interrupt becomes `resume` (`BotRelay.turn_frame/2`); a text turn becomes mekik/1
  `text` with `meta` = the end user's per-turn meta, under the channel's `meta`, under Converger's
  context (`conversationId`, origin `channel`, `participant`); a rich user message becomes a `text`
  turn with the fallback text and the typed message under `data.message`, because mekik/1 accepts no
  other user turn. `deliver_activity/2` returns once the frame is written to the socket; a rejected
  token is a permanent `DeliveryError`.
- **Connections.** `Converger.Channels.Mekik.Connections` (a `DynamicSupervisor`, `:transient`
  children) runs `Converger.Channels.Mekik.Connection`, a Mint WebSocket client, registered as
  `{:global, {Connection, channel_id, conversation_id}}` and in a local `Registry`. Started lazily,
  stopped after `idle_timeout_seconds` without traffic, reconnected with exponential backoff and
  jitter, `auth_retry_ms` after a 4401.
- **Resume.** A new table `mekik_sessions` (channel, conversation, tenant, `mekik_conversation_id`,
  `mekik_user_id`, `watermark`) records the pair from `welcome`; it is asserted in the query string
  and in `hello` on every connect, with the watermark. A different conversation in `welcome` resets
  the watermark to 0. The watermark is written lazily (about once a second and on stop).
- **Exactly-once storage.** Frames at or below the watermark are skipped; each stored frame's
  idempotency key is `bot:<bot_id>:<conversation>:mekik:<mekik conversation>:<seq>`, checked before
  `Inbound.receive_message/3`, so a lagging watermark only replays frames that are recognised. A frame
  that cannot be stored drops the connection, so the server replays it. `text` frames `from: "user"`
  are echoes of turns Converger sent and are skipped.
- **Relay.** `Converger.Channels.Mekik.Relay`, one per node, subscribes to the channel topics of the
  active mekik channels (a scan after boot and every `relay_scan_interval_ms`, plus `watch/1` on
  every delivery, broadcast to all nodes). It forwards `bot_frame`s on the node that runs the
  connection (or starts one on the rendezvous-hashed node) and keeps `turn_meta` in an ETS table for
  the delivery of that turn.

## Consequences

### Positive

- Any mekik/1 server becomes reachable from every Converger channel through a routing rule, with
  interrupts answered by WhatsApp buttons or chativa chips as `resume`.
- Disconnects and restarts lose nothing and duplicate nothing; the server's replay is the recovery.
- The adapter behaviour gained a reusable `:bot_relay` capability.

### Negative and trade-offs

- **Two transcripts and two `seq` spaces** (mekik's and Converger's); Converger uses mekik's `seq`
  only as the upstream watermark. Mode B removes this.
- One socket per active conversation; the idle timeout bounds it.
- The turn lock stays the bot's: a turn during a run draws mekik's `busy`, relayed to the end user,
  while the delivery counts as sent.
- The URL is SSRF-checked on save, not pinned at connect time (like broker hosts).

### Follow-ups

- [#64](https://github.com/AimTune/converger/issues/64) Mode B: `@mekik/converger` (AimTune/mekik#47).
- Native WhatsApp rendering of `interrupt` actions as interactive buttons (messages.md section 5).

## Implementation

- `lib/converger/channels/adapters/mekik.ex`, `lib/converger/channels/mekik/` (`connections.ex`,
  `connection.ex`, `relay.ex`, `sessions.ex`, `session.ex`), children in
  `lib/converger/application.ex`, registry entry and capability docs in
  `lib/converger/channels/adapter.ex`.
- Migration `priv/repo/migrations/20261014220000_create_mekik_sessions.exs`.
- Tests: `test/converger/channels/mekik_integration_test.exs` against a fake mekik/1 server
  (`test/support/mekik/`), `test/converger/channels/adapters/mekik_test.exs`, and
  `test/converger/channels/mekik_live_test.exs` (tag `:mekik`) against a real server
  (`node examples/refund.ts --serve`).

## Links

- [mekik channel](../channels/mekik.md), [channels overview](../channels/overview.md)
- [Protocol v1 section 9](../protocol/v1.md#9-the-bot-channel-and-mekik-relay-implemented-64)
- [mekik/1 PROTOCOL.md](https://github.com/AimTune/mekik/blob/main/PROTOCOL.md)
