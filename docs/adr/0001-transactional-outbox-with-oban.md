---
title: "ADR-0001: Transactional outbox with Oban jobs in the activity transaction"
sidebar_label: "0001 Transactional outbox"
description: Delivery jobs are inserted as Oban jobs in the same database transaction as the activity, and the PubSub broadcast runs only after commit.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#1](https://github.com/AimTune/converger/issues/1) |
| **Pull request** | [#69](https://github.com/AimTune/converger/pull/69) |
| **Related** | [ADR-0002](0002-broadway-for-throughput-oban-for-retries.md), [ADR-0003](0003-pipeline-is-the-only-delivery-path.md), [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0017](0017-conversation-lifecycle-enforced-under-the-seq-lock.md), [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md) |

Converger accepts an activity (a message, event or typing indicator) and must then deliver it to every target channel: the conversation's primary channel and any routing-rule targets. This ADR records how the "activity is stored" fact and the "deliveries are scheduled" fact are made to commit together.

## Context and problem statement

Before [#69](https://github.com/AimTune/converger/pull/69), `Converger.Activities.create_activity/1` committed the activity in a `Repo.transaction` and only afterwards called `Converger.Pipeline.process/1`. With the Oban backend, `Oban.insert/1` ran once per target channel **after** the commit. Anything that failed in that window lost the delivery for good:

- the BEAM node crashed or was killed during a deploy,
- the database connection dropped between the commit and the job insert,
- `resolve_delivery_channels/1` raised (for example a routing rule pointing at a deleted channel).

In each case the activity existed in the transcript but no delivery job was ever created, and nothing recorded that fan-out had been attempted. The webhook or WhatsApp recipient never got the message and no retry could pick it up. This violated the "no message loss" requirement in `PRD.md` section 6.3.

The Broadway backend was worse: `MemoryProducer` kept messages in process memory and its `ack/3` was a no-op, so any restart dropped every queued delivery.

## Decision drivers

- Zero data loss: a committed activity must always have its delivery work durably recorded.
- No new infrastructure for the default deployment (Postgres is already required).
- Re-processing an activity (manual replay, idempotent client resubmission) must not create duplicate deliveries.
- Non-durable side effects (PubSub broadcast to WebSocket clients) must not be sent for activities that later roll back.
- Callers must get a clear, retryable error when enqueueing fails instead of a silent partial success.

## Considered options

1. **Oban jobs inside the activity transaction** - insert one `ActivityDeliveryWorker` job per target channel in the same `Repo.transaction` as the activity insert. Oban stores jobs in the `oban_jobs` Postgres table, so the job table is the outbox.
2. **Dedicated `activity_outbox` table plus a relay process** - write an outbox row in the transaction; a relay polls it and pushes to whatever backend is configured (Oban, Broadway/Kafka, RabbitMQ).
3. **Keep enqueue after commit and add a reconciliation sweeper** - a periodic job finds activities without deliveries and enqueues them.
4. **Keep the existing behaviour and document it** - accept rare losses.

### Pros and cons of the options

#### Option 1: Oban jobs in the transaction

- Good: atomic by construction. Postgres commits the activity row and the job rows together or not at all.
- Good: no new table, no relay process, no polling latency. Oban already runs, prunes and retries the jobs.
- Good: Oban's `unique` option gives idempotent enqueue for free.
- Bad: only works for backends that live in the same database. Broadway with Kafka or RabbitMQ cannot participate in the transaction.
- Bad: delivery-channel resolution (a few queries) now runs inside the write transaction, which lengthens it slightly.

#### Option 2: Outbox table plus relay

- Good: works for every backend, including external brokers.
- Bad: a new table, a relay process with its own supervision, leader election or `FOR UPDATE SKIP LOCKED` polling, and an extra hop of latency.
- Bad: for the default Oban backend it duplicates what `oban_jobs` already is.

#### Option 3: Reconciliation sweeper

- Good: small change to the write path.
- Bad: losses are only repaired after the sweep interval, and "activity without deliveries" is ambiguous (an activity may legitimately have zero target channels), so the sweeper has to re-resolve routing for every recent activity.
- Bad: still allows a broadcast for a delivery that is never made, until the sweep.

#### Option 4: Document the gap

- Good: no work.
- Bad: contradicts the product's core promise. Rejected immediately.

## Decision

Chosen option: **"Oban jobs inside the activity transaction"** (option 1), because it gives the strongest guarantee for the default and recommended backend with the least moving parts. The `oban_jobs` table already is a durable, transactional queue in the same Postgres database as `activities`; writing to it inside the activity transaction makes it a transactional outbox without adding one.

To make this explicit for every backend, the `Converger.Pipeline` behaviour was split into two phases:

- `enqueue/1` runs **inside** the persistence transaction. Whatever it writes commits or rolls back with the activity. Returning `{:error, reason}` or raising rolls the activity back.
- `after_commit/1` runs once the transaction has committed and handles fire-and-forget work, most importantly the PubSub broadcast. WebSocket clients therefore never see an activity that was rolled back.

`create_activity` maps an enqueue failure to `{:error, :delivery_enqueue_failed}`, and the fallback controller turns it into HTTP 503 with "Activity could not be accepted, please retry". Retrying is safe when the client sends an idempotency key.

`ActivityDeliveryWorker` is declared with `unique: [keys: [:activity_id, :channel_id], period: :infinity]`, so `Pipeline.process/1` can re-run the pipeline for an existing activity without duplicating jobs. Oban's default unique states exclude cancelled and discarded jobs, so a dead delivery can still be re-enqueued on purpose (the replay work in [#32](https://github.com/AimTune/converger/issues/32) relies on this).

Option 2 was not rejected outright: it is the known fix for broker-backed Broadway and is recorded as a follow-up.

## Consequences

### Positive

- With the Oban backend, every committed activity has a delivery job for each target channel, regardless of crashes or connection drops after commit.
- Rolled-back activities produce neither jobs nor broadcasts.
- Idempotent resubmission and explicit re-processing do not duplicate deliveries.
- The durability of each backend is stated in one place, the `Converger.Pipeline` moduledoc:

| Backend | Delivery enqueue | Durable |
| --- | --- | --- |
| `Converger.Pipeline.Oban` | Oban jobs, in transaction | yes |
| `Converger.Pipeline.Broadway` | pushed after commit | no |
| `Converger.Pipeline.Inline` | delivered after commit | no |

### Negative and trade-offs

- Broadway (memory, Kafka, RabbitMQ, custom producers) and Inline remain non-durable: they still do their work in `after_commit/1`, so a crash between commit and push loses the delivery. Their `enqueue/1` is a no-op.
- The Broadway `:memory` producer is now dev-only. It refuses to start when `config :converger, env: config_env()` is `:prod`, unless `allow_memory_producer_in_prod: true` is set under `config :converger, :pipeline, broadway: [...]`.
- Channel resolution queries run inside the write transaction, holding the conversation row lock (see [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md)) slightly longer.
- A failure to enqueue now fails the client request (503) instead of silently succeeding. This is intended, but clients must handle it.

### Follow-ups

- Durable broker-backed Broadway needs an outbox relay (option 2): an outbox record in the transaction and a worker that pushes it to the broker. Tracked by the pluggable event backbone work in [#66](https://github.com/AimTune/converger/issues/66).
- Dead-letter inspection and replay: [#32](https://github.com/AimTune/converger/issues/32).
- Stuck-job recovery for nodes that die mid-job is handled by the Oban Lifeline plugin, decided in [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md).

## Implementation

- [`Converger.Activities.create_activity/2`](https://github.com/AimTune/converger/blob/main/lib/converger/activities.ex): one `Repo.transaction` runs `insert_with_seq/2` (which also allocates `seq`, see [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md)) and then `Converger.Pipeline.enqueue/1`. On commit it emits `[:converger, :activities, :create]` telemetry and calls `Converger.Pipeline.after_commit/1`.
- [`Converger.Pipeline`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline.ex): the behaviour with `enqueue/1`, `after_commit/1` and `child_specs/0`; `process/1` re-runs both phases for an existing activity.
- [`Converger.Pipeline.Oban`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline/oban.ex): `enqueue/1` inserts one job per resolved channel and halts with `{:error, {:enqueue_failed, reason}}` on the first failure; `after_commit/1` broadcasts.
- [`Converger.Workers.ActivityDeliveryWorker`](https://github.com/AimTune/converger/blob/main/lib/converger/workers/activity_delivery_worker.ex): queue `:deliveries`, unique per `{activity_id, channel_id}` forever.
- [`Converger.Pipeline.Broadway`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline/broadway.ex) and [`Converger.Pipeline.Inline`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline/inline.ex): no-op `enqueue/1`, work in `after_commit/1`; `ensure_memory_producer_allowed!/2` is the prod guard.
- [`ConvergerWeb.FallbackController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/fallback_controller.ex): `{:error, :delivery_enqueue_failed}` becomes 503.
- Configuration: [`config/config.exs`](https://github.com/AimTune/converger/blob/main/config/config.exs) sets `env: config_env()` and `pipeline: [backend: Converger.Pipeline.Oban]`. The test environment uses `Converger.Pipeline.Inline` and Oban `testing: :inline` ([`config/test.exs`](https://github.com/AimTune/converger/blob/main/config/test.exs)).

Tests: [`test/converger/pipeline/transactional_enqueue_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/pipeline/transactional_enqueue_test.exs) checks that jobs are enqueued with the activity, that re-running the pipeline and idempotent resubmission create no duplicates, that a raise or an error return after jobs were inserted rolls back both the activity and the jobs, and the prod guard for the memory producer. The failure cases use [`Converger.FailingPipeline`](https://github.com/AimTune/converger/blob/main/test/support/failing_pipeline.ex), which calls the real Oban `enqueue/1` and then fails.

## Links

- Issue [#1](https://github.com/AimTune/converger/issues/1), pull request [#69](https://github.com/AimTune/converger/pull/69)
- Epic [#57](https://github.com/AimTune/converger/issues/57) (v2.5 production hardening: no data loss)
- [ADR-0002](0002-broadway-for-throughput-oban-for-retries.md): what happens when a Broadway delivery fails
- [Oban unique jobs](https://hexdocs.pm/oban/Oban.html#module-unique-jobs)
