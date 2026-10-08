---
title: "ADR-0020: Per-subject, tenant-scoped socket ids and cluster-wide socket presence"
sidebar_label: "0020 Socket ids and presence"
description: Client WebSocket ids identify one end user (or conversation) within a tenant, and joined sockets are tracked per channel with Phoenix.Presence so a channel's sockets can be disconnected and counted.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#20](https://github.com/AimTune/converger/issues/20) |
| **Pull request** | [#81](https://github.com/AimTune/converger/pull/81) |
| **Related** | [ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md), [ADR-0017](0017-conversation-lifecycle-enforced-under-the-seq-lock.md), [ADR-0018](0018-keyset-pagination.md), [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md) |

Converger exposes two client socket endpoints: the Converger API socket (`/socket/converger`, `ConvergerWeb.ConvergerSocket`) and the legacy socket (`/socket`, `ConvergerWeb.UserSocket`). This ADR records how their sockets are identified, how they are forcibly disconnected, and how they are counted.

## Context and problem statement

Phoenix uses the value returned by a socket's `id/1` callback as a topic: `Endpoint.broadcast(id, "disconnect", %{})` closes **every** socket with that id, on every node. `ConvergerSocket.id/1` returned `"converger_socket:#{channel_id}"`, so every client of a channel shared one id. Any forced disconnect (a revoked token, a disabled channel, a banned user) would have dropped every user of that channel at once. Because of that, no code path ever used the id to disconnect anybody, and deactivating a channel left its sockets connected and receiving traffic.

The legacy `UserSocket` id was `"user_socket:#{sub}"`, which was not tenant-scoped: the same end-user id in two tenants collided, so disconnecting user `42` in tenant A would also disconnect user `42` in tenant B.

A shared id also made per-user presence and connection counting impossible, since Phoenix keeps no per-socket registry that can be queried by channel.

## Decision drivers

- A forced disconnect must affect exactly the intended subject and nobody else, across all nodes.
- Ids must be tenant-scoped; tenant isolation is a hard requirement.
- Deactivating or deleting a channel must disconnect its sockets right away and keep them from reconnecting.
- Hooks for future token revocation ([#52](https://github.com/AimTune/converger/issues/52)) and connection metrics ([#33](https://github.com/AimTune/converger/issues/33)).
- No new infrastructure: reuse Phoenix PubSub, which already spans the cluster.

## Considered options

1. **Per-subject ids plus `Phoenix.Presence` tracking per channel** - id `<prefix>:<tenant>:<subject>`, and each joined channel process tracks its socket id under `sockets:channel:<channel_id>`.
2. **Per-subject ids only** - disconnect a channel by computing every subject id from the database (participants, conversations).
3. **Keep the per-channel id** - use it as the channel-wide kill switch and add a second mechanism for per-user disconnects.
4. **A custom registry (`Registry` or ETS) of socket pids** - track transport pids per channel and kill them directly.

### Pros and cons of the options

**Option 1: per-subject ids plus Presence**

- Good: per-user and per-conversation disconnects are one broadcast to a precise id.
- Good: `Phoenix.Presence` is a CRDT replicated over PubSub, so the channel's socket list is cluster-wide and entries vanish automatically when the tracked process exits.
- Good: the same data gives a connection count.
- Bad: only sockets that **joined** a conversation are tracked; a connected socket that never joined is not in the list.
- Bad: Presence adds gossip traffic proportional to joins and leaves.

**Option 2: per-subject ids only**

- Good: no tracking state.
- Bad: the database does not know which subjects are currently connected, so a channel disconnect would broadcast to every possible subject, and still miss sockets whose subject is not in the database.

**Option 3: keep the per-channel id**

- Good: channel-wide disconnect stays a single broadcast.
- Bad: a socket has exactly one id, so per-user disconnects would need a separate mechanism anyway, and the tenant collision remains.

**Option 4: custom registry**

- Good: precise and cheap on one node.
- Bad: `Registry` is node-local; making it cluster-wide means re-implementing what Presence already provides.

## Decision

Chosen option: **"Per-subject ids plus `Phoenix.Presence` tracking per channel"** (option 1), because it makes every disconnect precise and cluster-wide using only primitives Phoenix already ships with.

Socket ids (built in `ConvergerWeb.Sockets`):

| Socket | Id | Subject |
| --- | --- | --- |
| Converger API | `converger_socket:<tenant_id>:user:<user_id>` | `user_id` claim of the token |
| Converger API, no user | `converger_socket:<tenant_id>:conversation:<conversation_id>` | the token's conversation |
| Legacy | `user_socket:<tenant_id>:<sub>` | `sub` claim |

Converger tokens gained an optional end-user id: `POST /api/v1/converger/tokens/generate` accepts a Direct Line-style body `{"user": {"id": "..."}}`, and the `user_id` claim survives conversation-token issuance and refresh. A channel-level token with neither a user nor a conversation gets a `nil` id (it cannot join a conversation anyway).

After join, both `ConvergerChannel` and `ConversationChannel` call `Sockets.track/3`, which registers the channel process under its socket id in topic `sockets:channel:<channel_id>` of `ConvergerWeb.SocketPresence`. The public API:

| Function | Effect |
| --- | --- |
| `Sockets.disconnect_user(tenant_id, user_id)` | disconnects that user on both endpoints |
| `Sockets.disconnect_conversation(tenant_id, conversation_id)` | disconnects Converger sockets identified by the conversation |
| `Sockets.disconnect_channel(channel_id)` | disconnects every tracked socket of the channel |
| `Sockets.count(channel_id)` | number of distinct tracked socket ids for the channel |

`Channels.update_channel/3` calls `disconnect_channel/1` after a change that leaves the channel non-active, and `delete_channel/2` after a delete. Reconnecting is blocked while the channel stays inactive: `ConvergerSocket.connect/3` requires `Channels.get_active_channel/2` to succeed, and `ConversationChannel.join/3` replies `{:error, %{reason: "channel_inactive"}}`.

## Consequences

### Positive

- Disconnecting one user leaves other users of the same channel connected (verified by a channel test).
- Tenant-scoped ids remove the cross-tenant collision.
- A disabled or deleted channel loses its sockets immediately and its tokens stop working for new connections.
- Token revocation ([#52](https://github.com/AimTune/converger/issues/52)) only has to call `disconnect_user/2`.

### Negative and trade-offs

- `count/1` counts distinct socket ids, not transport connections: one user with three tabs on the same subject counts once. It is a "connected subjects" gauge.
- All sockets of the same subject share an id, so disconnecting a user closes all of that user's tabs and devices. There is no per-device disconnect.
- Sockets that connected but never joined a conversation are not tracked and are not hit by `disconnect_channel/1`; they cannot receive conversation traffic, and Converger sockets of an inactive channel cannot connect in the first place.
- Presence state is eventually consistent across nodes; a disconnect issued right after a join on another node can miss that socket for the replication interval.
- The legacy `user_socket` id still uses the raw `sub` claim, so its format differs from the Converger socket's `user:` prefix.

### Follow-ups

- Token revocation, refresh rotation and scoped tokens: [#52](https://github.com/AimTune/converger/issues/52).
- A connections gauge built on `Sockets.count/1`: [#33](https://github.com/AimTune/converger/issues/33).
- User-visible presence and typing frames: [#25](https://github.com/AimTune/converger/issues/25).
- Connection limits, backpressure and socket draining on shutdown: [#27](https://github.com/AimTune/converger/issues/27).
- Unifying the two socket implementations into one protocol: [#23](https://github.com/AimTune/converger/issues/23); channel-scoped agent sockets in Converger Protocol v1: [#63](https://github.com/AimTune/converger/issues/63), [#64](https://github.com/AimTune/converger/issues/64).

## Implementation

- [`ConvergerWeb.Sockets`](https://github.com/AimTune/converger/blob/main/lib/converger_web/sockets.ex): `converger_socket_id/1`, `user_socket_id/1`, `disconnect_user/2`, `disconnect_conversation/2`, `disconnect_channel/1`, `count/1`, `track/3`.
- [`ConvergerWeb.SocketPresence`](https://github.com/AimTune/converger/blob/main/lib/converger_web/socket_presence.ex): `use Phoenix.Presence` on `Converger.PubSub`, started in [`Converger.Application`](https://github.com/AimTune/converger/blob/main/lib/converger/application.ex).
- [`ConvergerWeb.ConvergerSocket`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/converger_socket.ex) and [`ConvergerWeb.UserSocket`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/user_socket.ex): `id/1` delegates to `Sockets`; `ConvergerSocket.connect/3` requires an active channel.
- [`ConvergerWeb.ConvergerChannel`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/converger_channel.ex) and [`ConvergerWeb.ConversationChannel`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/conversation_channel.ex): track after join; the legacy channel refuses joins on inactive channels.
- [`Converger.Channels`](https://github.com/AimTune/converger/blob/main/lib/converger/channels.ex): `update_channel/3` and `delete_channel/2` trigger `disconnect_channel/1`.
- [`Converger.Auth.ConvergerToken`](https://github.com/AimTune/converger/blob/main/lib/converger/auth/converger_token.ex) (`:user_id` option and claim) and [`ConvergerWeb.ConvergerAPI.TokenController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/converger/token_controller.ex) (`user.id` body parameter).

Tests: [`test/converger_web/channels/sockets_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/channels/sockets_test.exs) checks that disconnecting one user leaves another user of the same channel connected, that deactivating a channel disconnects both socket types while a socket on another channel stays connected, and that reconnect and rejoin are refused afterwards.

## Links

- Issue [#20](https://github.com/AimTune/converger/issues/20), pull request [#81](https://github.com/AimTune/converger/pull/81)
- Epic [#57](https://github.com/AimTune/converger/issues/57) (v2.5 production hardening)
- [Phoenix.Socket `id/1`](https://hexdocs.pm/phoenix/Phoenix.Socket.html#c:id/1) and [Phoenix.Presence](https://hexdocs.pm/phoenix/Phoenix.Presence.html)
