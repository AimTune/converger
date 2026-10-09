---
title: Real-time
description: How Converger pushes activities to connected clients - the two Phoenix socket stacks, authentication, PubSub topics, socket identity, presence tracking and forced disconnects.
sidebar_position: 4
---

Converger is WebSocket-first: a client that holds a socket open sees every activity of its conversation as soon as it commits. Real-time fan-out is built on Phoenix Channels and Phoenix PubSub. This page explains the server side; the client-facing contract (frames, payloads, examples) is on the [WebSocket](../websocket.md) page.

Two socket stacks exist today, for historical reasons:

| | Legacy stack | Converger client API stack |
| --- | --- | --- |
| Socket path | `/socket` | `/socket/converger` |
| Socket module | [`ConvergerWeb.UserSocket`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/user_socket.ex) | [`ConvergerWeb.ConvergerSocket`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/converger_socket.ex) |
| Channel topic | `conversation:<conversation_id>` | `converger:conversation:<conversation_id>`, `converger:channel:<channel_id>` |
| Channel module | [`ConvergerWeb.ConversationChannel`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/conversation_channel.ex) | [`ConvergerWeb.ConvergerChannel`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/converger_channel.ex) |
| Token | `Converger.Auth.Token` (from `POST /api/v1/tokens`) | `Converger.Auth.ConvergerToken` (from `POST /api/v1/converger/tokens/generate` or `/conversations`) |
| Activity frame | `new_activity` (canonical map) | `activitySet` (`{activities, watermark, has_more}`) |
| Resume | `last_activity_id` in the join payload | opaque `watermark` in the join payload |
| Client sends | `new_activity` push | `new_activity` push (through `Converger.Inbound`) or REST; `ack` push |
| Delivery status | `delivery_status` pushed | not pushed |

Both are Phoenix sockets with `websocket: true` and `longpoll: false`, using the standard Phoenix V2 JSON serializer. A third socket, `/live`, serves LiveView for the admin and tenant UIs.

