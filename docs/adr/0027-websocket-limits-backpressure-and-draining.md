---
title: "ADR-0027: WebSocket limits in the socket transport, mailbox backpressure and readiness-gated draining"
sidebar_label: "0027 WebSocket limits and draining"
description: Per-socket frame, rate and join limits and slow-consumer protection are enforced in the socket transport process by wrapping Phoenix's socket callbacks, and shutdown flips readiness before Phoenix's drainer closes sockets in batches with a jittered retryAfterMs.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-09 |
| **Issue** | [#27](https://github.com/AimTune/converger/issues/27) |
| **Pull request** | [#117](https://github.com/AimTune/converger/pull/117) |
| **Related** | [ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md), [ADR-0020](0020-per-subject-socket-ids-and-presence.md), [ADR-0022](0022-deployment-hardening.md), [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md) |

## Context and problem statement

Nothing bounded a client WebSocket ([#27](https://github.com/AimTune/converger/issues/27)):

- Bandit accepted frames up to 8 MB, and a client could join any number of channels and send any number of frames.
- A client that reads slowly makes outbound frames pile up in its socket process's mailbox until the node runs out
  of memory, and with it every other client on the node.
- On deploy, Phoenix's default drainer (10 000 sockets every 2 s) closed sockets with no readiness signal. The
  load balancer kept routing new connections to the stopping node, and clients had no hint about when to come back,
  so they all reconnected at once.

Converger Protocol v1 ([ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md)) had already reserved
the vocabulary: `payload_too_large`, `rate_limited` with `retryAfterMs`, close 1009 above a hard cap, and
`unavailable` with close 1012 for a draining node.

## Decision drivers

- One client must not be able to exhaust a node's memory or CPU.
- The same rules for every channel on both client sockets, including channels added later (#22 to #26).
- No acknowledged message may be lost on a rolling restart.
- Rejections must not be logged as crashes, and must be observable.
- No new dependency. The checks run per frame, so they must cost no network round trip.

## Considered options

1. **Checks in each channel's `handle_in`**: a helper that every channel calls.
2. **Checks in the socket transport**: `use ConvergerWeb.SocketGuard` overrides the transport callbacks that
   `use Phoenix.Socket` generates (`connect/1`, `handle_in/2`, `handle_info/2`, `terminate/2`) and calls `super`
   for frames that pass.
3. **A separate WebSock handler** in front of Phoenix's socket, delegating every callback.

For the rate counter: the cluster-wide Hammer buckets of [ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md),
or a fixed window kept in the socket process.

For draining: Phoenix's drainer alone, or the drainer preceded by a readiness gate.

### Pros and cons of the options

#### Checks in each channel

- Good, because it uses only public channel APIs.
- Bad, because a per-socket rate or join count is not visible from one channel process. Every channel must remember
  to call the helper. Oversize frames and joins are already decoded and dispatched by then, and a slow consumer can
  only be closed by sending a message to the very mailbox that is backed up.

#### Checks in the socket transport

- Good, because the socket process sees every frame before it is decoded or dispatched, owns the mailbox to measure,
  and can return a close code and reason (`{:stop, :normal, {code, reason}, state}`) that Bandit sends as is.
- Good, because the checks stay out of the channels, and a new channel gets them without doing anything.
- Bad, because it depends on `use Phoenix.Socket` generating those callbacks and on its state holding the joined
  `channels` map. The tests run real sockets, so a Phoenix upgrade that changes either fails CI.

#### Separate WebSock handler

- Good, because it does not override anything.
- Bad, because it would have to replicate Phoenix's `child_spec`, `drainer_spec`, `connect/1` and state handling,
  which is more coupling to Phoenix internals than option 2.

## Decision

Chosen: **option 2, checks in the socket transport**, with a **fixed-window counter in the socket process** and a
**readiness gate before Phoenix's drainer**.

- **Limits** (`ConvergerWeb.SocketGuard`): frames above `max_frame_bytes` (128 KiB) get `payload_too_large`. Bandit
  closes frames above `websocket_max_frame_size` (1 MiB) with 1009, and its protocol-error log is turned off; the
  guard logs at `info` instead. More than `max_messages` frames per `rate_window_ms` (20/s) get `rate_limited` with
  `retryAfterMs`. More than `max_joins` (50) joined channels get `too_many_joins`. Rejected frames are not
  processed; the socket stays open.
- **Rate counter in the process**: a socket lives on one node and its counter dies with it, so a process-local
  window is exact and free. Hammer stays for the per-tenant and per-IP buckets.
- **Backpressure**: before each outbound frame the socket process reads its own `message_queue_len`. Above
  `slow_consumer_queue_len` (1 000) it closes with **4503** `slow_consumer` and a jittered `retryAfterMs`.
  `push_ephemeral/3` lets channels drop typing and presence frames above `ephemeral_drop_queue_len` (100) and
  keeps activities.
- **Draining** (`ConvergerWeb.Drain`, the last application child): on shutdown it marks the node as draining.
  `/health/ready` then answers 503 and new sockets are refused with 503 + `Retry-After`. It waits `drain_delay_ms`,
  then lets the endpoint stop. Phoenix's drainer, configured to 500 sockets per second for at most 30 s, makes each
  channel finish its current message and the socket close with **1012** and
  `{"reason":"unavailable","retryAfterMs":N}`, with `N` jittered between 1 and 6 s.

## Consequences

### Positive

- Memory per socket is bounded by the frame cap and the mailbox threshold. A slow or abusive client loses only its
  own connection.
- A rolling restart spreads reconnects over the drain window plus the jitter, and they land on ready nodes.
- No acknowledged send is lost: acks are sent after the activity is stored, and a channel is drained only between
  messages. An unacknowledged send is retried by the client with its idempotency key.
- One telemetry event, `[:converger, :socket, :limit]`, by `reason`, exported as `converger_socket_limit_count`.

### Negative and trade-offs

- The guard depends on Phoenix socket internals (generated callbacks, `state.channels`), as described above.
- A frame between 128 KiB and 1 MiB is still read and decoded before it is refused.
- Phoenix drains only sockets that have joined a channel. A socket with no channel is closed when the listener
  stops, with 1001 and no `retryAfterMs`.
- The rate limit counts heartbeats. A client that floods gets error replies to its heartbeats too, which the
  `phoenix` client accepts as heartbeat answers.
- The hard frame cap is compile time, because Phoenix reads socket mount options at compile time.

### Follow-ups

- Typing and presence ([#25](https://github.com/AimTune/converger/issues/25)) push through `push_ephemeral/3`.
- The native protocol endpoint ([#22](https://github.com/AimTune/converger/issues/22)) sends the same codes as
  protocol `error` frames and announces the limits in `welcome.data.limits`.
- Readiness checks for the database, Oban and migrations, plus Kubernetes manifests
  ([#29](https://github.com/AimTune/converger/issues/29)).
- A 10 000-socket rolling-restart test on a 2-node cluster in the chaos and load harness.

## Implementation

- [`lib/converger_web/socket_guard.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/socket_guard.ex):
  the `__using__` overrides and the checks. Used by `ConvergerWeb.UserSocket` and `ConvergerWeb.ConvergerSocket`.
- [`lib/converger_web/drain.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/drain.ex): the
  drain flag (`:persistent_term`), the shutdown gate and `drainer_config/0` (the `drainer:` MFA on both socket
  mounts).
- [`lib/converger_web/plugs/health.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/health.ex):
  `/health/live` and `/health/ready`.
- [`lib/converger_web/endpoint.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/endpoint.ex):
  `max_frame_size`, `timeout`, `error_handler`, `drainer` on both socket mounts.
- Config: `config :converger, :websocket` (`WS_*` variables) and `:websocket_max_frame_size`.
- Tests: `test/converger_web/channels/socket_guard_test.exs` runs real WebSockets against a Bandit listener through
  `test/support/ws_test_client.ex`; `test/converger_web/plugs/health_test.exs`.

## Links

- [WebSocket limits and draining](../operations/websocket-limits.md)
- [WebSocket: limits and disconnects](../websocket.md#limits-and-disconnects)
- [Converger Protocol v1, limits and errors](../protocol/v1.md)
- [Deployment](../deployment.md)
