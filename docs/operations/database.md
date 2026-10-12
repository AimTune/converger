---
title: Database pools and pressure
description: The interactive and background connection pools, how to size them against Postgres max_connections and PgBouncer, and how Converger degrades when the database is slow or unavailable (503 + Retry-After, WebSocket errors, readiness).
sidebar_position: 8
---

Every request path needs Postgres. When it is slow or briefly unavailable (a burst of inbound webhooks, a long query,
a failover), Converger answers with **retryable errors** instead of crashing, keeps background work from starving
requests, and tells the load balancer to send traffic elsewhere. Nothing that was acknowledged is lost: a request
answered `503` was not committed, and the client retries it with the same idempotency key.

The design is recorded in [ADR-0044](../adr/0044-bulkheaded-pools-and-graceful-degradation-under-database-pressure.md)
(issue [#35](https://github.com/AimTune/converger/issues/35)).

## Two pools

`Converger.Repo` runs two connection pools on each node:

| Pool | Used by | Size | `queue_target` / `queue_interval` | Query `timeout` |
| --- | --- | --- | --- | --- |
| **interactive** | HTTP requests, WebSockets, SSE, LiveView | `POOL_SIZE` (10) | `DB_QUEUE_TARGET_MS` (50 ms) / `DB_QUEUE_INTERVAL_MS` (1 s) | `DB_TIMEOUT_MS` (15 s) |
| **background** | Oban: every job (deliveries, retention, ...) and Oban's own queries | `BACKGROUND_POOL_SIZE` (10) | `BACKGROUND_DB_QUEUE_TARGET_MS` (500 ms) / `BACKGROUND_DB_QUEUE_INTERVAL_MS` (5 s) | `BACKGROUND_DB_TIMEOUT_MS` (60 s) |

The pools are a **bulkhead**: 46 Oban workers (the default queue limits) competing for 10 connections wait on their own
pool and can never take the connections a WebSocket join needs. Jobs may queue longer than requests, because nobody
is waiting on them interactively.

`BACKGROUND_POOL_SIZE=0` turns the background pool off: everything shares the interactive pool, as before #35. Dev
runs both pools (20 + 10); the test suite shares one sandboxed pool.

Not routed to the background pool: processes a job starts itself (`Task.async/1`), and the optional Broadway pipeline
backend. They use the interactive pool.

## Sizing

Per node, Converger opens `POOL_SIZE + BACKGROUND_POOL_SIZE` connections plus one for Oban's `LISTEN/NOTIFY` notifier.
Across the deployment:

```text
replicas x (POOL_SIZE + BACKGROUND_POOL_SIZE + 1)  +  1 (bin/migrate)  <  max_connections - superuser_reserved_connections - headroom
```

For example, 3 replicas with the defaults use 3 x 21 + 1 = 64 connections, comfortably below the Postgres default of
100. With an HPA, use `maxReplicas`.

- Raise `POOL_SIZE` when the interactive wait (`converger_repo_pool_queue_time_ms`) is often above a few milliseconds
  under normal load, not only during incidents.
- Raise `BACKGROUND_POOL_SIZE` when deliveries lag and `converger_background_repo_query_queue_time` is high. More
  connections only help while Postgres has CPU and I/O to spare; otherwise lower the Oban queue limits instead.
- More connections than Postgres can serve make every query slower. Prefer more replicas behind PgBouncer to very
  large pools.

### PgBouncer

Put PgBouncer in front of Postgres when `replicas x connections` grows past what Postgres handles well. Use **session
mode**:

- Oban's default notifier uses `LISTEN/NOTIFY`, which does not work through transaction pooling: jobs would only be
  picked up by polling, and cron and pause/resume signals would not reach other nodes.
- Migrations take a session-level advisory lock (`migration_lock: :pg_advisory_lock`, see
  [Migrations](migrations.md)).

If you must use transaction mode, run `bin/migrate` directly against Postgres, switch Oban to the `Oban.Notifiers.PG`
notifier (it needs [clustering](clustering.md)), and disable prepared statements (`prepare: :unnamed` in the repo
config).

## Under pressure

A pool checkout that waits longer than `queue_target`, for a whole `queue_interval`, is dropped with
`DBConnection.ConnectionError`; so is a query that runs past `timeout` or loses its connection. Converger turns that
error into a retryable answer on every interactive path:

| Path | Answer |
| --- | --- |
| HTTP (REST, inbound webhooks, admin) | `503 Service Unavailable`, `Retry-After: <s>`, body `{"errors": {"detail": "Service Unavailable", "code": "database_unavailable"}}`. No `500`, no crash report. |
| WebSocket upgrade (`/socket/converger`) | `503` with `Retry-After`, as while draining; the `phoenix` client reconnects with backoff. |
| Phoenix binding join (`converger:conversation:*`, `converger:channel:*`) | Join error `{"reason": "unavailable", "retry_after_ms": N}`. |
| Phoenix binding replay on join, gap fill | Still joined; event `error` `{"code": "replay_unavailable", "watermark": ..., "retry_after_ms": N}`. Live activities keep flowing. |
| Phoenix binding events (`postActivity`, `ack`, `read`, ...) | Reply `{"reason": "unavailable", "retry_after_ms": N}`; v1 `frame` sends get the `error` frame `unavailable` with the `clientId`. |
| Native v1 WebSocket `hello` | `error` `unavailable`, then close **1013** (try again later). |
| Native v1 replay, `sync`, gap fill | `welcome` and live frames as usual, plus `error` `replay_unavailable` with `details.watermark`; the client `sync`s later. |
| Native v1 frames (sends, `read`, ...) | `error` `unavailable` with `retryAfterMs` (and the `clientId` of a send). |
| Server-Sent Events stream | Before the stream starts: `503`. During it (replay, gap fill): an `error` `unavailable` event, then the stream ends and `EventSource` reconnects with `Last-Event-ID`. |
| Oban jobs | The job fails and Oban retries it with backoff (a delivery is never lost: it stays in `oban_jobs`). |

`Retry-After` / `retryAfterMs` is `DB_RETRY_AFTER_MS` (1 s) jittered up to twice that, so clients do not come back
in lockstep. The client-side view is in [WebSocket](../websocket.md#limits-and-disconnects) and
[Protocol v1](../protocol/v1.md#62-replay).

Each occurrence increments `converger_db_unavailable_count{source="http"|"socket"|"channel"|"protocol"|"sse"}`, and at most one
warning per second is logged, so an outage does not flood the logs.

Not covered: the deprecated legacy socket (`conversation:*` on `/socket/websocket`) and connected LiveView processes
still crash and reconnect on a database error, as before.

## Readiness

`GET /health/ready` adds a `pool` check: it fails while the interactive pool's **average wait** over the last
`DB_QUEUE_WINDOW_MS` (5 s) is at least `READY_DB_QUEUE_MS` (200 ms). The node still works, but readiness answers `503`
with status `degraded`, so the load balancer sends new traffic to less loaded replicas:

```json
{
  "status": "degraded",
  "reasons": ["database pool saturated"],
  "checks": {"database": "ok", "draining": "ok", "migrations": "ok", "oban": "ok", "pool": "error"}
}
```

When the database itself is unreachable, the `database` check (`SELECT 1` within 1 s) fails and the status is
`unavailable`. Liveness never touches the database, so an outage never makes Kubernetes restart the pods.

If every replica shares one overloaded database, all of them may report `degraded` together and the load balancer
has nowhere to send traffic. Kubernetes then removes every endpoint from the Service until the wait drops. Raise
`READY_DB_QUEUE_MS`, or set it to `0` to disable the check, if you would rather keep serving slowly than shed load.

## Metrics

| Metric | Meaning |
| --- | --- |
| `converger_repo_pool_queue_time_ms` | Average interactive pool wait over the last window (what readiness checks). |
| `converger_repo_query_queue_time` | Wait of the last interactive query. |
| `converger_background_repo_query_queue_time` | Wait of the last background (Oban) query. |
| `converger_db_unavailable_count` | Answers turned into retryable errors, by `source`. |

See [Observability](observability.md) for scraping.

## Chaos test

`CHAOS_MODE=db_pause test/chaos/run.sh` freezes the Postgres container for 10 s (`docker pause`) while REST and
WebSocket clients send messages. It fails when an acknowledged message is lost, when any REST answer is a 5xx other
than `503`, or when the app container restarted; it reports how long readiness took to recover. See
[Chaos testing](../chaos.md#database-pause).
