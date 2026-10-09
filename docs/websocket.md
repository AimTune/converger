---
title: WebSocket
description: Connect a client to Converger over WebSocket today - endpoints, tokens, channel topics, frames in both directions, resume with watermarks, errors and a JavaScript example.
sidebar_position: 8
---

This page is the client-facing reference for Converger's **current** WebSocket interface: what to connect to, how to authenticate, which topics to join, which frames you send and receive, and how to resume after a disconnect without losing activities. For the server-side design see [Real-time](architecture/realtime.md).

:::info Protocol v1 is being specified
Today's WebSocket interface is Phoenix Channels framing with Converger-specific events. Converger Protocol v1 (spec in progress, [#21](https://github.com/AimTune/converger/issues/21), [#63](https://github.com/AimTune/converger/issues/63)) will replace it with a documented, versioned wire protocol. Also planned: a raw WebSocket endpoint without Phoenix framing ([#26](https://github.com/AimTune/converger/issues/26)), client message ids with server acks ([#24](https://github.com/AimTune/converger/issues/24)), delivery/read receipts, typing indicators and presence pushed to clients ([#25](https://github.com/AimTune/converger/issues/25)), and one unified socket stack ([#23](https://github.com/AimTune/converger/issues/23)). Expect the interface below to change; build new integrations on the Converger API socket.
:::

## Endpoints

| Path | Socket module | Topic | Use |
| --- | --- | --- | --- |
| `/socket/converger/websocket` | `ConvergerWeb.ConvergerSocket` | `converger:conversation:<conversation_id>` | **Recommended.** Converger client API (Direct Line-inspired): `activitySet` frames with watermarks. Receive-only; send over REST. |
| `/socket/websocket` | `ConvergerWeb.UserSocket` | `conversation:<conversation_id>` | Legacy. Canonical `new_activity` frames, send over the socket, `delivery_status` frames. Will be deprecated ([#23](https://github.com/AimTune/converger/issues/23)). |

Both are Phoenix sockets (declared in [endpoint.ex](https://github.com/AimTune/converger/blob/main/lib/converger_web/endpoint.ex) as `/socket/converger` and `/socket`; the WebSocket transport is mounted under `/websocket`). Long-polling is disabled. Messages use the Phoenix V2 JSON serializer (`vsn=2.0.0`, the default of the `phoenix` JavaScript client).

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

`user.id` is optional but recommended: it becomes the token's `user_id` claim and the socket id (`converger_socket:<tenant_id>:user:alice`), which lets the server disconnect that one user. This endpoint is rate-limited per channel (bucket `token_generate`, 10 per minute by default).

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

Authorization: a conversation token must name this conversation; a token without `conversation_id` may join any conversation of its channel.

| Join reply | Meaning |
| --- | --- |
| `{"status": "ok", "response": {}}` | Joined. |
| `{"status": "error", "response": {"reason": "unauthorized"}}` | The token does not grant this conversation. |
| `{"status": "error", "response": {"reason": "invalid_topic"}}` | The topic is not `converger:conversation:<id>`. |

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
| `activities[].type` | `message`, `event`, `typing`, `conversationUpdate` or `endOfConversation`. |
| `watermark` | Opaque position after the last activity in this frame. Store it. |
| `has_more` | `true` only on a replay frame that hit the replay limit. |

The activity objects are produced by the same function as the REST API (`GET .../activities`), so they are identical.

When the conversation is closed or reopened, you receive an activity with `"type": "conversationUpdate"`, `"from": {"id": "system"}` and `channelData` such as `{"event": "conversation_closed", "status": "closed", "reason": "manual"}` (`reason` is `"expired"` for inactivity closes). Sending into a closed conversation returns `409 conversation_closed` until it is reopened.

### 6. Send activities (REST)

The Converger API channel does not handle client events; send over REST with the same token:

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

:::warning
Do not push events on a `converger:conversation:*` topic. The channel has no `handle_in`, so an incoming event crashes the channel process; the client receives `phx_error` and rejoins.
:::

### Resume without losing activities

Activities are committed before they are broadcast, and each frame tells you its watermark, so a client can always catch up:

1. Keep the `watermark` of the last `activitySet` you processed (persist it if the client may restart).
2. On every (re)join, send `{"watermark": "<last>"}` in the join payload. Without a watermark you start live with no replay.
3. The server replays up to `ws_replay_limit` activities (default `100`, `PAGINATION_WS_REPLAY_LIMIT`) after that watermark in one `activitySet`. If it has `has_more: true`, fetch the rest with `GET /api/v1/converger/conversations/:id/activities?watermark=<that frame's watermark>` and repeat until `has_more` is `false`.
4. Live frames may arrive while you replay (the subscription starts before the replay query). De-duplicate by activity `id`.

Watermarks are opaque; today they are URL-safe Base64 of `seq:<n>` (`c2VxOjQy` is `seq:42`), and older activity-id watermarks are still accepted. An invalid watermark is treated as "no watermark". Do not parse or construct them.

### Raw frames

If you are not using the `phoenix` JavaScript client, frames are JSON arrays `[join_ref, ref, topic, event, payload]`:

```json
["1", "1", "converger:conversation:6f1c0e7e-1f0b-4a5e-9a39-2b7c6f0d9a11", "phx_join", {"watermark": "c2VxOjQy"}]
["1", "1", "converger:conversation:6f1c0e7e-1f0b-4a5e-9a39-2b7c6f0d9a11", "phx_reply", {"status": "ok", "response": {}}]
["1", null, "converger:conversation:6f1c0e7e-1f0b-4a5e-9a39-2b7c6f0d9a11", "activitySet", {"activities": [], "watermark": "c2VxOjQz", "has_more": false}]
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

  async function send(text) {
    const res = await fetch(`${BASE}/api/v1/converger/conversations/${conversationId}/activities`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${currentToken}`,
        "Content-Type": "application/json",
        "x-idempotency-key": crypto.randomUUID(),
      },
      body: JSON.stringify({ type: "message", text }),
    });
    if (res.status === 409) throw new Error("conversation_closed");
    if (!res.ok) throw new Error(`send failed: ${res.status}`);
    return res.json(); // { id }
  }

  return { socket, channel, send };
}
```

To retry a send safely, reuse the same `x-idempotency-key` for the retry instead of generating a new one.

## Legacy socket

The legacy stack predates the Converger client API. It is still supported and is what the bundled `converger_js` demo uses.

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
  "read_at": null
}
```

