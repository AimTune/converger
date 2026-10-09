---
title: "ADR-0033: The websocket channel is a delivering adapter with pending receipts"
sidebar_label: "0033 WebSocket channel adapter"
description: A websocket channel is delivered to like any other channel, through its adapter, with a delivery row that stays pending until a client is connected, replays or acknowledges, so it can be a routing target and inbound frames take the same path as webhooks.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-10 |
| **Issue** | [#22](https://github.com/AimTune/converger/issues/22) |
| **Pull request** | [#119](https://github.com/AimTune/converger/pull/119) |
| **Related** | [ADR-0001](0001-transactional-outbox-with-oban.md), [ADR-0003](0003-pipeline-is-the-only-delivery-path.md), [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0008](0008-middleware-receives-channel-and-crashes-are-contained.md), [ADR-0020](0020-per-subject-socket-ids-and-presence.md), [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md), [ADR-0026](0026-one-client-socket-stack-and-shape-checked-legacy-tokens.md), [ADR-0032](0032-transient-conversation-signals.md) |

## Context and problem statement

Before this decision the `websocket` adapter was a stub: `supported_modes/0` returned only `outbound`, `deliver_activity/2` did nothing, and the pipeline left `websocket` out of its hardcoded list of delivered types (`@delivery_types ~w(echo webhook whatsapp_meta whatsapp_infobip)`, [ADR-0003](0003-pipeline-is-the-only-delivery-path.md)). WebSocket clients only saw the after-commit PubSub broadcast on `conversation:<id>`. As a result:

- a `websocket` channel could not be the target of a routing rule, so the most common hub use case, WhatsApp to an agent console, was impossible;
- nothing recorded whether any connected client received an activity;
- the Converger client socket could not send at all (clients posted over REST), and nothing applied the channel's mode to messages coming from sockets.

The question is how sockets fit the delivery model that every other channel uses: a delivery row per activity and target channel, created by the pipeline, retried by Oban, with the channel's middleware applied.

## Decision drivers

- One delivery path for every channel type: routing rules, middleware and delivery tracking must work for `websocket` targets exactly as for webhooks ([ADR-0003](0003-pipeline-is-the-only-delivery-path.md)).
- No data loss while a client is offline, without a second message store: activities are already persisted with a gap-free `seq` ([ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md)).
- An offline client is not a failure: it must not burn retries or end up dead-lettered.
- Inbound messages from sockets and from webhooks take the same path and obey the channel's mode.
- One socket must be able to follow a whole channel (agent console) or one conversation (end-user widget).
- Existing clients of `/socket/converger` keep working without changes.

## Considered options

1. **Broadcast-only (status quo)** - keep the PubSub broadcast as the only real-time path; let routing rules target `websocket` channels without delivery rows.
2. **Adapter delivery that fails while no client is connected** - `deliver_activity/2` returns `{:error, :no_clients}` and Oban retries until a client connects.
3. **Adapter delivery with a pending result** - `deliver_activity/2` broadcasts on channel topics and returns `{:pending, meta}` when no client is connected (or acks are required); the delivery stays `pending` without a retry and is marked `sent` when a client replays or acknowledges it.
4. **Per-socket outbox** - store a queue of undelivered activities per socket or per channel and drain it on reconnect.

### Pros and cons of the options

#### Option 1: broadcast-only

- Good, because nothing changes.
- Bad, because there is still no delivery record and no middleware for socket targets; routing rules would have two semantics.

#### Option 2: fail and retry

- Good, because it reuses the existing retry machinery without a new result.
- Bad, because an agent console that is closed overnight exhausts `max_attempts` and dead-letters every message, and the retries rebroadcast to nobody.

#### Option 3: pending result

- Good, because the delivery row answers "did a client get this?", offline buffering is the existing replay from the watermark, and no new storage is needed.
- Good, because retries stay reserved for real failures.
- Bad, because the adapter behaviour gains a result type and a delivery can stay `pending` indefinitely when no client ever comes back.

#### Option 4: per-socket outbox

- Good, because it could deliver to a specific socket.
- Bad, because it duplicates the activity log, needs its own retention and ordering rules, and sockets are anonymous and short-lived.

## Decision

Chosen option: **"Adapter delivery with a pending result"**, because it gives `websocket` channels the same delivery path, middleware and tracking as every other type, while relying on the persisted, `seq`-ordered log for offline catch-up.

- **Adapter.** `Converger.Channels.Adapters.WebSocket` supports `inbound`, `outbound` and `duplex`. `deliver_activity/2` broadcasts the canonical activity, after the channel's middleware, on `channel:<channel id>` and `channel:<channel id>:conversation:<conversation id>`, and counts the connected clients with `ConvergerWeb.Sockets.count_connections/2` (Presence entries of the channel that follow the conversation or the whole channel). It returns `{:ok, %{connected_clients: n}}` when `n > 0`, and `{:pending, %{connected_clients: n}}` when `n == 0` or the channel's config has `require_ack: true`.
- **Pending result.** `{:pending, meta}` is a new result of `c:Converger.Channels.Adapter.deliver_activity/2`. The pipeline records it with `Deliveries.mark_handed_off/2`: the delivery stays `pending`, `attempts` is incremented, the job succeeds and nothing is retried. `Deliveries.acknowledge(channel_id, conversation_id, seq)` marks the channel's handed-off (`attempts > 0`) pending deliveries of the conversation up to `seq` as `sent`. It runs when a client sends `ack {watermark}`, and after a replay on join when the channel does not require acks. Deliveries that have not been handed off yet are left alone, so the pipeline still broadcasts them to the channel's other sockets.
- **Capabilities, not type lists.** Adapters gain an optional `capabilities/0` callback (default `[:inbound, :outbound]`). The pipeline delivers to channels whose adapter has `:outbound`; the `@delivery_types` list is removed. This is the first step of adapter behaviour v2 ([#36](https://github.com/AimTune/converger/issues/36)).
- **Pipeline rules for websocket targets.** Lifecycle events (`conversationUpdate`) are delivered to `websocket` channels as well as webhooks, since they are frames of the protocol ([ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md)). The participant echo rule does not apply to a `websocket` channel: it is a hub of many sockets (the participant's other tabs, an agent console on the same channel), and the sending socket drops its own frame by `seq`.
- **Inbound.** The per-message logic of `ConvergerWeb.InboundController` moves into `Converger.Inbound.receive_message/3`, which checks the channel's mode. Webhooks call it, and so does the Converger socket's `postActivity` event ([ADR-0026](0026-one-client-socket-stack-and-shape-checked-legacy-tokens.md)) when the token's channel is a `websocket` channel: the socket is then that channel's own transport. A token of another channel type is a client of the conversation, like the REST API, and keeps writing directly.
- **Topics and authorization.** `converger:conversation:<id>` accepts a token restricted to the conversation and, with `scope: "channel"` (role `agent`), the conversation's own channel (owned: the after-commit `conversation:<id>` broadcast, as before) and a `websocket` channel that an enabled routing rule targets from the conversation's channel (routed: the channel's deliveries, after its middleware). An unscoped channel-level token still cannot join, as required by the security fix of [#114](https://github.com/AimTune/converger/pull/114). `converger:channel:<id>` follows every delivery to a `websocket` channel and requires a token with `scope: "channel"` ([ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md) decision 12 asks for an explicit claim rather than "a token without a conversation").
- **Ordering per conversation topic.** The channel process tracks the last `seq` it pushed, starting from the conversation head read before subscribing. Frames at or below it are dropped; a frame above `last + 1` first pushes the missing range from the database (with the channel's middleware for routed sockets). This covers lost cross-node broadcasts, concurrent delivery jobs and middleware-halted activities.
- **Existing channels.** Migration `20261010200000_make_websocket_channels_duplex` changes existing `websocket` channels from `outbound`, the only mode they could have, to `duplex`.

## Consequences

### Positive

- WhatsApp to agent console bridging works end to end: inbound WhatsApp messages reach the console in real time with a tracked delivery, and agent replies go back to WhatsApp through the pipeline with the WhatsApp channel's middleware.
- "Was this received by a client?" has an answer in the `deliveries` table, including `connected_clients` in its metadata.
- An offline client costs one delivery row and no retries; it catches up by replay.
- Messages from sockets obey the channel's mode like webhooks do.

### Negative and trade-offs

- Every activity of a conversation on a `websocket` channel in mode `outbound` or `duplex` now creates a delivery row and an Oban job. This is the price of tracking.
- A delivery whose client never returns stays `pending` indefinitely. Dashboards that count `pending` deliveries include them; retention of deliveries is [#30](https://github.com/AimTune/converger/issues/30).
- `connected_clients` is a Presence count: it is eventually consistent across nodes and counts joined channel processes, not end users.
- Owned and routed sockets see different payloads for the same conversation: owned sockets get the activity as committed, routed sockets get it after their channel's middleware.
- Gap detection is per conversation topic. The channel topic pushes frames as they arrive, without de-duplication.

### Follow-ups

- Client-generated ids and server acks for sends: [#24](https://github.com/AimTune/converger/issues/24).
- The native endpoint ([#26](https://github.com/AimTune/converger/issues/26), [ADR-0030](0030-native-websocket-endpoint-and-fallback-transports.md)) is one conversation per connection: it counts as a connected client and its sends go through `Converger.Inbound`, but channel-scoped (agent console) sessions over it are not built yet ([#64](https://github.com/AimTune/converger/issues/64), [#67](https://github.com/AimTune/converger/issues/67)).
- Adapter behaviour v2 (`config_schema/0`, registry, the remaining type lists in health checks and the dashboard): [#36](https://github.com/AimTune/converger/issues/36).
- Watermarks per conversation for channel-scoped sockets (`hello.watermarks`): [#64](https://github.com/AimTune/converger/issues/64), [#67](https://github.com/AimTune/converger/issues/67).

## Implementation

- Adapter: [`lib/converger/channels/adapters/websocket.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/websocket.ex).
- Behaviour (`{:pending, meta}`, `capabilities/0`, `capability?/2`): [`lib/converger/channels/adapter.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapter.ex).
- Pipeline (capability filter, lifecycle and echo rules, pending result): [`lib/converger/pipeline.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline.ex).
- Delivery tracking (`mark_handed_off/2`, `acknowledge/3`): [`lib/converger/deliveries.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/deliveries.ex).
- Inbound context: [`lib/converger/inbound.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/inbound.ex), used by [`ConvergerWeb.InboundController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/inbound_controller.ex).
- Socket (topics, authorization, `postActivity` through `Converger.Inbound`, `ack`, `seq` tracking): [`lib/converger_web/channels/converger_channel.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/converger_channel.ex); connection counting and channel-scoped socket ids: [`lib/converger_web/sockets.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/sockets.ex); `scope` claim: [`lib/converger/auth/converger_token.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/auth/converger_token.ex).
- Routing authorization: `Converger.RoutingRules.routes_to?/3` in [`lib/converger/routing_rules.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/routing_rules.ex).
- Migration: [`priv/repo/migrations/20261010200000_make_websocket_channels_duplex.exs`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261010200000_make_websocket_channels_duplex.exs).

Tests: [`test/converger_web/integration/websocket_channel_adapter_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/integration/websocket_channel_adapter_test.exs) drives a signed WhatsApp webhook into a routed agent console and back to a stubbed Graph API, and covers routed topics with middleware, gap fill and de-duplication, pending deliveries marked `sent` by replay, `require_ack` with `ack`, and authorization of both topics.

## Links

- [WebSocket channel type](../channels/websocket.md)
- [WebSocket API](../websocket.md)
- [Deliveries](../concepts/deliveries.md)
- [Routing rules](../concepts/routing-rules.md)
- [Converger Protocol v1](../protocol/v1.md)
