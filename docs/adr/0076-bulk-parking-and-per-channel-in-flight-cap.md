---
title: "ADR-0076: Park a channel's backlog in bulk and cap one channel's running deliveries per node"
sidebar_label: "0076 Bulk parking and in-flight cap"
description: When a channel's breaker opens or it is paused, its whole waiting backlog is parked in one statement and new deliveries are inserted parked; and one channel may run at most half of a queue's workers on a node, so a dead channel cannot stall the other tenants of its tier; a channel at its cap has its backlog demoted behind other channels' fresh deliveries, never delayed, so a busy one keeps its throughput.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-15 |
| **Issue** | [#191](https://github.com/AimTune/converger/issues/191) |
| **Pull request** | (this PR) |
| **Related** | [ADR-0031](0031-per-channel-circuit-breaker-rate-limit-and-tier-queues.md) (amended), [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md) |

## Context and problem statement

[ADR-0031](0031-per-channel-circuit-breaker-rate-limit-and-tier-queues.md) promised that "fresh deliveries of
healthy channels in the same queue are always fetched first" once a dead channel's breaker is open. The
`dead_channel` load scenario ([Dead-channel isolation](../benchmarks/dead-channel-isolation.md), #196) showed that a
tenant sharing a tier with a dead channel still waited for about 35 s (p95 12.3 s against a 0.6 s baseline), for two
reasons:

1. **Every worker of the queue was stuck in the dead provider.** The backlog's first 20 jobs took all 20 workers of
   `deliveries`, each waiting one 10 s adapter timeout. The breaker counts failures, not attempts in flight, so it
   only opened once those attempts had failed.
2. **The backlog sat ahead of the healthy tenant.** Backlog jobs were enqueued at priority 1 like every fresh
   delivery, and Oban fetches by priority and then by age. A job dropped to priority 3 only when it ran, saw the open
   breaker and snoozed itself: 10 000 jobs were fetched and parked one at a time, at a few hundred per second, while
   the healthy tenant's newer jobs waited behind them.

## Decision drivers

- A dead or slow channel must not delay other tenants of its tier by more than a fraction of a second.
- No new infrastructure (no Oban Pro partitioned queues, ADR-0031).
- No message may be lost or reordered within a channel beyond what retries already do.
- A healthy channel with a lot of traffic must keep most of its throughput.

## Considered options

1. **Bulk parking plus a per-node in-flight cap per channel** (chosen).
2. **A shorter first-attempt timeout** - bounds cause 1 to that timeout, but slow healthy providers would fail, and
   the backlog (cause 2) still sits ahead.
3. **Count in-flight attempts towards the breaker** (open after N attempts outstanding) - providers that are merely
   slow would trip it, and it does not move the backlog either.
4. **Oban Pro partitioned queues** - a global limit per channel; rejected in ADR-0031 (paid dependency).
5. **Tiers only** - put unreliable tenants on `bulk`; a mitigation that needs an operator to know in advance.

## Decision

Chosen option: **"Bulk parking plus a per-node in-flight cap per channel"**.

- **Park the backlog when the breaker opens or the channel is paused** (`Circuit.park_backlog/1`, run by the
  transition): one `UPDATE` moves every `available`, `scheduled` and `retryable` delivery job of the channel that is
  not parked yet to priority 3, asleep for `park_seconds` with jitter, and its `pending` deliveries to `paused`. Jobs
  already executing finish their attempt. Closing or resuming releases them all at once, as before.
- **Insert parked while open or paused** (`Circuit.insert_opts/1`, used by `Converger.Pipeline.Oban.enqueue/1` with the
  channel it already loaded): priority 3, asleep for `park_seconds` like any parked job. A job inserted parked by a
  node that still saw the breaker open as another closed it would otherwise sleep `park_seconds`, so closing
  schedules the probe worker 5 s later, and the probe worker releases the channel's parked jobs whenever it finds the
  breaker closed (`release_parked/1` is idempotent). A first version woke inserted jobs after `cooldown_ms`
  instead: thousands of them then woke together and were parked again one by one, which the load test showed as
  latency spikes for the other tenant 30 s after the breaker opened.
- **Cap a channel's running deliveries per node** (`Converger.Channels.InFlight`, `max_in_flight`, default `:auto` =
  half of the job's queue workers, at least 1): the delivery worker takes a slot before anything else.
  - A job over the cap is snoozed for `busy_snooze_ms` (1 s, Oban's smallest snooze) without a database query.
  - The first job over the cap per `busy_snooze_ms` also demotes the channel's other `available` priority-1 jobs to
    priority 2 in one statement (`Circuit.demote_backlog/1`). They stay available: the channel keeps all the
    throughput its cap allows, but other channels' fresh deliveries (priority 1) are fetched first, and its backlog is
    not fetched and snoozed ahead of them. Parked jobs (3) still come last.
  - Slots are released after the attempt, or by a process monitor if the job is killed.

  How the over-cap backlog is handled was settled by load runs (`dead_channel` for isolation, the 1-node
  `webhook_burst` for a busy healthy channel):

  | Variant | Other tenant's p95 (gate) | Burst deliveries/s |
  | --- | --- | --- |
  | Defer the channel's backlog by 1 s at priority 2 | 111 ms (114) | about 12 on CI: the busy channel's backlog was pushed back every second while being staged again |
  | Defer only once a running delivery is older than 1 s | 255 ms (116) | 142 |
  | Same at 250 ms, keeping the next `max_in_flight` jobs available | 454 ms (114) | 133 |
  | Cap three quarters of the queue for fast channels | 424 ms (114) | 158 |
  | **Demote to priority 2 without delay (chosen)** | **104 ms (117)** | **126** |

  Delaying a backlog starves a busy channel; leaving it at priority 1 lets a dead channel's jobs be fetched and snoozed
  ahead of everyone. Demoting does neither.

## Consequences

### Positive

- A dead channel can hold at most half of a queue's workers on a node during the adapter timeout before its breaker
  opens; the other half keeps serving the rest of the tier.
- Parking a backlog of any size is one statement instead of one job fetch per delivery, so other tenants are not
  queued behind it.
- Bursts sent to a channel that is already open or paused never enter the fetch order at priority 1.

### Negative and trade-offs

- A single healthy channel can no longer use every worker of its queue on a node: with the defaults it gets 10 of the
  20 `deliveries` workers, 5 of `deliveries_high` and 2 of `deliveries_bulk`. A channel that needs more sets
  `max_in_flight` (globally) or its tenant moves to a tier with more workers. `max_in_flight: nil` turns the cap off.
- The cap is per node, not cluster-wide: on N nodes a channel can run N × cap deliveries at once.
- `park_backlog/1` marks every `pending` delivery of the channel `paused`, including the few whose attempt is running;
  their outcome overwrites it when the attempt ends.
- Deliveries inserted parked have no delivery row until their job first runs, so they are counted in the parked job
  count (`Circuit.parked_count/1`) but not as `paused` deliveries.

## Validation

`test/converger/channels/circuit_test.exs` (backlog parked on open, inserted parked while open, a job over the cap
snoozed without an adapter call, `demote_backlog/1`) and `test/converger/channels/in_flight_test.exs` (cap, release,
slot freed when the process dies, one demotion per window). Load: the `dead_channel` scenario, see
[Dead-channel isolation](../benchmarks/dead-channel-isolation.md).
