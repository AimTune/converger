---
title: "ADR-0033: Native transports share the signals core, the client WebSocket limits and draining"
sidebar_label: "0033 Native signals, limits, draining"
description: The native Protocol v1 WebSocket and the SSE stream reuse one extracted module for receipts, typing and presence, apply the SocketGuard limits themselves, and are drained on shutdown through a node-local Registry.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-10 |
| **Issues** | [#26](https://github.com/AimTune/converger/issues/26) (follow-up), [#25](https://github.com/AimTune/converger/issues/25), [#27](https://github.com/AimTune/converger/issues/27) |
| **Pull request** | [#123](https://github.com/AimTune/converger/pull/123) |
| **Related** | [ADR-0030](0030-native-websocket-endpoint-and-fallback-transports.md), [ADR-0032](0032-transient-conversation-signals.md), [ADR-0027](0027-websocket-limits-backpressure-and-draining.md) |

## Context and problem statement

The native Protocol v1 transports (ADR-0030: `/socket/converger/v1` and the SSE stream) and two
features of the Phoenix binding were built in parallel:

- **#25** (ADR-0032) put receipts, typing and presence in `ConvergerWeb.ConvergerChannel`, with the
  participant identity, typing throttling and forwarding, read receipts and the visibility rules as
  private functions of the channel.
- **#27** (ADR-0027) put frame size, message rate, slow-consumer protection and draining in
  `ConvergerWeb.SocketGuard`, which wraps the transport callbacks of the Phoenix sockets, and relied
  on Phoenix's socket drainer, which only knows sockets mounted with the endpoint `socket` macro.

So the native endpoint ignored `typing` and `read`, pushed no receipts or presence, had its own
frame size settings and no rate limit or slow-consumer close, and was cut with close code 1001 when
Bandit stopped, instead of 1012 with a jittered `retryAfterMs`.

## Decision drivers

- One behaviour for every client transport: a participant must not see different receipts, typing
  or presence depending on how the other side connected.
- One set of limits and one set of settings (`config :converger, :websocket`, `WS_*`) for every
  client WebSocket; no second frame size setting.
- Rolling restarts hand native clients over as gently as Phoenix clients.

## Considered options

1. **Copy the #25 and #27 logic into the native transports.**
2. **Extract the #25 logic into a shared module; reuse SocketGuard's checks; drain native
   connections through a Registry** (chosen).
3. **Mount the native endpoint as a `Phoenix.Socket.Transport`** so SocketGuard and the drainer
   apply unchanged.

### Pros and cons of the options

#### Option 1: copy

- Good, because nothing in the Phoenix binding changes.
- Bad, because the two copies would drift; the rules (who sees which receipt, typing throttling,
  forwarding to WhatsApp) are exactly the part that must not differ.

#### Option 2: extract and reuse

- Good, because the channel, the native socket and the SSE stream call the same functions, and the
  channel loses ~170 lines.
- Good, because the limits read the same config and emit the same telemetry
  (`[:converger, :socket, :limit]` with `socket: ConvergerWeb.ProtocolSocket` or the SSE controller).
- Bad, because the native transports must call the checks themselves (they are not Phoenix sockets),
  and draining needs its own registry.

#### Option 3: Phoenix transport

- Good, because the existing wrappers and drainer would apply.
- Bad, because ADR-0030 chose a `WebSock` handler for control over subprotocols, credentials and
  close codes; this would reopen that decision for an operational detail.

## Decision

Chosen option: **"extract and reuse"**:

- `ConvergerWeb.ConversationSignals` holds the #25 logic: `participant/1`, `presence?/1`,
  `subscribe/2`, `frames/4` (which broadcasts a connection sees, tagged reliable or ephemeral),
  `typing/4` and `stop_typing/3`, `read/3`, `track_presence/2` and `presence_snapshot/2`. The
  Phoenix channel, the native socket and the SSE stream all use it; the frames stay
  `ConvergerWeb.ConvergerFrames`.
- The native socket applies `SocketGuard.rate_limited/0`, the shared `max_frame_bytes` and
  `websocket_max_frame_size`, drops typing and presence above `ephemeral_drop_queue_len` and closes
  with 4503 above `slow_consumer_queue_len`, answering with v1 `error` frames where the Phoenix
  sockets answer with error replies. The separate `max_frame_bytes` / `max_frame_hard_bytes` keys of
  `config :converger, ConvergerWeb.Protocol` (unreleased) are removed.
- `ConvergerWeb.ProtocolConnections` is a node-local duplicate-key `Registry` of native connections.
  `ConvergerWeb.Drain.terminate/2`, after the readiness delay, sends them `:socket_drain` in batches
  of `drain_batch_size` every `drain_batch_interval_ms` (at most `drain_shutdown_ms`), before the
  endpoint stops and Phoenix drains its own sockets. A native socket closes with 1012 and
  `{"reason":"unavailable","retryAfterMs":N}`; an SSE stream ends with an `error` frame `unavailable`.
  While draining, new native connections and streams get HTTP 503 with `Retry-After`.

## Consequences

### Positive

- Receipts, typing and presence work identically on every transport, including SSE viewers counted
  as online.
- Operators tune one set of WebSocket limits and see one telemetry event for all client sockets.

### Negative and trade-offs

- Shutdown can take up to one more `drain_shutdown_ms` when a node holds many native connections
  (the `Drain` child's shutdown timeout grows accordingly); the termination grace period guidance in
  docs/operations/websocket-limits.md is updated.
- SSE has no slow-consumer close (an HTTP response has no close code); it only drops ephemeral
  frames, and a stuck client is noticed on the next write.

## Implementation

- `lib/converger_web/conversation_signals.ex`, `lib/converger_web/protocol_connections.ex`;
  `ConvergerWeb.ConvergerChannel`, `ConvergerWeb.ProtocolSocket`,
  `ConvergerWeb.ConvergerAPI.EventStreamController`, `ConvergerWeb.ProtocolSocketController` and
  `ConvergerWeb.Drain` use them; `ConvergerWeb.SocketGuard` exposes `rate_limited/0`,
  `close_detail/2`, `retry_after_ms/0`, `queue_len/1` and `config/1`.
- Tests: the #25 channel tests run unchanged against the extracted module;
  `test/converger_web/protocol_socket_test.exs` (receipts, typing, presence, rate limit, slow
  consumer, ephemeral drop, 503 while draining, 1012 on drain) and
  `test/converger_web/controllers/event_stream_controller_test.exs` (signals, presence, drain).

## Links

- [Protocol v1](../protocol/v1.md), sections 2.1, 2.4, 8, 11, 12.3
- [WebSocket limits and draining](../operations/websocket-limits.md), [Real-time](../architecture/realtime.md)
