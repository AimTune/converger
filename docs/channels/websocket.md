---
title: WebSocket channel type
description: What the websocket channel type does today, how WebSocket clients receive activities, and the planned first-class duplex adapter.
sidebar_position: 4
---

The `websocket` channel type is the home of conversations whose participants are connected over WebSockets: a web chat widget, an agent console, a test client. Today the adapter itself ([`lib/converger/channels/adapters/websocket.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/websocket.ex)) is a stub. Real-time delivery does not go through it; it goes through the PubSub broadcast that every activity gets after it is committed.

For the client side (sockets, topics, frames, tokens, replay), see the [WebSocket API](../websocket.md).

## What the adapter does today

| Callback | Behaviour |
| --- | --- |
| `supported_modes/0` | `["outbound"]`. Creating a `websocket` channel in another mode fails with `websocket channels only support modes: outbound`. |
| `validate_config/1` | Accepts any config. The only key read today is `presence` (`"identified"` default, `"all"`, `"off"`), which controls presence frames for client API sockets; it is read from the token's channel, so it works on every channel type ([WebSocket API](../websocket.md#presence)). |
| `deliver_activity/2` | Returns `:ok` without doing anything. |
| `parse_inbound/2` | `{:error, "websocket channel does not receive inbound webhooks"}`. |

In addition, `websocket` is **not** in the pipeline's list of adapter-delivered types (`@delivery_types ~w(echo webhook whatsapp_meta whatsapp_infobip)` in [`lib/converger/pipeline.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline.ex)). As a consequence:

- no delivery row and no delivery job is created for a `websocket` channel, so `deliver_activity/2` is never actually called by the pipeline;
- a `websocket` channel cannot be the target of a routing rule: targets of excluded types are filtered out;
- there is no record of whether any connected client received an activity;
- websocket channels are not part of [channel health checks](overview.md#channel-health).

## How clients receive activities

Every committed activity, whatever the channel type of its conversation, is broadcast by `Converger.Pipeline.broadcast/1` (run in the backend's `after_commit/1`, outside the database transaction):

```elixir
ConvergerWeb.Endpoint.broadcast!(
  "conversation:#{activity.conversation_id}",
  "new_activity",
  Converger.Activities.Serializer.canonical(activity)
)
```

The payload is the canonical activity JSON ([ADR-0004](../adr/0004-single-canonical-activity-serializer.md)), the same shape as the REST API. Two sockets consume this topic:

| Socket | Topic joined by the client | What the client gets |
| --- | --- | --- |
| `/socket` (`ConvergerWeb.UserSocket`, deprecated, see [migrating from the legacy surfaces](../api/migrating-from-legacy.md)) | `conversation:<conversation id>` | `new_activity` events with the canonical activity. The client can also push `new_activity` to create activities; replay with `last_activity_id` on join. |
| `/socket/converger/v1` (`ConvergerWeb.ProtocolSocket`, native [Protocol v1](../protocol/v1.md)) | none: one conversation per connection, chosen in `hello` | v1 frames (`text`, `conversationUpdate`, ...) with integer `seq`; replay after `hello.watermark`; sends over the socket with `clientId` and `ack`. The SSE stream `/api/v1/converger/conversations/:id/events` delivers the same frames. |
| `/socket/converger` (`ConvergerWeb.ConvergerSocket`, client API) | `converger:conversation:<conversation id>` | `activitySet` frames `{activities, watermark, has_more}`; replay after an opaque `watermark` on join ([ADR-0006](../adr/0006-per-conversation-seq-and-opaque-watermarks.md)); transient `deliveryStatus`, `typing` and `presence` frames ([ADR-0032](../adr/0032-transient-conversation-signals.md)). Clients send activities over REST or with the `postActivity` push ([WebSocket](../websocket.md#6-send-activities-over-the-socket)), and `typing` and `read` over the socket. |

Because the broadcast is independent of the channel type, a WebSocket client can follow a conversation on **any** channel (for example watch a WhatsApp conversation live), as long as its token authorizes that conversation. What the `websocket` type adds is a channel to own conversations that have no external provider: tokens for the client API are generated with the channel `secret` (`POST /api/v1/converger/tokens/generate`), and conversations created with those tokens belong to that channel.

Activities sent by WebSocket clients go through `Activities.create_client_activity/2` and therefore through the same pipeline as every other activity: middleware of the target channels, routing rules, deliveries and retries apply ([ADR-0003](../adr/0003-pipeline-is-the-only-delivery-path.md)). For example, a client writing into a conversation whose channel is `whatsapp_meta` (mode `outbound` or `duplex`) produces a WhatsApp delivery.

When a channel is deactivated (status other than `active`), its connected sockets are disconnected and cannot rejoin.

:::note
The broadcast is fire-and-forget. A client that is not connected when an activity is broadcast catches up through replay on its next join (`last_activity_id` or `watermark`), not through a buffered delivery.
:::

## Planned: first-class duplex adapter

Making `websocket` a real adapter is Planned ([#22](https://github.com/AimTune/converger/issues/22)). The proposal:

- `supported_modes/0` becomes `inbound`, `outbound` and `duplex`;
- `deliver_activity/2` broadcasts the canonical activity on a channel-scoped topic and reports the number of connected clients; with no client connected the delivery stays `pending` and is replayed on the next resume;
- deliveries are marked `sent` when a client acknowledges the frame, with an optional per-channel `require_ack`;
- inbound frames go through the same context function as inbound webhooks, so middleware and routing apply identically;
- the hardcoded type lists are replaced by adapter capabilities (adapter behaviour v2, Planned ([#36](https://github.com/AimTune/converger/issues/36))), so `websocket` channels can be routing targets, for example WhatsApp to an agent console;
- topics allow subscribing to a whole channel (agent console) or to a single conversation (end-user widget).

The wire protocol for this work is Converger Protocol v1 (spec in progress, [#21](https://github.com/AimTune/converger/issues/21), [#63](https://github.com/AimTune/converger/issues/63)).

## Related

- [WebSocket API](../websocket.md)
- [Channels and adapters](overview.md)
- [ADR-0020](../adr/0020-per-subject-socket-ids-and-presence.md): per-subject socket ids and presence.
