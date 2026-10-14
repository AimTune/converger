---
title: Event backbone
description: How Converger publishes platform events through a pluggable backbone (Native PubSub + Oban, Kafka, NATS JetStream, RabbitMQ), the topics and event format, subscriptions, delivery guarantees, idempotency receipts and failure handling.
sidebar_position: 6
---

# Event backbone

The event backbone is where Converger publishes what happened: an activity was created, a delivery was sent or
failed, a conversation was closed, a channel's circuit opened. Converger's own consumers subscribe to it (today the
[platform event webhooks](../platform-webhooks.md)), and with a broker backbone so can your systems, straight from
the topic. The decision and the alternatives are in
[ADR-0070](../adr/0070-pluggable-event-backbone.md); how to choose one is in
[Deployment](../deployment.md#choosing-an-event-backbone).

```text
 Activities / Deliveries / Conversations / Channels / Participants
        │  Converger.Webhooks.emit/3  (after the change is stored)
        ▼
 Converger.Backbone.publish(topic, event) ──► mirrors (dual publish, optional)
        │
        ├─ Native:    Oban job per shared subscription + Phoenix.PubSub broadcast
        ├─ Kafka:     converger.activities | .deliveries | .events (key = conversation)
        ├─ NATS:      streams CONVERGER_ACTIVITIES | _DELIVERIES | _EVENTS
        └─ RabbitMQ:  topic exchange "converger", routing key = topic
        │
        ▼
 subscriptions ── "webhooks" (built in) ──► webhook_events rows + delivery jobs
               └─ your own (config), or any consumer reading the broker directly
```

## What is on the backbone

| Topic | Broker name | Event types | Key |
| --- | --- | --- | --- |
| `activities` | `converger.activities` | `activity.created` | conversation id |
| `deliveries` | `converger.deliveries` | `delivery.sent`, `delivery.delivered`, `delivery.read`, `delivery.failed` | conversation id |
| `events` | `converger.events` | `conversation.created`, `.closed`, `.reopened`, `channel.health_changed`, `.circuit_opened`, `.circuit_closed`, `participant.opted_out` | conversation id, else channel id, else tenant id |

The prefix (`converger`) is `BACKBONE_TOPIC_PREFIX`. The event types are the
[platform event catalog](../platform-webhooks.md#event-catalog); `data` is the same payload the webhooks carry.

Two things are deliberately **not** on the backbone:

- **Channel deliveries.** Their Oban jobs are inserted in the transaction that stores the activity
  ([ADR-0001](../adr/0001-transactional-outbox-with-oban.md)), so a committed activity always has its deliveries.
  No broker can take part in that transaction, and retries, the circuit breaker, tier queues and dead-letter
  replay are built on those jobs. See [Delivery pipeline](delivery-pipeline.md). To get delivery *payloads* on your
  own Kafka, RabbitMQ or NATS topic, use a [broker channel](../channels/brokers.md).
- **The WebSocket fan-out.** It stays on `Phoenix.PubSub` over Erlang distribution on every backbone, like
  presence, typing signals and channel replies. A broker hop would add latency to the real-time path, and clients
  recover anything they missed from Postgres by `seq` ([Real-time delivery](realtime.md)).

## Event format

On a broker an event is a JSON object (headers: `content-type: application/json`, `x-converger-event-id`,
`x-converger-event`, `x-converger-tenant-id`; on NATS also `Nats-Msg-Id`):

```json
{
  "spec": "converger.backbone/1",
  "id": "8d3c4c1e-5f0b-4a8e-9a43-1f8f0f0d2a11",
  "topic": "deliveries",
  "type": "delivery.failed",
  "tenant_id": "1b0e...",
  "key": "c6f1...",
  "occurred_at": "2026-10-15T12:00:00.123456Z",
  "data": { "delivery_id": "...", "activity_id": "...", "conversation_id": "c6f1...", "status": "failed", "last_error": "..." }
}
```

`id` is the idempotency key: the same event keeps its id through every redelivery, retry and mirror. It is also
the `id` of the platform webhook body and its `x-converger-event-id` header.

## Implementations

`Converger.Backbone` is a behaviour (`publish/2`, `subscribe/1`, `unsubscribe/1`, `guarantee/0`,
`child_specs/0`). One implementation is selected per deployment (`BACKBONE`), and every one declares
`:at_least_once` for shared subscriptions.

| | Native (default) | Kafka | NATS JetStream | RabbitMQ |
| --- | --- | --- | --- | --- |
| Extra services | none | Kafka or Redpanda | NATS with JetStream | RabbitMQ |
| Publish is acknowledged when | the Oban jobs are inserted | the partition leader and replicas have it (`acks=all`) | the stream stored it | the broker confirmed it (persistent) |
| Shared subscription | an Oban job per subscription and event (queue `backbone`) | consumer group `<prefix>.<name>`, partitions balanced over the nodes | durable pull consumer `<prefix>_<name>` per stream | durable queue `<prefix>.<name>`, competing consumers |
| Broadcast subscription | `Phoenix.PubSub` | a consumer group per node, latest offset | a durable consumer per node, new messages | an auto-delete queue per node |
| Order within a conversation | not guaranteed (jobs run concurrently) | guaranteed (one partition per key) | stream order; not guaranteed with concurrency > 1 | not guaranteed with concurrency > 1 |
| Retention and replay | none (jobs are pruned) | topic retention; consumers can rewind | `max_age_seconds` (7 days); consumers can rewind | none once acknowledged |
| Duplicate publish | n/a | receipts | dropped by the stream (`Nats-Msg-Id`, 2 min window) and receipts | receipts |

Topics, streams and the exchange are created at boot when missing (Kafka `create_topics`, NATS streams, the
RabbitMQ exchange and the queues of declared subscriptions).

## Subscriptions

A subscription (`Converger.Backbone.subscribe/3`) has a **name**, topics, a handler (a module implementing
`Converger.Backbone.Handler`, or a one-argument function) and options:

- `mode: :shared` (default): every event is handled once by the cluster, durably. `mode: :broadcast`: every node
  handles every event, best effort (for local fan-out); nothing is kept for a node that is down.
- `filter` / the handler's `accept?/1`: whether the subscription wants an event. On Native it runs at publish time,
  so an unwanted event costs no job.
- `dedup` (default `true` for shared): idempotency receipts, below.
- `concurrency`: consumer processors per node on a broker (default 4).

Every node declares the same subscriptions at boot (`Converger.Backbone.Bootstrap`): the built-in `webhooks`
subscription and the ones in `config :converger, Converger.Backbone, subscriptions: [{name, topics, handler, opts}]`.
Nodes with `BACKBONE_CONSUMERS=false` declare them but run no broker consumer.

## Delivery guarantees

**At least once, applied once.** Brokers and Oban redeliver an event whose consumer died before acknowledging it.
A subscription with `dedup: true` writes an idempotency receipt (`backbone_receipts`, unique on subscription and
event id) in the **same database transaction** as its handler. A redelivered event finds the receipt and is
skipped; a handler that fails rolls its receipt back and the event is retried. A handler's database writes are
therefore applied exactly once per event, on every backbone; anything it does outside the database (an HTTP call)
is at least once. Receipts are pruned after 7 days (`backbone_receipt_days`, see [Retention](../operations/retention.md)).

**Publishing never loses an acknowledged event.** `publish/2` returns once the backbone accepted the event. When a
broker refuses it or cannot be reached, the event is parked in Postgres (`Converger.Workers.BackbonePublishWorker`,
queue `backbone`) and published later with the same id; the request that produced it is not failed. After a failed
publish, further publishes to that broker are parked at once for `down_ms` (5 s), so requests do not each wait for
the produce timeout while the broker is down.

**Consumers never acknowledge what they could not hand over.** A broker consumer whose handler fails retries it in
place (`inline_attempts`, default 3), then parks the event as a `Converger.Workers.BackboneEventWorker` job that
retries it durably, and acknowledges the message only after that. If Postgres is unavailable too, the consumer
keeps retrying with backoff instead of acknowledging: it blocks its partition or queue rather than lose the event.

After a node dies, its unacknowledged events are redelivered to the other nodes: on Kafka once the dead member's
session times out (10 s, `group_config`) and its partitions are reassigned, on NATS after `ack_wait_seconds`, on
RabbitMQ as soon as the connection drops, on Native when Oban's Lifeline rescues the jobs. Until then those events
are delayed, not lost.

These guarantees are checked by one conformance suite that every implementation passes
(`test/support/backbone_conformance.ex`): unchanged delivery, fan-out to every shared subscription, filters,
retries with the effect applied once, duplicate publishes, broadcast subscriptions, per-key order (Kafka), and a
zero-loss test that publishes acknowledged events, kills the consumers mid-stream and checks that every event was
observed and applied exactly once.

## Telemetry

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:converger, :backbone, :publish, :start \| :stop \| :exception]` | `duration` | `backbone`, `topic`, `type`, `result` (`:ok` / `:error`, on stop) |
| `[:converger, :backbone, :handle]` | `duration` | `subscription`, `topic`, `type`, `outcome` (`:handled`, `:duplicate`, `:skipped`, `:error`) |
| `[:converger, :backbone, :poison]` | `count` | `subscription` (a broker message that is not a backbone event) |

Parked publishes and retries are ordinary Oban jobs in the `backbone` queue, so the queue depth gauge and the
Oban dashboard show a broker outage as a growing `backbone` queue.

## Related

- [ADR-0070](../adr/0070-pluggable-event-backbone.md): the decision
- [Deployment: choosing and migrating](../deployment.md#choosing-an-event-backbone)
- [Configuration reference](../operations/configuration.md#event-backbone)
- [Backbone matrix](../benchmarks/backbone-matrix.md): the numbers
