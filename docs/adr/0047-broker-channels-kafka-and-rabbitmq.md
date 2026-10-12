---
title: "ADR-0047: Broker channels - Kafka and RabbitMQ as channel types with cluster-singleton Broadway consumers and broker-id idempotency"
sidebar_label: "0047 Broker channels"
description: Kafka and RabbitMQ become channel types; each inbound channel gets one Broadway consumer in the cluster (a :global-registered supervisor reconciled by a per-node manager), consumed messages are keyed by their broker message id, poison messages go to a per-channel dead-letter topic or queue, and the internal Broadway pipeline transport stays separate.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-12 |
| **Issue** | [#42](https://github.com/AimTune/converger/issues/42) |
| **Pull request** | [#141](https://github.com/AimTune/converger/pull/141) |
| **Related** | [ADR-0002](0002-broadway-for-throughput-oban-for-retries.md), [ADR-0003](0003-pipeline-is-the-only-delivery-path.md), [ADR-0012](0012-secrets-at-rest-and-audit-redaction.md), [ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md), [ADR-0015](0015-per-message-idempotent-inbound-batches.md), [ADR-0037](0037-libcluster-clustering-health-endpoints-and-metrics-on-the-main-port.md), [ADR-0038](0038-adapter-behaviour-v2-and-config-driven-registry.md) |

## Context and problem statement

Kafka and RabbitMQ existed in Converger only as the **pipeline transport**: producers of the Broadway pipeline
backend ([ADR-0002](0002-broadway-for-throughput-oban-for-retries.md)) that carry internal
`{activity_id, channel_id}` pointers between "activity committed" and "deliver". Their client libraries were not even
dependencies. Backend integrators (CRM, analytics, bot runtimes) want something else: to consume conversation traffic
from a topic and to produce replies to another, with a documented message format, per tenant, alongside WhatsApp and
web chat. Issue [#42](https://github.com/AimTune/converger/issues/42) asks for brokers as first-class channels with
two acceptance criteria: a message produced to `topic_in` by an external script reaches a WebSocket client through a
routing rule and the reply appears on `topic_out`; and consumer restarts resume from committed offsets without
duplicates beyond at-least-once, with the broker message id as idempotency key.

Channels so far received inbound traffic by HTTP (webhooks) or over sockets: the provider pushes, Converger answers.
A broker channel has to **pull**, which means a long-running consumer per channel, on some node, started and stopped
as tenants create and change channels, and never two for the same channel.

## Decision drivers

- No message lost: a consumed message is acknowledged only once it is an activity or parked somewhere durable.
- No duplicate activities on redelivery (restarts, rebalances, requeues).
- Exactly one consumer per channel across the cluster, without new infrastructure, and consumers spread over nodes.
- A broker channel is a channel: same pipeline, routing rules, deliveries, retry policy, circuit breaker, health.
- Dependencies that compile on every supported platform, or a clearly documented exception.
- Keep the adapter behaviour generic ([ADR-0038](0038-adapter-behaviour-v2-and-config-driven-registry.md)): a third
  broker type should be one module.

## Considered options

1. **Extend the pipeline transport**: document its topic as the integration point.
2. **Broker channels with a cluster-singleton consumer per channel** (Broadway pipelines under a `DynamicSupervisor`,
   `:global` registration, a per-node reconciling manager).
3. **Broker channels with Oban-driven polling**: a recurring Oban job per channel fetches a batch and commits.
4. **Broker channels with one consumer per channel on every node**, relying on the broker (Kafka consumer groups,
   competing RabbitMQ consumers) for distribution.

For the consumer singleton within option 2: `:global` versus Oban's peer leader (`Oban.Peer`, one leader node runs
all consumers) versus a Postgres advisory lock per channel.

### Pros and cons of the options

#### Option 1: pipeline transport as integration point

- Good, because nothing new runs.
- Bad, because its messages are internal pointers, it is deployment-wide (not per tenant), not durable, one-way and
  bypasses routing rules and delivery tracking. It cannot carry inbound messages at all.

#### Option 2: broker channels, cluster-singleton consumers

- Good, because a broker channel is an ordinary channel type: outbound deliveries reuse the Oban pipeline untouched,
  inbound messages go through `Converger.Inbound` like webhooks.
- Good, because Broadway connectors (`broadway_kafka`, `broadway_rabbitmq`) bring acknowledgement, offset commits,
  reconnection and backpressure; per-partition ordering comes from `broadway_kafka`'s allocator.
- Good, because `:global` needs only the Erlang distribution the cluster already has
  ([ADR-0037](0037-libcluster-clustering-health-endpoints-and-metrics-on-the-main-port.md)); rendezvous hashing spreads
  consumers over nodes, which a single Oban leader would not.
- Bad, because `:global` can briefly run two consumers during a netsplit (resolved when it heals); idempotency makes
  that harmless.
- Bad, because `brod` and Broadway name processes and clients with atoms: one set of atoms per broker channel.

#### Option 3: Oban polling

- Good, because Oban already guarantees single execution.
- Bad, because a poll loop adds latency, fights the brokers' push/long-poll models, and Kafka consumer-group membership
  does not survive between jobs (every job would rejoin the group and trigger a rebalance).

#### Option 4: a consumer on every node

- Good, because no coordination is needed at all.
- Bad, because RabbitMQ would deliver a queue's messages to N competing consumers (no order) and every node would hold
  a connection per channel; for Kafka, N group members per channel multiply rebalances. The issue asks for one consumer
  per channel.

## Decision

Chosen option: **"Option 2"** with `:global`, because it treats a broker as a channel end to end, meets the
singleton requirement with the distribution already in place, and spreads consumers over nodes.

- **Types and behaviour.** `kafka` and `rabbitmq` are built-in adapters. A new capability `:consumer` marks adapters
  whose inbound side is a consumer; such adapters also implement `Converger.Channels.Broker` (`consumer_options/1`,
  `message_info/2`, `dead_letter/3`). Config fields can be `required: :inbound` / `required: :outbound`, required only
  in a channel mode that includes that direction, so an inbound-only Kafka channel needs no `topic_out`.
- **Envelope.** Outbound: the canonical activity ([ADR-0004](0004-single-canonical-activity-serializer.md)) plus
  `channel_id` and `event`; Kafka records are keyed by `conversation_id` (partition `phash2(key, partitions)`), so a
  conversation stays ordered. Inbound: the same shape; only client fields, `sender`, `participant`,
  `conversation_id` and `idempotency_key` are read, and `tenant_id` / `channel_id`, when present, must match.
- **Consumers.** `Converger.Channels.Consumers` is a `DynamicSupervisor` on every node. Each channel's consumer is a
  supervisor (`Converger.Channels.Broker.Consumer`, `:temporary`) registered as
  `{:global, {Consumer, channel_id}}`, running one Broadway pipeline. A manager per node
  (`Converger.Channels.Consumers.Manager`) reconciles: it reacts to channel changes published over PubSub by
  `Converger.Channels` (create, update, delete), to `nodeup`/`nodedown`, and runs every 30 s. The owner of a channel
  is the connected node with the highest `phash2({node, channel_id})`; a non-owner starts a consumer that is still
  missing on its next round. A consumer whose channel fingerprint (type, mode, status, tenant, config) changed is
  restarted on its node; a crashing consumer gives up after 3 restarts a minute and is restarted by the next round.
- **Idempotency.** The activity's idempotency key is the envelope's `idempotency_key`, else
  `<type>:<broker message id>` (Kafka `topic/partition/offset`, the AMQP `message_id`). `Inbound.receive_message/3`
  already turns a known key into a duplicate ([ADR-0015](0015-per-message-idempotent-inbound-batches.md)), so a
  redelivery creates nothing.
- **Poison messages and retries.** Decode errors, mismatched tenant or channel, unknown or closed conversations and
  rejected activities are dead-lettered at once to a per-channel topic (`<topic_in>.dlq`) or queue (`<queue>.dlq`)
  with `x-converger-error`; transient failures are retried in place with capped exponential backoff and then
  dead-lettered. The dead-letter write itself is retried until it succeeds; only then is the message acknowledged.
  Every message is acknowledged as successful to Broadway (`broadway_kafka` commits failed messages anyway).
- **Echo.** A consumed activity carries `metadata.converger_broker.channel_id`; the broker adapters skip delivering it
  back to that channel, which is the primary channel of the conversation it created.
- **Producing.** Each node keeps one producer connection per broker channel
  (`Converger.Channels.Broker.Publishers`, a `brod` client or an AMQP connection in confirm mode), replaced when the
  config changes and closed when idle. Deliveries return `provider_message_id` (`topic/partition/offset`, the activity
  id for RabbitMQ).
- **Security.** Broker hosts go through the webhook SSRF guard
  ([ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md)) at config time and when connecting; secrets live in
  the encrypted config ([ADR-0012](0012-secrets-at-rest-and-audit-redaction.md)), and `_password` keys are redacted.
- **Dependencies.** `broadway_kafka` 0.7 / `brod` 4.7 and `broadway_rabbitmq` 0.8 / `amqp` 4.2, pinned to their minor
  versions. `rabbit_common` pins `ranch` 2.2.0 (from 2.3.0; only `gen_smtp` uses it, with `>= 1.8`).
- **Pipeline transport unchanged.** The Broadway backend keeps its Kafka and RabbitMQ producers for internal
  throughput; the docs now name it the "pipeline transport" and recommend broker channels for integrations.

## Consequences

### Positive

- Integrations consume and produce conversations over their broker with a documented contract, per tenant, and
  everything that applies to channels (routing rules, middleware, delivery tracking, retries, circuit breaker, rate
  limits, health checks) applies to broker channels.
- At-least-once inbound without duplicate activities; nothing is acknowledged before it is stored or dead-lettered.
- A further broker (NATS JetStream, Redis Streams) is one adapter module implementing the two behaviours.

### Negative and trade-offs

- `:global` is not partition tolerant: during a netsplit both sides may consume one channel (no duplicates thanks to
  idempotency, but Kafka partitions or RabbitMQ messages are split between them until the split heals).
- One consumer per channel bounds a channel's inbound throughput to one node.
- A message whose dead-letter destination is missing stalls its partition (Kafka) or the consumer (RabbitMQ) until
  the destination exists; this is chosen over dropping it and is logged on every attempt.
- The Kafka offset-based key does not catch a message a producer wrote twice; producers that retry should send an
  `idempotency_key`. A RabbitMQ message without `message_id` has no stable id and is accepted again on redelivery.
- `brod` and Broadway use atom names: a handful of atoms per broker channel, created from validated channel UUIDs.
- `brod`'s CRC32C NIF (`crc32cer`) needs `cmake` to build and is not built on Windows: the Docker build stage installs
  `cmake`, and Kafka channels (and their tests) run on Linux or macOS only. RabbitMQ works everywhere.
- Kafka records are partitioned with `phash2`, not the murmur2 partitioner of the Java client.

### Follow-ups

- [#42](https://github.com/AimTune/converger/issues/42): `nats` (JetStream) and `redis_streams` channel types on the
  same `Converger.Channels.Broker` behaviour.
- Mutual TLS (client certificates) and SASL OAUTHBEARER for Kafka.
- A tool to replay a dead-letter topic or queue into its inbound topic from the admin panel.

## Implementation

- Adapters: [`kafka.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/kafka.ex),
  [`rabbitmq.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/rabbitmq.ex).
- Shared handling: [`broker.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/broker.ex)
  (behaviour, `handle/4`, idempotency key, retries, dead-lettering, echo), `broker/envelope.ex`,
  `broker/pipeline.ex` (the Broadway consumer), `broker/consumer.ex` (the `:global` supervisor),
  `broker/publishers.ex`, `broker/kafka_publisher.ex`, `broker/amqp_publisher.ex`.
- Consumers: [`consumers.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/consumers.ex) and
  `consumers/manager.ex`; started in `Converger.Application` after the endpoint; `Converger.Channels` notifies them on
  create, update and delete. Config `config :converger, :broker_channels` (`BROKER_CONSUMERS`,
  `BROKER_RECONCILE_INTERVAL_MS`).
- Adapter behaviour: `:consumer` capability and `required: :inbound | :outbound` in
  [`adapter.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapter.ex); the channel
  changeset passes the mode.
- Tests: unit tests without a broker (`test/converger/channels/broker_test.exs`, `consumers_test.exs` with a
  `Broadway.DummyProducer` test adapter, `adapters/kafka_test.exs`, `adapters/rabbitmq_test.exs`,
  `broker/envelope_test.exs`); end-to-end suites against real brokers tagged `:kafka` and `:rabbitmq`
  (`kafka_integration_test.exs`, `rabbitmq_integration_test.exs`), excluded by default and run by the optional CI job.

## Links

- [Broker channels](../channels/brokers.md), [Kafka](../channels/kafka.md), [RabbitMQ](../channels/rabbitmq.md)
- [Delivery pipeline](../architecture/delivery-pipeline.md) (the pipeline transport)
- [Clustering](../operations/clustering.md), [Configuration](../operations/configuration.md#broker-channels)