`status` is one of `sent`, `delivered`, `read`, `failed` (see [Delivery and retries](delivery.md)).

### Client to server

Push `new_activity` with client fields only (`type`, `text`, `attachments`, `metadata`); anything else, such as `sender`, `inserted_at` or `idempotency_key`, is ignored. The sender is the token's `sub`.

```json
{ "type": "message", "text": "Hello!", "metadata": { "locale": "en" } }
```

| Reply | Meaning |
| --- | --- |
| `{"status": "ok", "response": {}}` | Stored; it will also arrive as `new_activity`. |
| `{"status": "error", "response": {"reason": "conversation_closed"}}` | The conversation is closed. |
| `{"status": "error", "response": {"reason": "invalid_activity", "errors": {"text": ["should be at most 65536 byte(s)"]}}}` | Validation failed; `errors` is keyed by field. |
| `{"status": "error", "response": {"reason": "invalid_activity"}}` | Any other failure (for example the delivery jobs could not be enqueued); retry. |

Socket pushes carry no idempotency key, so retrying a push whose reply was lost can create a duplicate. Use the REST endpoint with `x-idempotency-key` when that matters; server acks with client ids are planned ([#24](https://github.com/AimTune/converger/issues/24)).

### Resume

Rejoin with the `id` of the last activity you processed as `last_activity_id`. The server replays up to `ws_replay_limit` activities with a greater `seq` as `new_activity` frames, then `replay_truncated` if more are pending. An unknown id replays from the start of the conversation; no `last_activity_id` means no replay.

## Presence, typing and receipts today

- **Presence**: the server tracks joined sockets per channel (`ConvergerWeb.SocketPresence`) for its own use (counting connections, disconnecting a channel's clients). Presence state is not pushed to clients.
- **Typing**: an activity with `"type": "typing"` is accepted, persisted and broadcast like any other activity. Ephemeral typing indicators are planned ([#25](https://github.com/AimTune/converger/issues/25)).
- **Receipts**: only the legacy socket pushes `delivery_status`; the Converger API socket does not ([#25](https://github.com/AimTune/converger/issues/25)).

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

The repository contains [`converger_js/`](https://github.com/AimTune/converger/tree/main/converger_js), a minimal demo for the **legacy** socket, not a published SDK:

- `src/converger-client.js` exports `ConvergerClient` with `connect(token)`, `joinConversation(conversationId)` (joins `conversation:<id>` and forwards `new_activity` to the `onActivity(callback)` handler) and `sendMessage(text)` (pushes `new_activity`). It does not resume (`last_activity_id`) or handle `delivery_status`.
- `index.html` is a demo page: paste a channel token, it creates a conversation (`POST /api/v1/conversations`), requests a conversation token (`POST /api/v1/tokens`) and connects to `ws://localhost:4000/socket`. It loads `phoenix` from jsDelivr through an import map; `package.json` depends on `phoenix` `^1.8.15`.

Serve the folder on port 5500 (for example with a "Live Server" editor extension): the default `cors_origins` in `config/config.exs` allow `http://127.0.0.1:5500` and `http://localhost:5500`. An SDK for Converger Protocol v1 will follow the protocol specification.
