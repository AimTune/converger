---
title: Dead-channel isolation
sidebar_label: Dead-channel isolation
description: Measured effect of one tenant's dead webhook channel with a 10,000-delivery backlog on another tenant's delivery latency, on the same tier and on different tiers. Before ADR-0076 the shared queue was blocked for about 35 s; with bulk parking and the per-channel in-flight cap the healthy tenant's p95 stays within the gate.
sidebar_position: 3
---

# Dead-channel isolation

Exit criterion of [epic #59](https://github.com/AimTune/converger/issues/59): *one dead channel does not degrade
other tenants (measured)*. The mechanisms under test are the per-channel circuit breaker, parking at a lower Oban
priority and tier queues of [ADR-0031](../adr/0031-per-channel-circuit-breaker-rate-limit-and-tier-queues.md)
(see [Delivery: flow control](../delivery.md#flow-control-circuit-breaker-rate-limits-and-tenant-fairness)).

:::note Fixed by ADR-0076
Since [ADR-0076](../adr/0076-bulk-parking-and-per-channel-in-flight-cap.md) (#191) the shared-tier run can pass: the
healthy tenant's p95 was **104 ms** against a 67 ms baseline (gate 117 ms), p99 142 ms, max 321 ms, no message lost (a second, noisier run measured p95 535 ms).
See [After ADR-0076](#after-adr-0076). The results below are the original measurement, before the fix.
:::

**Result before the fix: not met when the two tenants share a tier.** The breaker does its job: of 10,000 deliveries to the dead
channel only 23 requests ever reached the provider, and once the backlog is parked the healthy tenant's latency is
back to its baseline. But while the dead channel's backlog is still ahead of the healthy tenant's jobs in the shared
queue, about 35 seconds after the backlog appears, the healthy tenant's deliveries wait up to 13-17 s. With the
dead tenant on another tier (its own queue) the healthy tenant is not blocked; what remains is load on the shared
node and database.

## Scenario

`load/run.sh` scenario `dead_channel` (opt-in, not in the default list), on the release image, one node, native
backbone. Two tenants:

- **healthy**: one outbound webhook channel to the mock provider (`/hook/healthy`, answers after 20-30 ms). 50
  conversations, each posting 1 message/s over the REST API for 90 s (50 messages/s). The mock provider records the
  send → delivery latency of every message.
- **dead**: one outbound webhook channel to `/hook/hang-dead`, which accepts the request and never answers, so
  every attempt runs into the webhook adapter's 10 s receive timeout. Its backlog: 10,000 activities created
  through `Converger.Activities.create_activity/2` (each enqueues its delivery job in the same transaction), by 10
  concurrent processes, while the healthy tenant sends.

The script runs two phases back to back on the same stack: **baseline** (the healthy tenant alone) and **dead**
(the same traffic while the dead tenant's backlog is created). Every second it samples the dead channel's breaker
state and its jobs (executing, waiting at normal priority, parked). Configuration is the default: queue
`deliveries` with 20 workers, `failure_threshold` 5, `cooldown_ms` 30 s, `park_seconds` 600.

```bash
LOAD_SCENARIOS=dead_channel load/run.sh                      # both tenants on the default tier
LOAD_SCENARIOS=dead_channel LOAD_DEAD_TIER=bulk load/run.sh  # dead tenant on the bulk tier (own queue)
```

Knobs: `LOAD_DEAD_CONVERSATIONS` (50), `LOAD_DEAD_RATE` (1 message/s per conversation), `LOAD_DEAD_DURATION_S`
(90), `LOAD_DEAD_BACKLOG` (10,000), `LOAD_DEAD_BACKLOG_CONCURRENCY` (10), `LOAD_DEAD_TIER` (`default`). The
`smoke` profile uses 10 conversations, 30 s and a backlog of 1,000.

**Pass criterion**: the healthy tenant's p95 in the dead phase is at most **20 % or 50 ms above the baseline p95,
whichever is larger** (`load/results.js`, check `dead_channel: healthy tenant p95 with a dead channel within
tolerance of the baseline`). 20 % is the regression threshold of the nightly gate; the 50 ms floor keeps a 30 →
45 ms change on a 20-30 ms mock provider from counting, while anything a dead channel causes through the shared
queue is measured in adapter timeouts (10 s). The p95 is over every message of the phase, including those sent
while the breaker was opening: the criterion is about other tenants, and they also send during that time. The run
also checks that every healthy-tenant message was delivered exactly once and that the breaker opened.

## Results

Measured on 2026-10-15 at `772e42e` (`main`) plus this scenario, on Windows 11 with Docker Desktop (WSL 2), 12 vCPUs
and 31 GiB visible to Docker, no per-node limits, Postgres 17.11, pool 20 + 10 background. **The machine was not
quiet**: another project's stack (7 containers: an app, Postgres, Grafana, Loki, Jaeger, Prometheus, an OTel
collector) started during these runs, which shows in the noisy baseline of the shared-tier run. The comparison is
within each run (baseline and dead phase back to back), and the shared-tier result was the same on a quieter
earlier run (below).
Raw results: `load/results/2026-10-15-dead-channel-shared-tier.json` and
`load/results/2026-10-15-dead-channel-separate-tier.json`.

| Healthy tenant, send → provider | Shared tier: baseline | Shared tier: dead channel | Separate tier: baseline | Separate tier: dead channel |
| --- | --- | --- | --- | --- |
| Dead tenant's tier (queue, workers) | | `default` (`deliveries`, 20, shared) | | `bulk` (`deliveries_bulk`, 5) |
| Messages delivered / acknowledged | 4,495 / 4,495 | 4,500 / 4,500 | 4,500 / 4,500 | 4,500 / 4,500 |
| Deliveries/s | 48.4 | 49.1 | 49.2 | 49.1 |
| p50 | 60 ms | 136 ms | 57 ms | 93 ms |
| **p95** | **596 ms** | **12,269 ms** | **73 ms** | **217 ms** |
| p99 | 1,440 ms | 13,133 ms | 133 ms | 339 ms |
| max | 2,070 ms | 13,299 ms | 334 ms | 472 ms |
| p95 limit (20 % or 50 ms) | | 715 ms: **fail** | | 123 ms: **fail** |
| p95 of messages sent before the backlog was parked | | 12,763 ms (2,750 messages) | | 219 ms |
| p95 of messages sent after the backlog was parked | | 77 ms (1,750 messages) | | 71 ms |
| Messages over the limit, sent between | | 1,764, from 1.6 s to 36.8 s | | 1,078, from 5 s to 70 s |

| Dead channel | Shared tier | Separate tier |
| --- | --- | --- |
| Breaker opened after | 11.4 s | 11.1 s |
| Whole backlog parked (priority 3) after | 56.6 s (the backlog itself took 54.5 s to create) | 88.4 s |
| Deliveries in flight to the dead provider, max | 20 (every worker of the shared queue) | 5 (every worker of `deliveries_bulk`) |
| Requests that reached the dead provider (10,000 deliveries) | 23 | 7 |
| Deliveries lost or duplicated | 0 | 0 |

An earlier shared-tier run on a quieter machine (only the development Postgres running; the backlog created by 20
processes in 28 s) gave the same picture: baseline p95 112 ms, dead-phase p95 15,911 ms (p50 663 ms, max 16,910 ms),
breaker open after 11.8 s, backlog parked after 38.6 s, 20 deliveries in flight to the dead provider, 22 requests
reached it.

## Why the shared tier fails

The breaker timeline of the shared-tier run (seconds after the backlog started; sampled every few seconds):

| t | Breaker | Dead jobs executing | Dead jobs waiting at priority 1 | Dead jobs parked | Healthy jobs waiting |
| --- | --- | --- | --- | --- | --- |
| 3.6 s | closed | 20 | 1,264 | 0 | 143 |
| 7.7 s | closed | 20 | 3,148 | 0 | 336 |
| 11.4 s | open | 15 | 4,167 | 321 | 504 |
| 23.0 s | open | 10 | 1,933 | 4,191 | 654 |
| 34.3 s | open | 4 | 421 | 7,139 | 166 |
| 38.0 s | open | 2 | 4 | 8,007 | 3 |
| 56.6 s | open | 0 | 0 | 9,999 | 3 |

Two things hold the healthy tenant up, both before parking has any effect:

1. **Every worker of the queue is stuck in the dead provider for one adapter timeout.** The backlog's first 20
   jobs take all 20 workers of `deliveries` and each waits the full 10 s receive timeout. The breaker opens only
   when those attempts fail (`failure_threshold` 5 counts failures, not attempts in flight), so for about 10 s the
   queue runs nothing else.
2. **The backlog is ahead of the healthy tenant in the queue.** A backlog job is enqueued at priority 1, like
   every fresh delivery, and Oban fetches by priority and then by age. Parking moves a job to priority 3 only when
   that job runs: each of the 10,000 jobs has to be fetched once, see the open breaker and snooze itself. At about
   300-400 parked jobs/s (with the queue's workers and the database shared with the incoming traffic), the healthy
   tenant's newer jobs waited behind the backlog until about 37 s, the last moment a healthy message exceeded the
   limit. ADR-0031's "fresh deliveries are always fetched before parked ones" holds, but only once a job has been
   parked.

After the backlog is parked the queue is fair again: 77 ms p95 for messages sent afterwards, against a 60 ms
baseline median. Probes (one parked job per 30 s cooldown) hold one worker for 10 s each and did not show up in the
healthy tenant's latency.

On separate tiers the dead tenant can only block its own queue (`deliveries_bulk`, 5 workers, all stuck in the
dead provider at the start). The healthy tenant's p95 still rose from 73 ms to 217 ms, above the strict limit but
well below ADR-0031's 1 s target. That residue is shared resources on a single node: the 10,000 activities created
in 55 s and their parking ran on the same application node and Postgres (Postgres averaged 1.7 cores, the node 3
cores during the phase), and messages over the limit are spread over the whole time the backlog was being created
and parked, not concentrated in one stall.

## After ADR-0076

[ADR-0076](../adr/0076-bulk-parking-and-per-channel-in-flight-cap.md) (#191) removes both causes:

- **Cause 2:** when the breaker opens, the channel's whole waiting backlog is parked in one statement, and deliveries
  enqueued while it stays open are inserted parked.
- **Cause 1:** one channel runs at most half of a queue's workers on a node (10 of 20 here). Jobs over the cap are
  snoozed for 1 s without a database query, and the channel's waiting jobs are demoted to priority 2 in one statement,
  behind other channels' fresh deliveries.

Same scenario, shared tier, 1 node, on the same developer machine (`LOAD_SCENARIOS=dead_channel load/run.sh`):

| Healthy tenant, send → provider | Before | After |
| --- | --- | --- |
| Baseline p95 | 596 ms | 67 ms |
| Dead phase p95 / p99 | **12,269** / 13,133 ms | **104** / 142 ms |
| Dead phase max | | 321 ms |
| p95 of messages sent while / after the backlog was parked | – / 77 ms | 129 / 67 ms |
| Deliveries/s, dead phase | | 49.1 (baseline 49.3) |
| Breaker opened after | 11.4 s | 11.2 s |
| Requests that reached the dead provider | 23 | 15 |
| Lost acked messages | 0 | 0 |
| Gate (p95 ≤ max(baseline × 1.2, baseline + 50 ms)) | ❌ | ✅ (limit 117 ms) |

The before run's baseline was noisier (another stack shared the machine). The remaining messages over the gate are
sent in the ~10 s before the breaker opens, while the dead channel holds 10 of the 20 workers for one adapter timeout;
they wait up to about 300 ms rather than 13 s. ADR-0076 lists the variants that were measured on the way, including one
that passed here but starved a busy healthy channel in the 1-node `webhook_burst` run. The chosen version keeps that
run's delivery rate (126/s, burst drained in 56 s).

The gate is strict (50 ms over the baseline) and a developer machine is noisy: a second run of the same build, with a
noisier baseline (p99 142 ms against 78 ms), measured p95 535 ms, p99 961 ms and max 7.7 s, the slow messages again
in the ~10 s before the breaker opened. Both runs are far below the 12.3 s before the fix and around ADR-0031's 1 s
target, but only a quiet, repeated run (nightly CI) can say whether the gate holds reliably. Raw results:
`load/results/2026-10-15-dead-channel-shared-tier-after-0076.json`.

Tiers remain the stronger isolation: tenants with unreliable endpoints or bulk traffic on a different tier from
interactive tenants (`tenants.tier`, see [Tenant tiers](../delivery.md#tenant-tiers-fair-queueing)) do not share
workers at all.

## Related

- [ADR-0031: per-channel circuit breaker, parking, rate limits and tier queues](../adr/0031-per-channel-circuit-breaker-rate-limit-and-tier-queues.md)
- [Delivery: flow control](../delivery.md#flow-control-circuit-breaker-rate-limits-and-tenant-fairness)
- [Benchmarks and load testing](index.md)
