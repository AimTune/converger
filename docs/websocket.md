---
title: WebSocket
description: Connect a client to Converger over WebSocket today - endpoints, tokens, channel topics, frames in both directions, resume with watermarks, errors and a JavaScript example.
sidebar_position: 8
---

This page is the client-facing reference for Converger's **current** WebSocket interface: what to connect to, how to authenticate, which topics to join, which frames you send and receive, and how to resume after a disconnect without losing activities. For the server-side design see [Real-time](architecture/realtime.md).

:::info Protocol v1
[Converger Protocol v1](protocol/v1.md) is the documented, versioned wire protocol. Its **native endpoint** (`/socket/converger/v1`, raw frames, no Phoenix framing, [#26](https://github.com/AimTune/converger/issues/26)) is the recommended way to connect from any language; see [Native Protocol v1 endpoint](#native-protocol-v1-endpoint) below. The Converger API socket is the single Phoenix client stack ([#23](https://github.com/AimTune/converger/issues/23)); the legacy socket is deprecated. Still planned: v1 framing on the Phoenix binding ([#22](https://github.com/AimTune/converger/issues/22)).
:::

## Endpoints

| Path | Module | Use |
| --- | --- | --- |
| `/socket/converger/v1` | `ConvergerWeb.ProtocolSocket` | **Recommended.** Native [Protocol v1](protocol/v1.md): raw JSON (or MessagePack) frames, send and receive with acks, resume by `seq` watermark. Receipts, typing and presence included. No channel-scoped (agent console) sessions yet: those use the Phoenix socket. |
| `/api/v1/converger/conversations/:id/events` | `ConvergerWeb.ConvergerAPI.EventStreamController` | Server-Sent Events fallback when WebSockets are blocked: the same v1 frames (receipts, typing and presence included), receive-only; send over REST. |
| `/socket/converger/websocket` (topics `converger:conversation:<conversation_id>` and, for agent consoles, `converger:channel:<channel_id>`) | `ConvergerWeb.ConvergerSocket` | The Phoenix client socket. Converger client API (Direct Line-inspired): `activitySet` frames with watermarks, `deliveryStatus`, `typing` and `presence` frames; send with `postActivity` or over REST, and `typing`, `read` and `ack` (delivery receipts of a `websocket` channel) over the socket. Long-polling fallback at `/socket/converger/longpoll`. |
| `/socket/websocket` (topic `conversation:<conversation_id>`) | `ConvergerWeb.UserSocket` | **Deprecated** ([#23](https://github.com/AimTune/converger/issues/23)). Canonical `new_activity` frames, send over the socket, `delivery_status` frames. Every connection logs a deprecation warning; see [migrating from the legacy API](api/migrating-from-legacy.md). |

The two Phoenix sockets are declared in [endpoint.ex](https://github.com/AimTune/converger/blob/main/lib/converger_web/endpoint.ex) as `/socket/converger` and `/socket`; the WebSocket transport is mounted under `/websocket`. They use the Phoenix V2 JSON serializer (`vsn=2.0.0`, the default of the `phoenix` JavaScript client). Long-polling is enabled on `/socket/converger` only (the `phoenix` client falls back to it automatically when the WebSocket cannot connect); the legacy socket has none.

## Native Protocol v1 endpoint

```text
wss://<host>/socket/converger/v1
Sec-WebSocket-Protocol: converger.v1        (or converger.v1+msgpack; none = JSON, mekik/1 clients)
Authorization: Bearer <converger token>     (or ?token=<token>, or "token" in hello)
```

One frame per WebSocket message. The full contract (every frame, field and error code) is the [Protocol v1 specification](protocol/v1.md); the short version:

```json
→ {"type": "hello", "protocol": "converger/1", "watermark": 15}
← {"type": "welcome", "data": {"conversationId": "…", "userId": "alice", "watermark": 17, "limits": {…}, …}}
← {"type": "text", "id": "…", "seq": 16, "from": "bot", "data": {"text": "Your order has shipped."}, "timestamp": 1750000000000}
← {"type": "text", "id": "…", "seq": 17, …}
→ {"type": "text", "clientId": "c-18", "data": {"text": "When will it arrive?"}}
← {"type": "ack", "clientId": "c-18", "id": "…", "seq": 18, "timestamp": 1750000004000}
→ {"type": "ping", "nonce": "p-1"}
← {"type": "heartbeat", "nonce": "p-1", "headSeq": 18, "timestamp": 1750000005000}
```

- **Handshake.** Send `hello` first; anything else draws `error` `no_session`. The server answers `welcome` (whose `watermark` is the conversation head) and replays every frame with `seq` greater than your `hello.watermark` (absent means 0: the whole transcript, at most 10 000 frames, then `replayTruncated`). A conversation token fixes the conversation; with a channel-level token, `hello.conversationId` is adopted if it belongs to the channel, otherwise a new conversation is started.
- **Watermark.** Keep the highest `seq` you have processed. Reconnect with it in `hello.watermark`, or send `sync {"watermark": n}` on a live connection to replay after `n`. The old opaque watermarks are still accepted.
- **Sending.** A `text` frame with a `clientId` is persisted exactly once and acknowledged with `ack {clientId, id, seq}`; resending the same `clientId` (after a reconnect, for example) returns the same ack with `duplicate: true`. Your own turn is not echoed back to the connection that sent it; your other tabs receive it with `from: "user"` and your `clientId`. Rejections are `error` frames carrying your `clientId` (`invalid_message`, `conversation_closed`, `rate_limited` with `retryAfterMs`, ...).
- **Receipts, typing, presence.** Send `{"type": "typing", "isTyping": true}` (at most every 2 s) and `{"type": "read", "watermark": 18}`; you receive the other participants' `typing`, read receipts and delivery progress as `deliveryStatus`, and `presence` (online/offline, per channel config). The semantics are the Phoenix binding's, described in [5a. Receipts, typing and presence](#5a-receipts-typing-and-presence); `welcome.data.capabilities` says which are on.
- **Liveness.** The server sends `heartbeat` after 30 s of silence and answers `ping`; it closes a connection that sent nothing (not even a ping or a WebSocket ping) for 60 s with code 4408.
- **Limits.** The [client WebSocket limits](operations/websocket-limits.md) apply: too many frames per second draw `rate_limited` with `retryAfterMs`, a client that does not read fast enough is closed with 4503, and a node that shuts down refuses new connections with 503 and closes open ones with 1012 (both with a jittered `retryAfterMs` to wait before reconnecting).
- **Close codes.** 4401: invalid or expired token (`error` `unauthorized` / `token_expired` first; refresh in-band with `auth {"token": ...}` before `welcome.data.expiresAt` to avoid it). 4403: channel deactivated or forced disconnect. 4503: too slow to read (`slow_consumer`). 1012: the node is restarting. 4400: unsupported `hello.protocol`. 1008: the token's conversation does not exist. Reconnect with backoff and the same watermark: nothing is lost.
- **MessagePack.** Offer `converger.v1+msgpack` to send and receive binary MessagePack frames; the maps are identical to the JSON frames.

A complete client in Python using only the [`websockets`](https://pypi.org/project/websockets/) library (version 14 or later) is in [`examples/python/converger_ws.py`](https://github.com/AimTune/converger/blob/main/examples/python/converger_ws.py):

```bash
pip install websockets
python examples/python/converger_ws.py --url wss://converger.example.com/socket/converger/v1 \
  --token "$CONVERGER_TOKEN" --text "Where is my order?"
```

## Server-Sent Events fallback

When WebSockets are blocked, receive with Server-Sent Events and send over REST:

```js
const events = new EventSource(
  `https://converger.example.com/api/v1/converger/conversations/${conversationId}/events` +
    `?token=${encodeURIComponent(token)}&watermark=${lastSeq}`
);
events.addEventListener("text", (e) => {
  const frame = JSON.parse(e.data); // a Protocol v1 frame; e.lastEventId === String(frame.seq)
  render(frame);
});
events.addEventListener("error", (e) => { if (e.data) console.warn(JSON.parse(e.data)); });
```

Every event is a v1 frame, named by its `type` (`text`, `event`, `conversationUpdate`, `heartbeat`, `replayTruncated`, `error`). Persistent frames have their `seq` as the SSE `id`, so the browser's automatic reconnect resumes after the last one it saw (`Last-Event-ID` wins over `?watermark=`). The stream ends with `error` `token_expired` when the token expires: fetch a fresh token and open a new `EventSource` with your last `seq`. Send with `POST /api/v1/converger/conversations/:id/activities` and an `X-Idempotency-Key` ([client API](api/client-api.md)).

**Origins.** In production, browser connections are accepted only from the endpoint host (`PHX_HOST`) unless `CHECK_ORIGIN` lists more origins (comma-separated). Clients that send no `Origin` header (mobile apps, servers) are not affected. In development `check_origin` is off. See [deployment](deployment.md).

## Converger API socket

### 1. Get a token

Tokens are HS256 JWTs signed with `SECRET_KEY_BASE`. Your backend exchanges the channel **secret** for a user token; never ship the channel secret to browsers.

```http
POST /api/v1/converger/tokens/generate
Authorization: Bearer <channel secret>
Content-Type: application/json

{ "user": { "id": "alice" } }
```

```json
{ "conversationId": null, "token": "<token>", "expires_in": 1800 }
```

`user.id` is optional but recommended: it becomes the token's `user_id` claim and the socket id (`converger_socket:<tenant_id>:user:alice`), which lets the server disconnect that one user. It is also the sender of the activities the socket sends. This endpoint is rate-limited per channel (bucket `token_generate`, 10 per minute by default).

For an agent console that follows every conversation of a `websocket` channel, add `"scope": "channel"` to the body. The token gets the claim `scope: "channel"`, which is required to join `converger:channel:<channel_id>` ([Follow a whole channel](#follow-a-whole-channel)); `tokens/refresh` keeps it. Any other `scope` value is rejected with `400`.

### 2. Start or resume a conversation

```http
POST /api/v1/converger/conversations
Authorization: Bearer <token>
```

```json
{
  "conversationId": "6f1c0e7e-1f0b-4a5e-9a39-2b7c6f0d9a11",
  "token": "<conversation token>",
  "expires_in": 1800,
  "streamUrl": "wss://converger.example.com:443/socket/converger/websocket?token=<conversation token>&conversation_id=6f1c0e7e-1f0b-4a5e-9a39-2b7c6f0d9a11"
}
```

The returned token is scoped to that conversation (claim `conversation_id`) and keeps `user_id`. For an existing conversation, `GET /api/v1/converger/conversations/:id` returns a fresh conversation token and `streamUrl` (it appends `&watermark=` when you pass `?watermark=`).

:::note
`streamUrl` is a convenience. The socket only reads `token` from the query string; `conversation_id` and `watermark` in the URL are ignored. Pass the watermark in the **join payload** (below). Also, `streamUrl` is built from the request's host and port, so behind a TLS-terminating proxy it may carry the internal scheme or port; build the URL yourself if that is the case.
:::

Refresh a token before it expires (30 minutes) with:

```http
POST /api/v1/converger/tokens/refresh
Authorization: Bearer <token>
```

```json
{ "conversationId": "6f1c0e7e-...", "token": "<new token>", "expires_in": 1800 }
```

The token is checked when the socket connects. An already connected socket is not closed when its token expires, but every reconnect needs a valid token, so keep the latest one.

### 3. Connect

```text
wss://<host>/socket/converger/websocket?token=<token>&vsn=2.0.0
```

The connection is refused (HTTP `403` on the upgrade) when the token is missing, invalid, expired, not of type `converger`, or when its channel is not active.

### 4. Join the conversation

Join `converger:conversation:<conversation_id>`. The join payload may carry the watermark of the last activity you processed:

```json
{ "watermark": "c2VxOjQy" }
```

Authorization: a conversation token must name this conversation. A token issued with `"scope": "channel"` (an agent console, step 1) may join any conversation of its channel (**owned**) and, when its channel is a `websocket` channel, any conversation of a channel that an enabled routing rule routes to it (**routed**, for example a WhatsApp conversation routed to an agent console). An unscoped channel-level token (from `tokens/generate` without `scope`) cannot join; create or resume a conversation first to get a conversation token. The token's channel must be active.

| | Owned conversation | Routed conversation |
| --- | --- | --- |
| Receives | every activity of the conversation, as committed | what the pipeline delivers to the token's channel, after that channel's [middleware](concepts/middleware.md) |
| Replay | activities as stored | activities through the channel's middleware; an activity the middleware halts is skipped |

| Join reply | Meaning |
| --- | --- |
| `{"status": "ok", "response": {}}` | Joined. |
| `{"status": "error", "response": {"reason": "unauthorized"}}` | The token does not grant this conversation, or its channel is not active. |
| `{"status": "error", "response": {"reason": "invalid_topic"}}` | The topic is neither `converger:conversation:<id>` nor `converger:channel:<id>`. |

### 5. Receive activities

The server sends one event, `activitySet`:

```json
{
  "activities": [
    {
      "id": "0b9f2d3e-6c1a-4f7e-8f53-0f4f9e6f5a20",
      "type": "message",
      "from": { "id": "alice" },
      "text": "Hello!",
      "timestamp": "2026-10-09T12:00:00.123456Z",
      "attachments": [],
      "conversationId": "6f1c0e7e-1f0b-4a5e-9a39-2b7c6f0d9a11",
      "channelData": {}
    }
  ],
  "watermark": "c2VxOjQz",
  "has_more": false
}
```

| Field | Meaning |
| --- | --- |
| `activities` | Activities in `seq` order. Live frames carry exactly one. |
| `activities[].from.id` | The activity's `sender` (`"system"` for lifecycle events, `"bot"` for echo replies). |
| `activities[].channelData` | The activity's `metadata`. |
| `activities[].type` | `message`, `event`, `typing`, `messageReaction`, `messageUpdate`, `messageDelete`, `conversationUpdate` or `endOfConversation`. Activities also carry `replyToId`, `editedAt` and `deletedAt` ([references](concepts/activities.md#references-replies-reactions-edits-and-deletes)). |
| `watermark` | Opaque position after the last activity in this frame. Store it. |
| `has_more` | `true` only on a replay frame that hit the replay limit. |

The activity objects are produced by the same function as the REST API (`GET .../activities`), so they are identical.

The server tracks the last `seq` it pushed on the topic: an activity is pushed at most once, in order. If a live activity arrives with a gap before it (a broadcast lost between nodes, deliveries finishing out of order), the server first reads the missing activities from the database and pushes them in one `activitySet`.

When the conversation is closed or reopened, you receive an activity with `"type": "conversationUpdate"`, `"from": {"id": "system"}` and `channelData` such as `{"event": "conversation_closed", "status": "closed", "reason": "manual"}` (`reason` is `"expired"` for inactivity closes). Sending into a closed conversation returns `409 conversation_closed` until it is reopened.

### 5a. Receipts, typing and presence

Besides `activitySet` the server pushes three **transient** events: they are never stored and never replayed, so a client that was disconnected does not get the ones it missed. `typing` and `presence` frames are also dropped for a client that is not keeping up with its socket ([WebSocket limits](operations/websocket-limits.md)); `deliveryStatus` frames are not. Each payload is the complete [Protocol v1](protocol/v1.md) frame (section 8), `type` included, and validates against its JSON Schema in `priv/protocol/v1/frames/server/`.

**Who you are.** Receipts, typing and presence are attributed to the connection's *participant*, derived from its conversation token: `{"id": "<user_id>", "role": "user"}`, or `{"id": "anonymous", "role": "user"}` when the token has no `user_id` (an anonymous widget). A connection never receives its own participant's typing, read receipts or presence, also not from the same user's other tabs. Issue tokens with `user.id` (`POST /api/v1/converger/tokens/generate`) so participants can be told apart; an agent console that joins with its own `user.id` appears as that participant. A separate `agent` role comes with channel-scoped sockets ([#64](https://github.com/AimTune/converger/issues/64), [#67](https://github.com/AimTune/converger/issues/67)).

#### deliveryStatus

Delivery progress of an activity towards one external channel (WhatsApp, webhook, ...), including provider receipts such as WhatsApp's `delivered` and `read`:

```json
{ "type": "deliveryStatus", "data": { "activityId": "a2f7d9e4-...", "seq": 18, "channelId": "a1b2...", "status": "delivered", "timestamp": 1750000005000 } }
```

`status` only moves forward: `queued`, `sent`, `delivered`, `read`. `failed` means the delivery was dead-lettered; the frame then carries `attempt` and `error` (`{"code": "delivery_failed", "message": "...", "retryable": false}`). `timestamp` is the provider's time for `delivered` / `read` when it sent one, in milliseconds. Every connection of the conversation receives these frames, except end users with a `user_id`, who receive them only for activities whose sender (`from.id`) is their `user_id`.

A **read receipt** of another participant uses the same event with `upToSeq` instead of `activityId`:

```json
{ "type": "deliveryStatus", "data": { "upToSeq": 18, "status": "read", "by": { "id": "user-42", "role": "user" }, "timestamp": 1750000006000 } }
```

#### typing

```json
{ "type": "typing", "isTyping": true, "from": "user", "sender": { "id": "user-42", "role": "user" } }
```

`from` is `"user"` for the end user and `"bot"` for every other party (mekik/1). Treat an indicator that is not refreshed within 6 seconds as stopped; a connection that closes while typing sends `isTyping: false` for you.

#### presence

```json
{ "type": "presence", "data": { "participant": { "id": "agent-7", "role": "agent" }, "status": "online", "connections": 1 } }
{ "type": "presence", "data": { "participant": { "id": "agent-7", "role": "agent" }, "status": "offline", "connections": 0, "lastSeenAt": 1750000009000 } }
```

Right after joining you receive one `online` frame per participant already connected, then a frame whenever a participant's connection count changes. Presence is cluster-wide. It is configured per channel with the channel config key `presence`:

| `presence` | Effect |
| --- | --- |
| `"identified"` (default) | Every participant except anonymous end users is announced, and receives presence. |
| `"all"` | Anonymous end users too, as the single participant `anonymous`. |
| `"off"` | No presence frames on the channel. |

#### Send typing and read

Push these events on the conversation topic:

| Event | Payload | Reply |
| --- | --- | --- |
| `typing` | `{"isTyping": true}` | `ok`. Relayed to the conversation's other connections and, when the channel supports it, to the external user (WhatsApp Cloud API typing indicator). Send at most one every 2 seconds while typing; repeats of the same state within 2 seconds are dropped. `isTyping` that is not a boolean: `error` `bad_request`. |
| `read` | `{"watermark": 18}` | `ok` with `{"watermark": <stored>}`: you have read every activity up to `seq` 18. The stored position never moves backwards and is capped at the conversation's last `seq`. When it moves, the other participants get a `deliveryStatus` read receipt and channels that support it are told (WhatsApp blue ticks on the external user's messages). A `watermark` that is not a positive integer: `error` `invalid_watermark`. |

`watermark` may be the `watermark` of the `activitySet` frame you displayed (as received, for example `"c2VxOjE4"`), the integer `seq` (Protocol v1 frames carry it directly) or its decimal string form.

Typing is no longer something to persist: the `typing` event is transient. Activities with `"type": "typing"` posted over REST are still stored and broadcast for existing clients, but new clients should use the event.

### 6. Send activities over the socket

Push `postActivity` on the joined topic:

```js
channel.push("postActivity", {
  type: "message",               // default "message"
  text: "Hello!",
  channelData: { locale: "en" }, // optional, stored as the activity's metadata
  attachments: [],               // optional, each needs a contentType
  replyToId: "0e7d...",          // optional; required for messageReaction / messageUpdate / messageDelete
  clientId: "c-17"               // optional, see below
})
  .receive("ok", ({ id, seq, watermark }) => { /* stored */ })
  .receive("error", ({ reason, errors, retry_after_ms }) => { /* not stored */ });
```

The activity is stored and routed exactly like a REST send (middleware, routing rules, deliveries), and comes back
to every joined socket, including yours, as an `activitySet`. The reply's `id` and `watermark` match that frame.

- **Sender**: the token's `user_id`. A token without one takes `from.id` from the payload, else `"user"`. Any
  other field (`sender`, `seq`, timestamps) is ignored.
- **`clientId`** (1 to 128 characters of `A-Z a-z 0-9 . _ : ~ -`): re-sending with the same `clientId`, also
  after a reconnect, returns the stored activity instead of a duplicate, and the reply then carries
  `duplicate: true`. Keep it across retries; use a new one per message. It is stored as `ws:<sender>:<clientId>`,
  so it never collides with REST `x-idempotency-key`s or other senders.
- **Errors** (`reason`): `invalid_activity` (with `errors` per field, e.g. `{"type": ["is invalid"]}`,
  `{"reply_to_id": ["does not exist in this conversation"]}` or `{"clientId": [...]}`), `conversation_closed`, `rate_limited` (with `retry_after_ms`; the tenant's
  `activity_create` bucket, shared with REST).
  On a `websocket` channel also `inbound_not_supported` (the channel is `outbound` only) and, on a channel topic,
  `unauthorized` or `not_found`.
- **`websocket` channels**: the message goes through the same inbound path as webhooks
  ([WebSocket channel type](channels/websocket.md#receiving-messages-from-sockets)), so the channel must be in mode
  `inbound` or `duplex`. On `converger:channel:<id>` the payload also names its `conversation_id`, which must be
  owned by or routed to the channel.

#### With Protocol v1 frames and acks

On a conversation topic you can also send Converger Protocol v1 `text` frames with the event `frame`
([protocol, section 7](protocol/v1.md)). This is the same send as `postActivity` (same storage, routing, rate
limit and `clientId` key, so the two are interchangeable for retries), but the answer is a v1 frame pushed back as a
`frame` event, and the Phoenix reply is always `ok` (it only says the frame arrived):

```json
{ "type": "text", "clientId": "3f0c9a52-7c1e-4d0b-9a57-1f2e3d4c5b6a", "data": { "text": "Hello!" }, "metadata": { "locale": "en" } }
```

```json
{ "type": "ack", "clientId": "3f0c9a52-7c1e-4d0b-9a57-1f2e3d4c5b6a", "id": "0b9f2d3e-6c1a-4f7e-8f53-0f4f9e6f5a20", "seq": 43, "timestamp": 1760011200123 }
```

```json
{ "type": "error", "data": { "code": "conversation_closed", "message": "the conversation is closed", "number": 4000, "retryable": false, "clientId": "3f0c9a52-7c1e-4d0b-9a57-1f2e3d4c5b6a", "frameType": "text" } }
```

- `data.text` is required; `data.attachments` (legacy attachment objects) and `metadata` (stored as `channelData`)
  are optional. Without `clientId`, a mekik/1 style `id` with the same syntax is used instead; a send with neither
  gets no ack.
- The `ack` arrives after the commit and before your own copy of the activity in `activitySet`. Its `seq` is the
  `seq` every other client sees; `id` is the activity id.
- A resent `clientId` stores nothing and gets the original ack with `"duplicate": true`, so after a reconnect you can
  resend everything that has no ack yet.
- At most `max_in_flight` (32 by default, `WS_MAX_IN_FLIGHT`) sends per connection may be unacked. If you push more
  at once, the oldest are accepted and the newest are refused with `too_many_in_flight`; resend them, in order, once
  acks come in.
- Errors with `"retryable": true` (`too_many_in_flight`, `rate_limited` with `retryAfterMs`, `internal`) may be
  resent with the **same** `clientId`. The others must not be: `bad_request` (invalid `clientId`, missing
  `data.text`), `invalid_message` (validation, `details` per field), `conversation_closed`, `forbidden` (the
  `websocket` channel is `outbound` only).
- Only `text` is accepted for now; rich message types (`image`, `location`, ...) get `invalid_message` until
  [#28](https://github.com/AimTune/converger/issues/28). `frame` is refused on `converger:channel:<id>` topics.

A client outbox built on this (keep every send until it is acked, resend on every rejoin):

```js
const outbox = new Map(); // clientId -> { frame, resolve, reject }

channel.on("frame", (frame) => {
  const clientId = frame.type === "ack" ? frame.clientId : frame.data?.clientId;
  const entry = clientId && outbox.get(clientId);
  if (!entry) return;

  if (frame.type === "ack") {
    outbox.delete(clientId);
    entry.resolve(frame); // { id, seq, timestamp, duplicate? }
  } else if (!frame.data.retryable) {
    outbox.delete(clientId);
    entry.reject(new Error(frame.data.code));
  } else {
    setTimeout(() => channel.push("frame", entry.frame), frame.data.retryAfterMs ?? 1000);
  }
});

function send(text) {
  const frame = { type: "text", clientId: crypto.randomUUID(), data: { text } };
  return new Promise((resolve, reject) => {
    outbox.set(frame.clientId, { frame, resolve, reject });
    channel.push("frame", frame);
  });
}

// The "ok" hook runs on the first join and on every automatic rejoin.
channel.join().receive("ok", () => {
  for (const { frame } of outbox.values()) channel.push("frame", frame);
});
```

### 7. Send activities (REST)

You can also send over REST with the same token:

```http
POST /api/v1/converger/conversations/6f1c0e7e-1f0b-4a5e-9a39-2b7c6f0d9a11/activities
Authorization: Bearer <token>
Content-Type: application/json
x-idempotency-key: 7d2c1c1e-client-generated

{ "type": "message", "from": { "id": "alice" }, "text": "Hello!", "channelData": { "locale": "en" } }
```

```json
{ "id": "0b9f2d3e-6c1a-4f7e-8f53-0f4f9e6f5a20" }
```

Your own activity also comes back over the socket as an `activitySet`. Use `x-idempotency-key` so that a retry after a timeout returns the same activity instead of creating a second one. Errors: `422` (validation, with field errors), `409` (`conversation_closed`), `503` (could not be accepted, retry), `429` (rate limit, bucket `activity_create` per tenant). See [client API](api/client-api.md).

Any other event pushed on a `converger:conversation:*` topic is answered with the reply `{"reason": "bad_request"}`; the connection stays open.

### 8. Acknowledge activities

On a `websocket` channel, each activity delivered to the channel has a [delivery](concepts/deliveries.md) row. Tell the server what you have received with `ack`:

```json
{ "watermark": "c2VxOjQz" }
```

`watermark` is a frame's watermark, or a `seq` as a number or decimal string; on `converger:channel:<id>` add the frame's `conversation_id`. Every pending delivery of the channel in that conversation up to the watermark is marked `sent`. The reply is `{"acknowledged": <count>}`, or `{"reason": "invalid_ack"}`.

Acks are required when the channel's config has `require_ack: true`: its deliveries stay `pending` until a client acknowledges them. Otherwise a delivery is `sent` as soon as one client is connected, or when a client replays it after reconnecting ([WebSocket channel type](channels/websocket.md#delivery)).

### Follow a whole channel

With a token issued with `"scope": "channel"` (step 1), join `converger:channel:<channel_id>` (the token's own channel, which must be a `websocket` channel) to receive every activity delivered to the channel, across conversations. This is how an agent console follows the conversations routed to it. Each `activitySet` carries the conversation:

```json
{
  "conversation_id": "6f1c0e7e-1f0b-4a5e-9a39-2b7c6f0d9a11",
  "activities": [{ "id": "...", "type": "message", "from": { "id": "16505550022" }, "text": "Where is my order?" }],
  "watermark": "c2VxOjQz",
  "has_more": false
}
```

The channel topic starts live, with no replay; catch up on a conversation over REST or by joining its conversation topic with a watermark. `postActivity` and `ack` on this topic name their `conversation_id`. Typing and read are per conversation and answered with `bad_request` here. Per-conversation watermarks in one handshake are Planned ([#64](https://github.com/AimTune/converger/issues/64), [#67](https://github.com/AimTune/converger/issues/67)).

### Resume without losing activities

Activities are committed before they are broadcast, and each frame tells you its watermark, so a client can always catch up:

1. Keep the `watermark` of the last `activitySet` you processed (persist it if the client may restart).
2. On every (re)join, send `{"watermark": "<last>"}` in the join payload. Without a watermark you start live, from the conversation's current head, with no replay.
3. The server replays up to `ws_replay_limit` activities (default `100`, `PAGINATION_WS_REPLAY_LIMIT`) after that watermark in one `activitySet`. If it has `has_more: true`, fetch the rest with `GET /api/v1/converger/conversations/:id/activities?watermark=<that frame's watermark>` and repeat until `has_more` is `false`.
4. Live frames that the replay already covered are not pushed again. When a replay stops at `has_more`, the server also fills the rest in on the next live activity (gap detection); if you fetch over REST at the same time, de-duplicate by activity `id`.

Watermarks are opaque; today they are URL-safe Base64 of `seq:<n>` (`c2VxOjQy` is `seq:42`), and older activity-id watermarks are still accepted. An invalid watermark is treated as "no watermark". Do not parse or construct them.

### Raw frames

If you are not using the `phoenix` JavaScript client, frames are JSON arrays `[join_ref, ref, topic, event, payload]`:

```json
["1", "1", "converger:conversation:6f1c0e7e-1f0b-4a5e-9a39-2b7c6f0d9a11", "phx_join", {"watermark": "c2VxOjQy"}]
["1", "1", "converger:conversation:6f1c0e7e-1f0b-4a5e-9a39-2b7c6f0d9a11", "phx_reply", {"status": "ok", "response": {}}]
["1", null, "converger:conversation:6f1c0e7e-1f0b-4a5e-9a39-2b7c6f0d9a11", "activitySet", {"activities": [{"id": "0b9f2d3e-6c1a-4f7e-8f53-0f4f9e6f5a20", "type": "message", "text": "Hello!"}], "watermark": "c2VxOjQz", "has_more": false}]
[null, "2", "phoenix", "heartbeat", {}]
[null, "2", "phoenix", "phx_reply", {"status": "ok", "response": {}}]
```

Send a `heartbeat` on the `phoenix` topic periodically (the JavaScript client does it every 30 seconds); Phoenix closes sockets that stay silent past its timeout.

### JavaScript example

Using the official [`phoenix`](https://www.npmjs.com/package/phoenix) client:

```js
import { Socket } from "phoenix";

const BASE = "https://converger.example.com";

// `token` comes from your backend (tokens/generate with the channel secret),
// then POST /conversations returns a conversation token.
async function startConversation(userToken) {
  const res = await fetch(`${BASE}/api/v1/converger/conversations`, {
    method: "POST",
    headers: { Authorization: `Bearer ${userToken}` },
  });
  if (!res.ok) throw new Error(`create conversation failed: ${res.status}`);
  return res.json(); // { conversationId, token, expires_in, streamUrl }
}

export async function connect(userToken, onActivity) {
  const { conversationId, token } = await startConversation(userToken);
  let currentToken = token;
  let watermark = localStorage.getItem(`wm:${conversationId}`); // may be null
  const seen = new Set();

  // params is a function so reconnects use the latest (refreshed) token.
  const socket = new Socket("wss://converger.example.com/socket/converger", {
    params: () => ({ token: currentToken }),
  });
  socket.connect();

  // Join params are also re-evaluated on every rejoin: always resume from
  // the latest watermark.
  const channel = socket.channel(`converger:conversation:${conversationId}`, () =>
    watermark ? { watermark } : {}
  );

  channel.on("activitySet", async ({ activities, watermark: wm, has_more }) => {
    for (const a of activities) {
      if (seen.has(a.id)) continue;
      seen.add(a.id);
      onActivity(a);
    }
    watermark = wm;
    localStorage.setItem(`wm:${conversationId}`, wm);
    if (has_more) await catchUp();
  });

  async function catchUp() {
    let more = true;
    while (more) {
      const res = await fetch(
        `${BASE}/api/v1/converger/conversations/${conversationId}/activities?watermark=${encodeURIComponent(watermark)}`,
        { headers: { Authorization: `Bearer ${currentToken}` } }
      );
      const page = await res.json(); // { activities, watermark, has_more }
      for (const a of page.activities) {
        if (!seen.has(a.id)) { seen.add(a.id); onActivity(a); }
      }
      watermark = page.watermark;
      more = page.has_more;
    }
  }

  channel
    .join()
    .receive("ok", () => console.log("joined", conversationId))
    .receive("error", ({ reason }) => console.error("join failed:", reason));

  // Refresh the token before it expires (expires_in is 1800 s).
  setInterval(async () => {
    const res = await fetch(`${BASE}/api/v1/converger/tokens/refresh`, {
      method: "POST",
      headers: { Authorization: `Bearer ${currentToken}` },
    });
    if (res.ok) currentToken = (await res.json()).token;
  }, 25 * 60 * 1000);

  // Pass the same clientId again to retry a send safely.
  function send(text, clientId = crypto.randomUUID()) {
    return new Promise((resolve, reject) => {
      channel
        .push("postActivity", { type: "message", text, clientId })
        .receive("ok", resolve) // { id, seq, watermark }
        .receive("error", reject) // { reason, ... }
        .receive("timeout", () => reject({ reason: "timeout", clientId }));
    });
  }

  return { socket, channel, send };
}
```

To retry a send safely (after a `timeout` or a reconnect), call `send` again with the same `clientId` instead of generating a new one.

## Legacy socket

:::warning Deprecated
The legacy socket, conversation tokens and channel tokens are deprecated ([#23](https://github.com/AimTune/converger/issues/23)) and will be removed no earlier than two minor releases and 6 months after the deprecation. Every connection logs a warning. Move to the Converger API socket above; see [migrating from the legacy API](api/migrating-from-legacy.md).
:::

The legacy stack predates the Converger client API. It keeps working unchanged until it is removed.

### Tokens

1. A **channel token** (`Converger.Auth.Token.generate_channel_token/1`, claims `channel_id`, `tenant_id`, `sub: "channel_<id>"`, valid for 1 hour). The admin UI shows one per channel in the channel list.
2. Create a conversation with it: `POST /api/v1/conversations` with header `x-channel-token: <channel token>`; the response is `{"data": {"id": ..., "status": ..., ...}}` with status `201`.
3. Exchange it for a **conversation token**:

```http
POST /api/v1/tokens
x-channel-token: <channel token>
Content-Type: application/json

{ "conversation_id": "6f1c0e7e-...", "user_id": "alice" }
```

```json
{ "token": "<conversation token>", "expires_in": 3600 }
```

The conversation token carries `conversation_id`, `tenant_id` and `sub` (the `user_id`). It is rate-limited per IP (bucket `token_create`). The tenant must be active and the channel token must belong to the conversation's channel.

### Connect and join

```text
wss://<host>/socket/websocket?token=<conversation token>&vsn=2.0.0
```

Join `conversation:<conversation_id>`, optionally with the id of the last activity you processed:

```json
{ "last_activity_id": "0b9f2d3e-6c1a-4f7e-8f53-0f4f9e6f5a20" }
```

| Join reply `reason` | Meaning |
| --- | --- |
| `unauthorized` | The token's `conversation_id` is not this conversation. |
| `channel_inactive` | The conversation's channel is not active. |

### Server to client

| Event | Payload |
| --- | --- |
| `new_activity` | The canonical activity (live and replayed). |
| `delivery_status` | Status change of one of the activity's external deliveries. |
| `replay_truncated` | `{"has_more": true, "last_activity_id": "<uuid>"}`: the replay hit `ws_replay_limit`; rejoin with that `last_activity_id` to continue. |

`new_activity` payload (`Converger.Activities.Serializer.canonical/1`):

```json
{
  "id": "0b9f2d3e-6c1a-4f7e-8f53-0f4f9e6f5a20",
  "type": "message",
  "sender": "alice",
  "text": "Hello!",
  "attachments": [],
  "metadata": {},
  "idempotency_key": null,
  "seq": 43,
  "reply_to_id": null,
  "edited_at": null,
  "deleted_at": null,
  "conversation_id": "6f1c0e7e-1f0b-4a5e-9a39-2b7c6f0d9a11",
  "tenant_id": "3a0d5e1c-8a7b-4b8e-9b1f-1c2d3e4f5a6b",
  "inserted_at": "2026-10-09T12:00:00.123456Z"
}
```

`delivery_status` payload:

```json
{
  "delivery_id": "9c7e...",
  "activity_id": "0b9f2d3e-...",
  "channel_id": "a1b2...",
  "status": "sent",
  "sent_at": "2026-10-09T12:00:01.000000Z",
  "delivered_at": null,
  "read_at": null,
  "seq": 42,
  "sender": "alice",
  "attempts": 1,
  "last_error": null,
  "updated_at": "2026-10-09T12:00:01.000000Z"
}
```

`status` is one of `sent`, `delivered`, `read`, `failed` (see [Delivery and retries](delivery.md)). `seq` and `sender` are the activity's; `attempts` and `last_error` describe the delivery.

### Client to server

Push `new_activity` with client fields only (`type`, `text`, `attachments`, `metadata`, `reply_to_id`) and an optional `idempotency_key`; anything else, such as `sender` or `inserted_at`, is ignored. The sender is the token's `sub`.

```json
{ "type": "message", "text": "Hello!", "metadata": { "locale": "en" } }
```

| Reply | Meaning |
| --- | --- |
| `{"status": "ok", "response": {"id": "...", "seq": 18}}` | Stored; it will also arrive as `new_activity`. |
| `{"status": "error", "response": {"reason": "conversation_closed"}}` | The conversation is closed. |
| `{"status": "error", "response": {"reason": "invalid_activity", "errors": {"text": ["should be at most 65536 byte(s)"]}}}` | Validation failed; `errors` is keyed by field. |
| `{"status": "error", "response": {"reason": "invalid_activity"}}` | Any other failure (for example the delivery jobs could not be enqueued); retry. |

A re-push with the same `idempotency_key` (a non-empty string of at most 255 bytes) returns the stored activity instead of a duplicate, also after a reconnect. It is stored as `ws:<sender>:<key>`.

### Resume

Rejoin with the `id` of the last activity you processed as `last_activity_id`. The server replays up to `ws_replay_limit` activities with a greater `seq` as `new_activity` frames, then `replay_truncated` if more are pending. An unknown id replays from the start of the conversation; no `last_activity_id` means no replay.

## Presence, typing and receipts on the legacy socket

The legacy socket pushes `delivery_status` (above) but no read receipts, typing events or presence: those are only on the Converger API socket ([section 5a](#5a-receipts-typing-and-presence)). On the legacy socket, typing is an activity with `"type": "typing"` that is persisted and broadcast like any other activity.

## Limits and disconnects

Each socket is limited (defaults; operators can change them, see [WebSocket limits and draining](operations/websocket-limits.md)):

| Limit | Default | What you get |
| --- | --- | --- |
| Frame size | 128 KiB | Error reply `{"reason": "payload_too_large"}`; the frame is ignored. Above 1 MiB the socket is closed with 1009. |
| Frames sent per socket | 20 per second, heartbeats and joins included | Error reply `{"reason": "rate_limited", "retryAfterMs": N}`; the frame is ignored. Wait `N` ms before sending again. |
| Joined channels per socket | 50 | The join is refused with `{"reason": "too_many_joins"}`. |
| Reading speed | the server buffers up to 1 000 frames for you | The socket is closed with 4503 `slow_consumer`. |

The server closes sockets when:

- the channel is deactivated or deleted: every tracked socket of the channel is disconnected, and reconnects are refused while it stays inactive;
- an operator disconnects one user or conversation (`ConvergerWeb.Sockets.disconnect_user/2`, `disconnect_conversation/2`);
- the node shuts down (a deploy): close code **1012** with the reason `{"reason": "unavailable", "retryAfterMs": N}`. While a node is draining it refuses new connections with HTTP 503 and `Retry-After`; reconnect and the load balancer sends you to another node;
- the client cannot keep up: close code **4503** with `{"reason": "slow_consumer", "retryAfterMs": N}`;
- a frame exceeds the hard size cap (1009), or nothing was received for 60 s (send heartbeats).

Close reasons with `retryAfterMs` are JSON in the WebSocket close frame (`event.reason` in the browser). On every close except an auth failure, reconnect with **jittered** exponential backoff and resume from your last watermark (`converger:` socket) or `last_activity_id` (legacy socket) so you miss nothing. Jitter matters: without it, every client of a restarted node reconnects at the same instant. A client that manages its own reconnects should wait `retryAfterMs` when the close carries one. The `phoenix` client schedules its reconnect before `onClose` callbacks run, so give it a jittered `reconnectAfterMs` instead (its default has no jitter):

```javascript
const socket = new Socket(url, {
  params: { token },
  // 1 s, 2 s, 4 s ... capped at 30 s, each with up to 50% random jitter.
  reconnectAfterMs: (tries) => {
    const base = Math.min(30_000, 1_000 * 2 ** (tries - 1));
    return base / 2 + Math.random() * (base / 2);
  },
});
```

The `phoenix` client reconnects automatically with backoff and rejoins its channels; handle a refused connection (inactive channel, expired token) by fetching a new token. Sockets connected with a channel-level token that has neither `user_id` nor `conversation_id` have no socket id and cannot be disconnected individually or by channel, so always issue tokens with `user.id`.

## The converger_js demo

The repository contains [`converger_js/`](https://github.com/AimTune/converger/tree/main/converger_js), a minimal client for the Converger API socket, not a published SDK:

- `src/converger-client.js` exports `ConvergerClient` with `connect(token)`, `joinConversation(conversationId, {watermark})` (joins `converger:conversation:<id>`, forwards each activity of every `activitySet` to the `onActivity(callback)` handler, and rejoins with the latest watermark) and `sendMessage(text, {clientId})` (pushes `postActivity` and returns a promise of `{id, seq, watermark}`; a random `clientId` by default).
- `index.html` is a demo page: paste a user token from `POST /api/v1/converger/tokens/generate`, it creates a conversation (`POST /api/v1/converger/conversations`) and connects to `ws://localhost:4000/socket/converger`. It loads `phoenix` from jsDelivr through an import map; `package.json` depends on `phoenix` `^1.8.15`.

Serve the folder on port 5500 (for example with a "Live Server" editor extension): the default `cors_origins` in `config/config.exs` allow `http://127.0.0.1:5500` and `http://localhost:5500`. An SDK for Converger Protocol v1 will follow the protocol specification.
