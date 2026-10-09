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
[Observability](observability.md#exported-metrics).

## Health probes

[`ConvergerWeb.Plugs.Health`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/health.ex) runs
first in the endpoint, so the probes need no authentication, are not redirected to HTTPS and are not logged per
request.

| Probe | Answer |
| --- | --- |
| `GET /health/live` | `200 {"status": "ok"}` while the node is up. |
| `GET /health/ready` | `200 {"status": "ready"}`; `503 {"status": "draining"}` once the node has started shutting down. |

Database, Oban and migration checks in readiness are Planned ([#29](https://github.com/AimTune/converger/issues/29)).

## Draining on shutdown

When a node receives `SIGTERM` (a rolling deploy, a scale-down), the application supervisor stops its children in
reverse order. [`ConvergerWeb.Drain`](https://github.com/AimTune/converger/blob/main/lib/converger_web/drain.ex) is
the last child, so it stops first, while the endpoint still serves every socket:

1. **Readiness flips.** `GET /health/ready` answers 503 and new WebSocket connections are refused with HTTP 503 and
   a `Retry-After` header, for `drain_delay_ms` (5 s). The load balancer takes the node out of rotation, and
   reconnecting clients land on other nodes. Existing sockets keep working.
2. **Sockets are drained in batches.** The native Protocol v1 connections (WebSocket and SSE, registered in
   `ConvergerWeb.ProtocolConnections`), which Phoenix's drainer does not know, are drained first, with the same
   batch size and pacing: a native socket is closed with **1012** and the reason below, an SSE stream ends with an
   `error` frame `unavailable` carrying `retryAfterMs`. Then the endpoint stops, and Phoenix's socket drainer closes the sockets that
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

The hard frame cap is `config :converger, :websocket_max_frame_size` (default `1_048_576`). The socket mounts read it
at compile time, so changing it needs a rebuild. Bandit's `log_protocol_errors` is turned off for WebSockets
(`http: [websocket_options: ...]` in `config/config.exs`). Without that, every oversize frame would be logged as an
error; the guard logs it at `info` and counts it as `frame_too_large` instead.

## Verifying a rolling restart

`test/converger_web/channels/socket_guard_test.exs` opens real WebSockets against a Bandit listener and covers each
limit, the 1012 drain close and the 503 refusal. The cluster-scale check (10 000 sockets, a rolling restart of a
2-node cluster, every client reconnected within 30 s and no acknowledged message lost) belongs to the load-testing
work ([#57](https://github.com/AimTune/converger/issues/57) chaos harness, [#29](https://github.com/AimTune/converger/issues/29)
clustering).
