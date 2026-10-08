---
title: "ADR-0013: Cluster-wide rate limiting with Hammer 7 ETS counters replicated over PubSub"
sidebar_label: "0013 Rate limiting"
description: Hot paths and logins are rate limited with node-local Hammer 7 fixed-window counters whose increments are batched and broadcast to every node over Phoenix.PubSub, instead of Redis or Postgres buckets.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#13](https://github.com/AimTune/converger/issues/13) |
| **Pull request** | [#83](https://github.com/AimTune/converger/pull/83) |
| **Related** | [ADR-0009](0009-inbound-signature-scheme-and-per-channel-enforcement.md), [ADR-0011](0011-custom-trusted-proxies-plug.md), [ADR-0023](0023-platform-and-dependency-baseline.md) |

Converger protects shared resources (the database pool, the Oban `deliveries` queue) from a single noisy tenant, a leaked channel secret or a password-guessing script. This ADR records where limits apply, how they are keyed, which backend stores the counters, and why Redis and Postgres were rejected in favor of in-memory counters replicated between nodes.

## Context and problem statement

Before [#83](https://github.com/AimTune/converger/pull/83):

- The tenant rate limit in `ConvergerWeb.ActivityController` was **commented out**. The Converger API `ActivityController`, `UploadController` and `InboundController` had no limits at all. One tenant, or anyone holding a leaked channel secret, could saturate the DB pool and the Oban queue for every other tenant.
- `Hammer.Backend.ETS` keeps counters per node. With N nodes behind a load balancer every limit was effectively multiplied by N, and counters reset on every deploy.
- Converger token generation was limited per IP only, so tenants behind one NAT shared a bucket while one abusive tenant could rotate IPs.
- The admin and tenant portal login forms (`AdminSessionController`, `TenantSessionController`) had no throttling at all, which allowed online password brute force.
- Hammer 6.x was end of life; Hammer 7 has a different API (`use Hammer`), so an upgrade was needed anyway.

## Decision drivers

- Limits must hold across nodes, not per node.
- The check must be cheap: it runs on the hottest paths (activity create, inbound webhooks) and must not add load to the resources it protects.
- No mandatory new infrastructure; Postgres is the only required dependency today.
- Per-tenant overrides stored in the database.
- Standard 429 responses with `Retry-After`, and telemetry for every rejection.
- Inbound floods must be rejected before any database work, including before the channel is loaded and the signature checked.

## Considered options

1. **Hammer 7 ETS counters with PubSub replication** - every node counts locally in ETS and broadcasts batched deltas to the other nodes over `Phoenix.PubSub`.
2. **Hammer with a Redis backend** (`hammer_backend_redis`) - a single shared counter store.
3. **Postgres token bucket** - counters in a table, updated per request.
4. **Hammer Mnesia backend** (`hammer_backend_mnesia`) - counters in a replicated Mnesia table.
5. **Local ETS only** (Hammer 7, no sync) - correct on one node.

### Pros and cons of the options

**Option 1: ETS + PubSub replication**

- Good: no new infrastructure; reuses the Erlang distribution that `DNS_CLUSTER_QUERY` already sets up and the PubSub server the app already runs.
- Good: one ETS update per request; replication is batched (one broadcast per node every 100 ms), not per hit.
- Good: degrades to per-node limits on a netsplit instead of failing requests.
- Bad: eventually consistent. A burst can overshoot by what the other nodes accept within one sync interval (plus PubSub latency).
- Bad: counters are in memory; a restarted node starts empty for the current window and catches up on the next sync.
- Bad: fixed windows are aligned to wall-clock time, so node clocks must be NTP-synchronized.

**Option 2: Redis**

- Good: exact global counters; mature Hammer backend.
- Bad: requires Redis infrastructure that Converger does not otherwise need.
- Bad: a network round trip on every rate-limited request.
- Bad: Redis becomes a new availability dependency for every API call (fail open or fail closed has to be decided).

**Option 3: Postgres token bucket**

- Good: no new infrastructure; exact; survives restarts.
- Bad: adds a database write to every request on exactly the paths the limits are meant to protect (DB pool, Oban). Under attack the limiter itself would exhaust the pool.
- Bad: hot rows per tenant create lock contention.

**Option 4: Mnesia**

- Good: replicated, no external service.
- Bad: synchronous replicated transactions on every hit are expensive; Mnesia netsplit recovery needs manual handling; adds operational knowledge most operators lack.

**Option 5: local ETS only**

- Good: simplest, exact on a single node.
- Bad: does not satisfy the cross-node requirement. Kept as the default for single-node deployments.

## Decision

Chosen option: **"Hammer 7 ETS counters with batched PubSub replication"**, with the local-only mode as the default when no cluster is configured. The PR text states the reasoning directly: Redis was rejected because it is exact but "needs Redis infrastructure plus a round trip per request"; a Postgres token bucket was rejected because "it adds a DB write to every request on the very paths the limits protect (DB pool, Oban)". ETS plus PubSub needs no new infrastructure and costs one ETS update per request. The accepted price is eventual consistency.

How it works:

- `Converger.RateLimit.Local` is a Hammer 7 module (`use Hammer, backend: :ets, algorithm: :fix_window`). Windows are `div(now_ms, scale_ms)`, so every node maps a hit to the same window.
- With `backend: :cluster`, every local hit is also recorded as a pending delta in an ETS table owned by `Converger.RateLimit.ClusterSync`. Every `sync_interval_ms` (default 100) the deltas are drained and broadcast with `Phoenix.PubSub.broadcast_from/4` on `"converger:rate_limit"`. Receivers add them to their own counters. Deltas for a window that has already ended are dropped on both sides.
- The backend is chosen by `RATE_LIMIT_BACKEND=local|cluster`. When unset, it is `cluster` if `DNS_CLUSTER_QUERY` is set, and `local` otherwise.
- `ConvergerWeb.Plugs.RateLimit` takes `bucket:` and `scope:` (`:ip`, `:tenant`, `:channel`). Denials return 429 with `Retry-After` in seconds and emit `[:converger, :rate_limit, :exceeded]` telemetry (`bucket`, `key`, `limit`, `scale_ms`, `retry_after_ms`), exported as the Prometheus counter `converger_rate_limit_exceeded_count{bucket}`.
- Limit resolution order: tenant override in `tenants.limits`, then `config :converger, Converger.RateLimit, limits: %{...}`, then a caller default, then the built-in defaults. Only `activity_create`, `upload`, `inbound` and `token_generate` are overridable per tenant.
- Tenant overrides are cached per node in ETS (`Converger.RateLimit.Overrides`, 30 s TTL) because limits are checked before the request touches the database. `Tenants.update_tenant_limits/3` validates the map, writes an audit log when an actor is given, and invalidates the cache on every node over PubSub.
- **Login lockout** (`Converger.RateLimit.LoginThrottle`): only failed attempts are counted, per client IP and per account. `peek/3` checks both counters **before** the password is verified, so once either reaches the limit even a correct password is rejected with 429 until the window ends. Successful logins are not counted.

Default buckets:

| Bucket | Default | Keyed by | Endpoints |
| --- | --- | --- | --- |
| `activity_create` | 100 per second | tenant | both activity create APIs (shared budget) |
| `upload` | 10 per second | tenant | Converger upload |
| `inbound` | 500 per second | channel (path param) | inbound and status webhooks, checked before any DB work |
| `token_generate` | 10 per minute | channel | Converger token generate and refresh (was per IP) |
| `token_create` | 10 per minute | IP | legacy `/api/v1/tokens` (unauthenticated) |
| `login_ip` | 5 failures per minute | IP | admin and portal login |
| `login_account` | 5 failures per minute | account | admin and portal login |

## Consequences

### Positive

- Limits apply across the cluster with no Redis and no extra database load.
- Inbound floods are rejected by channel id before the channel is loaded or its signature verified ([ADR-0009](0009-inbound-signature-scheme-and-per-channel-enforcement.md)), so signature checking cannot be used as a CPU amplifier.
- Online password guessing is capped at 5 attempts per minute per IP and per account.
- Per-IP buckets are meaningful behind proxies because the client IP is resolved by [ADR-0011](0011-custom-trusted-proxies-plug.md).
- Rejections are observable through telemetry and Prometheus.
- The Hammer 6 to 7 upgrade moved off an end-of-life release and removed `poolboy` from the lock file (the wider dependency baseline is in [ADR-0023](0023-platform-and-dependency-baseline.md)).

### Negative and trade-offs

- **Eventual consistency**: a burst can exceed a limit by what the other nodes accept within one sync interval.
- A restarted node starts with empty counters for the current window; a deploy briefly loosens limits.
- Clock skew between nodes shifts window boundaries; NTP is required.
- A netsplit falls back to per-node limits (N times the configured limit).
- **Per-account lockout can be triggered by anyone who knows the account identifier**, a bounded denial of service; the one-minute window keeps it short.
- **Breaking on deploy**: limits that were previously off are now on. Tenants with higher legitimate traffic need an override before the upgrade. The Converger token limit moved from per IP to per channel.
- Fixed windows allow up to twice the limit across a window boundary; a sliding window or token bucket would be smoother but costlier.

### Follow-ups

- [#29](https://github.com/AimTune/converger/issues/29): a two-node test suite in CI (booting real peers) to verify shared limits beyond the in-process `ClusterSyncTest`.
- [#31](https://github.com/AimTune/converger/issues/31): per-channel outbound (provider) rate limits, circuit breakers and tenant-fair queueing.
- [#24](https://github.com/AimTune/converger/issues/24) and [#27](https://github.com/AimTune/converger/issues/27): WebSocket send backpressure and connection limits, which are not covered by these HTTP plugs.
- [#52](https://github.com/AimTune/converger/issues/52): further auth hardening (2FA, session expiry) on top of the login lockout.

## Implementation

- Facade and defaults: [`lib/converger/rate_limit.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/rate_limit.ex) (`check/3`, `peek/3`, `record/3`, `limit_for/2`).
- Counters: [`lib/converger/rate_limit/local.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/rate_limit/local.ex).
- Replication: [`lib/converger/rate_limit/cluster_sync.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/rate_limit/cluster_sync.ex).
- Overrides cache: [`lib/converger/rate_limit/overrides.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/rate_limit/overrides.ex).
- Login lockout: [`lib/converger/rate_limit/login_throttle.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/rate_limit/login_throttle.ex), used by `AdminSessionController` and `TenantSessionController`.
- Supervision (backend stored in `:persistent_term`, `ClusterSync` started only for `:cluster`): [`lib/converger/rate_limit/supervisor.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/rate_limit/supervisor.ex).
- Plug: [`lib/converger_web/plugs/rate_limit.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/rate_limit.ex), applied in `ActivityController`, `Converger.ActivityController`, `Converger.UploadController`, `Converger.TokenController`, `TokenController` and `InboundController`.
- Metric: `counter("converger.rate_limit.exceeded.count", tags: [:bucket])` in [`lib/converger_web/telemetry.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/telemetry.ex).
- Migration: [`priv/repo/migrations/20261009130000_add_limits_to_tenants.exs`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261009130000_add_limits_to_tenants.exs) (`tenants.limits`, `NOT NULL DEFAULT '{}'`).
- Config: `config :converger, Converger.RateLimit, backend: :local, sync_interval_ms: 100, override_cache_ttl_ms: 30_000, limits: %{}` in [`config/config.exs`](https://github.com/AimTune/converger/blob/main/config/config.exs); `RATE_LIMIT_BACKEND` and `RATE_LIMIT_SYNC_INTERVAL_MS` in [`config/runtime.exs`](https://github.com/AimTune/converger/blob/main/config/runtime.exs).

Example tenant override (stored in `tenants.limits`):

```json
{"activity_create": {"limit": 200, "scale_ms": 1000}}
```

Tests: [`test/converger/rate_limit_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/rate_limit_test.exs); [`test/converger/rate_limit/cluster_sync_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/rate_limit/cluster_sync_test.exs) runs two sync processes with separate counter tables on one topic ("node A" and "node B", see `test/support/rate_limit_node_b.ex`) and checks that hits count across both, that deltas are batched and that stale windows are dropped; [`test/converger_web/controllers/rate_limiting_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/rate_limiting_test.exs) covers login lockout (per account even with the right password afterwards, per IP across accounts) and per-tenant overrides end to end; [`test/converger_web/plugs/rate_limit_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/plugs/rate_limit_test.exs) covers the plug.

## Links

- Issue [#13](https://github.com/AimTune/converger/issues/13), pull request [#83](https://github.com/AimTune/converger/pull/83)
- [Deployment: rate limiting section](../deployment.md)
