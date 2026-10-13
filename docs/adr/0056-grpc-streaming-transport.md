---
title: "ADR-0056: Protocol v1 over a gRPC bidirectional stream, sharing one transport-agnostic session with the native WebSocket"
sidebar_label: "0056 gRPC streaming transport"
description: Backend clients can speak Protocol v1 over a gRPC bidirectional stream on its own port; the native WebSocket's session logic moves into a transport-agnostic module both transports run, frames map losslessly between JSON and protobuf with a raw Struct fallback, and a stream ends with a Close frame carrying the WebSocket close code plus the matching gRPC status.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-13 |
| **Issue** | [#44](https://github.com/AimTune/converger/issues/44) |
| **Pull request** | [#156](https://github.com/AimTune/converger/pull/156) |
| **Related** | [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md), [ADR-0027](0027-websocket-limits-backpressure-and-draining.md), [ADR-0030](0030-native-websocket-endpoint-and-fallback-transports.md), [ADR-0035](0035-native-transports-share-signals-limits-and-draining.md) |

## Context and problem statement

Converger Protocol v1 ([ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md)) is WebSocket-first:
the native endpoint ([ADR-0030](0030-native-websocket-endpoint-and-fallback-transports.md)) speaks JSON or
MessagePack frames. Backend clients (bot runtimes, agent services, integrations in Go, Java or Python) prefer
gRPC: a typed contract generated from a `.proto`, HTTP/2 multiplexing, deadlines, and the service meshes and
load balancers they already run. #44 asks for a bidirectional stream alternative to the WebSocket that shares
the Protocol v1 frame definitions through protobuf.

The WebSocket's session (handshake, replay, acks and idempotency, receipts, typing, presence, token refresh,
limits, draining) lived in `ConvergerWeb.ProtocolSocket`, a `WebSock` handler whose callbacks returned encoded
WebSocket messages. A second transport must not get a second copy of that logic: acks, at-least-once delivery,
resume, limits and draining have to behave identically, and stay identical as the protocol evolves.

## Decision drivers

- One implementation of the protocol's semantics for every transport.
- The `.proto` must cover the v1 frames as they are, and not block additive protocol changes (section 13 of
  the spec) on a `.proto` change.
- No message loss: the same watermark resume and exactly-once persistence by `clientId` as the WebSocket.
- The same limits, backpressure and draining as the WebSocket ([ADR-0027](0027-websocket-limits-backpressure-and-draining.md),
  [ADR-0035](0035-native-transports-share-signals-limits-and-draining.md)), including on node shutdown.
- Off by default; no impact on deployments that do not use it.

## Considered options

1. **A transport-agnostic session module, a gRPC server that runs it on its own port** - the WebSocket handler
   and the gRPC stream both become thin adapters around `ConvergerWeb.Protocol.Session`.
2. **A gRPC server that proxies to the WebSocket endpoint** - each stream opens an internal WebSocket.
3. **A separate gRPC implementation of the protocol** - its own handshake, feed and send code.
4. **gRPC on the main HTTP port** (Bandit) - one port for HTTP, WebSocket and gRPC.

### Pros and cons of the options

#### Option 1

- Good, because there is one implementation of the protocol; the WebSocket's tests keep covering it.
- Good, because the gRPC stream gets limits, backpressure and draining by registering like the WebSocket.
- Bad, because the WebSocket handler is refactored (a behaviour-preserving move, covered by its test suite).

#### Option 2

- Good, because nothing in the WebSocket path changes.
- Bad, because every stream costs a second connection, frames are encoded twice, and limits, slow-consumer
  detection and draining apply to the proxy, not to the gRPC client.

#### Option 3

- Bad, because two implementations of acks, replay and limits drift apart.

#### Option 4

- Good, because one port.
- Bad, because there is no maintained gRPC server for Bandit/Plug; the `grpc` library serves on Cowboy. Running
  both on one port would need a custom HTTP/2 router in front.

## Decision

Chosen option: **"Option 1"**, because it is the only option where acks, resume, limits and draining are the
same code for both transports.

- **Session.** `ConvergerWeb.Protocol.Session` holds everything `ProtocolSocket` did, on decoded frames (the JSON
  maps of the spec). It runs in the connection's process and returns transport-neutral results: `{:ok, s}`,
  `{:push, frames, s}` or `{:close, %{code, reason, retry_after_ms}, frames, s}` with the WebSocket close code of
  section 12.3. `ProtocolSocket` maps them to WebSocket messages and closes (the 1012/4503 JSON close reasons are
  unchanged); the slow-consumer check takes a `backlog` function so each transport measures its own buffers.
- **Contract.** `priv/protos/converger/v1/protocol.proto`: service `converger.v1.ChannelStream` with
  `rpc Connect(stream ClientFrame) returns (stream ServerFrame)`; `ClientFrame` and `ServerFrame` are `oneof`s with
  a typed message per v1 frame type. Open-ended JSON (rich message `data`, `metadata`, `meta`, `details`) is
  `google.protobuf.Struct`. Every `oneof` has a `raw` case: the JSON frame as a Struct. The Elixir modules are
  generated with `protoc-gen-elixir` and committed (`priv/protos/generate.sh`, runs `protoc` in Docker).
- **Mapping.** `ConvergerWeb.GRPC.Frames` maps JSON frames to protobuf and back. A server frame is sent typed only
  when the typed message, through the wire format, maps back to the same JSON frame; otherwise it is sent `raw`.
  So the mapping is lossless by construction, and frames the `.proto` does not name yet (relayed bot frames,
  #64, or a field added in a minor release) still reach gRPC clients.
- **Server.** The `grpc` / `grpc_server` libraries (Cowboy adapter) on `GRPC_PORT` (default 50051), started by
  `ConvergerWeb.GRPC.child_specs/0` only when `GRPC_ENABLED=true`, TLS when `GRPC_TLS_CERTFILE` and
  `GRPC_TLS_KEYFILE` are set. Credentials: the `authorization: Bearer` metadata or `Hello.token`, the same
  Converger tokens as the WebSocket, checked on `hello`.
- **Stream process.** The RPC process is the session process (`ConvergerWeb.GRPC.Connection`): it subscribes to
  the conversation and sends replies with `GRPC.Server.send_reply/2`. A linked reader process reads the request
  body itself (not the library's request enumerable) so it can check each message's length prefix against the
  1 MiB hard cap before buffering it, and reads the next message only after the session handled the previous
  one: HTTP/2 flow control then holds back a client that sends too fast, and at most one send is unacked, as on
  the native WebSocket. The RPC process traps exits, so a cancelled stream (the Cowboy stream process exits)
  still runs the session's cleanup (typing stopped, connection gauge).
- **Endings.** A stream cannot carry a close code, so the server sends a gRPC-only `Close {code, reason,
  retry_after_ms}` frame last and ends the RPC with a matching status (4401 `UNAUTHENTICATED`, 4403
  `PERMISSION_DENIED`, 4408 `DEADLINE_EXCEEDED`, 4503 and 1009 `RESOURCE_EXHAUSTED`, 1012/1013 `UNAVAILABLE`,
  1008 `NOT_FOUND`, 4400 `FAILED_PRECONDITION`); a client half-close ends with `Close 1000` and `OK`. These
  expected endings are filtered from the server's exception log.
- **Draining and supervision.** Streams register in `ConvergerWeb.ProtocolConnections`, so `ConvergerWeb.Drain`
  drains them with the native WebSockets (`Close 1012` with `retryAfterMs`, `UNAVAILABLE`); new streams are
  refused with `UNAVAILABLE` while the node drains. The gRPC server is a child before `ConvergerWeb.Drain`, so it
  stops only after the drain.
- **Telemetry.** The existing client connection metrics with `transport="grpc"` (`[:converger, :ws, :connected |
  :disconnected | :frame]`, the connection gauge) and `[:converger, :socket, :limit]` with the gRPC server module.

## Consequences

### Positive

- Backend clients get a generated, typed client in any gRPC language with exactly the WebSocket's guarantees.
- The protocol's semantics live in one module; the gRPC transport is two small adapters plus a mapping.
- The `raw` fallback lets the protocol grow without a lockstep `.proto` change.

### Negative and trade-offs

- A second listening port (and Cowboy next to Bandit) when enabled; deployments must expose and secure it.
- Struct numbers are doubles: integers in `metadata` above 2^53 lose precision, and the server reads whole
  numbers back as integers.
- One unacked send per stream (no pipelining of sends), as on the native WebSocket; a client that needs
  throughput opens several streams.
- gRPC-Web and HTTP/JSON transcoding are not offered.
- The reader relies on the Cowboy adapter's `read_body/1` (a public function of `grpc_server`); the
  dependency is pinned to patch releases.

### Follow-ups

- [#64](https://github.com/AimTune/converger/issues/64): typed messages for the relayed bot frames (they travel
  as `raw` until then) and channel-scoped streams.
- Server reflection and the gRPC health service, if operators ask for them.

## Implementation

- `lib/converger_web/protocol/session.ex` (`ConvergerWeb.Protocol.Session`), `lib/converger_web/protocol_socket.ex`
  (now a WebSock adapter around it).
- `priv/protos/converger/v1/protocol.proto`, `priv/protos/generate.sh`, generated `lib/converger_web/grpc/gen/`.
- `lib/converger_web/grpc.ex` (config, child spec, log filter), `grpc/endpoint.ex`, `grpc/channel_stream_server.ex`,
  `grpc/connection.ex`, `grpc/frames.ex`; `lib/converger/application.ex` (child before `ConvergerWeb.Drain`).
- Config: `config :converger, ConvergerWeb.GRPC` and `GRPC_ENABLED`, `GRPC_PORT`, `GRPC_TLS_CERTFILE`,
  `GRPC_TLS_KEYFILE` in `config/runtime.exs`; Helm `grpc.*` values; docker compose maps 50051.
- Tests: `test/converger_web/grpc/channel_stream_test.exs` (the `grpc` client end to end: handshake, auth
  failure, acks and duplicates, routing to a WebSocket client, typing, resume from a watermark with no loss,
  sync, limits, hard cap, slow consumer, idle timeout, draining, half-close, cancel, telemetry; every server
  frame validated against the v1 JSON Schema), `test/protocol/grpc_frames_test.exs` (every schema example and
  example-session frame round-trips through protobuf), and the unchanged `test/converger_web/protocol_socket_test.exs`
  for the refactored WebSocket.

## Links

- [Protocol v1 over gRPC](../protocol/grpc.md)
- [Converger Protocol v1](../protocol/v1.md)
- [WebSocket limits and draining](../operations/websocket-limits.md)
- [elixir-grpc](https://github.com/elixir-grpc/grpc), [protobuf-elixir](https://github.com/elixir-protobuf/protobuf)
