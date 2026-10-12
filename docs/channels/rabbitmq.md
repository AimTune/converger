---
title: RabbitMQ
description: Configuration, queues and exchanges, publisher confirms, message ids, dead-letter queue and TLS of the rabbitmq broker channel.
sidebar_position: 3.7
---

The `rabbitmq` adapter makes a RabbitMQ broker (AMQP 0-9-1) a channel
([`lib/converger/channels/adapters/rabbitmq.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/rabbitmq.ex)).
It supports the modes `inbound`, `outbound` and `duplex`: inbound messages are consumed from `queue`, and activities the
pipeline delivers to the channel are published to `exchange` with `routing_key`. What broker channels share (the
envelope, idempotency, dead letters, consumers in a cluster, security) is described in [Broker channels](brokers.md);
this page covers what is specific to RabbitMQ.

## Setup

1. Create the inbound queue and the dead-letter queue (default `<queue>.dlq`), and the exchange and bindings your
   services read the outbound messages from, or set `declare: true` to have the consumer declare the two queues
   (durable classic queues without arguments).
2. Allow the broker host in the SSRF guard when it is private: `WEBHOOK_ALLOWED_TARGETS=rabbitmq.internal`, see
   [security](brokers.md#security).
3. Create the channel (admin **Channels** page, tenant portal or `POST /api/v1/channels`) with type `rabbitmq`:

   ```json
   {
     "name": "Bot runtime",
     "type": "rabbitmq",
     "mode": "duplex",
     "config": {
       "url": "amqps://rabbitmq.internal:5671/converger",
       "username": "converger",
       "password": "…",
       "queue": "bot.converger.in",
       "exchange": "converger",
       "routing_key": "bot.replies"
     }
   }
   ```

4. Route the channel with routing rules (for example from a web chat `websocket` channel to the bot, so the bot gets
   every user message on its queue). The bot answers by publishing an envelope with the `conversation_id` to the
   channel's queue.

## Configuration

The `config` map is encrypted at rest; `password` is masked in the admin UI and redacted in audit logs.

| Key | Required | Description |
| --- | --- | --- |
| `url` | yes | `amqp://host[:port][/vhost]` or `amqps://…` (TLS, port 5671 by default). The virtual host is URL-encoded (`%2F` is `/`, the default). No credentials, query or fragment in the URL. The host is checked by the SSRF guard. |
| `username`, `password` | no | Broker credentials (default: the broker's, usually `guest`, which RabbitMQ only accepts from localhost). |
| `queue` | in modes `inbound`, `duplex` | Queue consumed for inbound messages. |
| `exchange` | no | Exchange activities are published to. Empty (default): the default exchange, which routes to the queue named by `routing_key`. |
| `routing_key` | in modes `outbound`, `duplex` | Routing key of published activities. |
| `dlq_queue` | no | Dead-letter queue, default `<queue>.dlq`. Must differ from `queue`. |
| `declare` | no | `true` declares `queue` and `dlq_queue` (durable) when the consumer connects. Default `false`: they must exist. |
| `prefetch_count` | no | Unacknowledged messages the consumer holds, 1 to 1000 (default 10). |
| `concurrency` | no | Processors of the consumer, 1 to 64 (default 1, which keeps the queue order). |
| `tls_verify` | no | `amqps` only: verify the broker certificate and host name (default `true`). |
| `tls_ca_cert` | no (API only) | PEM CA certificates to verify the broker with. Default: the operating system trust store. |

A config change restarts the channel's consumer and replaces its producer connections.

## Outbound

Each delivered activity is published to `exchange` with `routing_key`:

| Property | Value |
| --- | --- |
| body | the [outbound envelope](brokers.md#outbound) |
| `content_type` | `application/json` |
| `message_id` | the activity id (stable across retries: consumers deduplicate on it) |
| `type` | the activity type |
| `delivery_mode` | persistent |
| `app_id` | `converger` |
| `timestamp` | publish time (Unix seconds) |
| headers | `x-converger-event: activity.created`, `x-converger-conversation-id`, `x-converger-tenant-id` |

The channel is in publisher-confirm mode: the delivery is `sent` once the broker confirmed the message, and its provider
message id is the activity id. A message that no queue is bound for is dropped by RabbitMQ, as for any publisher, and
still counts as sent: bind a queue before the channel delivers. An authentication failure, a forbidden virtual host or
a broker host rejected by the SSRF guard is permanent (the delivery is dead-lettered after one attempt); a nack, a
confirm timeout or a lost connection is retried with the channel's retry policy (adapter default `timeout_ms: 10000`).
Each node keeps one connection per RabbitMQ channel, opened on the first delivery; publishes of a channel on a node are
sent one after the other.

## Inbound

The channel's consumer is a [Broadway](https://hexdocs.pm/broadway_rabbitmq) pipeline on `queue`. Every message body is
decoded as the [inbound envelope](brokers.md#inbound) and acknowledged once accepted or dead-lettered; a message
in flight when the consumer stops is requeued by the broker.

| Item | Value |
| --- | --- |
| Broker message id | the `message_id` property, so the default idempotency key is `rabbitmq:<message_id>`. **Set it when publishing**: without it (and without an envelope `idempotency_key`) a redelivered message creates a second activity |
| Ordering | queue order with `concurrency: 1` (the default) |
| Poison messages | published to `dlq_queue` through the default exchange (persistent, confirmed, `mandatory`), with the original body, `message_id` and headers plus `x-converger-error`, `x-converger-source` (`<queue>/<message_id>`) and `x-converger-channel-id` |

If the dead-letter queue does not exist, the publish is returned as unroutable and retried until it does (the consumer
stalls on that message): create it, or set `declare: true`.

## Health

Idle RabbitMQ channels are probed by the health check by opening (and closing) a connection with the channel's
credentials (5 s timeout).

## Limitations

- Client certificates (mutual TLS) are not supported; authentication is by username and password.
- Quorum queues and queues with arguments (TTL, length limits, a broker-side dead-letter exchange) are supported when
  you declare them yourself (`declare: false`).
- One consumer per channel in the cluster; use `prefetch_count` and `concurrency` for throughput.
