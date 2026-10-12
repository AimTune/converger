---
title: "ADR-0044: Bulkheaded connection pools and graceful degradation under database pressure"
sidebar_label: "0044 Database pressure"
description: Oban runs on a second pool of the same repo, every interactive path answers a dropped or timed-out checkout with a retryable error (503 + Retry-After, WebSocket unavailable / replay_unavailable) instead of crashing, and readiness reports degraded while the interactive pool's average wait is above a threshold.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-12 |
| **Issue** | [#35](https://github.com/AimTune/converger/issues/35) |
| **Pull request** | [#137](https://github.com/AimTune/converger/pull/137) |
| **Related** | [ADR-0001](0001-transactional-outbox-with-oban.md), [ADR-0027](0027-websocket-limits-backpressure-and-draining.md), [ADR-0030](0030-native-websocket-endpoint-and-fallback-transports.md), [ADR-0037](0037-libcluster-clustering-health-endpoints-and-metrics-on-the-main-port.md) |

The operator documentation is [Database pools and pressure](../operations/database.md); the client-facing behaviour
is in [WebSocket](../websocket.md) and [Protocol v1](../protocol/v1.md#62-replay).

## Context and problem statement

Every request path (REST, WebSocket joins, inbound webhooks, LiveView) and every Oban job shared one Ecto pool
(`POOL_SIZE`, 10 in production), with the default `queue_target` / `queue_interval` and no handling of pool errors.
A slow query or a burst of inbound webhooks, each of which enqueues delivery jobs, exhausted the pool:

- requests failed with `DBConnection.ConnectionError`, which Phoenix renders as **500** with a crash report;
- WebSocket joins and replays raised in the channel process, the channel crashed, the client rejoined at once and
  added load;
- Oban's 46 workers (the default queue limits) competed with requests for the same 10 connections;
- readiness only ran `SELECT 1`, which usually still succeeds while the pool is saturated, so the load balancer kept
  sending traffic to the overloaded node.

## Decision drivers

- No acknowledged message may be lost, and an unacknowledged one must be safe to retry (idempotency keys and
  `clientId`s already make retries safe).
- Saturation must produce retryable answers (`503`, `retryAfterMs`), not `500`s, crashes and reconnect storms.
- Background work must not be able to starve interactive traffic.
- No new infrastructure dependency; the default deployment (one Postgres, optional PgBouncer) keeps working.
- Operators can size and turn off each part.

## Considered options

For the bulkhead:

1. **One pool, larger** - raise `POOL_SIZE`.
2. **A second Repo module for Oban** (`Converger.ObanRepo`, `repo:` in the Oban config).
3. **A second instance of the same Repo** (a dynamic repo), used by Oban (`get_dynamic_repo`) and by every job
   process (`put_dynamic_repo/1` from the `[:oban, :job, :start]` telemetry event).
4. **`pool_count`** - several pools behind one repo.

For pool errors on the request path:

1. **`Plug.Exception` implementation** for `DBConnection.ConnectionError` with status 503.
2. **A plug wrapping the router** that rescues the error and sends `503` itself.
3. **Rescue in every controller** (`action_fallback`).

For readiness:

1. **Keep `SELECT 1` only.**
2. **Fail readiness while the average pool wait is above a threshold** (`degraded`).

### Pros and cons of the options

#### One pool, larger

- Good, because it is a configuration change.
- Bad, because jobs still take the connections requests need, and more connections than Postgres can serve make
  every query slower.

#### A second Repo module for Oban

- Good, because Oban's own queries (fetching, acking, plugins) get their own pool.
- Bad, because the jobs' business code calls `Converger.Repo` everywhere: deliveries, retention and conversation
  expiry would still use the interactive pool, unless every context took the repo as a parameter.

#### A second instance of the same Repo

- Good, because Oban's queries and every query a job makes, through the existing contexts, use the background pool
  with no change to them; `put_dynamic_repo/1` is per process, and Oban runs each job in its own process.
- Good, because each instance has its own `pool_size`, `queue_target`, `queue_interval` and `timeout`, and its own
  telemetry prefix (`[:converger, :background_repo]`).
- Bad, because processes a job starts (`Task.async/1`) do not inherit the dynamic repo, and the Broadway backend is
  not routed. Both use the interactive pool.

#### `pool_count`

- Good, because it reduces contention on the pool's queue.
- Bad, because it is not a bulkhead: every caller picks any of the pools.

#### `Plug.Exception` implementation

- Good, because it is a few lines.
- Bad, because Phoenix still re-raises the exception after rendering, so the adapter logs a crash report, and the
  error view cannot set `Retry-After`.

#### A plug wrapping the router

- Good, because one place covers every route, sets `Retry-After`, logs a throttled warning instead of a crash
  report, and re-raises everything else (and errors after a streamed response was sent) untouched.
- Bad, because the endpoint plugs in front of the router (`ConvergerWeb.Plugs.Health` has its own handling) and
  socket upgrades are outside it, so sockets need their own handling.

#### Rescue in every controller

- Bad, because every new controller would have to remember it.

#### Readiness on the pool wait

- Good, because the load balancer sheds load from a saturated node before its requests start failing.
- Bad, because when every replica shares one overloaded database, all of them report `degraded` together and the
  Service has no endpoints. The threshold is configurable and `0` disables the check.

## Decision

- **Bulkhead: a second instance of `Converger.Repo`** (`Converger.Repo.Pools`), registered as
  `Converger.Repo.Background`, with longer queue targets and timeout (500 ms / 5 s / 60 s against 50 ms / 1 s /
  15 s). Oban uses it through `get_dynamic_repo`, and a `[:oban, :job, :start]` handler switches each job process
  to it. `BACKGROUND_POOL_SIZE=0` restores one shared pool.
- **Retryable errors on every interactive path** (`Converger.Repo.Pressure` classifies and reports):
  - HTTP: `ConvergerWeb.Plugs.DbUnavailable` wraps the router: `503`, `Retry-After`, body code
    `database_unavailable`.
  - Socket upgrade (`ConvergerSocket.connect/3`): `{:error, :database_unavailable}`, answered `503` with
    `Retry-After` by `ConvergerWeb.SocketGuard`, as while draining.
  - Phoenix binding: a join or event fails with `{"reason": "unavailable", "retry_after_ms": N}`. A **replay that
    fails does not fail the join**: the socket stays joined, keeps its position and pushes the event `error`
    `{code: "replay_unavailable", watermark}`; the client fetches the gap again later.
  - Native v1 WebSocket: `error` `unavailable` (retryable, error number 9001 already existed) for frames; `hello`
    closes with **1013**; a failed replay or `sync` starts or keeps the session with the new `error`
    `replay_unavailable` (9002, `details.watermark`) and the client `sync`s from that watermark.
  - SSE: a failed replay or gap fill ends the stream with `error` `unavailable`; `EventSource` reconnects with
    `Last-Event-ID`.
  - `Retry-After` / `retryAfterMs` is `DB_RETRY_AFTER_MS` jittered up to twice its value.
- **Readiness `pool` check**: `degraded` (503) while the interactive pool's average `queue_time` over a 5 s window
  is at least 200 ms. Liveness still never touches the database.

## Consequences

### Positive

- The chaos test pauses Postgres for 10 s under REST and WebSocket load with zero acknowledged messages lost, no
  `5xx` other than `503`, no restart, and readiness back within seconds of the unpause (results in
  [Chaos testing](../chaos.md#database-pause)).
- A burst of background work queues on its own pool; interactive requests keep their connections.
- Clients get one retry contract everywhere: a retryable error with a jittered delay.

### Negative and trade-offs

- Each node opens up to `POOL_SIZE + BACKGROUND_POOL_SIZE + 1` connections instead of `POOL_SIZE + 1`: 21 instead
  of 11 with the defaults. Deployments near `max_connections` must re-check their sizing on upgrade (or set
  `BACKGROUND_POOL_SIZE=0`).
- After `replay_unavailable` the client receives live frames before the gap is filled, so it must place frames by
  `seq` and keep the older watermark as its resume point until the gap is fetched.
- The deprecated legacy socket and connected LiveView processes still crash and reconnect on a database error.
- The test build compiles a `prepare_query/3` hook into `Converger.Repo` (`Converger.RepoFaults`) to inject
  connection errors; production code does not have it.

### Follow-ups

- Route the Broadway pipeline backend to the background pool when it becomes the default.
- Remove the legacy socket ([#23](https://github.com/AimTune/converger/issues/23)), which is not covered.

## Implementation

- `lib/converger/repo/pools.ex` (bulkhead), `lib/converger/repo/pressure.ex` (classification, reporting, pool
  wait window), `lib/converger_web/plugs/db_unavailable.ex` (HTTP), `ConvergerWeb.ConvergerSocket`,
  `ConvergerWeb.ConvergerChannel`, `ConvergerWeb.ProtocolSocket`, `ConvergerWeb.ConvergerAPI.EventStreamController`
  (sockets and streams), `Converger.Health` (`pool` check).
- Configuration: `config :converger, Converger.Repo.Pools` and `Converger.Repo.Pressure`; environment variables
  `BACKGROUND_POOL_SIZE`, `DB_QUEUE_TARGET_MS`, `DB_QUEUE_INTERVAL_MS`, `DB_TIMEOUT_MS`, `BACKGROUND_DB_*`,
  `DB_RETRY_AFTER_MS`, `READY_DB_QUEUE_MS`, `DB_QUEUE_WINDOW_MS`.
- Metrics: `converger.repo.pool.queue_time_ms`, `converger.background_repo.query.queue_time`,
  `converger.db.unavailable.count{source}`.
- Tests: `test/converger/repo/pressure_test.exs`, `test/converger_web/plugs/db_unavailable_test.exs`,
  `test/converger_web/db_pressure_test.exs` (HTTP, readiness, both WebSocket bindings and SSE with injected
  connection errors, `Converger.RepoFaults`), and the chaos harness in mode `db_pause`
  (`CHAOS_MODE=db_pause test/chaos/run.sh`, run nightly next to the kill mode).

## Links

- [Database pools and pressure](../operations/database.md)
- [Configuration reference](../operations/configuration.md#database)
- [Observability](../operations/observability.md#health-endpoints)
- [Chaos testing](../chaos.md#database-pause)
- [DBConnection queue configuration](https://hexdocs.pm/db_connection/DBConnection.html#start_link/2-queue-config)
- [Oban: dynamic repositories](https://hexdocs.pm/oban/Oban.html#start_link/1)
