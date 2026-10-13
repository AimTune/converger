---
title: "ADR-0055: MQTT channel with an in-house 3.1.1 client acknowledging after commit, and Discord Gateway inbound on the broker consumer infrastructure"
sidebar_label: "0055 MQTT and Discord Gateway"
description: The mqtt channel type uses a small in-house MQTT 3.1.1 client so a QoS 1 message is acknowledged only after its activity is committed (emqtt needs a QUIC NIF, tortoise311 acknowledges on receipt), keeps a persistent session per channel and derives idempotency keys from topic and payload; Discord gains an optional Gateway mode run as a consumer of the broker consumer infrastructure, which gets a generic child spec and a per-channel consume? callback.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-13 |
| **Issue** | [#44](https://github.com/AimTune/converger/issues/44) |
| **Pull request** | [#157](https://github.com/AimTune/converger/pull/157) |
| **Related** | [ADR-0038](0038-adapter-behaviour-v2-and-config-driven-registry.md), [ADR-0047](0047-broker-channels-kafka-and-rabbitmq.md), [ADR-0048](0048-additional-adapters-shared-meta-code-bot-framework-jwt-and-pull-outbox.md), [ADR-0015](0015-per-message-idempotent-inbound-batches.md), [ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md) |

## Context and problem statement

Issue [#44](https://github.com/AimTune/converger/issues/44) is the backlog of additional adapters.
[ADR-0048](0048-additional-adapters-shared-meta-code-bot-framework-jwt-and-pull-outbox.md) delivered Discord
(Interactions Endpoint only), Teams, Messenger, Instagram, Viber and HTTP pull, and left three items: an **MQTT**
channel, **Discord Gateway inbound**, and gRPC streaming (a separate decision).

- **MQTT** is the IoT case: devices publish to topics such as `devices/<id>/up` and subscribe to their own downlink
  topic. The channel has to consume a topic filter (with wildcards) at least once, publish replies per conversation,
  and survive restarts and node moves without losing the QoS 1 messages published meanwhile.
- **Discord Gateway**: interactions (slash commands, buttons) arrive by webhook, but plain channel and direct messages
  reach a bot only over the Gateway, a WebSocket the bot keeps open: identify, heartbeats, resume after a reconnect.

Both are inbound connections Converger has to hold open, once per channel in the cluster, started and stopped as
tenants change channels. [ADR-0047](0047-broker-channels-kafka-and-rabbitmq.md) built exactly that for Kafka and
RabbitMQ, but only for Broadway pipelines and only per channel type.

## Decision drivers

- No message lost: a QoS 1 message is acknowledged to the broker only once it is an activity or dead-lettered.
- No duplicate activities when a message is delivered again (restart, node move, resume replay).
- One connection per channel in the cluster, reusing the consumer supervision of ADR-0047 instead of a second one.
- Dependencies that build on every supported platform (Linux, macOS, Windows development machines) without a C
  toolchain beyond what the image already has.
- Adapters stay one module each ([ADR-0038](0038-adapter-behaviour-v2-and-config-driven-registry.md)).

## Considered options

MQTT client:

1. **`emqtt`** (EMQX, MQTT 5, maintained)
2. **`tortoise311`** (MQTT 3.1.1, pure Elixir, maintained) or its predecessor `tortoise` (last release 2021)
3. **An in-house MQTT 3.1.1 client** limited to what the channel needs

Consumer hosting:

1. **Generalise the ADR-0047 consumer** (a child spec per adapter, a per-channel `consume?/1`)
2. **A second supervisor and manager** for non-Broadway connections

Discord Gateway WebSocket client: **`mint_web_socket`** (already a test dependency) or **`websockex`** / **`fresh`**.

### Pros and cons of the options

#### `emqtt`

- Good, because it is the most complete client (MQTT 5, QUIC, WebSocket) and supports manual acknowledgements
  (`auto_ack: false`).
- Bad, because its Hex package requires `quicer` 0.2.15 (`optional: false` in its metadata), a NIF that builds msquic
  with `cmake` and fetches it at build time: no build on Windows, a heavier Docker build stage, and a C dependency we
  would use none of.

#### `tortoise311`

- Good, because it is pure Elixir with two small dependencies and builds everywhere.
- Bad, because it acknowledges a QoS 1 message **on receipt, before the handler runs**: the controller hands the
  `PUBLISH` to its inflight manager (`Inflight.track/2`), whose track for an incoming QoS 1 message dispatches the
  `PUBACK` first (`Inflight.Track.create(:positive, %Publish{qos: 1})`). A node that crashes between that `PUBACK`
  and the commit loses the message, which defeats the at-least-once guarantee the channel is for. `tortoise` (0.10,
  2021) has the same design and is unmaintained.

#### In-house client

- Good, because acknowledging after the commit is the whole point, and the subset is small: `CONNECT`/`CONNACK`,
  `SUBSCRIBE`/`SUBACK`, `PUBLISH` QoS 0 and 1 / `PUBACK`, `PINGREQ`/`PINGRESP`, `DISCONNECT` (about 250 lines of
  codec and 300 of connection), no dependency.
- Good, because MQTT 3.1.1 is what every broker speaks (Mosquitto, EMQX, HiveMQ, VerneMQ, AWS IoT Core).
- Bad, because we own a protocol implementation: covered by codec tests, a scripted fake broker in unit tests and an
  end-to-end suite against Mosquitto. No QoS 2, no MQTT 5 (session expiry, user properties), no WebSocket transport.

#### Generalised consumer vs a second supervisor

- A second supervisor would duplicate `:global` registration, rendezvous ownership, reconciliation and restart
  pacing. Generalising costs two optional callbacks.

#### `mint_web_socket` vs `websockex`

- `mint_web_socket` is maintained, depends only on `mint` (already a runtime dependency through Req/Finch) and is
  already used by the test suite; `websockex` would add a dependency for the same job.

## Decision

**MQTT: an in-house MQTT 3.1.1 client** (`Converger.Channels.Mqtt.Packet`, `Converger.Channels.Mqtt.Connection`),
because it is the only option that both builds everywhere and acknowledges after the commit.

- **Inbound**: one `Converger.Channels.Mqtt.Subscriber` per channel in the cluster, connected with
  `clean_session: false` and client id `<client_id>-<channel id>-s<hash of topic_in and qos>`, subscribed to
  `topic_in`. The broker keeps the subscription and queues QoS 1 messages while the subscriber is down or moving
  between nodes. Messages are handled one at a time, in order, by `Converger.Channels.Broker.handle/4` (envelope,
  `Converger.Inbound`, retries, dead-lettering); the connection sends `PUBACK` when the subscriber calls `ack/2`
  afterwards. A message the subscriber never acknowledges is redelivered with the same session. The hash in the
  client id starts a fresh session when the filter changes (MQTT 3.1.1 cannot list a session's subscriptions, so a
  reused session would keep the old filter).
- **Idempotency key**: the envelope's `idempotency_key`, else `mqtt:<hex SHA-256 of topic, NUL, payload>`. MQTT packet
  ids are reused as soon as a message is acknowledged, so they identify nothing. The derived key makes a redelivery a
  duplicate, at the cost that two byte-identical payloads on the same topic are one message: a device that repeats a
  reading must add a varying field (a timestamp or counter) or an `idempotency_key`. `derive_idempotency_key: false`
  turns the derivation off for channels whose devices legitimately repeat payloads; redeliveries (rare: only messages
  in flight during a crash) then create duplicates.
- **Outbound**: the canonical envelope published with QoS 1 (default) to `topic_out`, a template with
  `{conversation_id}`, `{channel_id}` and `{tenant_id}`, waiting for the `PUBACK`, through one publishing connection
  per channel and node (`Converger.Channels.Mqtt.Publisher`, clean session, under `Broker.Publishers`). Connection
  refusals for credentials or authorisation and invalid topics are permanent errors; everything else is retried.
- **Dead letters**: poison messages and exhausted retries are published to `topic_dlq` (default
  `converger/dlq/{channel_id}`) as a JSON object with the error, source topic and payload (MQTT 3.1.1 has no headers).
- **Validation**: the host goes through the SSRF guard; `topic_out` and `topic_dlq` must not match `topic_in` (the
  channel would consume its own messages).

**Consumers: generalise ADR-0047.** `Converger.Channels.Broker` gains two optional callbacks:
`consumer_child_spec/1` (the consumer process; default the Broadway pipeline) and `consume?/1` (whether this channel
needs one; default every active inbound or duplex channel of the type). `consumer_options/1`, `message_info/2` and
`dead_letter/3` become optional, and `Broker.handle_message/5` handles a message the consumer parsed itself (without
a dead-letter destination, a message that cannot be accepted is logged, counted and dropped).

**Discord Gateway: an optional mode of the `discord` adapter** (`gateway: true`, `gateway_intents`), not a new type,
so one channel carries interactions, Gateway messages and outbound together and replies keep using the participant's
`discord_channel_id`. `Converger.Channels.Discord.Gateway` (a `Mint.WebSocket` client, `mint_web_socket` moved from
test-only to runtime) identifies, heartbeats with a random first-beat jitter, treats a missing `HEARTBEAT_ACK` as a
zombie connection, resumes with `session_id` and the last sequence number on `resume_gateway_url`, follows op 7 and
op 9, and backs off on close codes no retry fixes (4004, 4010-4014). `MESSAGE_CREATE` events (not from the bot itself
or other bots) go to a linked worker with idempotency key `message:<id>`, so an event replayed by a resume is a
duplicate. The public key becomes optional in Gateway mode; without it every interaction is rejected.

## Consequences

### Positive

- MQTT inbound is at-least-once end to end: verified by a test that kills the subscriber after the commit and before
  the `PUBACK`, and gets the redelivery as a duplicate.
- No new Hex dependency for MQTT; `mint_web_socket` was already in the lock file.
- Any future pulled channel (NATS, Redis Streams, a provider stream) plugs into the same consumer supervision with a
  child spec.

### Negative and trade-offs

- Converger maintains an MQTT 3.1.1 client subset: no QoS 2, no MQTT 5, no WebSocket transport, no will messages.
- The persistent session of a deleted channel stays on the broker (MQTT 3.1.1 has no session expiry): configure the
  broker's expiry (Mosquitto `persistent_client_expiration`, EMQX `session_expiry_interval`).
- Derived idempotency keys merge byte-identical payloads on one topic (documented, switchable).
- Under MQTT 3.1.1 a publish the broker refuses by ACL is usually still acknowledged (Mosquitto does): outbound cannot
  detect it.
- The Discord Gateway has no acknowledgements: an event that cannot be stored after the retries is dropped (logged,
  `converger.broker.dead_lettered.count`), and events sent while no connection is open are recovered only by a
  resume within Discord's window. One shard: bots in 2500 guilds or more need sharding, which is not implemented.
- A Discord channel with `gateway: true` holds one Gateway session: running the same bot token in two channels (or
  in another program) with the Gateway opens two sessions that both receive every message.

### Follow-ups

- [#44](https://github.com/AimTune/converger/issues/44): gRPC streaming (separate pull request).
- MQTT 5 (session expiry, user properties for dead-letter headers, reason codes on `PUBACK`) if a broker deployment
  needs it.
- Discord Gateway sharding for large bots.

## Implementation

- `lib/converger/channels/mqtt/packet.ex`, `connection.ex`, `subscriber.ex`, `publisher.ex`;
  `lib/converger/channels/adapters/mqtt.ex` (type `mqtt`, `:consumer` capability).
- `lib/converger/channels/discord/gateway.ex`, `gateway_worker.ex`; `lib/converger/channels/adapters/discord.ex`
  (`gateway`, `gateway_intents`, `consume?/1`, `consumer_child_spec/1`, `parse_gateway_message/2`, `fetch_media/2`).
- `lib/converger/channels/broker.ex` (optional callbacks, `consumer_child_spec/1`, `handle_message/5`),
  `broker/consumer.ex`, `Converger.Channels.list_consumer_channels/0` (filtered by `Broker.consumes?/1`).
- Tests: `test/converger/channels/mqtt/` (codec; connection against `Converger.FakeMqttBroker`),
  `adapters/mqtt_test.exs` (config, subscriber, publisher, dead letters, health probe against the fake broker),
  `discord/gateway_test.exs` (against `Converger.FakeDiscordGateway`, a Bandit WebSocket server: identify,
  heartbeats, resume after op 7, zombie detection, op 9, close codes, `MESSAGE_CREATE`), and
  `mqtt_integration_test.exs` (tag `:mqtt`, Mosquitto, run in the optional broker CI job).

## Links

- [MQTT](../channels/mqtt.md), [Discord](../channels/discord.md#gateway-mode), [Broker channels](../channels/brokers.md)
- [MQTT 3.1.1 (OASIS standard)](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/mqtt-v3.1.1.html)
- [Discord Gateway documentation](https://discord.com/developers/docs/events/gateway)
