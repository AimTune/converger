---
title: NATS JetStream
description: Configuration, stream and durable pull consumer, JetStream publish acks, message ids, dead-letter subject, authentication (user/password, token, NKey, creds) and TLS of the nats broker channel.
sidebar_position: 3.8
---

The `nats` adapter makes a NATS server with JetStream a channel
([`lib/converger/channels/adapters/nats.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/nats.ex)).
It supports the modes `inbound`, `outbound` and `duplex`: inbound messages are pulled from a durable consumer of a
JetStream stream, and activities the pipeline delivers to the channel are published to `subject_out` with a JetStream
publish. What broker channels share (the envelope, idempotency, dead letters, consumers in a cluster, security) is
described in [Broker channels](brokers.md); this page covers what is specific to NATS. The design is recorded in
[ADR-0054](../adr/0054-nats-and-redis-streams-channels.md).

Core NATS (without JetStream) is not supported: it has no persistence or acknowledgements, so neither direction could
keep the [delivery guarantees](brokers.md#delivery-guarantees-and-idempotency).

## Setup

1. Create a stream that captures the inbound subject and the dead-letter subject (default `<subject_in>.dlq`), and a
   stream that captures `subject_out`, or set `declare: true` to have the consumer create the inbound stream:

   ```bash
   nats stream add CRM --subjects "crm.in,crm.in.dlq" --storage file --defaults
   nats stream add CRM_OUT --subjects "crm.out.>" --storage file --defaults
   ```

2. Allow the server hosts in the SSRF guard when they are private: `WEBHOOK_ALLOWED_TARGETS=nats.internal`, see
   [security](brokers.md#security).
3. Create the channel (admin **Channels** page, tenant portal or `POST /api/v1/channels`) with type `nats`:

   ```json
   {
     "name": "CRM bus",
     "type": "nats",
     "mode": "duplex",
     "config": {
       "servers": "tls://nats-1.internal:4222,tls://nats-2.internal:4222",
       "username": "converger",
       "password": "…",
       "stream": "CRM",
       "subject_in": "crm.in",
       "subject_out": "crm.out.{conversation_id}"
     }
   }
   ```

4. Route the channel with routing rules. An external service writes into a conversation by publishing an
   [inbound envelope](brokers.md#inbound) to `subject_in`:

   ```bash
   nats pub crm.in '{"text":"Where is my order?","participant":{"external_id":"cust-1"}}'
   ```

## Configuration

The `config` map is encrypted at rest; `password`, `token` and `nkey_seed` are masked in the admin UI, and `password`,
`token`, `nkey_seed` and `creds` are redacted in audit logs.

| Key | Required | Description |
| --- | --- | --- |
| `servers` | yes | Comma-separated `nats://host[:port]`, `tls://host[:port]` or `host:port` (port 4222 by default), tried in order until one accepts the connection. No credentials or path. Every host is checked by the SSRF guard. |
| `stream` | in modes `inbound`, `duplex` | The JetStream stream consumed for inbound messages (letters, digits, `_`, `-`). |
| `subject_in` | in modes `inbound`, `duplex` | The durable consumer's filter subject in `stream`. Wildcards (`crm.in.*`, `crm.in.>`) are allowed when `dlq_subject` is set and does not match them. |
| `subject_out` | in modes `outbound`, `duplex` | Subject activities are published to, without wildcards. The token `{conversation_id}` is replaced with the activity's conversation id (`crm.out.{conversation_id}`). A stream must capture it. Must not match `subject_in`. |
| `durable_name` | no | Durable pull consumer, default `converger-<channel id>`. Created on `stream` when missing (explicit acks, filtered on `subject_in`). |
| `dlq_subject` | no | Dead-letter subject, default `<subject_in>.dlq`. Must not match `subject_in`; a stream must capture it. |
| `declare` | no | `true` creates `stream` with the subjects `subject_in` and `dlq_subject` (file storage, server defaults) when it does not exist. Default `false`: the stream must exist. |
| `deliver_policy` | no | Where a new durable consumer starts: `all` (default, the whole stream) or `new` (messages published after it is created). Ignored for an existing consumer. |
| `batch_size` | no | Messages per pull request, 1 to 256 (default 10). |
| `ack_wait_seconds` | no | The durable consumer's ack wait, 1 to 86400 (default 300): a message not acknowledged in this time is redelivered. It covers the in-place retries of a transient failure (about a minute with the default retry settings). Applied when the consumer is created. |
| `concurrency` | no | Processors of the consumer, 1 to 64 (default 1, which keeps the stream order). |
| `username`, `password` | no | User/password authentication. |
| `token` | no | Token authentication. |
| `nkey_seed` | no | NKey authentication: the user seed (`SU…`). |
| `creds` | no (API only) | Decentralized (JWT) authentication: the contents of a `.creds` file (user JWT and NKey seed). |
| `tls` | no | Connect with TLS (default `false`; a `tls://` server implies it). |
| `tls_verify` | no | Verify the server certificate and host name (default `true`). |
| `tls_ca_cert` | no (API only) | PEM CA certificates to verify the server with. Default: the operating system trust store. |

At most one authentication method (user/password, token, NKey seed or creds) can be set. The consumer, the publisher
and the health probe check the credentials (and that JetStream is enabled for the account) with a JetStream account
info request right after connecting, because the NATS handshake does not wait for the server to accept them; a server
that rejects them closes the connection (`connection_rejected`).

A config change restarts the channel's consumer and replaces its producer connections. Changing `subject_in`,
`deliver_policy` or `ack_wait_seconds` does not change an existing durable consumer: set a new `durable_name`, or edit
or delete the consumer with the `nats` CLI.

## Outbound

Each delivered activity is published to `subject_out` with a JetStream publish: a request answered by the stream once
it stored the message.

| Item | Value |
| --- | --- |
| subject | `subject_out`, with `{conversation_id}` replaced |
| body | the [outbound envelope](brokers.md#outbound) |
| `Nats-Msg-Id` | the activity id: a retried delivery of the same activity within the stream's duplicate window (default 2 minutes) is stored once |
| headers | `Content-Type: application/json`, `X-Converger-Event: activity.created`, `X-Converger-Activity-Id`, `X-Converger-Conversation-Id`, `X-Converger-Tenant-Id` |

The delivery is `sent` once the stream acknowledged the message; its provider message id is `<stream>/<sequence>`. A
subject no stream captures fails at once (`no_responders`) and is retried, so create the outbound stream before the
channel delivers. A message larger than the server's `max_payload` or rejected by the stream (`400`), and a server
host rejected by the SSRF guard, are permanent (the delivery is dead-lettered after one attempt); a timeout, an
unavailable stream (`503`) or a lost connection is retried with the channel's retry policy (adapter default
`timeout_ms: 10000`). Each node keeps one connection per NATS channel, opened on the first delivery.

Ordering: the stream keeps the publish order, and the activities of a conversation are delivered in order. With
`{conversation_id}` in `subject_out`, a subscriber can read one conversation (`crm.out.<id>`) or all (`crm.out.>`).

## Inbound

The channel's consumer is a Broadway pipeline with a pull-based producer
([`NatsProducer`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/broker/nats_producer.ex)): it
keeps one pull request (at most `batch_size` messages, expiring after 5 s) open on the durable consumer while the
pipeline has demand, so messages arrive as soon as they are published.

| Item | Value |
| --- | --- |
| Acknowledgement | `+ACK` on the message's reply subject after it is accepted or dead-lettered. A message that arrives while the consumer stops is `-NAK`ed (redelivered at once); one in flight when the node dies is redelivered after `ack_wait_seconds` |
| Broker message id | `<stream>/<stream sequence>`, so the default idempotency key is `nats:<stream>/<sequence>` (for example `nats:CRM/41`). The sequence is the message's position in the stream: the same on every redelivery and on a replay |
| Resuming | the durable consumer stores the acknowledged position on the server: a restarted consumer, on any node, continues after the last acknowledged message |
| Ordering | stream order with `concurrency: 1` (the default) |
| Poison messages | published with a JetStream publish to `dlq_subject`, with the original body and headers plus `X-Converger-Error`, `X-Converger-Source` (`<stream>/<sequence>`), `X-Converger-Channel-Id` and `Nats-Msg-Id: dlq:<stream>/<sequence>` (a repeated dead-letter write is stored once) |

Producers that retry a publish should set `Nats-Msg-Id`, so the stream stores the message once; the envelope
`idempotency_key` covers retries outside the duplicate window. If no stream captures `dlq_subject`, the dead-letter
write is retried until one does (the consumer stalls on that message): create it, or set `declare: true`.

## Health

Idle NATS channels are probed by the health check: a connection with the channel's credentials, the JetStream account
info request, and, when `stream` is set, the stream's info (5 s timeout).

## Limitations

- Client certificates (mutual TLS) are not configurable.
- One server connection at a time: the consumer and the publisher connect to the first reachable server of `servers`
  and reconnect (through a restart) when it closes; they do not follow the cluster's gossiped server list.
- JetStream domains and cross-account imports are not supported.
- One consumer per channel in the cluster; use `batch_size` and `concurrency` for throughput.
