---
title: Redis Streams
description: Configuration, consumer group, XADD with MAXLEN, entry ids as message ids, pending-entry recovery with XAUTOCLAIM, dead-letter stream and TLS of the redis_streams broker channel.
sidebar_position: 3.9
---

The `redis_streams` adapter makes Redis Streams a channel
([`lib/converger/channels/adapters/redis_streams.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/redis_streams.ex)).
It supports the modes `inbound`, `outbound` and `duplex`: inbound entries are read from `stream_in` with a consumer
group, and activities the pipeline delivers to the channel are appended to `stream_out` with `XADD`. What broker
channels share (the envelope, idempotency, dead letters, consumers in a cluster, security) is described in
[Broker channels](brokers.md); this page covers what is specific to Redis. The design is recorded in
[ADR-0054](../adr/0054-nats-and-redis-streams-channels.md).

Redis 6.2 or later is required (`XAUTOCLAIM`); Redis 7 is recommended. Valkey and other servers that implement the
stream commands work the same way.

## Setup

1. Nothing to create in Redis: the consumer creates the consumer group (and `stream_in`, `MKSTREAM`) when it is
   missing, and `XADD` creates `stream_out` and the dead-letter stream.
2. Allow the Redis host in the SSRF guard when it is private: `WEBHOOK_ALLOWED_TARGETS=redis.internal`, see
   [security](brokers.md#security).
3. Create the channel (admin **Channels** page, tenant portal or `POST /api/v1/channels`) with type `redis_streams`:

   ```json
   {
     "name": "Bot queue",
     "type": "redis_streams",
     "mode": "duplex",
     "config": {
       "url": "rediss://redis.internal:6380/0",
       "username": "converger",
       "password": "…",
       "stream_in": "bot.in",
       "stream_out": "bot.out",
       "maxlen": 100000
     }
   }
   ```

4. Route the channel with routing rules. An external service writes into a conversation by adding an entry whose
   `payload` field is an [inbound envelope](brokers.md#inbound):

   ```bash
   redis-cli XADD bot.in '*' payload '{"text":"Where is my order?","participant":{"external_id":"cust-1"}}'
   ```

## Configuration

The `config` map is encrypted at rest; `password` is masked in the admin UI and redacted in audit logs.

| Key | Required | Description |
| --- | --- | --- |
| `url` | yes | `redis://host[:port][/db]` or `rediss://…` (TLS), port 6379 and database 0 by default. No credentials, query or fragment in the URL. The host is checked by the SSRF guard. |
| `username`, `password` | no | Credentials: `password` alone authenticates the `default` user (`requirepass`); `username` (an ACL user) needs a password. |
| `stream_in` | in modes `inbound`, `duplex` | Stream read for inbound entries. |
| `stream_out` | in modes `outbound`, `duplex` | Stream activities are appended to. Must differ from `stream_in`. |
| `group` | no | Consumer group, default `converger-<channel id>`. Created at `start_id` when missing. |
| `dlq_stream` | no | Dead-letter stream, default `<stream_in>.dlq`. Must differ from `stream_in`. |
| `maxlen` | no | Trim `stream_out` to about this many entries (`XADD … MAXLEN ~ n`), 1 to 10^9. Default: no trimming. |
| `start_id` | no | Where a new consumer group starts: `earliest` (default, the whole stream) or `latest` (entries added after it is created). Ignored for an existing group. |
| `batch_size` | no | Entries per read, 1 to 1000 (default 10). |
| `concurrency` | no | Processors of the consumer, 1 to 64 (default 1, which keeps the stream order). |
| `tls_verify` | no | `rediss` only: verify the server certificate and host name (default `true`). |
| `tls_ca_cert` | no (API only) | PEM CA certificates to verify the server with. Default: the operating system trust store. |

Stream and group names are Redis keys of at most 512 bytes without whitespace. A config change restarts the channel's
consumer and replaces its producer connections.

## Outbound

Each delivered activity is appended to `stream_out` with `XADD stream_out [MAXLEN ~ maxlen] * …`, with the fields:

| Field | Value |
| --- | --- |
| `payload` | the [outbound envelope](brokers.md#outbound) |
| `content_type` | `application/json` |
| `event` | `activity.created` |
| `activity_id` | the activity id (stable across retries: consumers deduplicate on it) |
| `conversation_id`, `tenant_id` | the activity's conversation and tenant |

The delivery is `sent` once Redis replied with the entry id; its provider message id is `<stream_out>/<entry id>`. A
retried delivery appends a second entry (Redis has no producer deduplication), with the same `activity_id`. A
`WRONGTYPE` (`stream_out` is not a stream), `NOPERM` or `WRONGPASS` error and a host rejected by the SSRF guard are
permanent (the delivery is dead-lettered after one attempt); a lost connection or a timeout is retried with the
channel's retry policy (adapter default `timeout_ms: 10000`). Each node keeps one connection per Redis channel, opened
on the first delivery. One stream keeps the order in which the conversation's activities are delivered.

## Inbound

The channel's consumer is a Broadway pipeline with a consumer-group producer
([`RedisStreamsProducer`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/broker/redis_streams_producer.ex)).
It is a member of `group` named after its node (`converger@host-1`), and reads with two connections: one for blocking
reads (`XREADGROUP … BLOCK 2000 … >`), one for acknowledgements.

| Item | Value |
| --- | --- |
| Envelope | the entry's `payload` field. An entry without one is dead-lettered (`message has no payload`); its other fields are kept as headers for the dead-letter entry |
| Acknowledgement | `XACK` after the entry is accepted or dead-lettered |
| Broker message id | `<stream_in>/<entry id>`, so the default idempotency key is `redis_streams:<stream>/<entry id>` (for example `redis_streams:bot.in/1760000000000-0`) |
| Resuming | the group stores the last delivered id; entries delivered but not acknowledged stay in the group's pending entries list (PEL) |
| Pending-entry recovery | on every start, before reading new entries, the consumer walks the PEL with `XAUTOCLAIM` and takes over every pending entry, whichever consumer of the group it was delivered to (this node's earlier run, or the consumer of a node that died). The channel's consumer is a singleton in the cluster, so these entries are not being processed elsewhere |
| Ordering | stream order with `concurrency: 1` (the default); recovered entries come before new ones |
| Poison entries | appended to `dlq_stream` with the original fields plus `x-converger-error`, `x-converger-source` (`<stream_in>/<entry id>`) and `x-converger-channel-id` |

An entry trimmed from `stream_in` (by `MAXLEN` or `XDEL`) while pending is dropped from the PEL by Redis and skipped.
A replay (`XGROUP SETID <stream> <group> 0`) brings the same entry ids again: each is recognised as a duplicate.
Consumer names of nodes that left stay in the group (with no pending entries after a recovery); remove them with
`XGROUP DELCONSUMER` if you like.

## Health

Idle Redis channels are probed by the health check: a connection with the channel's credentials and a `PING`
(5 s timeout).

## Limitations

- Redis Cluster and Sentinel are not supported: the channel connects to one server (use a single primary, or a proxy
  that presents one).
- Client certificates (mutual TLS) are not configurable.
- One consumer per channel in the cluster; use `batch_size` and `concurrency` for throughput.
