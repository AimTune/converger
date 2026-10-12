---
title: Kafka
description: Configuration, topics, consumer group, outbound keying, inbound idempotency, dead-letter topic, SASL and TLS of the kafka broker channel.
sidebar_position: 3.6
---

The `kafka` adapter makes an Apache Kafka cluster (or a Kafka-compatible broker such as Redpanda) a channel
([`lib/converger/channels/adapters/kafka.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/kafka.ex)).
It supports the modes `inbound`, `outbound` and `duplex`: inbound messages are consumed from `topic_in`, and activities
the pipeline delivers to the channel are produced to `topic_out`. What broker channels share (the envelope,
idempotency, dead letters, consumers in a cluster, security) is described in [Broker channels](brokers.md); this page
covers what is specific to Kafka.

## Setup

1. Create the topics (`topic_in`, `topic_out` and the dead-letter topic, default `<topic_in>.dlq`), unless the cluster
   creates topics automatically. Give `topic_out` as many partitions as you need consumers in parallel: activities are
   keyed by conversation, so the order within a conversation is kept on any partition count.
2. Allow the broker hosts in the SSRF guard when they are private: `WEBHOOK_ALLOWED_TARGETS=kafka-1.internal,kafka-2.internal`
   (or a CIDR range), see [security](brokers.md#security).
3. Create the channel (admin **Channels** page, tenant portal or `POST /api/v1/channels`) with type `kafka`:

   ```json
   {
     "name": "CRM events",
     "type": "kafka",
     "mode": "duplex",
     "config": {
       "brokers": "kafka-1.internal:9093,kafka-2.internal:9093",
       "topic_in": "crm.converger.in",
       "topic_out": "crm.converger.out",
       "sasl_mechanism": "scram_sha_512",
       "sasl_username": "converger",
       "sasl_password": "…",
       "tls": true
     }
   }
   ```

   The consumer starts within a second on one node of the cluster (log `Broker consumer started`).
4. Route the channel with routing rules, for example to an agent console (a `websocket` channel), as in
   [bridging another channel to an agent console](websocket.md#bridging-another-channel-to-an-agent-console). Replies
   posted to the conversation are produced to `topic_out`.

## Configuration

The `config` map is encrypted at rest; `sasl_password` is masked in the admin UI and redacted in audit logs.

| Key | Required | Description |
| --- | --- | --- |
| `brokers` | yes | Bootstrap brokers, comma-separated `host:port` (IPv6: `[::1]:9092`). Checked by the SSRF guard. |
| `topic_in` | in modes `inbound`, `duplex` | Topic consumed for inbound messages. |
| `topic_out` | in modes `outbound`, `duplex` | Topic the channel's activities are produced to. |
| `group_id` | no | Consumer group, default `converger-<channel id>`. Changing it restarts the consumer in the new group, which starts at `start_offset`: already accepted messages are recognised as duplicates. |
| `start_offset` | no | Where a consumer group without committed offsets starts: `earliest` (default, nothing produced before the channel was created is skipped) or `latest`. |
| `dlq_topic` | no | Dead-letter topic, default `<topic_in>.dlq`. Must differ from `topic_in`. |
| `concurrency` | no | Processors of the consumer, 1 to 64 (default 4). Messages of one partition are always processed in order, by one processor. |
| `sasl_mechanism` | no | `plain`, `scram_sha_256` or `scram_sha_512`. Requires `sasl_username` and `sasl_password`. |
| `sasl_username`, `sasl_password` | with `sasl_mechanism` | SASL credentials. |
| `tls` | no | `true` to connect with TLS (default `false`). |
| `tls_verify` | no | Verify the broker certificate and host name (default `true`). `false` accepts any certificate (testing only). |
| `tls_ca_cert` | no (API only) | PEM CA certificates to verify the broker with. Default: the operating system trust store. |

Like every channel it also takes `retry_policy` and `rate_limit` (outbound), and the shared config keys
(`conversation_idle_timeout_seconds`). A config change restarts the channel's consumer and replaces its producer
connections.

## Outbound

Each delivered activity is one Kafka record on `topic_out`:

| Part | Value |
| --- | --- |
| key | the `conversation_id` |
| partition | `:erlang.phash2(conversation_id, partition count)`: every activity of a conversation goes to one partition, so a consumer sees a conversation in order. (This is not the murmur2 partitioner of the Java client: do not rely on records produced by other clients with the same key landing on the same partition.) |
| value | the [outbound envelope](brokers.md#outbound) |
| headers | `content-type: application/json`, `x-converger-event: activity.created`, `x-converger-activity-id`, `x-converger-conversation-id` |

The produce waits for the acknowledgement of all in-sync replicas (`acks=all`). The delivery is then `sent`, and its
provider message id is `topic/partition/offset`. Failures are classified for the retry policy and the circuit breaker:
authorization and SASL failures, a broker host rejected by the SSRF guard, an invalid topic and a record that is too
large are permanent (the delivery is dead-lettered after one attempt); everything else (timeouts, leader changes,
unreachable brokers) is retried with the channel's retry policy (adapter default `timeout_ms: 10000`). Each node keeps
one producer client per Kafka channel, connected on the first delivery.

## Inbound

The channel's consumer is a [Broadway](https://hexdocs.pm/broadway_kafka) pipeline in consumer group `group_id`,
subscribed to `topic_in`. Every record value is decoded as the [inbound envelope](brokers.md#inbound); the record key
is not used (put the conversation or participant in the envelope). Offsets are committed after each processed message.

| Item | Value |
| --- | --- |
| Broker message id | `topic/partition/offset`, so the default idempotency key is `kafka:crm.converger.in/2/41` |
| Ordering | per partition; a message being retried holds back its partition |
| Poison messages | produced to `dlq_topic` with the original key, value and headers plus `x-converger-error`, `x-converger-source` (`topic/partition/offset`) and `x-converger-channel-id` |

Read the dead-letter topic with the console consumer:

```bash
kafka-console-consumer.sh --bootstrap-server kafka:9092 --topic crm.converger.in.dlq --from-beginning \
  --property print.headers=true --property print.key=true
```

## Health

Idle Kafka channels are probed by the health check with a metadata request for `topic_out` and `topic_in` (5 s
timeout): an unreachable cluster, failing authentication or a missing topic marks the channel `degraded`.

## Limitations

- The Kafka client (`:brod`) needs its CRC32C NIF, which is not built on Windows ([platform notes](brokers.md#platform-notes)).
- One consumer per channel: throughput of a channel's inbound side is bounded by one node. Use more partitions and
  `concurrency` for parallelism within it, or several channels on different topics.
- Client certificates (mutual TLS) and SASL `GSSAPI` / `OAUTHBEARER` are not supported.
- Producer-side idempotence (Kafka transactions, idempotent producer ids) is not used: a retried produce can write an
  activity twice; consumers deduplicate on the envelope `id`.
