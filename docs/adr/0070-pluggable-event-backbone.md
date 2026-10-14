---
title: "ADR-0070: A pluggable event backbone for platform events, with Native as the default"
sidebar_label: "0070 Pluggable event backbone"
description: Platform events go through a Converger.Backbone behaviour with Native (Phoenix.PubSub + Oban), Kafka, NATS JetStream and RabbitMQ implementations selected by one config value; subscriptions deduplicate by event id in the handler's transaction; broker outages park events in Postgres; channel deliveries and the WebSocket fan-out stay where they are.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-15 |
| **Issue** | [#66](https://github.com/AimTune/converger/issues/66) |
| **Pull request** | (this PR) |
| **Related** | [ADR-0001](0001-transactional-outbox-with-oban.md), [ADR-0002](0002-broadway-for-throughput-oban-for-retries.md), [ADR-0047](0047-broker-channels-kafka-and-rabbitmq.md), [ADR-0049](0049-k6-load-harness-on-the-release-image-with-seq-based-loss-checks.md), [ADR-0053](0053-platform-event-webhooks.md), [ADR-0054](0054-nats-and-redis-streams-channels.md) |

## Context and problem statement

Operators run Converger under different constraints. A small deployment wants no infrastructure besides Postgres
and Erlang distribution. A large one already runs Kafka and wants Converger to publish what happens there, for
durability, replay and its own downstream consumers. Before this decision the only "backbone" was implicit: the
delivery pipeline (`Converger.Pipeline`, Oban / Broadway / Inline backends, [#1](https://github.com/AimTune/converger/issues/1),
[#2](https://github.com/AimTune/converger/issues/2)), `Phoenix.PubSub` for real time, and the platform event webhooks
([#49](https://github.com/AimTune/converger/issues/49)) writing their rows straight from the code that emits an event.
None of it could be pointed at a broker, none of it was tested against one, and there were no numbers to choose by.

Issue #66 asks for a first-class, documented and benchmarked choice: a `Converger.Backbone` behaviour
(`publish(topic, event)`, `subscribe(topic, handler)`, a declared delivery guarantee) with Native, Kafka, NATS
JetStream and RabbitMQ implementations, selected by a single config change, with the event webhooks and broker
channels consuming from it where that is sound.

## Decision drivers

- No acknowledged event may be lost, on any backbone, across consumer crashes and broker outages.
- An event must not be applied twice because a broker redelivered it ("exactly-once-ish").
- The default deployment keeps zero extra services.
- Switching backbone, and migrating between backbones, needs no downtime and no code change.
- The guarantees Converger already has (transactional delivery outbox, ADR-0001; seq-ordered WebSocket replay,
  ADR-0006) must not get weaker.

## Considered options

1. **Put everything on the backbone**: channel deliveries, the WebSocket fan-out and platform events.
2. **Platform events on the backbone; deliveries and the WebSocket fan-out stay** on the pipeline and PubSub.
3. **Keep the status quo** and document Broadway's Kafka/RabbitMQ producers as "the Kafka backbone".

### Pros and cons of the options

#### Option 1: everything on the backbone

- Good, because one path carries every message, and Kafka users get every delivery on a topic.
- Bad, because delivery jobs are inserted in the transaction that stores the activity (ADR-0001). A broker cannot
  join that transaction, so this would bring back the lost-delivery window of #1, or need an outbox relay in front
  of the broker that adds a hop and its own failure mode.
- Bad, because retries, the circuit breaker, tier queues and dead-letter replay (ADR-0019, ADR-0028, ADR-0031) are
  built on Oban jobs and delivery rows. They would have to be rebuilt per broker.
- Bad, because the WebSocket fan-out needs Erlang distribution anyway (presence, signals, channel replies, agent
  groups), and a broker hop adds produce and consume latency to the path with a p95 < 250 ms target.

#### Option 2: platform events on the backbone

- Good, because platform events have no transactional coupling: they are emitted after the fact, which is also
  where a broker publish fits.
- Good, because they are what downstream systems want (activity created, delivery failed, conversation closed),
  keyed by conversation.
- Good, because deliveries keep their outbox, retries and dead letters, and real time keeps its latency.
- Bad, because a Kafka user who wants every delivery *payload* on a topic still uses a `kafka` broker channel
  (ADR-0047) for that, a second concept to explain.

#### Option 3: status quo

- Good, because there is nothing to build.
- Bad, because the Broadway producers carry internal `activity_id`/`channel_id` pointers, not events, and are not
  durable (ADR-0002). Nothing a downstream system could consume.

## Decision

Chosen option: **option 2, platform events on the backbone**, because it meets every driver without weakening the
delivery outbox or the real-time path.

**The behaviour.** `Converger.Backbone` defines `publish/2`, `subscribe/1`, `unsubscribe/1`, `guarantee/0` and
`child_specs/0`. Events (`Converger.Backbone.Event`) have a UUID `id` (the idempotency key), a topic, the platform
event `type`, `tenant_id`, a partition `key` (the conversation id when there is one), JSON-normalised `data` and
`occurred_at`; the wire format is a JSON object (`spec: converger.backbone/1`). There are three topics:
`activities` (`activity.created`), `deliveries` (`delivery.*`) and `events` (conversation, channel and participant
events), named `<prefix>.<topic>` on brokers (`converger.activities`).

**Selection.** `config :converger, :backbone, Converger.Backbone.Kafka` (or `BACKBONE=kafka`) is the whole switch.
Every implementation declares `:at_least_once` for shared subscriptions.

| Implementation | Shared subscription (once per cluster) | Broadcast subscription (every node) |
| --- | --- | --- |
| `Native` (default) | an Oban job per subscription and event, filtered at publish time | `Phoenix.PubSub` |
| `Kafka` | consumer group `<prefix>.<name>`, `brod` producer keyed by conversation, acks=all | a consumer group per node, from the latest offset |
| `Nats` | a JetStream durable pull consumer per subscription, `Nats-Msg-Id` = event id | a durable consumer per node, new messages only |
| `RabbitMQ` | a durable queue per subscription bound to a topic exchange, publisher confirms | an auto-delete queue per node |

**Exactly once, the "-ish".** Subscriptions with `dedup: true` (the default for shared ones) record an idempotency
receipt (`backbone_receipts`, unique on subscription and event id) in the same database transaction as the
handler. A redelivered event finds the receipt and is skipped; a failed handler rolls its receipt back and is
retried. Database writes of a handler therefore apply once per event id on every backbone; side effects outside
the database stay at least once. The same id travels through every path (broker redelivery, a parked retry, a
dual-publish mirror), which is what makes migration safe (below).

**Failure handling.**

- A publish the broker refuses (down, unknown topic, timeout) is parked in Postgres as a
  `Converger.Workers.BackbonePublishWorker` job and published later with the same id. `publish/2` returns `:ok`
  once the event is either accepted by the broker or parked, so callers never lose events to a broker outage.
  After a failed publish, publishes to that broker are parked at once for a few seconds (`down_ms`), so requests
  do not each wait for the produce timeout while it is down.
- A broker consumer whose handler fails retries in place (`inline_attempts`), then parks the event as a
  `Converger.Workers.BackboneEventWorker` job ("the broker for throughput, Oban for retries", as ADR-0002 does for
  deliveries) and only then acknowledges it. If Postgres is down too, it keeps retrying and never acknowledges an
  event it could not hand over: a consumer blocks rather than loses.

**What consumes the backbone.** `Converger.Webhooks.emit/3` publishes; the built-in `webhooks` subscription
(`Converger.Webhooks.BackboneHandler`, every topic) writes the `webhook_events` rows and their delivery jobs in the
receipt's transaction. On Native, its `accept?/1` runs at publish time, so a tenant without subscriptions costs no
job, as before.

**What does not.** Channel deliveries stay on `Converger.Pipeline` (their jobs commit with the activity). The
WebSocket fan-out stays on `Phoenix.PubSub` on every backbone; clients recover anything missed from Postgres by
`seq` watermark (ADR-0006). Broker channels (ADR-0047, ADR-0054) keep their own consumers and producers: they talk
to the *customer's* topics with per-channel config, credentials and SSRF checks, and their outbound side is a
channel delivery with delivery rows, retries and dead-letter replay. The backbone reuses their client code
(brokers, SASL/TLS parsing, the NATS connection and JetStream producer, the AMQP connection options).

**Zero-downtime migration.** `mirror: [module]` (`BACKBONE_MIRROR`) publishes every event to more backbones. A
migration is: add the target as a mirror and roll; switch primary and mirror and roll; drop the mirror and roll.
Events published by old nodes during the rollout reach both sides, and the receipts make sure each is applied once
(see [Deployment](../deployment.md#migrating-between-backbones-without-downtime)).

## Consequences

### Positive

- Kafka, NATS or RabbitMQ users get every platform event on a topic keyed by conversation, with replay, without a
  webhook channel per conversation.
- A broker outage delays events instead of losing them or failing requests.
- One conformance suite (`Converger.BackboneConformance`) defines the contract, including a zero-loss test that
  kills consumers mid-stream; every implementation runs it in CI.
- The benchmark harness has a backbone dimension and a zero-loss check that every activity reaches a backbone
  subscriber exactly once.

### Negative and trade-offs

- One more table (`backbone_receipts`, pruned after 7 days) and one more Oban queue (`backbone`).
- On the Native backbone a platform event that some subscription wants costs one extra job hop (backbone job, then
  webhook job) compared with writing the webhook rows directly.
- Per-conversation order is guaranteed on Kafka (one partition per key, Broadway keeps partition order). On Native,
  NATS and RabbitMQ events of a conversation can be handled out of order when the consumer runs concurrently; the
  platform webhooks never promised order, and `occurred_at` is in every event.
- Native shared subscriptions exist per node: every node must declare the same ones (the built-in and configured
  ones are declared at boot).
- `brod` needs its CRC32C NIF: the Kafka backbone runs on Linux and macOS (the release image), not on Windows.

### Follow-ups

- The Broadway pipeline transport stays as it is (not durable, ADR-0002). The outbox relay that ADR-0001 names as
  the way to a durable broker-backed pipeline is not built here, because deliveries do not move onto the backbone.
- Broker channels could read from the backbone for "mirror every event of this tenant to my topic" without a
  routing rule; not needed by any current use.
- NATS and RabbitMQ columns in the benchmark matrix (the harness supports Native and Kafka).

## Implementation

- `lib/converger/backbone.ex` (behaviour and facade), `backbone/event.ex`, `subscription.ex`, `handler.ex`,
  `registry.ex`, `bootstrap.ex`, `dispatch.ex` (filters, receipts, retries, parking), `pipeline.ex` (the Broadway
  consumer of a broker subscription).
- Implementations: `backbone/native.ex` (+ `native/subscriber.ex`), `backbone/kafka.ex` (+ `kafka/client.ex`),
  `backbone/nats.ex` (+ `nats/connection.ex`), `backbone/rabbitmq.ex` (+ `rabbitmq/connection.ex`).
- Workers: `Converger.Workers.BackboneEventWorker`, `Converger.Workers.BackbonePublishWorker` (queue `backbone`).
- Migration `20261015120000_create_backbone_receipts.exs`; pruning in `Converger.Retention.prune/1`.
- Config: `config :converger, :backbone`, `config :converger, Converger.Backbone` and per implementation, set from
  `BACKBONE*` variables in `config/runtime.exs`.
- Platform webhooks: `Converger.Webhooks.emit/3`, `record/1`, `Converger.Webhooks.BackboneHandler`.
- Tests: `test/support/backbone_conformance.ex` run by `test/converger/backbone/{native,kafka,nats,rabbitmq}_conformance_test.exs`;
  `test/converger/backbone/integration_test.exs` (CI runs it with `BACKBONE=native` and `BACKBONE=kafka`);
  `test/converger/backbone/backbone_test.exs`.
- Benchmarks: `LOAD_BACKBONE=kafka` in `load/run.sh`, `load/matrix.sh`, the `matrix` job of the `Load` workflow.

## Links

- [Event backbone](../architecture/event-backbone.md)
- [Deployment: choosing a backbone](../deployment.md#choosing-an-event-backbone)
- [Configuration](../operations/configuration.md#event-backbone)
- [Backbone matrix](../benchmarks/backbone-matrix.md)
- [Platform event webhooks](../platform-webhooks.md)
