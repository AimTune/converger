---
title: MQTT
description: Configuration, topics and topic templates, persistent sessions, acknowledgement after commit, idempotency keys, dead letters, TLS and the end-to-end tests of the mqtt broker channel.
sidebar_position: 3.8
---

The `mqtt` adapter makes an MQTT broker a channel
([`lib/converger/channels/adapters/mqtt.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/mqtt.ex)):
devices and services publish to a topic filter Converger subscribes to, and activities the pipeline delivers to the
channel are published to a topic per conversation. It supports the modes `inbound`, `outbound` and `duplex`. What broker
channels share (the envelope, consumers in a cluster, routing, security) is described in
[Broker channels](brokers.md); this page covers what is specific to MQTT.

Converger speaks **MQTT 3.1.1** over TCP or TLS, with QoS 0 and 1. That covers Mosquitto, EMQX, HiveMQ, VerneMQ, AWS IoT
Core and most managed brokers. Not supported: QoS 2 (subscriptions are made with at most QoS 1, so the broker
downgrades QoS 2 messages), MQTT 5 features, MQTT over WebSocket, will messages. The client is part of Converger; why
it is not a Hex package is in [ADR-0055](../adr/0055-mqtt-channel-and-discord-gateway.md).

## Setup

1. Give Converger a broker user allowed to subscribe to `topic_in` and to publish to `topic_out` and `topic_dlq`.
2. Allow the broker host in the SSRF guard when it is private: `WEBHOOK_ALLOWED_TARGETS=mqtt.internal`, see
   [security](brokers.md#security).
3. Create the channel (admin **Channels** page, tenant portal or `POST /api/v1/channels`) with type `mqtt`:

   ```json
   {
     "name": "Thermostats",
     "type": "mqtt",
     "mode": "duplex",
     "config": {
       "host": "mqtt.internal",
       "port": 8883,
       "tls": true,
       "username": "converger",
       "password": "…",
       "topic_in": "devices/+/up",
       "topic_out": "devices/{conversation_id}/down"
     }
   }
   ```

4. Route the channel with routing rules, for example to an agent console `websocket` channel. A device subscribes to
   the downlink topic of its conversation (or a service subscribes to `devices/+/down` and dispatches).

A device publishes the [envelope](brokers.md#inbound) (JSON) with QoS 1:

```bash
mosquitto_pub -h mqtt.internal -p 8883 -u device-42 -P … -q 1 -t devices/42/up \
  -m '{"text":"Temperature 31C","participant":{"external_id":"thermostat-42"},"idempotency_key":"42-1700000000"}'
```

The `participant` makes every message of the device join its open conversation; the reply comes back on
`devices/<conversation id>/down` as the outbound envelope.

## Configuration

The `config` map is encrypted at rest; `password` is masked in the admin UI and redacted in audit logs.

| Key | Required | Description |
| --- | --- | --- |
| `host` | yes | Broker host name or IP address (no scheme, no port). Checked by the SSRF guard when the channel is saved and on every connection. |
| `port` | no | Default `1883`, or `8883` with `tls`. |
| `tls` | no | Connect with TLS (default `false`). |
| `tls_verify` | no | Verify the broker certificate and host name (default `true`). |
| `tls_ca_cert` | no (API only) | PEM CA certificates to verify the broker with. Default: the operating system trust store. |
| `username`, `password` | no | Broker credentials. A password needs a username. |
| `client_id` | no | Client id **prefix**, 1 to 64 letters, digits, `.`, `_` or `-` (default `converger`). See [client ids](#client-ids-and-sessions). |
| `topic_in` | in modes `inbound`, `duplex` | Topic filter subscribed for inbound messages. `+` (one level) and `#` (the rest, last level only) are allowed: `devices/+/up`, `crm/#`. |
| `topic_out` | in modes `outbound`, `duplex` | Topic activities are published to: a template in which `{conversation_id}`, `{channel_id}` and `{tenant_id}` are replaced. No wildcards. |
| `topic_dlq` | no | Dead-letter topic, a template like `topic_out`. Default `converger/dlq/{channel_id}`. |
| `qos` | no | `1` (default, at least once) or `0` (at most once): the QoS of the subscription and of published messages. |
| `keepalive` | no | Keepalive in seconds, 5 to 3600 (default 30). Converger pings every half keepalive and reconnects when the broker does not answer. |
| `derive_idempotency_key` | no | Default `true`: messages without an envelope `idempotency_key` get one derived from topic and payload ([idempotency](#idempotency)). |
| `conversation_idle_timeout_seconds`, `unsupported_activities` | no | As for every channel. |

`topic_out` and `topic_dlq` must not match `topic_in`: Converger would consume what it publishes. Saving such a config
fails with `must not match topic_in`.

## Inbound

`Converger.Channels.Consumers` runs **one subscriber per channel in the cluster**
(`Converger.Channels.Mqtt.Subscriber`), on the node that owns the channel, like the Kafka and RabbitMQ consumers
([consumers in a cluster](brokers.md#consumers-in-a-cluster)). It subscribes to `topic_in` in a **persistent session**
(`clean_session: false`): the broker keeps the subscription while the subscriber is stopped, restarting or moving to
another node, and queues the QoS 1 messages published meanwhile. They arrive when the subscriber reconnects.

Messages are handled one at a time, in arrival order, like any broker message: the payload is decoded as the
[envelope](brokers.md#inbound), the idempotency key is set, and `Converger.Inbound.receive_message/3` creates the
activity (routing rules, middleware, deliveries). `metadata.converger_broker.source` is the topic the message was
published to.

**Acknowledgement after commit.** A QoS 1 message is acknowledged (`PUBACK`) only after its activity is committed or
it was dead-lettered. If the subscriber stops before that (a crash, a node shutdown, a lost connection), the broker
delivers the message again to the session's next connection, and its idempotency key turns it into a duplicate
instead of a second activity. QoS 0 messages are never acknowledged and are lost if the subscriber stops while
handling them.

Retained messages are delivered on every subscribe (each time the subscriber connects); with an idempotency key they
are duplicates after the first time.

### Idempotency

MQTT packet ids are reused as soon as a message is acknowledged, so they cannot identify a message. The idempotency key
is, in order:

1. the envelope's `idempotency_key` (recommended: a device id plus a counter or timestamp);
2. else, with `derive_idempotency_key: true` (the default), `mqtt:<hex SHA-256 of topic, NUL, payload>`;
3. else none: a redelivered message creates a second activity.

The derived key makes redeliveries duplicates, but it also makes **two byte-identical payloads on the same topic one
message**, forever (idempotency keys are not time-limited). A device that sends `{"text":"ping"}` every hour gets one
activity. Add a varying field (a timestamp, a counter) or an `idempotency_key` to such messages, or set
`derive_idempotency_key: false` and accept a duplicate in the rare case of a redelivery (only messages in flight while
a subscriber stops are redelivered).

### Poison messages and dead letters

As for every broker channel ([poison messages and retries](brokers.md#poison-messages-and-retries)): a message that
can never be accepted is dead-lettered at once, a transient failure is retried in place and dead-lettered after
`inbound_max_attempts`. MQTT 3.1.1 has no message headers, so the dead letter published (QoS 1) to `topic_dlq` is a
JSON object:

```json
{
  "error": "message body is not valid JSON",
  "source": "devices/42/up",
  "channel_id": "3f0c6e8e-5a51-4f38-9d6c-2f3e2f8c1a10",
  "message_id": "9b1c…",
  "payload": "{not json"
}
```

`payload` is the original payload as a string, or `payload_base64` when it is not UTF-8; `message_id` is the derived id
(or `null`). The message is acknowledged once the dead letter is published; the publish is retried until it succeeds.

## Outbound

Every activity the pipeline delivers to the channel is published to `topic_out` (with `{conversation_id}`,
`{channel_id}` and `{tenant_id}` replaced) as the [outbound envelope](brokers.md#outbound), QoS `qos`, not retained.
With QoS 1 the delivery is `sent` once the broker acknowledged the message (`PUBACK`). The delivery's
`provider_message_id` is the activity id; `mqtt_topic` in its metadata is the topic.

Each node keeps one publishing connection per channel (clean session), opened on the first delivery, replaced when
the channel's config changes and closed after 15 minutes without deliveries.

| Failure | Retried |
| --- | --- |
| broker unreachable, connection lost, no `PUBACK` within the delivery timeout (10 s by default), broker unavailable (`CONNACK` 3) | yes |
| bad user name or password (`CONNACK` 4), not authorised (`CONNACK` 5), client id rejected (2), protocol version refused (1), host blocked by the SSRF guard, invalid topic | no |

MQTT 3.1.1 has no negative acknowledgement: a broker that denies a publish by ACL usually still acknowledges it
(Mosquitto does), so such a message is `sent` but dropped by the broker. Check the broker's ACL when devices receive
nothing.

## Client ids and sessions

| Connection | Client id | Session |
| --- | --- | --- |
| Subscriber (one in the cluster) | `<client_id>-<channel id>-s<hash of topic_in and qos>` | persistent (`clean_session: false`) |
| Publisher (one per node) | `<client_id>-<channel id>-p<hash of the node name>` | clean |
| Health probe | `<client_id>-<channel id>-h<random>` | clean |

The ids are up to about 110 characters: Mosquitto, EMQX, HiveMQ and AWS IoT Core accept them; MQTT 3.1.1 only obliges
brokers to accept 23. Changing `topic_in` or `qos` changes the subscriber's client id, and so starts a new session (MQTT
3.1.1 cannot remove the old filter from a session). Sessions of deleted channels or old filters stay on the broker
until it expires them: set the broker's session expiry (Mosquitto `persistent_client_expiration`, EMQX
`session_expiry_interval`).

## Health probe

Connects with the probe client id and a clean session, waits for `CONNACK` (5 seconds) and disconnects: checks the
host, TLS and credentials.

## Running the MQTT tests

Unit tests (packet codec, connection, config, subscriber and publisher against a scripted fake broker) run with
`mix test`. The end-to-end suite runs against a real broker and is excluded by default (tag `:mqtt`): a message
published to `topic_in` reaches a WebSocket client through a routing rule and the WebSocket reply is published to the
conversation's `topic_out`; a stopped subscriber gets the QoS 1 messages published meanwhile, without duplicates; a
subscriber killed after the commit and before its `PUBACK` gets the message again as a duplicate; poison messages
reach `topic_dlq`.

```bash
docker run -d --name mosquitto -p 1883:1883 eclipse-mosquitto:2 mosquitto -c /mosquitto-no-auth.conf
MQTT_HOST=localhost MQTT_PORT=1883 mix test --only mqtt
```

(In Git Bash on Windows, prefix the `docker run` with `MSYS_NO_PATHCONV=1`.) CI runs the suite in the optional
"Broker channel suites" job.

## Related

- [Broker channels](brokers.md), [Kafka](kafka.md), [RabbitMQ](rabbitmq.md)
- [ADR-0055](../adr/0055-mqtt-channel-and-discord-gateway.md), [ADR-0047](../adr/0047-broker-channels-kafka-and-rabbitmq.md)
