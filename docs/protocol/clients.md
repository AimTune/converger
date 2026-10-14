---
title: Connecting chat clients (chativa)
sidebar_position: 4
description: How to point chativa's MekikConnector at Converger, which mekik/1 frames work, the mekik/1 profile of the native endpoint, and how the hub extras (receipts, history, upload, conversation list) map to chativa's IConnector.
---

# Connecting chat clients (chativa)

[chativa](https://github.com/AimTune/chativa) is Converger's reference WebSocket client
([#65](https://github.com/AimTune/converger/issues/65),
[ADR-0065](../adr/0065-chativa-as-reference-client-and-history-cursor.md)). Because
[Converger Protocol v1](./v1.md) is a superset of mekik/1, the unmodified `@chativa/connector-mekik` works against
the native endpoint, and a compatibility suite keeps it that way: every pull request runs chativa's real
`MekikConnector` and `parseChatFrame` in Node against a Converger server
(`test/protocol/chativa_compat_test.exs`, CI job "chativa reference client compatibility"). A Converger change that
breaks chativa fails the build.

The hub extras that mekik does not have (delivery receipts, history paging, uploads, the conversation list for agent
consoles) are served over REST and the full protocol, for `@chativa/connector-converger`, a thin extension of
`MekikConnector` built in [AimTune/chativa#86](https://github.com/AimTune/chativa/issues/86) (**Planned**).

## Widget setup with connector-mekik: **Implemented (#65)**

1. **Token, on your backend.** Never ship the channel secret to the browser. A small endpoint of yours calls
   `POST /api/v1/converger/tokens/generate` with the channel secret and the signed-in user, and returns the token
   ([client API](../api/client-api.md#generate-a-token)):

   ```bash
   curl -s -X POST "$CONVERGER/api/v1/converger/tokens/generate" \
     -H "authorization: Bearer $CHANNEL_SECRET" \
     -H "content-type: application/json" \
     -d '{"user": {"id": "user-42"}}'
   ```

2. **Conversation.** Either create one with `POST /api/v1/converger/conversations` (it returns `conversationId` and
   a conversation-bound token, which is the better token to hand to the widget), or let the socket create one: a
   `hello` without `conversationId` and a channel-level token starts a new conversation, and `welcome` names it.
3. **Connector.** Point `MekikConnector` at the native endpoint `wss://HOST/socket/converger/v1`:

   ```ts
   import { MekikConnector, TokenAuth } from "@chativa/connector-mekik";

   const connector = new MekikConnector({
     url: "wss://chat.example.com/socket/converger/v1",
     // A function, so a rejected or expired token is replaced by a fresh one.
     auth: new TokenAuth({
       token: async () => (await (await fetch("/api/chat-token")).json()).token,
     }),
     conversationId, // from POST /conversations, or omit to let the server create one
     routeInUrl: true, // conversationId in the query string, for L7 affinity
     resumeConversation: true, // keep the id and the watermark across reloads
   });
   ```

   - Do not set `protocols`: a client that offers no subprotocol and sends no `hello.protocol` gets the
     [mekik/1 profile](#the-mekik1-profile).
   - The token travels in `hello.token` (the `TokenAuth` default). `transport: "query"` (`?token=`) also works.
   - `routeInUrl` puts `conversationId` (and `userId`) in the URL. Converger treats them as hints for a load
     balancer that routes by conversation; the token decides ([v1 section 2.1](./v1.md#21-native-endpoint-implemented-26)).
   - The `userId` that `welcome` returns is the token's `user_id` when it has one; a client-asserted `userId` never
     overrides it.

## What works

| chativa / mekik/1 | over Converger | status |
| --- | --- | --- |
| `hello` / `welcome`, identity adopted, server-minted conversation | as mekik/1; `welcome.data.watermark` is the head seq | Implemented |
| Watermark resume (`resumeConversation`) | replay of every persistent frame after `hello.watermark`; open interrupts re-announced in `welcome.data.pending` | Implemented (pending: #65) |
| User turns (`sendMessage`) | stored once: the message `id` chativa stamps is used as the `clientId` ([v1 section 7](./v1.md#7-sending-acks-and-idempotency-implemented-native-endpoint-26-phoenix-binding-24)) | Implemented |
| Bot and agent messages, `from: "user"` replays of the user's own turns | `text` frames; `from` is relative to the token's `user_id` | Implemented |
| Quick-reply chips (`text` with `actions`) | `parseChatFrame` turns them into a `quick-reply` with `keepActions` | Implemented |
| Rich message types (`buttons`, `card`, `carousel`, `image`, `file`, `video`, ...) | stored and replayed by name; chativa renders them from its registry ([messages](./messages.md)) | Implemented (#68) |
| `tool_call`, `genui`, `interrupt`, `interrupt_resolved` | stored and replayed byte-identically except `seq`; chativa shows the trace, mounts GenUI, renders interrupt chips | Implemented (#68) |
| `typing` from other participants | the flat `typing` frame `parseChatFrame` expects | Implemented (#25) |
| Auth rejection, expiry | `error` `unauthorized` and close 4401; `TokenAuth` with a function fetches a new token and reconnects | Implemented |
| `regenerate` / `edit` buttons | hidden: `welcome.data.capabilities` reports them as false | Implemented |
| Live frames from a mekik bot behind Converger: `run` (typing), `genui_components`, `skills`, live `tool_call` / `genui` / `interrupt` | relayed from the bot channel ([v1 section 9](./v1.md#9-the-bot-channel-and-mekik-relay-implemented-64)) | Implemented (#64), verified live (#65) |
| `resume`, `genui_event`, `client_tools`, `client_skills`, `abort`, `survey` | forwarded to the bot channel; without one, answered with `error` `bot_unavailable`, which connector-mekik ignores | Implemented (#64); `resume` verified live (#65) |

The suite checks each "Implemented" row with the real connector: a replayed transcript of every frame family, a live
message and a typing indicator, a send that is persisted once, an idle connection kept open by pings, the REST
history in frame form, and agent-panel switching.

### A mekik bot behind Converger: verified live (#63, #65)

`test/protocol/chativa_live_bot_test.exs` (same CI job) puts a mekik bot behind Converger and talks to it through the
unmodified connector, on a `websocket` widget channel routed to the bot. It runs once per bot mode:

- **Mode A**: a [`mekik` channel](../channels/mekik.md). The adapter dials a mekik/1 server (a scripted fake in the
  tests).
- **Mode B**: an agent on a channel-scoped socket ([v1 section 10](./v1.md#10-channel-scoped-sockets-implemented-64-on-the-native-endpoint))
  that sends the same mekik frames.

What chativa's UI callbacks receive, in order:

1. The user sends a text. The bot's `run started` turns typing on, then `onToolCall` gets the `tool_call` running
   and completed, `onGenUIChunk` gets the GenUI chunk, `onMessage` gets the bot's `text` and the `interrupt` as a
   quick reply with one chip per action. `run interrupted` turns typing off.
2. The user taps a chip. connector-mekik sends its own `resume` frame (`answers: {<interrupt id>: <action value>}`),
   which the bot receives unchanged. The bot's `interrupt_resolved` renders nothing, and its final `text` renders.
3. The connector disconnects, the bot sends two more frames, and the connector reconnects with its watermark. It
   renders exactly those two frames, once.
4. A page reload while the bot waits on the interrupt (`resumeConversation`, so the stored watermark is already past
   the interrupt): nothing is replayed, `welcome.data.pending` re-announces the interrupt, connector-mekik renders the
   same chips, and a tap still resumes the bot.

### The mekik/1 profile

mekik/1 has an open rule: a frame type the client does not know is a rich message, rendered by name. connector-mekik
follows it, so Converger's additive frames (`ack`, `deliveryStatus`, ...) would appear as empty chat bubbles. The
native endpoint therefore serves a **mekik/1 profile** to a connection that negotiated no WebSocket subprotocol and
whose `hello` has no `protocol` (or `"mekik/1"`) ([v1 section 14.1](./v1.md#141-the-mekik1-profile-implemented-65)):

- it does not send `ack`, `deliveryStatus`, `presence`, `tokenRefreshed` or `replayTruncated`;
- it sends `heartbeat` as a WebSocket ping, which the browser answers with a pong, so an idle widget is not closed
  with 4408;
- it reports `token_expired` and `token_revoked` with the mekik/1 code `unauthorized` (the `number` keeps the
  Converger code), so the auth provider fetches a fresh token.

Persistent `event` and `conversationUpdate` frames (reactions, edits, a conversation closing) are still delivered:
chativa renders them with its fallback component unless you register renderers named `event` and
`conversationUpdate`, or drop them with an `afterReceive` extension.

A client that offers the `converger.v1` subprotocol, or sends `hello.protocol: "converger/1"`, gets the full
protocol; that is how `@chativa/connector-converger` receives receipts and acks.

## Hub extras

The capabilities of chativa's `IConnector` that connector-mekik leaves empty, and what Converger serves for each.
`@chativa/connector-converger` ([AimTune/chativa#86](https://github.com/AimTune/chativa/issues/86), **Planned**)
implements them; the Converger side is **Implemented (#65)** unless marked otherwise.

| `IConnector` | Converger | notes |
| --- | --- | --- |
| `onMessageStatus` | `deliveryStatus` frames ([v1 section 8.1](./v1.md#81-deliverystatus-implemented-25)) | full protocol only (`converger.v1`). Map `queued` and `sent` to chativa's `sent`, `read` to `read`; the frame names the activity `id` and `seq`, and `ack` maps a `clientId` to them |
| `sendFile` | `POST /api/v1/converger/conversations/:id/upload` ([client API](../api/client-api.md#upload-a-file)) | the response carries `seq` and `frame`, the attachment message as the socket delivers it, so the widget can show it at once and drop the socket copy by `id` |
| `loadHistory(cursor)` | `GET .../activities?direction=backward&format=frames`, then `?before=<cursor>&format=frames` ([history paging](../api/client-api.md#history-paging-backwards)) | pages are oldest first; `cursor` is a seq; frames go through the same routing as live frames |
| `listConversations` | `GET /api/v1/converger/conversations` with a channel-scoped token ([list](../api/client-api.md#list-the-channels-conversations)) | most recently active first; `title`, `contact`, `lastMessage`, `lastMessageAt` as chativa names them; map `active` to `open` |
| `createConversation(title)` | `POST /api/v1/converger/conversations` with `{"title": ...}` | the title is stored as `metadata.title` |
| `switchConversation(id)` | `GET /api/v1/converger/conversations/:id` with the channel-scoped token, then reconnect with the returned conversation-bound token and `conversationId: id` | one socket per open conversation today; one multiplexed channel-scoped socket is Planned (#64, [v1 section 10](./v1.md#10-channel-scoped-sockets-implemented-64-on-the-native-endpoint)) |
| `closeConversation(id)` | `POST /api/v1/converger/conversations/:id/close` | a `conversationUpdate` frame announces it |
| `onConversationUpdate` | `conversationUpdate` frames on open sockets; refresh the list with `updated_since` | per-conversation updates on the multiplexed socket are Planned (#64) |
| `sendFeedback` | `POST .../activities` with `type: "messageReaction"`, `replyToId` and the reaction as `text` | |

### Agent-panel mode

chativa's agent-panel mode (one agent, many conversations) runs on a **channel-scoped** token:

1. The agent console's backend mints it: `POST /api/v1/converger/tokens/generate` with the channel secret and
   `{"scope": "channel", "user": {"id": "agent-7"}}`.
2. `listConversations` pages `GET /api/v1/converger/conversations` (filters: `status`, `updated_since`).
3. `switchConversation` exchanges the channel-scoped token for a conversation-bound one
   (`GET /api/v1/converger/conversations/:id`, same user and permissions) and reconnects the connector with it. The
   agent's turns are stored with sender `agent-7`, so the customer sees them as `from: "bot"`.

**Implemented (#65)** as above, and covered by the compatibility suite. **Planned (#64):** a single channel-scoped
native socket that carries every conversation of the channel in `{conversationId, frame}` envelopes, the `agent`
participant role in typing and presence, and conversation-level updates on it; `connector-converger` will switch to
it without a new socket per conversation.