:::info Planned
The two stacks will be unified into one implementation of Converger Protocol v1 (spec in progress, [#21](https://github.com/AimTune/converger/issues/21), [#63](https://github.com/AimTune/converger/issues/63)); the legacy stack and its token family will be deprecated ([#23](https://github.com/AimTune/converger/issues/23)). Also planned: a raw WebSocket endpoint without Phoenix framing ([#26](https://github.com/AimTune/converger/issues/26)), client message ids with server acks ([#24](https://github.com/AimTune/converger/issues/24)), and receipts, typing and presence pushed to clients ([#25](https://github.com/AimTune/converger/issues/25)).
:::

## How an activity reaches a socket

```mermaid
sequenceDiagram
    participant A as Activities (after commit)
    participant PS as PubSub (conversation topic)
    participant LC as ConversationChannel process
    participant CC as ConvergerChannel process
    participant LV as Admin conversation LiveView
    participant C1 as Legacy client
    participant C2 as Converger API client

    A->>PS: broadcast "new_activity" (canonical map)
    PS->>LC: Phoenix.Socket.Broadcast
    LC->>C1: push "new_activity" (unchanged payload)
    PS->>CC: Phoenix.Socket.Broadcast (explicit subscription)
    CC->>C2: push "activitySet" (one activity, watermark, has_more false)
    PS->>LV: handle_info
```

- `Converger.Pipeline.broadcast/1` publishes `"new_activity"` on `conversation:<conversation_id>` with the canonical activity map ([ADR-0004](../adr/0004-single-canonical-activity-serializer.md)) **after** the activity's transaction committed ([Activity flow](activity-flow.md)).
- A `ConversationChannel` process is joined to exactly that topic, so Phoenix forwards the broadcast to the client as-is (no `intercept`).
- A `ConvergerChannel` process joined to `converger:conversation:<id>` of a conversation that belongs to the token's channel (**owned**) additionally calls `ConvergerWeb.Endpoint.subscribe("conversation:<id>")` in `join/3`. Its `handle_info/2` turns each `new_activity` broadcast into an `activitySet` frame with one activity (formatted by `ConvergerWeb.ConvergerAPI.ActivityJSON.activity_data/1`, the same function the REST API uses) and the watermark of that activity's `seq`. `delivery_status` broadcasts are received and dropped.

PubSub is cluster-wide, so a client connected to node B receives activities created on node A.

### Through the websocket channel adapter

Activities delivered to a `websocket` channel by the pipeline (the conversation's own channel or a routing rule target) are also broadcast by the adapter, after the channel's middleware ([WebSocket channel type](../channels/websocket.md), [ADR-0028](../adr/0028-websocket-channel-adapter-delivery.md)):

```mermaid
sequenceDiagram
    participant P as Pipeline (delivery job)
    participant WS as WebSocket adapter
    participant PS as PubSub
    participant RC as ConvergerChannel (routed conversation)
    participant CH as ConvergerChannel (channel topic)

    P->>WS: deliver_activity(channel, transformed)
    WS->>PS: "new_activity" on channel:<channel_id>
    WS->>PS: "new_activity" on channel:<channel_id>:conversation:<id>
    PS->>CH: push "activitySet" with conversation_id
    PS->>RC: push "activitySet" (seq-checked)
    WS-->>P: {:ok, %{connected_clients: n}} or {:pending, ...}
```

- A `ConvergerChannel` joined to `converger:conversation:<id>` of a conversation **routed** to its `websocket` channel subscribes to `channel:<channel_id>:conversation:<id>` instead of `conversation:<id>`, so it sees activities as delivered to its channel.
- A `ConvergerChannel` joined to `converger:channel:<channel_id>` subscribes to `channel:<channel_id>` and pushes every delivery with its `conversation_id`.

On a conversation topic the channel process keeps `last_seq`, starting from the conversation's head read in `join/3` before subscribing. A frame with `seq <= last_seq` is dropped (replay overlap, the same activity broadcast twice); a frame with `seq > last_seq + 1` makes it read the missing range from the database and push that instead (lost cross-node broadcast, concurrent delivery jobs, an activity halted by middleware).

## PubSub topics

| Topic | Event | Payload | Publisher |
| --- | --- | --- | --- |
| `conversation:<conversation_id>` | `new_activity` | canonical activity: `id`, `type`, `sender`, `text`, `attachments`, `metadata`, `idempotency_key`, `seq`, `conversation_id`, `tenant_id`, `inserted_at` | `Converger.Pipeline.broadcast/1` |
| `conversation:<conversation_id>` | `delivery_status` | `delivery_id`, `activity_id`, `channel_id`, `status`, `sent_at`, `delivered_at`, `read_at` | `Converger.Deliveries` on `sent`, dead letter (`failed`) and provider receipts |
| `channel_health` | `health_changed` | `channel_id`, `channel_name`, `tenant_id`, `previous_status`, `status`, `failure_rate`, `total_deliveries`, `failed_deliveries`, `checked_at` | `Converger.Channels.Health` (from `ChannelHealthWorker`) |
| `channel:<channel_id>` | `new_activity` | canonical activity, after the channel's middleware | `Converger.Channels.Adapters.WebSocket` |
| `channel:<channel_id>:conversation:<conversation_id>` | `new_activity` | canonical activity, after the channel's middleware | `Converger.Channels.Adapters.WebSocket` |
| `sockets:channel:<channel_id>` | presence diffs | socket id (or `anonymous:<pid>`) with meta `tenant_id` and `conversation_id`, or `scope: "channel"` | `ConvergerWeb.SocketPresence` |
| `converger_socket:<tenant_id>:user:<user_id>`, `converger_socket:<tenant_id>:channel:<channel_id>`, `converger_socket:<tenant_id>:conversation:<conversation_id>`, `user_socket:<tenant_id>:<sub>` | `disconnect` | `{}` | `ConvergerWeb.Sockets` |

Conversation lifecycle changes are not a separate event: closing or reopening a conversation creates a `conversationUpdate` activity (sender `"system"`, metadata `event`, `status`, `reason`), which flows through `new_activity` / `activitySet` like any other activity.

## Authentication

Both sockets authenticate once, in `connect/3`, from the `token` connect parameter. Both token types are HS256 JWTs signed by `Converger.Auth.Signer` with the endpoint's `secret_key_base` (`SECRET_KEY_BASE`), so rotating that secret invalidates all outstanding tokens. There is no per-message authentication; authorization to a conversation is checked on channel join.

### Legacy socket (`/socket`)

`UserSocket.connect/3` verifies the token with `Converger.Auth.Token.verify_token/1` and stores the claims. Tokens come from `POST /api/v1/tokens` (body `conversation_id`, `user_id`; header `x-channel-token`) and carry `conversation_id`, `tenant_id`, `sub` (the user id) and a 1 hour expiry.

`ConversationChannel.join/3` for `conversation:<id>`:

1. rejects with `{"reason": "unauthorized"}` unless the token's `conversation_id` equals `<id>`;
2. rejects with `{"reason": "channel_inactive"}` if the conversation's channel is not active in the token's tenant;
3. otherwise joins and, in `handle_info({:after_join, ...})`, tracks the socket in presence and replays missed activities if `last_activity_id` was given.

### Converger API socket (`/socket/converger`)

`ConvergerSocket.connect/3` verifies the token with `Converger.Auth.ConvergerToken.verify_token/1` (which also requires `"type": "converger"`) **and** checks that the token's channel is active (`Channels.get_active_channel/2`). A token for a deactivated channel cannot connect even before it expires.

Converger tokens carry `type`, `channel_id`, `tenant_id`, `sub` (`converger_<channel_id>`), an expiry (1800 s by default), and optionally `conversation_id`, `user_id` and `scope` (`channel`). Both joins require the token's channel to be active. `ConvergerChannel.join/3` for `converger:conversation:<id>` authorizes when the conversation exists in the token's `tenant_id`, the token's `conversation_id` claim (if any) equals `<id>`, and either:

- the conversation belongs to the token's `channel_id` (owned), or the token is restricted to this conversation, or
- the token's channel is a `websocket` channel and an enabled routing rule routes the conversation's channel to it (`Converger.RoutingRules.routes_to?/3`, routed).

`converger:channel:<channel_id>` requires `scope: "channel"`, `channel_id` equal to the token's, and a `websocket` channel. Any other topic is rejected with `{"reason": "invalid_topic"}`; a failed authorization with `{"reason": "unauthorized"}`.

## Socket identity

Phoenix lets a socket declare an `id/1`; broadcasting `"disconnect"` to that id closes every socket with it, on every node. Converger derives the id per **subject**, never per channel ([ADR-0020](../adr/0020-per-subject-socket-ids-and-presence.md)), in [`ConvergerWeb.Sockets`](https://github.com/AimTune/converger/blob/main/lib/converger_web/sockets.ex):

| Socket | Id | Derived from |
| --- | --- | --- |
| `ConvergerSocket` with `user_id` claim | `converger_socket:<tenant_id>:user:<user_id>` | `user.id` passed to `tokens/generate` |
| `ConvergerSocket` with `scope: "channel"` but no `user_id` | `converger_socket:<tenant_id>:channel:<channel_id>` | channel-scoped token (agent console) |
| `ConvergerSocket` with `conversation_id` but no `user_id` | `converger_socket:<tenant_id>:conversation:<conversation_id>` | conversation token |
| `ConvergerSocket` with none of them | `nil` (anonymous socket) | channel-level token |
| `UserSocket` | `user_socket:<tenant_id>:<sub>` | legacy token |

Ids are tenant-scoped, so the same user id in two tenants is two different subjects. Before [#81](https://github.com/AimTune/converger/pull/81) the Converger socket id was per channel, so disconnecting one user dropped every client of that channel.

`ConvergerWeb.Sockets` exposes:

| Function | Effect |
| --- | --- |
| `disconnect_user(tenant_id, user_id)` | Disconnects that user's sockets on both endpoints. |
| `disconnect_conversation(tenant_id, conversation_id)` | Disconnects Converger sockets identified by that conversation. |
| `disconnect_channel(channel_id)` | Disconnects every tracked socket that joined a conversation of the channel. |
| `count(channel_id)` | Number of distinct tracked sockets on the channel. |
| `count_connections(channel_id, conversation_id)` | Joined channel processes of the channel that receive the conversation's activities (joined to it, or following the whole channel). The `websocket` adapter's `connected_clients`. |

## Presence and channel-wide disconnects

Because socket ids are per subject, "every socket of a channel" cannot be addressed by one id. Instead, after a successful join both channels call `ConvergerWeb.Sockets.track/3`, which tracks the channel process in [`ConvergerWeb.SocketPresence`](https://github.com/AimTune/converger/blob/main/lib/converger_web/socket_presence.ex) (a `Phoenix.Presence` on `Converger.PubSub`) under the topic `sockets:channel:<channel_id>`, keyed by the socket id, with meta `tenant_id` and `conversation_id`. Presence is CRDT-replicated, so the list is cluster-wide, and an entry disappears automatically when the channel process exits.

`disconnect_channel/1` lists the socket ids on that topic and broadcasts `"disconnect"` to each. `Converger.Channels.update_channel/3` calls it whenever a channel ends up in a non-`active` status, and `delete_channel/2` calls it after deleting. Combined with the active-channel checks in `ConvergerSocket.connect/3` and `ConversationChannel.join/3`, a deactivated channel's clients are dropped and cannot reconnect while it stays inactive.

:::note
Sockets without an id (a `ConvergerSocket` connected with a channel-level token that has neither `user_id`, `scope` nor `conversation_id`) are tracked under an `anonymous:<pid>` key so that `count_connections/2` counts them, but `disconnect_channel/1` skips them: there is no id to disconnect. Issue tokens with `user.id` (or per conversation) for clients that must be force-disconnectable. Presence is used for server-side bookkeeping only; presence state is not pushed to clients today (planned, [#25](https://github.com/AimTune/converger/issues/25)).
:::

## Replay and resume

Live frames are not durable: a client that was disconnected misses them. Both channels replay from the database on join; the replay is capped at `ws_replay_limit` activities (`config :converger, :pagination`, default `100`, env `PAGINATION_WS_REPLAY_LIMIT`).

| Channel | Join payload | Replay | When more are pending |
| --- | --- | --- | --- |
| `ConversationChannel` | `{"last_activity_id": "<uuid>"}` | `new_activity` frames for activities with `seq` greater than that activity's `seq` (from the start of the conversation if the id is unknown) | a `replay_truncated` frame `{has_more: true, last_activity_id}`; rejoin with that id |
| `ConvergerChannel` | `{"watermark": "<opaque>"}` | one `activitySet` with the activities after the watermark and the new watermark | `has_more: true` in that frame; page the rest over `GET /api/v1/converger/conversations/:id/activities?watermark=` |

Without `last_activity_id` / `watermark` neither channel replays; the client starts live. An invalid watermark is treated like no watermark.

Watermarks encode the per-conversation `seq` (`Converger.ConvergerAPI.Watermark`: URL-safe Base64 of `seq:<n>`), so resuming needs no lookup and is exact ([ADR-0006](../adr/0006-per-conversation-seq-and-opaque-watermarks.md)). Legacy watermarks (Base64 activity ids) are still accepted.

`ConvergerChannel` queues the replay, then subscribes to the PubSub topic in `join/3`, so every live frame is handled after the replay and dropped when the replay already covered it (`last_seq`, see above). After a replay, it marks the replayed activities' pending deliveries to a `websocket` channel `sent` unless the channel has `require_ack: true` (`Converger.Deliveries.acknowledge/3`). A routed socket's replay runs the activities through its channel's middleware. Clients that also page over REST de-duplicate by activity `id`.

## Related

- [WebSocket](../websocket.md) for the client contract
- [Activity flow](activity-flow.md)
- [ADR-0004](../adr/0004-single-canonical-activity-serializer.md), [ADR-0006](../adr/0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0020](../adr/0020-per-subject-socket-ids-and-presence.md), [ADR-0024](../adr/0024-converger-protocol-v1-as-superset-of-mekik-1.md)
