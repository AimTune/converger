---
title: "ADR-0071: activity.created is published in the activity's transaction"
sidebar_label: "0071 activity.created in the transaction"
description: The activity.created platform event is stored in the transaction that stores the activity (a transactional outbox on every backbone) instead of being published after the commit, which lost events when a node died in between.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-15 |
| **Issue** | [#66](https://github.com/AimTune/converger/issues/66) |
| **Pull request** | (this PR) |
| **Related** | [ADR-0001](0001-transactional-outbox-with-oban.md), [ADR-0053](0053-platform-event-webhooks.md), [ADR-0070](0070-pluggable-event-backbone.md) |

## Context and problem statement

ADR-0070 routed platform events through `Converger.Backbone`. `activity.created` was still published from
`Converger.Pipeline.broadcast/1`, after the activity's transaction had committed, and
`Converger.Webhooks.emit/3` rescued and logged every error.

The quiet-machine benchmark matrix (`load/matrix.sh`) checks that every stored activity reaches a platform webhook
subscriber exactly once. That check failed:

| Backbone | 1 node | 3 nodes |
| --- | --- | --- |
| Native | 0 missing of 31,646 | **360 missing of 42,777** |
| Kafka | **4 missing of 27,654** | **2 missing of 39,820** |

The events were still missing after the 300 s catch-up window, and Lifeline rescues stuck jobs after 30 s in the
load stack. The `backbone` queue held only 5 more jobs than the subscriber observed, so for nearly every missing
event no job was ever inserted.

The events were lost at publish time. A node that is killed (`node_kill`) or drained (`rolling_restart`) between
the commit and the publish never publishes. Under database pressure, `emit/3` swallowed the error. No user message
was lost (0 lost acked messages in every cell), because channel deliveries already use the transactional outbox of
ADR-0001.

## Decision drivers

- A committed activity must have its `activity.created` event, whatever happens to the node after the commit.
- No event for an activity that rolled back.
- Work on every backbone, including brokers, which cannot join a Postgres transaction.

## Considered options

1. **Store the event in the activity's transaction** (Native: the subscription jobs; brokers: a publish job).
2. **Publish after the commit, plus a recovery sweep** that compares activities with published events.
3. **Publish directly to the broker inside the transaction.**

### Pros and cons of the options

#### Option 1

- Good, because it is the same pattern as the delivery jobs (ADR-0001): the event commits or rolls back with the
  activity.
- Good, because a failure to store the event fails the request, and the client retries it.
- Bad, because on a broker every event takes one Oban job before it reaches the broker (more latency and more
  Postgres writes).

#### Option 2

- Good, because the latency stays low in the normal case.
- Bad, because it needs a sweep, a high-water mark per backbone and a way to tell a missing event from a delayed one.

#### Option 3

- Bad, because a broker publish that succeeded for a transaction that then rolls back is an event for an activity
  that does not exist. It also holds the transaction open across a network call.

## Decision

Chosen option: **"Option 1"**.

`Converger.Backbone.publish_in_transaction/2` (it must run in a `Converger.Repo` transaction):

- **Native** (or Native as a mirror) inserts the shared subscriptions' jobs (`Native.enqueue/2`).
- **A broker** (and broker mirrors) inserts a `Converger.Workers.BackbonePublishWorker` job that publishes the event
  after the commit and retries with backoff. The event keeps its id, so a retried publish is a duplicate that the
  subscriptions' receipts skip.
- It raises when the insert fails, and the transaction rolls back.
- `Converger.Backbone.after_commit/1` hands the event to Native broadcast subscriptions once the transaction
  committed (best effort, as before).

`Converger.Activities.create_activity/2` publishes `activity.created` this way through
`Converger.Webhooks.emit_in_transaction/3`. `Converger.Pipeline.broadcast/1` no longer emits it.

## Consequences

### Positive

- `activity.created` exists exactly when the activity does, on every backbone.
- A database error while storing the event fails the activity (HTTP 503, retryable) instead of dropping the event.

### Negative and trade-offs

- On Kafka, NATS and RabbitMQ, `activity.created` reaches the broker through one Oban job. That adds latency and
  one job row per event.
- The other platform events (`delivery.*`, `conversation.*`, `channel.*`, `participant.opted_out`) are still
  published after their change commits. A node that dies in between loses that event. They should move to the
  outbox too, where their change runs in a transaction.

### Follow-ups

- Move the other platform events to `emit_in_transaction/3`.
- Rerun the benchmark matrix and publish `docs/benchmarks/backbone-matrix.md` when the zero-loss check passes on
  Native and Kafka, on 1 and 3 nodes (#66).

## Implementation

- `Converger.Backbone.publish_in_transaction/2` and `after_commit/1`.
- `Converger.Backbone.Native.enqueue/2` and `broadcast/2`.
- `Converger.Webhooks.emit_in_transaction/3`.
- `Converger.Activities.create_activity/2`.
- Tests: `test/converger/backbone/transactional_publish_test.exs`:
  - Native and broker outbox rows commit and roll back with the transaction.
  - It refuses to run outside a transaction.
  - `create_activity/2` stores the event.
  - No event for a rejected activity.
  - The event survives a node that "dies" right after the commit; this test fails on the previous code.

## Links

- [Event backbone](../architecture/event-backbone.md#delivery-guarantees)
- [Activity flow](../architecture/activity-flow.md)
