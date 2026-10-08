---
title: "ADR-0002: Broadway for throughput, Oban for retries and dead-lettering"
sidebar_label: "0002 Broadway + Oban retries"
description: Failed Broadway deliveries are handed to durable Oban jobs for backed-off retries, and exhausted deliveries are dead-lettered under one shared retry policy.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#2](https://github.com/AimTune/converger/issues/2) |
| **Pull request** | [#70](https://github.com/AimTune/converger/pull/70) |
| **Related** | [ADR-0001](0001-transactional-outbox-with-oban.md), [ADR-0008](0008-middleware-receives-channel-and-crashes-are-contained.md), [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md) |

Converger has three delivery pipeline backends (Oban, Broadway, Inline). This ADR records what the Broadway backend does when an external delivery fails, and how the retry limit and backoff are shared across backends.

## Context and problem statement

In `Converger.Pipeline.Broadway.Pipeline`, `handle_batch/4` marked a message `Broadway.Message.failed/2` when `Pipeline.deliver/2` returned an error, and `handle_failed/2` only logged it. The `MemoryProducer` acknowledger ignored failures. So with the Broadway backend selected, **a webhook that was down for five seconds caused permanent message loss**, while the Oban backend retried the same delivery five times.

`Deliveries.mark_attempt_failed/2` did bump the `attempts` counter on the delivery record, but nothing ever re-attempted the delivery, and it hardcoded `5` as the attempt limit independently of the Oban worker's own `max_attempts`. The two backends had different, duplicated retry semantics and no common notion of a dead letter.

## Decision drivers

- A transient failure must not lose a delivery under any backend.
- Broadway is chosen for throughput and backpressure; the retry path should not slow the hot path or block a batch.
- Retries must survive node restarts, which in-process Broadway state does not.
- One retry policy (attempt limit, backoff) for all backends, so behaviour does not depend on the backend.
- A delivery that will never succeed must end in a visible, queryable terminal state.
- A retry must never send a message twice.

## Considered options

1. **Hand failed deliveries to Oban** ("Broadway for throughput, Oban for retries") - on a transient failure, insert a scheduled `ActivityDeliveryWorker` job with policy backoff and ack the Broadway message.
2. **Re-push to the Broadway producer with a `retry_at`** - keep retries inside Broadway by re-queueing the message and delaying it.
3. **Rely on the broker's redelivery** - nack the message and let Kafka or RabbitMQ redeliver it (RabbitMQ dead-letter exchanges, Kafka retry topics).
4. **Retry synchronously inside `handle_batch/4`** - sleep and retry a few times before giving up.

### Pros and cons of the options

#### Option 1: Hand off to Oban

- Good: retries are durable Postgres rows that survive restarts and are visible in Oban Web.
- Good: one retry implementation for every backend; the Oban worker already exists.
- Good: the Broadway batch is never blocked by a slow or failing endpoint.
- Bad: a Broadway deployment now always needs Oban and Postgres for its failure path.
- Bad: retried deliveries leave the Broadway topology, so broker-level metrics undercount them.

#### Option 2: Re-push with `retry_at`

- Good: stays inside Broadway.
- Bad: with the `:memory` producer the delayed message lives in process memory and is lost on restart. Each producer (memory, Kafka, RabbitMQ, custom) would need its own delay mechanism.

#### Option 3: Broker redelivery

- Good: native to the broker.
- Bad: every broker has different semantics (no delay in plain Kafka, DLX topology in RabbitMQ), nothing for `:memory` or custom producers, and the policy would live in broker configuration instead of the application.

#### Option 4: Synchronous retry in the batcher

- Good: trivial.
- Bad: blocks the batcher for the backoff duration, defeats the purpose of Broadway, and still loses the delivery if the node stops mid-retry.

## Decision

Chosen option: **"Hand failed deliveries to Oban"** (option 1). Broadway is valued for fast, backpressured first attempts; retries are rare, need durable scheduling, and Oban already provides exactly that in the same database as the delivery records. Making Oban the single retry engine also makes the retry policy and dead-letter state identical across backends, which options 2 and 3 cannot do without per-producer code.

The concrete rules:

- `Pipeline.deliver/2` classifies its result. `Pipeline.retryable?/1` is true only for a plain `{:error, reason}`; `{:error, {:halted, _}}` (middleware halt) and `{:error, {:dead_lettered, _}}` are terminal.
- On a retryable failure, `handle_batch/4` calls `Pipeline.schedule_retry/3`, which inserts an `ActivityDeliveryWorker` job scheduled after the policy backoff (or a provider `Retry-After`), and the Broadway message is **acked**, because Oban now owns the delivery. The message is marked failed only if the hand-off itself fails.
- The retry policy lives in one module, `Converger.Pipeline.RetryPolicy`, configured with `config :converger, :retry_policy` (defaults: `max_attempts: 5`, exponential backoff `base_ms * 3^attempt` with `base_ms: 10_000`, capped at one hour). `Deliveries`, the Oban worker and Broadway all read it.
- The `attempts` counter on the delivery record, not the Oban job's attempt number, decides when to stop. When attempts are exhausted the delivery is **dead-lettered**: `status: "failed"`, a `[:converger, :deliveries, :dead_lettered]` telemetry event with `attempts`, and a status broadcast. `Deliveries.list_dead_letters/1` lists them.
- Middleware halts are dead-lettered immediately, since a retry would halt again (see [ADR-0008](0008-middleware-receives-channel-and-crashes-are-contained.md)).
- The Oban worker returns `{:cancel, reason}` for terminal results and `Pipeline.deliver/2` returns `:ok` without re-sending when the delivery is already `sent`, `delivered` or `read`, so a duplicate job never sends twice.

## Consequences

### Positive

- A transient outage no longer loses messages under the Broadway backend; behaviour matches the Oban backend.
- Retry limits and backoff are configured once and behave the same everywhere.
- Exhausted deliveries have a terminal, queryable state and a telemetry signal for alerting.
- Retries are idempotent with respect to already-sent deliveries.

### Negative and trade-offs

- The Broadway backend depends on Oban for its failure path, so it is not a "Postgres-free" option.
- The first Broadway attempt is still not durable: the push happens after commit (see [ADR-0001](0001-transactional-outbox-with-oban.md)). This ADR only covers what happens once a delivery has been attempted.
- The Oban worker's own `max_attempts` is only a safety cap. PR #70 set it to `20`; [#85](https://github.com/AimTune/converger/pull/85) raised it to `100` when per-channel `max_attempts` was introduced, so that any sane channel policy stays below it. Operators who read job attempt counts in Oban Web must remember that the delivery record is authoritative.

### Follow-ups

- Per-channel retry policy, `DeliveryError` classification and `Retry-After` handling extended this decision in [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md) (issue [#19](https://github.com/AimTune/converger/issues/19)).
- Dead-letter inspection and replay API/UI, and the optional tenant webhook on dead-letter, were left to [#32](https://github.com/AimTune/converger/issues/32).
- Per-channel circuit breakers and provider rate limiting: [#31](https://github.com/AimTune/converger/issues/31).
- Delivery telemetry dashboards and alerts on `dead_lettered`: [#33](https://github.com/AimTune/converger/issues/33).
- A pluggable, benchmarked backbone including durable broker publishing: [#66](https://github.com/AimTune/converger/issues/66).

## Implementation

- [`Converger.Pipeline.Broadway.Pipeline`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline/broadway/pipeline.ex): `handle_batch/4` and the private `hand_off_retry/4`.
- [`Converger.Pipeline`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline.ex): `deliver/2`, `retryable?/1`, `schedule_retry/3`, `retry_delay_ms/3`.
- [`Converger.Pipeline.RetryPolicy`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline/retry_policy.ex): defaults, `for_channel/1`, `backoff_ms/2`, `exhausted?/2`. The legacy `base_backoff_seconds` config key is still honoured.
- [`Converger.Workers.ActivityDeliveryWorker`](https://github.com/AimTune/converger/blob/main/lib/converger/workers/activity_delivery_worker.ex): `perform/1` returns the error for retryable results and `{:cancel, reason}` otherwise; `backoff/1` uses the channel policy or a provider `Retry-After`.
- [`Converger.Deliveries`](https://github.com/AimTune/converger/blob/main/lib/converger/deliveries.ex): `mark_attempt_failed/3`, `mark_dead/2`, `list_dead_letters/2`, `paginate_dead_letters/2`.
- The webhook adapter merges optional `:webhook_req_options` into its `Req` call, which the tests use to plug in `Req.Test`.

Tests: [`test/converger/pipeline/broadway_retry_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/pipeline/broadway_retry_test.exs) drives a real push through the Broadway processor and batcher callbacks with a `Req.Test` stubbed webhook, then drains the Oban retries. It covers "fails twice, then succeeds" (ends `sent` with `attempts == 3`), permanent failure ending `failed` and listed by `list_dead_letters`, immediate dead-lettering of middleware halts, the shared policy, and `retryable?/1`.

## Links

- Issue [#2](https://github.com/AimTune/converger/issues/2), pull request [#70](https://github.com/AimTune/converger/pull/70)
- [Broadway documentation](https://hexdocs.pm/broadway/Broadway.html)
