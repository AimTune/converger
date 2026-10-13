---
title: Protocol v1 over gRPC
sidebar_position: 3
description: The gRPC bidirectional stream transport of Converger Protocol v1 for backend clients - the .proto, authentication, the JSON frame to protobuf mapping, endings, limits, draining and configuration.
---

# Protocol v1 over gRPC

**Implemented (#44).** Backend clients (bot runtimes, agent services, integrations written in Go, Java, Python,
...) can speak [Converger Protocol v1](./v1.md) over a **gRPC bidirectional stream** instead of the native
WebSocket. One `Connect` stream is one v1 connection to one conversation, with exactly the WebSocket semantics:
the same handshake, replay from a watermark, acks and exactly-once persistence by `clientId`, receipts, typing,
presence, token refresh, limits and draining. The decision is recorded in
[ADR-0056](../adr/0056-grpc-streaming-transport.md).

The frames are the v1 frames as protobuf messages. A frame that has no typed message yet travels as `raw`, the
JSON frame as a `google.protobuf.Struct`, so nothing of the protocol is out of reach.

The transport is **off by default**; enable it with `GRPC_ENABLED=true` (see [Configuration](#configuration)).

## The service

```protobuf
package converger.v1;

service ChannelStream {
  rpc Connect(stream ClientFrame) returns (stream ServerFrame);
}
```

The complete file is
[`priv/protos/converger/v1/protocol.proto`](https://github.com/AimTune/converger/blob/main/priv/protos/converger/v1/protocol.proto)
(it imports only `google/protobuf/struct.proto`). Generate a client from it with `protoc` and your language's
plugin, for example `protoc -I priv/protos --go_out=. --go-grpc_out=. converger/v1/protocol.proto`.

`ClientFrame` and `ServerFrame` are `oneof`s, one case per frame type:

```protobuf
message ClientFrame {
  oneof frame {
    Hello hello = 1;
    MessageSend message = 2;   // "text" and every message type (a user turn)
    TypingSignal typing = 3;
    Read read = 4;
    Sync sync = 5;
    Ping ping = 6;
    Auth auth = 7;
    google.protobuf.Struct raw = 15;  // any other v1 client frame, as JSON
  }
}

message ServerFrame {
  oneof frame {
    Welcome welcome = 1;
    Activity activity = 2;     // persistent frames: text, event, conversationUpdate, message types
    Ack ack = 3;
    Error error = 4;
    DeliveryStatus delivery_status = 5;
    Typing typing = 6;
    Presence presence = 7;
    Heartbeat heartbeat = 8;
    TokenRefreshed token_refreshed = 9;
    ReplayTruncated replay_truncated = 10;
    Close close = 11;          // gRPC only: the close code the stream ends with
    google.protobuf.Struct raw = 15;  // any other v1 server frame, as JSON
  }
}
```

## Connecting and authentication

- The server listens on its own port (`GRPC_PORT`, default `50051`), plaintext HTTP/2 (h2c) unless TLS is
  configured. Put it behind a gRPC-aware load balancer, or terminate TLS on the server itself.
- The credential is a [Converger token](./v1.md#31-tokens), the same as on the WebSocket: the
  `authorization: Bearer <token>` metadata (preferred), or `Hello.token`. It is checked when `hello` arrives;
  a missing or invalid token is answered with `error` `unauthorized`, then `Close {code: 4401}`, and the RPC
  ends with `UNAUTHENTICATED`.
- The first client frame must be `hello`, exactly as on the WebSocket (section 4 of the spec); `welcome`, the
  replay of every persistent frame after `Hello.watermark`, then live frames follow.
- While the node drains, a new `Connect` is refused with `UNAVAILABLE`.

## Frame mapping

JSON keys become snake_case protobuf fields (`clientId` is `client_id`), and the frame's `type` picks the
`oneof` case. Open-ended JSON (message `data` of rich types, `metadata`, `meta`, `error.details`, attachments,
`welcome.pending`) is a `google.protobuf.Struct`. Struct numbers are doubles: the server reads whole numbers
back as integers.

| JSON frame (`type`) | Direction | Protobuf |
| --- | --- | --- |
| `hello` | c2s | `ClientFrame.hello` (`Hello`); `watermark` is `Hello.watermark` (integer seq) or `Hello.legacy_watermark` (the pre-v1 opaque string) |
| `text` and message types | c2s | `ClientFrame.message` (`MessageSend`): `type`, `client_id`, `text` (`TextData {text, attachments}` for `text`) or `data` (Struct), `metadata`, `meta`, `reply_to`, `id` |
| `typing` | c2s | `ClientFrame.typing` (`TypingSignal {is_typing}`) |
| `read` | c2s | `ClientFrame.read` (`Read {watermark}`) |
| `sync` | c2s | `ClientFrame.sync` (`Sync`, `watermark` or `legacy_watermark`) |
| `ping` | c2s | `ClientFrame.ping` (`Ping {nonce}`) |
| `auth` | c2s | `ClientFrame.auth` (`Auth {token}`) |
| `resume`, `abort`, `genui_event`, `client_tools`, `client_skills`, `survey`, `regenerate`, `edit` | c2s | `ClientFrame.raw` (answered with `bot_unavailable` until the bot channel relay, #64) |
| `welcome` | s2c | `ServerFrame.welcome` (`Welcome` with `Capabilities` and `Limits`) |
| `text`, `event`, `conversationUpdate`, message types | s2c | `ServerFrame.activity` (`Activity`): `type`, `id`, `seq`, `from`, `sender`, `text` or `data`, `timestamp`, `metadata`, `client_id`, `reply_to` |
| `ack` | s2c | `ServerFrame.ack` (`Ack`) |
| `error` | s2c | `ServerFrame.error` (`Error`: `code`, `message`, `number`, `retryable`, `retry_after_ms`, `client_id`, `frame_type`, `details`) |
| `deliveryStatus` | s2c | `ServerFrame.delivery_status` (`DeliveryStatus`) |
| `typing` | s2c | `ServerFrame.typing` (`Typing`; `seq`, `id`, `timestamp` only for persisted typing activities) |
| `presence` | s2c | `ServerFrame.presence` (`Presence`) |
| `heartbeat` | s2c | `ServerFrame.heartbeat` (`Heartbeat`) |
| `tokenRefreshed` | s2c | `ServerFrame.token_refreshed` |
| `replayTruncated` | s2c | `ServerFrame.replay_truncated` |
| `tool_call`, `skill`, `genui`, `interrupt`, `interrupt_resolved`, `run`, `skills`, `genui_components` | s2c | `ServerFrame.raw` (relayed bot frames, #64) |
| - (WebSocket close) | s2c | `ServerFrame.close` (`Close {code, reason, retry_after_ms}`), then the RPC ends |

The server sends a frame as its typed message only when the mapping is lossless (the typed message maps back to
the same JSON); otherwise, for example a frame with a field this `.proto` does not name yet, it sends `raw`. A
client SHOULD therefore handle `raw` like the WebSocket's JSON frame: by its `type`, ignoring what it does not
know (section 5.5). The mapping is `ConvergerWeb.GRPC.Frames`; `test/protocol/grpc_frames_test.exs` checks that
every frame of the schema examples and example sessions round-trips through the wire format.

Since every `seq`-bearing frame keeps its `seq`, watermarks, gap detection and the echo rule work exactly as in
section 6 of the spec.

## Endings

A WebSocket closes with a close code; a gRPC stream cannot, so the server sends `Close {code, reason,
retry_after_ms}` as its last frame and ends the RPC with the matching status. The codes are the WebSocket close
codes of section 12.3:

| `Close.code` | Meaning | gRPC status |
| --- | --- | --- |
| 1000 | the client half-closed its side (end of its request stream) | `OK` |
| 1008 | the conversation of the token does not exist | `NOT_FOUND` |
| 1009 | a message above the hard cap (1 MiB) | `RESOURCE_EXHAUSTED` |
| 1012 | the node is draining: reconnect with backoff after `retry_after_ms`, same watermark | `UNAVAILABLE` |
| 1013 | the database was unavailable during the handshake | `UNAVAILABLE` |
| 4400 | unsupported `Hello.protocol` | `FAILED_PRECONDITION` |
| 4401 | `unauthorized` or `token_expired` | `UNAUTHENTICATED` |
| 4403 | channel deactivated or forced disconnect | `PERMISSION_DENIED` |
| 4408 | idle timeout: no client frame for `idleTimeoutMs` | `DEADLINE_EXCEEDED` |
| 4503 | slow consumer: reconnect after `retry_after_ms`, same watermark | `RESOURCE_EXHAUSTED` |

A client that cancels the RPC or loses the connection simply ends the session. Reconnect with the highest `seq`
you have durably processed as `Hello.watermark`: everything after it is replayed, so nothing is lost. Do not set
a gRPC deadline on `Connect`: the stream is long-lived, and a deadline ends it with `DEADLINE_EXCEEDED`.

## Limits and backpressure

The [WebSocket limits](../operations/websocket-limits.md) apply unchanged, with the same `WS_*` settings and the
same `[:converger, :socket, :limit]` telemetry (`socket: ConvergerWeb.GRPC.ChannelStreamServer`):

- a message above `maxFrameBytes` (its protobuf size) draws `payload_too_large` and the stream stays open; a
  message above the 1 MiB hard cap ends the stream (`Close 1009`) before it is buffered;
- more than `WS_MAX_MESSAGES_PER_WINDOW` client frames per window draw `rate_limited` with `retryAfterMs`;
- the server reads the next client message only after it handled the previous one, so a client that sends
  faster is held back by HTTP/2 flow control; at most one send is ever unacked (`maxInFlight` as on the native
  WebSocket);
- frames waiting for a slow client (in the stream's processes) drop `typing` and `presence` first, then end the
  stream with `Close 4503`;
- the client sends `ping` after `idleTimeoutMs / 2` of its own silence, as on the WebSocket; without any client
  frame for `idleTimeoutMs` the stream ends with `Close 4408`. HTTP/2 PING frames do not count.

## Examples

### grpcurl

```bash
# A Converger token, issued by your backend with the channel secret. Without a
# conversationId in hello, the stream starts a new conversation (section 3.2).
TOKEN=$(curl -s -X POST https://converger.example.com/api/v1/converger/tokens/generate \
  -H "authorization: Bearer $CHANNEL_SECRET" -H 'content-type: application/json' \
  -d '{"user": {"id": "alice"}}' | jq -r .token)

grpcurl -plaintext -import-path priv/protos -proto converger/v1/protocol.proto \
  -H "authorization: Bearer $TOKEN" -d @ localhost:50051 converger.v1.ChannelStream/Connect <<'EOF'
{"hello": {"protocol": "converger/1", "watermark": 0}}
{"message": {"type": "text", "clientId": "c-1", "text": {"text": "Where is my order?"}}}
{"ping": {"nonce": "p-1"}}
EOF
```

grpcurl prints `{"welcome": {...}}`, the replay, `{"ack": {"clientId": "c-1", "seq": ...}}` and
`{"heartbeat": {...}}`; when its input ends it half-closes, and the server answers `{"close": {"code": 1000}}`.

### Elixir

With the [`grpc`](https://hex.pm/packages/grpc) client and the modules generated from the `.proto` (Converger
ships them as `Converger.V1.*`):

```elixir
{:ok, channel} = GRPC.Stub.connect("localhost:50051", adapter: GRPC.Client.Adapters.Mint)
stream = Converger.V1.ChannelStream.Stub.connect(channel, metadata: %{"authorization" => "Bearer " <> token})

hello = %Converger.V1.ClientFrame{frame: {:hello, %Converger.V1.Hello{position: {:watermark, 0}}}}
stream = GRPC.Stub.send_request(stream, hello)

send = %Converger.V1.MessageSend{type: "text", client_id: "c-1", payload: {:text, %Converger.V1.TextData{text: "hi"}}}
stream = GRPC.Stub.send_request(stream, %Converger.V1.ClientFrame{frame: {:message, send}})

{:ok, replies} = GRPC.Stub.recv(stream, timeout: :infinity)

Enum.each(replies, fn
  {:ok, %Converger.V1.ServerFrame{frame: {:ack, ack}}} -> IO.puts("acked #{ack.client_id} as seq #{ack.seq}")
  {:ok, %Converger.V1.ServerFrame{frame: {:activity, a}}} -> IO.inspect({a.seq, a.payload})
  {:ok, %Converger.V1.ServerFrame{frame: other}} -> IO.inspect(other)
  {:error, error} -> IO.inspect(error, label: "stream ended")
end)
```

### Go

```go
conn, _ := grpc.NewClient("localhost:50051", grpc.WithTransportCredentials(insecure.NewCredentials()))
client := convergerv1.NewChannelStreamClient(conn)
ctx := metadata.AppendToOutgoingContext(context.Background(), "authorization", "Bearer "+token)
stream, _ := client.Connect(ctx)

stream.Send(&convergerv1.ClientFrame{Frame: &convergerv1.ClientFrame_Hello{Hello: &convergerv1.Hello{
    Position: &convergerv1.Hello_Watermark{Watermark: lastSeq}}}})

for {
    frame, err := stream.Recv()
    if err != nil { break } // status.Code(err): Unavailable -> reconnect with lastSeq
    switch f := frame.Frame.(type) {
    case *convergerv1.ServerFrame_Activity:
        lastSeq = f.Activity.Seq // process, then remember the watermark
    case *convergerv1.ServerFrame_Close:
        log.Printf("closing: %d %s", f.Close.Code, f.Close.Reason)
    }
}
```

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `GRPC_ENABLED` | `false` | `true` (or `1`) starts the gRPC server. |
| `GRPC_PORT` | `50051` | Port of the gRPC server (all interfaces, IPv4 and IPv6). |
| `GRPC_TLS_CERTFILE`, `GRPC_TLS_KEYFILE` | unset | PEM certificate and key paths. Both set: the server speaks TLS (h2, ALPN). Otherwise plaintext h2c. |

The same settings in `config :converger, ConvergerWeb.GRPC` (`enabled`, `port`, `ip`, `certfile`, `keyfile`).
Heartbeat, idle timeout and replay settings are those of `config :converger, ConvergerWeb.Protocol`
([configuration](../operations/configuration.md#protocol-v1-transports)). In Kubernetes, the Helm chart's
`grpc.enabled` sets the variables and adds a `grpc` container and Service port
([Kubernetes](../operations/kubernetes.md)).

## Observability

The gRPC connections are part of the client connection metrics with `transport="grpc"`:
`converger_ws_connections_count{socket="protocol",transport="grpc"}` (open streams per node) and
`converger_ws_frame_count{socket="protocol",transport="grpc",direction=...}`
([Observability](../operations/observability.md)). The `grpc` library adds the telemetry events
`[:grpc, :server, :rpc, :start | :stop | :exception]` for each stream.

## Regenerating the Elixir modules

The generated modules are committed under `lib/converger_web/grpc/gen/`. After changing the `.proto`, run:

```bash
priv/protos/generate.sh          # protoc + protoc-gen-elixir in Docker
LOCAL=1 priv/protos/generate.sh  # with protoc and protoc-gen-elixir on your PATH
```

Install the plugin locally with `mix escript.install hex protobuf 0.17.1` (the `protobuf` version in
`mix.lock`). Changes to the `.proto` follow the protocol's compatibility rules (section 13): only additive
changes within v1, new fields with new numbers, never a renumbered or retyped field.
