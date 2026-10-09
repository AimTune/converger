---
title: "ADR-0030: Native v1 WebSocket on WebSock, MessagePack by subprotocol, SSE and long-poll fallbacks"
sidebar_label: "0030 Native WebSocket and fallbacks"
description: Protocol v1 gets a raw WebSocket endpoint implemented directly on WebSock, encodings negotiated by subprotocol, and Server-Sent Events plus Phoenix long-polling for networks that block WebSockets, all sharing one frame and ordering core.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-09 |
| **Issue** | [#26](https://github.com/AimTune/converger/issues/26) |
| **Pull request** | [#122](https://github.com/AimTune/converger/pull/122) |
| **Related** | [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md), [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0020](0020-per-subject-socket-ids-and-presence.md), [ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md), [ADR-0026](0026-one-client-socket-stack-and-shape-checked-legacy-tokens.md), [ADR-0027](0027-websocket-limits-backpressure-and-draining.md), [ADR-0032](0032-transient-conversation-signals.md) |

## Context and problem statement

The only WebSocket entry points used Phoenix Channels framing
(`[join_ref, ref, topic, event, payload]`). A client in Go, Python, Rust, embedded C or a browser
without the `phoenix` package had to reimplement that framing, which is not documented outside
Phoenix. mekik/1 clients (ADR-0024) speak raw frames and could not connect at all. Some corporate
proxies block WebSockets, and both sockets had `longpoll: false`, so those users had no way in.

Protocol v1 (docs/protocol/v1.md, section 2.1) already specified the native endpoint
(`/socket/converger/v1`, subprotocol `converger.v1`, close codes, heartbeat and idle timeout). #26
asked for it, plus an optional binary encoding and fallbacks.

## Decision drivers

- Speak v1 frames byte-for-byte as the spec and its JSON Schemas define them, so mekik/1 clients
  and the conformance suite work unchanged.
- One implementation of ordering (replay, de-duplication, gap fill, echo rule) for every
  transport, so they cannot drift.
- No new infrastructure; the Bandit/WebSock stack Phoenix already runs on.
- Fallbacks must keep the zero-loss guarantee: resumable from a watermark.

## Considered options

1. **A `Phoenix.Socket.Transport` behind the endpoint `socket` macro.**
2. **A `WebSock` handler upgraded from a router route** (chosen).
3. **Phoenix Channels with a custom serializer** that strips the framing.

### Pros and cons of the options

#### Option 1: `Phoenix.Socket.Transport`

- Good, because Phoenix handles the upgrade, `check_origin` and subprotocol checks.
- Bad, because the transport always rejects a request that offers no supported subprotocol in the
  way Phoenix chooses, the mount path gets a `/websocket` suffix unless overridden, and the
  credential handling is shaped around connect params. The spec needs exact control of all three.

#### Option 2: `WebSock` handler from a route

- Good, because the controller decides everything the spec defines: subprotocol selection (first
  supported offer, none means JSON, only unsupported means HTTP 400), credential sources (header,
  query, `hello.token`), frame size caps, and close codes from the handler.
- Good, because the handler is a plain process with pure callbacks, easy to test over a real
  socket.
- Bad, because origin checking is not automatic. Acceptable: authentication is a bearer token,
  never a cookie, so cross-site WebSocket hijacking has nothing to ride on.

#### Option 3: Phoenix Channels with a custom serializer

- Good, because it reuses channel processes and PubSub plumbing.
- Bad, because topics, joins and replies are still the model underneath; the v1 handshake, acks and
  close codes would be emulated on top of it.

## Decision

Chosen option: **"WebSock handler from a route"**:

- `GET /socket/converger/v1` (`ConvergerWeb.ProtocolSocketController`) upgrades to
  `ConvergerWeb.ProtocolSocket`, one process per connection and conversation. The issue's working
  name `/ws/v1` was replaced by the path the spec already fixed.
- **Encodings by subprotocol** (`ConvergerWeb.Protocol.Codec`): `converger.v1` (JSON, as the spec
  says), `converger.v1+json` (explicit alias) and `converger.v1+msgpack` (MessagePack in binary
  messages). The frame maps are identical for both encodings; MessagePack is a re-encoding, not a
  second schema.
- **One core for every transport**: `ConvergerWeb.Protocol.Frames` maps canonical activities
  (`Converger.Activities.Serializer`, ADR-0004) to v1 frames, and `ConvergerWeb.Protocol.Feed` owns
  replay (batches, `replayMax`, `replayTruncated`), de-duplication by `seq`, gap filling from the
  database and the echo rule. Subscribing to the conversation topic before reading the head and
  the replay makes the mailbox the hold-back buffer.
- **Fallbacks**: Server-Sent Events at `GET /api/v1/converger/conversations/:id/events` deliver the
  same v1 frames with `seq` as the SSE `id`, so a reconnecting `EventSource` resumes through
  `Last-Event-ID`; sending stays on REST. Phoenix long-polling is enabled on `/socket/converger` as
  the last resort for the Phoenix binding.
- Sends on the native socket store the `clientId` as the idempotency key `ws:<sender>:<clientId>`,
  the scheme the Phoenix binding's `postActivity` uses (ADR-0026), under the existing unique index
  (spec section 7). The native socket therefore gives exactly-once persistence and acks, and a
  resend over either WebSocket binding is recognised.

## Consequences

### Positive

- Any language with a WebSocket library can use Converger with no Phoenix knowledge; mekik/1
  clients connect unmodified (no subprotocol means mekik semantics).
- Every server frame is validated against the protocol schemas in the test suite, over real
  connections.
- Networks without WebSockets keep a resumable path (SSE) with the same frames.

### Negative and trade-offs

- `msgpax` becomes a runtime dependency; `mint_web_socket` a test-only one.
- The native socket processes sends one at a time, so `maxInFlight` is announced but never reached.
- An SSE stream notices a vanished client only on its next write, at most one heartbeat interval
  later.
- Phoenix long-polling serves the pre-v1 Phoenix binding, not v1 frames.

### Follow-ups

- [#22](https://github.com/AimTune/converger/issues/22): v1 framing on the Phoenix binding can reuse `Frames` and `Feed`.
- Transient signals ([ADR-0032](0032-transient-conversation-signals.md), #25) on the native endpoint: `typing`, `read`, `deliveryStatus` and `presence` are pushed on the Phoenix binding only; the native endpoint accepts and ignores client `typing`/`read` for now.
- Per-connection limits and draining ([ADR-0027](0027-websocket-limits-backpressure-and-draining.md), #27) on the native endpoint: it enforces its own frame size caps and idle timeout, but not yet the per-connection message rate, slow-consumer close (4503) or readiness-gated draining (1012).
- [#28](https://github.com/AimTune/converger/issues/28): rich message types (answered with `invalid_message` until then).
- [#64](https://github.com/AimTune/converger/issues/64): channel-scoped sockets and the bot relay (`bot_unavailable` until then).

## Implementation

- `lib/converger_web/protocol.ex` (settings, watermark parsing), `lib/converger_web/protocol/`
  (`Codec`, `Frames`, `Feed`), `lib/converger_web/protocol_socket.ex`,
  `lib/converger_web/controllers/protocol_socket_controller.ex`,
  `lib/converger_web/controllers/converger/event_stream_controller.ex`.
- Config: `config :converger, ConvergerWeb.Protocol` (heartbeat, idle timeout, frame caps,
  `replay_max`).
- Tests: `test/converger_web/protocol_socket_test.exs` and
  `test/converger_web/controllers/event_stream_controller_test.exs` run against a real Bandit
  listener (`ConvergerWeb.ProtocolClient`); `test/converger_web/protocol/feed_test.exs` covers gap
  fill, truncation and the echo rule.

## Links

- [Converger Protocol v1](../protocol/v1.md), sections 2.1, 6, 7, 8.5, 12
- [WebSocket](../websocket.md), [Client API](../api/client-api.md), [Real-time](../architecture/realtime.md)
- Python example: [`examples/python/converger_ws.py`](https://github.com/AimTune/converger/blob/main/examples/python/converger_ws.py)
