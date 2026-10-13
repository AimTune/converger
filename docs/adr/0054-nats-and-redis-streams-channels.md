---
title: "ADR-0054: NATS JetStream and Redis Streams channels with own Broadway producers on gnat and redix"
sidebar_label: "0054 NATS and Redis Streams channels"
description: NATS JetStream and Redis Streams become broker channel types on the ADR-0047 machinery; both get a small Broadway producer of our own (a JetStream durable pull consumer on gnat, a Redis consumer group with XAUTOCLAIM recovery on redix), the broker position (stream sequence, entry id) is the message id, and dead letters go to a per-channel subject or stream.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-13 |
| **Issue** | [#42](https://github.com/AimTune/converger/issues/42) |
| **Pull request** | [#155](https://github.com/AimTune/converger/pull/155) |
| **Related** | [ADR-0047](0047-broker-channels-kafka-and-rabbitmq.md), [ADR-0012](0012-secrets-at-rest-and-audit-redaction.md), [ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md), [ADR-0038](0038-adapter-behaviour-v2-and-config-driven-registry.md) |

## Context and problem statement

[ADR-0047](0047-broker-channels-kafka-and-rabbitmq.md) made Kafka and RabbitMQ channel types on a generic
`Converger.Channels.Broker` behaviour: one Broadway consumer per channel in the cluster, every message through
`Converger.Inbound`, broker-message-id idempotency, per-channel dead letters, retries with backoff, echo suppression.
Issue [#42](https://github.com/AimTune/converger/issues/42) also asks for **NATS JetStream** and **Redis Streams**
with the same acceptance criteria: a message produced to the inbound subject or stream by an external script reaches a
WebSocket client through a routing rule and the reply appears on the outbound subject or stream; a restarted consumer
resumes from its committed position with no duplicates beyond at-least-once.

ADR-0047 predicted that a further broker would be one adapter module. The open questions were which client libraries
to build on, what the "broker message id" and the "committed position" are for each broker, and how un-acknowledged
messages come back after a crash, given that our consumer moves between nodes.

## Decision drivers

- Same guarantees as Kafka and RabbitMQ: acknowledge only after accepted or dead-lettered, a stable id per message
  for idempotency, resume after restarts and node moves, dead letters per channel.
- Maintained, pure-Elixir dependencies (no NIF, so they work on every platform, unlike `brod`'s `crc32cer`).
- Few moving parts: a cluster singleton consumer does not need multi-consumer failover machinery.
- Authentication and TLS options real deployments use (NATS: user/password, token, NKey, decentralized JWT creds;
  Redis: `requirepass`, ACL users, TLS).

## Considered options

NATS client:

1. **`gnat` 1.18** - the NATS client maintained under the nats-io organisation, pure Elixir, with the former
   `jetstream` package merged in (`Gnat.Jetstream`: stream and consumer management, pull requests, ack helpers).
2. **`jetstream` 0.0.x** - the separate JetStream package with a Broadway producer (`OffBroadway.Jetstream`).
3. Core NATS without JetStream.

Redis Streams consumer:

1. **`redix` 1.9 with a producer of our own** (`XREADGROUP`, `XACK`, `XAUTOCLAIM`).
2. **`off_broadway_redis_stream` 0.10** - a Broadway producer on `redix` with heartbeat-based failover between
   consumers (`XPENDING` + `XCLAIM` of consumers that missed heartbeats).

### Pros and cons of the options

#### gnat with a producer of our own

- Good, because it is maintained (releases every few weeks in 2026), pure Elixir, supports headers,
  `no_responders`, user/password, token, NKey and JWT (`.creds`) authentication and TLS, and keeps credentials out of
  crash reports when given as functions.
- Good, because the pull consumer loop is small: one open pull request (`batch`, `expires`) while there is demand,
  status messages (`408`, `409`) end a pull, `+ACK` / `-NAK` on the reply subject.
- Bad, because we own ~250 lines of producer code and its tests.

#### jetstream 0.0.x

- Bad, because every release is retired on Hex: the package was merged into `gnat`, and its Broadway producer did not
  move with it.

#### Core NATS

- Bad, because core NATS has no persistence or acknowledgement: a message published while the consumer is down is
  lost, which breaks the first driver.

#### redix with a producer of our own

- Good, because `redix` is the standard Redis client (tens of millions of downloads, maintained), pure Elixir.
- Good, because a cluster-singleton consumer only needs: create the group, claim everything pending once on start
  (`XAUTOCLAIM` with minimum idle time 0), then read new entries. No heartbeats, no claiming from live consumers.
- Bad, because we own ~200 lines of producer code.

#### off_broadway_redis_stream

- Good, because it exists and handles acknowledgements.
- Bad, because its failover is built for many concurrent consumers: a heartbeat process per consumer, dead
  consumers detected after missed heartbeats, then their pending entries claimed. Our consumer is a singleton that
  moves between nodes under a new consumer name; with the library, entries a crashed node left pending wait for the
  heartbeat timeout and its claim loop, and it raises on unexpected Redis replies (`{:ok, _} =` matches). It does not
  use `XAUTOCLAIM`.
- Bad, because it is one more dependency with a small user base (about 170k downloads, one release in 2026).

## Decision

Chosen options: **`gnat` (`~> 1.18.1`) and `redix` (`~> 1.9.2`), each with a small Broadway producer of our own**,
because they are the maintained clients, they are pure Elixir, and the producers we need are simpler than the
general-purpose ones exactly because the consumer is a cluster singleton (ADR-0047). Patch-level pins like the other
broker dependencies: the producers rely on their ack and request semantics.

### `nats` (JetStream)

- **Outbound**: a JetStream publish (a request answered by the stream with `{"stream", "seq"}`) to `subject_out`,
  where `{conversation_id}` is replaced with the conversation id so subscribers can filter one conversation.
  `Nats-Msg-Id` is the activity id, so a retried delivery within the stream's duplicate window is stored once. The
  connection uses `no_responders`: a subject no stream captures fails at once (retried) instead of timing out.
- **Inbound**: `Converger.Channels.Broker.NatsProducer` creates the durable pull consumer `durable_name` (default
  `converger-<channel id>`, explicit acks, filter `subject_in`) when missing, and the stream when `declare` is set.
  The **broker message id is `<stream>/<stream sequence>`**: the message's position in the stream, the same on every
  redelivery and on a replay. The **committed position** is the durable consumer's ack floor on the server, so any node
  resumes where the last one stopped. A message is `+ACK`ed after `Broker.handle/4`; a message arriving while the
  pipeline drains is `-NAK`ed (redelivered at once); one lost with a dying node comes back after `ack_wait`
  (default 300 s, long enough for the in-place retries).
- **Dead letters**: a JetStream publish to `dlq_subject` (default `<subject_in>.dlq`) with
  `Nats-Msg-Id: dlq:<stream>/<sequence>`, so a retried dead-letter write is stored once. Validation rejects a
  `dlq_subject` or `subject_out` that `subject_in` matches (the consumer would read its own output), and requires an
  explicit `dlq_subject` when `subject_in` has wildcards.
- **Connection check**: the NATS handshake does not wait for the server to accept the credentials, so every
  connection (consumer, publisher, health probe) is verified with a `$JS.API.INFO` request, which also proves
  JetStream is enabled for the account.

### `redis_streams`

- **Outbound**: `XADD stream_out [MAXLEN ~ maxlen] *` with the envelope in the `payload` field plus `content_type`,
  `event`, `activity_id`, `conversation_id`, `tenant_id`. Redis has no producer deduplication; consumers deduplicate on
  `activity_id`, as for Kafka.
- **Inbound**: `Converger.Channels.Broker.RedisStreamsProducer` joins consumer group `group` (default
  `converger-<channel id>`, created with `MKSTREAM` at `start_id`) as a consumer named after the node. On every start
  it first walks the group's pending entries list with `XAUTOCLAIM … 0` and takes over every un-acknowledged entry,
  whichever consumer it was delivered to; then it reads new entries with `XREADGROUP … BLOCK 2000 … >`. Blocking reads
  and `XACK`s use separate connections. The **broker message id is `<stream>/<entry id>`**; the **committed position**
  is the group's last delivered id plus the pending entries list.
- **Dead letters**: `XADD` to `dlq_stream` (default `<stream_in>.dlq`) with the original fields and the
  `x-converger-*` fields. An entry without a `payload` field is a poison message (`message has no payload`).

Both types are registered built-ins with the `:consumer` capability, use mode-dependent `required:` fields, check
every host with the webhook SSRF guard, keep credentials in the encrypted channel config (`nkey_seed` and `creds` are
added to the audit-redacted keys), and implement `health_probe/1`.

## Consequences

### Positive

- Four broker types on one behaviour; the shared machinery (consumers, idempotency, retries, dead letters, metrics)
  did not change, which confirms ADR-0047's design. The only shared change is that `message_info/2` may return a nil
  payload (decoded as the poison reason `message has no payload`).
- NATS and Redis channels work on Windows hosts too (no NIF).
- Redis entries a crashed node left pending are taken over on the next start, without waiting for a heartbeat
  timeout.

### Negative and trade-offs

- Two producers to maintain (pull-request lifecycle, status codes; group creation, `XAUTOCLAIM` cursor).
- `XAUTOCLAIM` with minimum idle time 0 relies on the consumer being a singleton: during a network partition in which
  `:global` lets two nodes run the consumer (ADR-0047), both may process the same pending entries. Idempotency keeps
  that to duplicates, not double activities.
- Redis 6.2+ is required (`XAUTOCLAIM`); Redis Cluster and Sentinel are not supported.
- NATS connects to one server at a time (the first reachable of `servers`) and reconnects through a pipeline restart;
  JetStream domains are not supported. A NATS message lost with a dying node is redelivered only after `ack_wait`.
- An existing durable consumer is not reconfigured when `subject_in`, `deliver_policy` or `ack_wait_seconds` change.

### Follow-ups

- Mutual TLS (client certificates) for all broker types, if requested.
- Redis Cluster support (one stream key per channel makes it a single-slot workload).

## Implementation

- Adapters: [`lib/converger/channels/adapters/nats.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/nats.ex),
  [`lib/converger/channels/adapters/redis_streams.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/redis_streams.ex).
- Producers: `Converger.Channels.Broker.NatsProducer`, `Converger.Channels.Broker.RedisStreamsProducer`; publishers
  (per node and channel, under `Converger.Channels.Broker.Publishers`): `NatsPublisher`, `RedisPublisher`.
- Registry: `@builtin_adapters` in `lib/converger/channels/adapter.ex`; dependencies `gnat`, `redix` in `mix.exs`.
- Tests: unit tests without a broker (`test/converger/channels/adapters/nats_test.exs`, `redis_streams_test.exs`);
  end-to-end suites against `nats:2.10 -js` and `redis:7` (`nats_integration_test.exs`, tag `:nats`;
  `redis_streams_integration_test.exs`, tag `:redis_streams`): external publish to WebSocket client and reply,
  restart without duplicates, replay recognised as duplicates, Redis pending-entry recovery from a dead consumer,
  dead letters, health probes. They run in the optional "Broker channel suites" CI job.

## Links

- [Broker channels](../channels/brokers.md), [NATS JetStream](../channels/nats.md),
  [Redis Streams](../channels/redis-streams.md)
- [NATS JetStream consumers](https://docs.nats.io/nats-concepts/jetstream/consumers),
  [Redis XAUTOCLAIM](https://redis.io/docs/latest/commands/xautoclaim/)
