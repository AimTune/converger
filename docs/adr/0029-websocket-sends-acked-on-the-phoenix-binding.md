---
title: "ADR-0029: Protocol v1 sends on the Phoenix binding are acked in the channel process, with an in-flight window counted from its mailbox"
sidebar_label: "0029 Sends and acks on the Phoenix binding"
description: A v1 text frame pushed as the Phoenix event frame is stored synchronously by its channel process through the same path as postActivity, answered with an ack or error frame before the sender's own activitySet, and bounded by an in-flight window read from the process mailbox.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-10 |
| **Issue** | [#24](https://github.com/AimTune/converger/issues/24) |
| **Pull request** | to be added when the PR is opened |
| **Related** | [ADR-0015](0015-per-message-idempotent-inbound-batches.md), [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md), [ADR-0026](0026-one-client-socket-stack-and-shape-checked-legacy-tokens.md), [ADR-0027](0027-websocket-limits-backpressure-and-draining.md), [ADR-0030](0030-native-websocket-endpoint-and-fallback-transports.md) |

## Context and problem statement

Converger Protocol v1 ([docs/protocol/v1.md](../protocol/v1.md), section 7) specifies at-least-once sending with exactly-once persistence: a send may carry a `clientId`; the server stores it under `ws:<sender>:<clientId>` and answers `ack {clientId, id, seq, timestamp}` to the sending connection after the commit and before the activity is fanned out; a resent `clientId` gets the original ack with `duplicate: true`; at most `maxInFlight` (32) sends per connection may be unacked, and more draw `too_many_in_flight`.

The native endpoint implements this ([ADR-0030](0030-native-websocket-endpoint-and-fallback-transports.md)). It handles one inbound frame at a time and acks it before reading the next, so at most one send is ever unacked there. The Phoenix binding (`converger:conversation:*`) only had `postActivity` ([ADR-0026](0026-one-client-socket-stack-and-shape-checked-legacy-tokens.md)): the same storage and `clientId` key, but the answer is a Phoenix reply, a duplicate is not reported, and nothing bounds how many sends a client can queue. Issue [#24](https://github.com/AimTune/converger/issues/24) brings section 7 to that binding.

## Decision drivers

- One send path: a `frame` send and a `postActivity` with the same `clientId` must be the same send, and both bindings must share validation, rate limiting and error codes.
- The ack must precede the sender's own `activitySet` of that activity, and a client's sends must be stored in the order it sent them.
- Backpressure must refuse the **newest** sends, so the accepted ones keep their order, and must cost nothing for a client that waits for its acks.
- No new storage: reuse the `(conversation_id, idempotency_key)` unique index.

## Considered options

1. **Synchronous send in the channel process, in-flight window counted from the mailbox**
2. **Asynchronous sends in a per-connection worker with an explicit in-flight counter**
3. **A counter in the socket transport process (`ConvergerWeb.SocketGuard`)**

### Pros and cons of the options

#### Option 1

- Good, because the channel process handles one message at a time: sends commit in arrival order, and the ack is pushed before the process reads the activity's `new_activity` broadcast from its mailbox, with no coordination.
- Good, because the in-flight count is exact without bookkeeping: the unacked sends are the one being processed plus the `frame` sends still in the mailbox.
- Bad, because a slow commit delays live pushes to that one connection while it runs.
- Bad, because counting means reading the mailbox; this is limited to the case where the mailbox already holds `max` messages.

#### Option 2

- Good, because live pushes keep flowing while a send commits.
- Bad, because the committing process broadcasts, so the broadcast can reach the channel before the worker's result and the ack would no longer precede the sender's copy without buffering broadcasts.
- Bad, because concurrent sends of one client could commit out of order unless the worker is serial, which removes the benefit.

#### Option 3

- Good, because the transport sees frames before they are queued and could refuse exactly the newest.
- Bad, because the transport cannot see acks, which are produced by the channel process; it would need a second message per send to decrement, and a channel crash would leave the count wrong.

## Decision

Chosen option: **Option 1**.

- **Event and answer.** On a conversation topic the client pushes the event `frame` with a v1 frame. A `text` frame is a send; the answer (`ack` or `error`, built by `ConvergerWeb.Protocol.Frames`) is pushed as a `frame` event and the Phoenix reply is `ok`, a transport receipt (section 2.2). Other types draw `bad_request` or, for rich message types, `invalid_message` until [#28](https://github.com/AimTune/converger/issues/28). `frame` is refused on channel topics, whose v1 envelope is [#64](https://github.com/AimTune/converger/issues/64).
- **One send path.** Parsing (`clientId`, mekik/1 `id` fallback, `data.text`, attachments, metadata) lives in `ConvergerWeb.Protocol.Send`, used by both the native endpoint and the channel. The channel stores a `frame` send exactly like `postActivity`: `Converger.Inbound` for a `websocket` channel, the tenant's `activity_create` rate limit, the sender from the token's `user_id` (or `"user"`), and the key `Frames.client_key/2` (`ws:<sender>:<clientId>`).
- **Duplicates.** For a `websocket` channel `Inbound` already returns `{:duplicate, activity}`; for other channel types the channel looks the key up before creating, as the native endpoint does. The ack then carries `duplicate: true`, and `postActivity` replies `duplicate: true` as well. A resend is acked even after the conversation was closed, because the original send was accepted.
- **In-flight window** (`ConvergerWeb.Protocol.InFlight`). While the mailbox holds fewer than `max_in_flight` messages, a send is accepted without looking. Otherwise the mailbox is scanned once and a window is fixed: this send and the next `max - 1` queued sends are accepted, the remaining queued sends are refused with `too_many_in_flight` (retryable, same `clientId`). The window is then consumed send by send. `max_in_flight` lives with the other client WebSocket limits (`config :converger, :websocket`, env `WS_MAX_IN_FLIGHT`) and is announced as `welcome.data.limits.maxInFlight`.

## Consequences

### Positive

- Exactly-once persistence with acks on both WebSocket bindings, including for unmodified mekik/1 clients that stamp an `id` on every message.
- `postActivity` and `frame` are interchangeable for retries, so clients can migrate one message at a time.
- No new tables, jobs or processes.

### Negative and trade-offs

- A slow database delays live frames to the sending connection for the duration of a commit.
- Scanning the mailbox copies it; this happens at most once per window and only when the mailbox already holds `max_in_flight` messages.
- A resent `clientId` that races its original on another connection can be acked as a new send (`duplicate` missing) on non-`websocket` channels; it is still stored once. The native endpoint has the same behaviour.

### Follow-ups

- [#22](https://github.com/AimTune/converger/issues/22) follow-up: the `{"protocol": "converger/1"}` join that turns every server frame of the binding into v1 frames, and the echo rule (the sending connection does not get its own turn back).
- [#28](https://github.com/AimTune/converger/issues/28): rich message types.

## Implementation

- [`ConvergerWeb.Protocol.Send`](https://github.com/AimTune/converger/blob/main/lib/converger_web/protocol/send.ex): send parsing shared by both bindings.
- [`ConvergerWeb.Protocol.InFlight`](https://github.com/AimTune/converger/blob/main/lib/converger_web/protocol/in_flight.ex): the window.
- [`ConvergerWeb.ConvergerChannel`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/converger_channel.ex): `handle_in("frame", ...)`, the duplicate lookup, `duplicate` in the `postActivity` reply.
- Tests: `test/converger_web/channels/converger_channel_send_test.exs` (frames validated against the v1 JSON Schemas; dedupe across `frame` and `postActivity`; ack before the sender's `activitySet`; the seq another connection sees; errors; the in-flight window).

## Links

- [Converger Protocol v1](../protocol/v1.md), sections 2.2 and 7
- [WebSocket](../websocket.md), section 6
- [WebSocket limits and draining](../operations/websocket-limits.md)
