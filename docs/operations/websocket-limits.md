---
title: WebSocket limits and draining
description: Per-socket frame size, message rate and join limits, slow-consumer protection, health probes and how Converger drains WebSocket connections on shutdown and rolling deploys.
sidebar_position: 6
---

Every client WebSocket (`/socket/converger/websocket`, `/socket/websocket` and the native Protocol v1 endpoint
`/socket/converger/v1`) is bounded, so one client cannot
exhaust a node, and a node that shuts down hands its clients over to the other nodes gradually instead of dropping
them all at once. The design is recorded in
[ADR-0027](../adr/0027-websocket-limits-backpressure-and-draining.md); the client-facing view is in
[WebSocket](../websocket.md#limits-and-disconnects).

## Per-socket limits

The limits are enforced in the socket process by
[`ConvergerWeb.SocketGuard`](https://github.com/AimTune/converger/blob/main/lib/converger_web/socket_guard.ex),
before a frame reaches a channel, so they apply equally to every channel on both sockets. The native endpoint
(`ConvergerWeb.ProtocolSocket`) applies the same settings itself, answering with Protocol v1 `error` frames
(`payload_too_large`, `rate_limited` with `retryAfterMs`) instead of Phoenix error replies; it has no joins. The
Server-Sent Events stream drops `typing` and `presence` for a lagging client the same way.

| Limit | Default | On violation |
| --- | --- | --- |
| Inbound frame size (`max_frame_bytes`) | 128 KiB | The frame is not processed; error reply `{"reason": "payload_too_large"}`. The socket stays open. |
| Hard frame cap (`websocket_max_frame_size`, compile time) | 1 MiB | Bandit closes the socket with **1009**. Logged at `info`, not as a crash. |
| Inbound frames per socket (`max_messages` per `rate_window_ms`) | 20 per 1 000 ms | The frame is not processed; error reply `{"reason": "rate_limited", "retryAfterMs": N}`, where `N` is the time left in the window. Heartbeats and joins count. |
| Joined channels per socket (`max_joins`) | 50 | The join is refused with `{"reason": "too_many_joins"}`. Rejoining an already joined topic is allowed. |
| Unacked v1 sends per connection on the Phoenix binding (`max_in_flight`) | 32 | The newest sends beyond it get the `error` frame `too_many_in_flight` (retryable with the same `clientId`); the oldest are processed in order. Announced as `welcome.data.limits.maxInFlight`. |
| Outbound backlog (`slow_consumer_queue_len`) | 1 000 frames | The socket is closed with **4503** and the reason `{"reason": "slow_consumer", "retryAfterMs": N}`. |
| Ephemeral backlog (`ephemeral_drop_queue_len`) | 100 frames | Ephemeral frames (typing, presence) are dropped. |
| Idle timeout (Phoenix `timeout`) | 60 000 ms | A socket that sends nothing, heartbeats included, is closed. |

The error replies are ordinary Phoenix replies to the rejected push or join:

```json
[null, "4", "phoenix", "phx_reply", {"status": "error", "response": {"reason": "rate_limited", "retryAfterMs": 412}}]
```

### Slow consumers

A client that reads its socket more slowly than the server writes to it makes the frames waiting in the socket
process's mailbox pile up, until the node runs out of memory. The guard checks the mailbox length before every
outbound frame.

1. Above `ephemeral_drop_queue_len`, channels drop ephemeral frames. They send them with
   `ConvergerWeb.SocketGuard.push_ephemeral/3`, which returns `:dropped` instead of pushing. Typing and presence
   frames ([#25](https://github.com/AimTune/converger/issues/25)) must use it. Activities are never dropped.
2. Above `slow_consumer_queue_len`, the socket is closed with 4503. The client reconnects and resumes from its
   last watermark (`converger:` socket) or `last_activity_id` (legacy socket), so it loses nothing: every activity
   is stored before it is pushed.

Writes to a client that stops reading entirely are also bounded by the TCP send timeout (Thousand Island default
30 s), after which the connection is closed.

### Telemetry

Every rejection emits `[:converger, :socket, :limit]` with `%{count: 1}` and metadata `reason` (`rate_limited`,
`payload_too_large`, `frame_too_large`, `too_many_joins`, `slow_consumer`, `ephemeral_dropped`, `draining`) and
`socket` (the socket module). It is exported as the counter `converger_socket_limit_count` by `reason`. See
[Observability](observability.md#exported-metrics). Open connections, connects and frames per second are exported too
(`converger_ws_connections_count`, `converger_ws_frame_count`, see [Realtime metrics](observability.md#realtime-metrics)).

## Health probes

[`ConvergerWeb.Plugs.Health`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/health.ex) runs
first in the endpoint, so the probes need no authentication, are not redirected to HTTPS and are not logged per
request.

| Probe | Answer |
| --- | --- |
| `GET /health/live` | `200 {"status": "ok"}` while the node is up. |
| `GET /health/ready` | `200 {"status": "ready", "checks": {...}}`; `503 {"status": "draining", ...}` once the node has started shutting down (`"unavailable"` when another check fails). |

Readiness also checks the database, Oban and pending migrations; see [Observability](observability.md#health-endpoints)
([ADR-0037](../adr/0037-libcluster-clustering-health-endpoints-and-metrics-on-the-main-port.md)).

## Draining on shutdown

When a node receives `SIGTERM` (a rolling deploy, a scale-down), the application supervisor stops its children in
reverse order. [`ConvergerWeb.Drain`](https://github.com/AimTune/converger/blob/main/lib/converger_web/drain.ex) is
the last child, so it stops first, while the endpoint still serves every socket:

1. **Readiness flips.** `GET /health/ready` answers 503 and new WebSocket connections are refused with HTTP 503 and
   a `Retry-After` header, for `drain_delay_ms` (5 s). The load balancer takes the node out of rotation, and
   reconnecting clients land on other nodes. Existing sockets keep working.
2. **Sockets are drained in batches.** The native Protocol v1 connections (WebSocket, SSE and gRPC streams, registered in
   `ConvergerWeb.ProtocolConnections`), which Phoenix's drainer does not know, are drained first, with the same
   batch size and pacing: a native socket is closed with **1012** and the reason below, an SSE stream ends with an
   `error` frame `unavailable` carrying `retryAfterMs`, a gRPC stream gets `Close {code: 1012, retry_after_ms}` and ends
   with `UNAVAILABLE` ([Protocol v1 over gRPC](../protocol/grpc.md); new streams get `UNAVAILABLE` while draining, and
   the gRPC server stops after the drain). Then the endpoint stops, and Phoenix's socket drainer closes the sockets that
   have joined a channel, `drain_batch_size` (500) every `drain_batch_interval_ms` (1 s), for at most
   `drain_shutdown_ms` (30 s). Each socket is closed with **1012** and the reason
   `{"reason": "unavailable", "retryAfterMs": N}`, where `N` is `reconnect_base_ms` plus a random jitter of up to
   `reconnect_jitter_ms` (1 to 6 s). With the defaults, 10 000 sockets are closed over 20 s, and their reconnects are
   spread further by the jitter.
3. **The listener stops.** Sockets that never joined a channel are not drained by Phoenix. They are closed when
   Bandit stops (close code 1001).

Before a channel is drained it finishes the message it is handling, so a send that was acknowledged has been
stored. A send that the drain cuts off is not acknowledged, and the client re-sends it with the same idempotency
key to another node. That is why a rolling restart loses no acknowledged message.

### Reconnect bursts

A drained node's clients all reconnect to the other nodes within a few seconds. On the native v1 endpoint (WebSocket
and gRPC), the database work of every `hello` and `sync` goes through a per-node admission queue
([`ConvergerWeb.Protocol.Admission`](https://github.com/AimTune/converger/blob/main/lib/converger_web/protocol/admission.ex),
[ADR-0076](../adr/0076-admission-queue-for-reconnect-bursts.md)). At most `handshake_concurrency` handshakes read the
database at once, by default half of the interactive pool (`POOL_SIZE`). Each reads through a single pool checkout:
the channel, the conversation and its head, the open interrupts, and the replay. A client whose watermark is already
the head skips the replay. Further handshakes wait in arrival order, so a burst becomes a short queue instead of a
saturated pool, and the rest of the pool stays free for REST and live delivery.

A handshake that waits longer than `handshake_queue_ms` (10 s), or that arrives while `handshake_queue_max` (10 000)
are already waiting, gets the same answer as when the database is unavailable
([Database pressure](database.md)): `error` `unavailable` with `retryAfterMs`, then close **1013**. A `sync` gets
`replay_unavailable` with `details.watermark`. Watch `converger_protocol_admission_wait_ms` (by `result`, `ok` or
`overloaded`). If handshakes queue for seconds while the database has spare capacity, raise
`WS_HANDSHAKE_CONCURRENCY` (and `POOL_SIZE` with it).

Clients should treat `retryAfterMs` (in the 1012 close reason and in `unavailable`) as the minimum delay, and cap
their exponential backoff at about 10 s. The TypeScript SDK does both. A larger cap stretches the time to
reconnect after a client has failed a few times while a node restarted.

### Sizing the termination grace period

The orchestrator must wait for the whole sequence before it kills the process. In Kubernetes, set
`terminationGracePeriodSeconds` to at least:

```text
drain_delay_ms
  + min(native v1 connections per node / drain_batch_size * drain_batch_interval_ms, drain_shutdown_ms)
  + min(Phoenix sockets per node / drain_batch_size * drain_batch_interval_ms, drain_shutdown_ms)
  + Oban and pipeline shutdown + margin
```

That is 60 s with the defaults when most clients use one kind of socket (the native phase takes no time
without native connections), and up to 90 s when a node holds many of both. Point the readiness probe at `/health/ready` with a period shorter than
`drain_delay_ms`, or raise `WS_DRAIN_DELAY_MS` to cover your load balancer's deregistration delay.

## Configuration

`config :converger, :websocket` in `config/config.exs`. Each key can be overridden at runtime with an environment
variable (integers; unset or empty keeps the default).

| Variable | Config key | Default | Meaning |
| --- | --- | --- | --- |
| `WS_MAX_FRAME_BYTES` | `max_frame_bytes` | `131072` | Frames above this get `payload_too_large`. |
| `WS_MAX_MESSAGES_PER_WINDOW` | `max_messages` | `20` | Inbound frames allowed per socket per window. |
| `WS_RATE_WINDOW_MS` | `rate_window_ms` | `1000` | Rate window length. |
| `WS_MAX_JOINS` | `max_joins` | `50` | Channels one socket may join at the same time. |
| `WS_MAX_IN_FLIGHT` | `max_in_flight` | `32` | Unacked v1 `text` sends per Phoenix connection ([ADR-0029](../adr/0029-websocket-sends-acked-on-the-phoenix-binding.md)). |
| `WS_EPHEMERAL_DROP_QUEUE_LEN` | `ephemeral_drop_queue_len` | `100` | Outbound backlog above which ephemeral frames are dropped. |
| `WS_SLOW_CONSUMER_QUEUE_LEN` | `slow_consumer_queue_len` | `1000` | Outbound backlog above which the socket is closed with 4503. |
| `WS_RECONNECT_BASE_MS` | `reconnect_base_ms` | `1000` | Base of the `retryAfterMs` sent with 1012 and 4503 closes. |
| `WS_RECONNECT_JITTER_MS` | `reconnect_jitter_ms` | `5000` | Maximum random jitter added to it. |
| `WS_DRAIN_DELAY_MS` | `drain_delay_ms` | `5000` | Time between readiness turning 503 and the sockets being drained (`0` in test). |
| `WS_DRAIN_BATCH_SIZE` | `drain_batch_size` | `500` | Sockets closed per drain batch. |
| `WS_DRAIN_BATCH_INTERVAL_MS` | `drain_batch_interval_ms` | `1000` | Pause between drain batches. |
| `WS_DRAIN_SHUTDOWN_MS` | `drain_shutdown_ms` | `30000` | Upper bound for the drain. |
| `WS_HANDSHAKE_CONCURRENCY` | `handshake_concurrency` | `0` | Native v1 handshakes and `sync` replays reading the database at once per node; `0` is half the interactive pool, at least 1 ([reconnect bursts](#reconnect-bursts)). |
| `WS_HANDSHAKE_QUEUE_MS` | `handshake_queue_ms` | `10000` | Longest wait for a slot before `unavailable` (close 1013) or `replay_unavailable`. |
| `WS_HANDSHAKE_QUEUE_MAX` | `handshake_queue_max` | `10000` | Handshakes allowed to wait at once; beyond it they are answered at once. |

The hard frame cap is `config :converger, :websocket_max_frame_size` (default `1_048_576`). The socket mounts read it
at compile time, so changing it needs a rebuild. Bandit's `log_protocol_errors` is turned off for WebSockets
(`http: [websocket_options: ...]` in `config/config.exs`). Without that, every oversize frame would be logged as an
error; the guard logs it at `info` and counts it as `frame_too_large` instead.

## Verifying a rolling restart

`test/converger_web/channels/socket_guard_test.exs` opens real WebSockets against a Bandit listener and covers each
limit, the 1012 drain close and the 503 refusal. The cluster-scale check is the load harness's `rolling_restart` scenario with 10 000 sockets
([Benchmarks](../benchmarks/index.md), [#190](https://github.com/AimTune/converger/issues/190)). On a 3-node cluster it lost
no acknowledged message, but reconnects took p95 93.6 s instead of the 30 s this design aims for, because the
surviving nodes' database pools saturated on handshakes and replays
([2026-10-15 run](../benchmarks/2026-10-15-a8dd704-rolling-restart-10k.md)). The
[admission queue](#reconnect-bursts) addresses that ([#198](https://github.com/AimTune/converger/issues/198)); re-run
the same command to check a cluster:

```bash
LOAD_NODES=3 LOAD_SCENARIOS=rolling_restart LOAD_CONVERSATIONS=1000 LOAD_SUBSCRIBERS=10 LOAD_RATE=0.1 \
  LOAD_RESTART_CONNECT_RATE=100 LOAD_RESTART_DELAY_S=130 LOAD_WARMUP_S=0 load/run.sh
```
