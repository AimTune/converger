---
title: "ADR-0031: Per-channel circuit breaker on the channel row, priority-based parking, Hammer rate limits and tier queues"
sidebar_label: "0031 Circuit breaker and fair queueing"
description: Each channel has a database-backed delivery circuit breaker whose parked jobs drop to a lower Oban priority, outbound rate limits reuse Hammer with a snooze, and tenants are isolated by tier queues instead of Oban Pro partitions.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-10 |
| **Issue** | [#31](https://github.com/AimTune/converger/issues/31) |
| **Pull request** | [#120](https://github.com/AimTune/converger/pull/120) |
| **Related** | [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md), [ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md), [ADR-0001](0001-transactional-outbox-with-oban.md) |

## Context and problem statement

Every delivery job runs in one shared Oban queue (`deliveries`, 20 workers per node). When a webhook endpoint
is down or WhatsApp answers 429, each delivery to that channel still goes through its whole retry schedule
([ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md)). Each attempt holds a worker until
the adapter times out, so one dead channel with thousands of pending deliveries delays every other tenant
(noisy neighbour). `Converger.Channels.Health` already classified channels as `unhealthy`, but nothing acted
on it. Provider rate limits (Meta: 80 messages/s per phone number by default) were not modelled, so bursts
turned into 429s and retries.

The goal from [#31](https://github.com/AimTune/converger/issues/31): with one dead webhook channel and 10k
pending deliveries, deliveries to a healthy channel of another tenant keep p95 below 1 s. Breaker changes
must be visible in the admin UI and in metrics.

## Decision drivers

- Breaker state must be consistent across nodes; a cluster ([#29](https://github.com/AimTune/converger/issues/29)) must not run one breaker per node.
- No message may be lost or dead-lettered because a channel was paused or broken; parking must not use up delivery attempts.
- A healthy channel must not wait behind parked jobs of a dead one, even in the same queue.
- No new infrastructure and no commercial dependency (Oban Pro).
- Parked jobs must cost almost nothing, and recovery must be immediate rather than waiting out a long snooze.

## Considered options

1. **Breaker state** - `:fuse` / GenServer + ETS per node, or **columns on `channels`** updated with conditional `UPDATE`s.
2. **Parking** - keep retrying with backoff, snooze for the cooldown, or **long snooze at a lower Oban priority with explicit release**.
3. **Rate limit** - a token bucket GenServer per channel, or **the existing Hammer counters** (`Converger.RateLimit`) with a snooze.
4. **Tenant fairness** - Oban Pro partitioned queues, a queue per tenant, or **a queue per tenant tier** (`deliveries_high`, `deliveries`, `deliveries_bulk`).

### Pros and cons of the options

#### Breaker in ETS (`:fuse` or GenServer)

- Good, because reads are memory-fast.
- Bad, because each node has its own breaker: N nodes probe N times, and a pause made from the admin UI on one node does not stop the others.
- Bad, because the state is lost on deploy.

#### Breaker columns on `channels`

- Good, because the worker already loads the channel for every job, so reading the state costs nothing extra.
- Good, because transitions are atomic `UPDATE ... WHERE circuit_state IN (...)`. Exactly one caller opens, probes or closes, and only that caller sends the alert and releases jobs.
- Good, because the state survives restarts and is the same on every node.
- Bad, because every transient failure costs one `UPDATE ... SET consecutive_failures = consecutive_failures + 1`, and every success costs one `UPDATE` that matches no row on the hot path.

#### Parking by long snooze at priority 3

- Good, because Oban fetches by priority first, so new deliveries (priority 1) of healthy channels in the same queue are always taken before parked ones. That bounds the delay that parked jobs can cause.
- Good, because a snooze does not use up an Oban attempt (Oban 2.24 rolls `attempt` back), and the delivery's `attempts` counter is not touched either.
- Good, because a parked job wakes at most once per `park_seconds`. Closing or resuming releases all of them right away with one `UPDATE` on `oban_jobs`, which finds them by priority 3 and `args->>'channel_id'`.
- Bad, because it depends on the snooze ack not overwriting `priority`. The priority is set with a separate `UPDATE` during `perform/1`.
- Bad, because the half-open probe needs a waker: `ChannelCircuitProbeWorker` (unique per channel) wakes one parked job every cooldown.

#### Snooze for the cooldown

- Bad, because 10k parked jobs wake every 30 s and compete with fresh jobs at the same priority.

#### Oban Pro partitioned queues

- Good, because it gives true per-tenant fairness and global limits.
- Bad, because it is a commercial dependency and replaces the engine (`Smart`).

#### A queue per tenant

- Bad, because queues are static configuration and the number of tenants is not bounded.

#### A queue per tier

- Good, because it is plain Oban OSS with a fixed, small number of queues, and an admin chooses the tier.
- Bad, because tenants in the same tier still share workers. In-tier fairness depends on the breaker, the parking priority and rate limits.

## Decision

- **Breaker state on the channel row** (`circuit_state` = `closed` | `open` | `half_open` | `paused`, `circuit_changed_at`, `consecutive_failures`), managed only by `Converger.Channels.Circuit`.
- The breaker opens after `failure_threshold` (default 5) consecutive transient failures, or when the health check moves the channel to `unhealthy`. Only that transition counts, so a closed breaker is not re-opened while the 60-minute window still contains old failures.
- After `cooldown_ms` (default 30 s), one delivery claims `half_open` and is the probe. Success closes the breaker and releases every parked job; failure re-opens it.
- Permanent errors and middleware halts do not count as failures.
- **Parking**: snooze for `park_seconds` (default 600, plus jitter) at priority 3, with the delivery marked `paused`. Closing or resuming releases parked jobs to `available` at priority 1, and their deliveries go back to `pending`.
- **Manual pause/resume**: the same mechanism with state `paused` (never probed). It is available from the admin UI and from `POST /api/v1/channels/:id/pause|resume`, and both actions are audited.
- **Rate limit**: `channels.rate_limit` (`"80/s"`, `"1000/m"`, `"5000/h"`), falling back to an optional adapter `rate_limit/0` callback (WhatsApp Meta `80/s`). It is enforced with `Converger.RateLimit.check/3` (bucket `channel_outbound`), so it is cluster-wide with the cluster backend. A delivery over the limit is snoozed and is not counted as a failure.
- **Tier queues**: `tenants.tier` selects `deliveries_high` (10), `deliveries` (20, default tier, keeps the historical name) or `deliveries_bulk` (5). Delivery job uniqueness uses `fields: [:worker, :args]`, so a tier change cannot create a duplicate job.

The breaker, rate limit and pause are applied in `ActivityDeliveryWorker` before the activity is loaded. A
parked job therefore costs a channel read and two small updates. Outcomes are recorded in `Converger.Pipeline`,
so the Broadway and Inline backends feed the breaker as well, although only the Oban worker parks.

## Consequences

### Positive

- A dead channel's backlog sinks below fresh work in its queue, and once the breaker is open it no longer holds workers for adapter timeouts.
- Recovery is immediate (bulk release) instead of waiting for a long backoff.
- Every node sees the same breaker, pause and probe, with no extra infrastructure.
- Operators get alerts (`channel.circuit_opened` / `channel.circuit_closed` on the tenant alert webhook), live admin UI state and counters (`converger.channel.circuit_*`, `converger.deliveries.parked`, `converger.deliveries.rate_limited`).

### Negative and trade-offs

- Up to `failure_threshold` attempts per channel still run into timeouts before the breaker opens, plus one probe per cooldown.
- Tiers isolate classes of tenants, not individual tenants.
- Releasing parked jobs scans `oban_jobs` on `(state, priority)` and filters on `args`. That is fine for tens of thousands of rows, but very large backlogs may need an index on `args->>'channel_id'`.
- The acceptance target (p95 < 1 s with 10k parked deliveries) follows from fetch-by-priority. It is not yet covered by an automated load test.

### Follow-ups

- [#33](https://github.com/AimTune/converger/issues/33) delivery SLO telemetry and a load test that measures p95 under a dead-channel backlog.
- [#49](https://github.com/AimTune/converger/issues/49) durable, signed platform event webhooks for `channel.circuit_*`.
- [#51](https://github.com/AimTune/converger/issues/51) management API for `rate_limit` and `tier`.

## Implementation

- [`Converger.Channels.Circuit`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/circuit.ex): admission, recording, transitions, parking, release, rate limit.
- [`Converger.Workers.ChannelCircuitProbeWorker`](https://github.com/AimTune/converger/blob/main/lib/converger/workers/channel_circuit_probe_worker.ex) and [`ActivityDeliveryWorker`](https://github.com/AimTune/converger/blob/main/lib/converger/workers/activity_delivery_worker.ex).
- [`Converger.Pipeline.Oban`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline/oban.ex): tier queue selection; `ChannelHealthWorker` trips the breaker.
- Migration `20261010040000_add_circuit_breaker_rate_limit_and_tenant_tier`; config `:circuit_breaker` and the queue list in `config/config.exs`.
- `ConvergerWeb.ChannelDeliveryController` (tenant API), the admin channel and tenant LiveViews.
- Tests: `test/converger/channels/circuit_test.exs`, `test/converger_web/controllers/channel_delivery_controller_test.exs`, `test/converger/workers/channel_health_worker_test.exs`.

## Links

- [Delivery: flow control](../delivery.md#flow-control-circuit-breaker-rate-limits-and-tenant-fairness)
- [Tenant API: channel delivery state](../api/tenant-api.md#channel-delivery-state)
- [Observability](../operations/observability.md)
- [Oban: snoozing jobs](https://hexdocs.pm/oban/Oban.Worker.html#module-snoozing-jobs)
