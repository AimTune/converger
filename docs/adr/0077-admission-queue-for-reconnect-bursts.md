---
title: "ADR-0077: Reconnect bursts wait in a per-node admission queue"
sidebar_label: "0077 Admission queue for reconnect bursts"
description: Protocol v1 handshakes and sync replays wait for one of a bounded number of slots and read the database through one pool checkout, so a drained node's clients queue on the survivors instead of failing in the pool; clients honour retryAfterMs and cap their backoff lower.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-15 |
| **Issue** | [#198](https://github.com/AimTune/converger/issues/198) |
| **Pull request** | (this PR) |
| **Related** | [ADR-0027](0027-websocket-limits-backpressure-and-draining.md), [ADR-0044](0044-bulkheaded-pools-and-graceful-degradation-under-database-pressure.md), [ADR-0049](0049-k6-load-harness-on-the-release-image-with-seq-based-loss-checks.md), [ADR-0059](0059-client-token-keys-revocation-rotation-and-permissions.md) |

## Context and problem statement

The 10 000-socket rolling restart of [#190](https://github.com/AimTune/converger/issues/190)
([results](../benchmarks/2026-10-15-a8dd704-rolling-restart-10k.md)) lost no acknowledged message, but clients took
p95 93.6 s (max 175.5 s) from the drain close to the next `welcome`. ADR-0027 aims for about 30 s.

What happens when a node drains: its sockets are closed with 1012, 500 per second, and reconnect to the other nodes.
Every native v1 `hello` read the database six times, each through its own pool checkout: the channel, the
conversation, the channel again (for the presence setting), the conversation head, the open interrupts and the replay.
Thousands of handshakes within a few seconds therefore put tens of thousands of checkouts into the 20-connection
interactive pool. Once checkouts wait longer than `queue_target` (50 ms) for a whole `queue_interval`, DBConnection
drops them (`DBConnection.ConnectionError`). The #35 degradation (ADR-0044) answers that with `unavailable` and close
1013, or with `replay_unavailable`, both retryable. The clients back off exponentially and try again, while REST sends
fail with 503 in the same pool (42 307 send retries in that run).

Two things in the load harness made it worse than a real deployment:

- A dropped subscriber always reconnected to the *next* node. All sockets of a drained node therefore landed on one
  survivor. That survivor was restarted next, so its own sockets and the ones it had taken over moved on together.
  By the third restart, nearly all 10 000 sockets reconnected to a single node. A load balancer spreads reconnects over
  the nodes that are ready.
- Its backoff ignored the server's `retryAfterMs` and grew to 10 s, drawn from `[b/2, 3b/2]`. A socket that hit an
  overloaded node or the restarting node a few times then sat out up to 15 s between attempts.

Token verification is already free of database reads: signatures are checked in memory, and revocations come from
the per-node cache of ADR-0059.

## Decision drivers

- No acknowledged message may be lost. Ordering, de-duplication and gap filling must not change.
- Under overload, a burst should wait in a queue rather than fail and come back on a client backoff.
- REST and live delivery on a surviving node must keep working while it absorbs a burst.
- Fail fast (ADR-0044) must still apply when the database is actually unavailable.
- Token revocation and channel deactivation must take effect as they do today, with no stale caches.
- No new infrastructure.

## Considered options

1. **Admission queue and one checkout per handshake**: a per-node limit on concurrent handshake and `sync` database
   work. Callers above the limit wait in arrival order, for a bounded time. Each handshake reads through a single pool
   checkout.
2. **Cache channel and conversation lookups** in ETS, invalidated by PubSub.
3. **Pace the drain against the survivors**, for example 100 sockets per second instead of 500.
4. **Larger pools** sized for the reconnect peak (`POOL_SIZE`).
5. **Client-side only**: honour `retryAfterMs` and cap the backoff lower.

### Pros and cons of the options

#### Option 1

- Good, because a burst becomes a short queue on the node. A client that would have been told 1013 and backed off
  for seconds gets its `welcome` as soon as a slot frees up.
- Good, because handshakes can take at most `handshake_concurrency` connections (half the pool by default), and
  they hold one connection each instead of making six checkouts. REST and live traffic keep the rest of the pool.
- Good, because the queue is bounded in time (`handshake_queue_ms`) and length (`handshake_queue_max`). Past those
  bounds the answer is the same retryable `unavailable` / `replay_unavailable` as before, with `retryAfterMs`.
- Good, because nothing is cached, so revocation and deactivation behave exactly as before.
- Bad, because every handshake calls one more process, a GenServer per node. This is negligible next to the
  database reads: the queue handles hundreds of thousands of calls per second.
- Bad, because a waiting handshake blocks its own connection process for up to `handshake_queue_ms`. That process
  has nothing else to do before `welcome`.

#### Option 2

- Good, because it removes reads entirely.
- Bad, because a deactivated channel or a changed presence setting could be served from a stale entry, and a cache
  that is invalidated across nodes needs its own correctness argument. The reads it saves are primary-key lookups on
  a connection the handshake already holds (option 1), so the gain is small.

#### Option 3

- Good, because it spreads the arrivals.
- Bad, because a slower drain only shifts the problem: 10 000 sockets at 100/s take 100 s, longer than
  `drain_shutdown_ms` and most termination grace periods. The jittered `retryAfterMs` (1–6 s) already spreads the
  arrivals for clients that honour it.

#### Option 4

- Good, because it is configuration only.
- Bad, because a burst can always outgrow the pool, and Postgres connections are expensive. It does not change how a
  saturated pool fails.

#### Option 5

- Good, because the server already sends the hint. Honouring it spreads the load, and a lower cap shortens the tail.
- Bad, because on its own the survivors still fail requests under the burst.

## Decision

Chosen: **option 1, together with option 5 in the clients we ship**.

- `ConvergerWeb.Protocol.Admission`, a GenServer started before the endpoint, hands out `handshake_concurrency`
  slots. The default `0` means half the interactive pool, at least 1. Callers that find no free slot queue in arrival
  order. A caller still waiting after `handshake_queue_ms` (10 s), or arriving while `handshake_queue_max` (10 000)
  callers are already waiting, gets `{:error, :overloaded}`. A slot is tied to its caller through a monitor, so it is
  freed when the work returns or raises, and when the caller exits.
- `ConvergerWeb.Protocol.Session` takes a slot for the database work of `hello` and of `sync` and runs it inside one
  `Repo.checkout/1`. Without a slot, `hello` gets `error` `unavailable` with `retryAfterMs` and close 1013, and `sync`
  gets `replay_unavailable` with `details.watermark`. These are the frames a saturated pool produced before, so clients
  need no change. Live frames and their gap fills do not use the queue: they are rare, and the next live frame
  retries a failed gap fill.
- The handshake also reads less. The presence setting comes from the channel row the handshake already loaded, and a
  client whose watermark equals the head skips the replay query. The head is read after the subscription, so anything
  committed later arrives live.
- Clients: the TypeScript SDK's default `maxDelayMs` drops from 30 s to 10 s, and `retryAfterMs` stays a floor. The
  load harness now does what a load balancer and the SDK do. It reconnects to a random other node, takes the
  `retryAfterMs` of the `unavailable` frame before 1013 as a floor, and uses equal jitter capped at 5 s. It would
  also honour the `retryAfterMs` of a 1012 close reason, but k6 1.8's close event does not carry the reason, so
  drained harness sockets reconnect after the backoff alone. That is harsher on the survivors than SDK clients are.

The drain pacing and the #35 fail-fast behaviour of the pool stay as they are.

## Consequences

### Positive

- One handshake makes one checkout instead of six. A burst queues on the node for at most `handshake_queue_ms` instead
  of failing.
- REST sends and live delivery on a survivor keep at least half the pool during a burst.
- Zero loss is unchanged. The replay is skipped only when the watermark equals a head read after subscribing, and
  the feed's ordering and de-duplication are untouched.
- New metric `converger_protocol_admission_wait_ms{result="ok"|"overloaded"}` shows how long handshakes queue.

### Negative and trade-offs

- A node can now hold up to `handshake_queue_max` connections that wait for their `welcome`. Each costs what an open
  connection costs and waits at most `handshake_queue_ms`, which stays below the TypeScript SDK's 15 s connect
  timeout.
- `handshake_concurrency` caps handshake throughput per node. Raise it, or the pool, when handshakes regularly report
  `overloaded` while the database is idle.
- Part of the improvement measured in the harness comes from the harness itself: it no longer piles a drained node's
  sockets onto one survivor. Compare runs made before and after this change with that in mind.

### Follow-ups

- [#198](https://github.com/AimTune/converger/issues/198): re-run the 10 000-socket rolling restart and record it
  under `docs/benchmarks/`.
- The Go, Python and Elixir client SDKs still cap their backoff at 30 s. They should follow the TypeScript SDK.
- The Phoenix binding (`converger:` channel join) and the Server-Sent Events stream do not use the admission queue
  yet. Neither is used by the reconnect benchmark.

## Implementation

- [`lib/converger_web/protocol/admission.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/protocol/admission.ex):
  the queue, started in `Converger.Application` before the endpoint.
- [`lib/converger_web/protocol/session.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/protocol/session.ex):
  `handshake/2` and `sync/2` go through the queue and `Repo.checkout/1`; the presence setting comes from the loaded
  channel; the replay is skipped at the head.
- Config: `handshake_concurrency`, `handshake_queue_ms` and `handshake_queue_max` in `config :converger, :websocket`,
  read from `WS_HANDSHAKE_CONCURRENCY`, `WS_HANDSHAKE_QUEUE_MS` and `WS_HANDSHAKE_QUEUE_MAX`.
- Telemetry: `[:converger, :protocol, :admission]`, exported as `converger_protocol_admission_wait_ms`.
- Clients: `packages/client-ts/src/backoff.ts` (default `maxDelayMs` 10 s), `load/lib/converger.js` (random other
  node, `retryAfterMs` floor, 5 s cap).
- Tests: `test/converger_web/protocol/admission_test.exs` covers limits, FIFO order, expiry, a full queue, and
  release on raise and on exit. `test/converger_web/db_pressure_test.exs` covers a `hello` and a `sync` without a slot,
  a burst that waits instead of failing, and a `hello` at the head that skips the replay.

## Links

- [WebSocket limits and draining](../operations/websocket-limits.md#reconnect-bursts)
- [Database pressure](../operations/database.md)
- [Protocol v1, close codes](../protocol/v1.md)
