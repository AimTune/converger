---
title: Migrating from the legacy API
description: Move a client from the deprecated legacy socket, conversation tokens and channel tokens to the Converger API socket and tokens - step by step, with a mapping of every request, frame and field.
sidebar_position: 5
---

The legacy client surfaces are **deprecated** ([#23](https://github.com/AimTune/converger/issues/23),
[ADR-0026](../adr/0026-one-client-socket-stack-and-shape-checked-legacy-tokens.md)). They keep working until they are
removed, no earlier than two minor releases and 6 months after the deprecation
([protocol v1, section 13.3](../protocol/v1.md#133-deprecation-of-the-pre-v1-surfaces)). The removal release is
announced in the [changelog](https://github.com/AimTune/converger/blob/main/CHANGELOG.md) one release ahead.

| Deprecated | Replacement |
| --- | --- |
| `/socket/websocket`, topic `conversation:<id>` | `/socket/converger/websocket`, topic `converger:conversation:<id>` |
| `POST /api/v1/tokens` (conversation token) | `POST /api/v1/converger/tokens/generate` (your backend, channel secret), or `POST /api/v1/converger/conversations` |
| `POST /api/v1/conversations` with `x-channel-token` | `POST /api/v1/converger/conversations` with a Converger token |
| `x-channel-token` on the tenant API | `x-api-key` (the tenant API key), server side only |

The tenant API itself (`/api/v1/conversations...`, `/api/v1/routing_rules...` with `x-api-key`) is **not**
deprecated.

## Finding what still uses them

Every use logs a warning that names the surface and the replacement:

```text
[warning] Deprecated legacy_socket used; connect to /socket/converger with a Converger token and join converger:conversation:<id>. It will be removed. See https://converger.aimtune.dev/api/migrating-from-legacy
```

- The legacy socket warns once per connection, HTTP surfaces once per request. The log metadata carries
  `deprecated` (the surface) and `tenant_id` (and `conversation_id` for the socket).
- Each use also emits the telemetry event `[:converger, :deprecated, :use]` with `%{count: 1}` and the metadata
  `surface` (`:legacy_socket`, `:token_endpoint` or `:channel_token`) plus `tenant_id`; see
  [observability](../operations/observability.md).
- HTTP responses carry the [RFC 9745](https://www.rfc-editor.org/rfc/rfc9745) headers
  `Deprecation: @<unix time>` and `Link: <https://converger.aimtune.dev/api/migrating-from-legacy>; rel="deprecation"`.

## 1. Tokens

Legacy clients got a channel token from the admin panel, put it in the browser, and exchanged it for a
conversation token. Converger API tokens are issued by **your backend** with the channel secret, which never
reaches the browser:

```bash
# your backend
curl -s -X POST "$CONVERGER/api/v1/converger/tokens/generate" \
  -H "Authorization: Bearer $CHANNEL_SECRET" \
  -H "Content-Type: application/json" \
  -d '{"user": {"id": "user-123"}}'
# {"conversationId": null, "token": "<user token>", "expires_in": 1800}
```

The client then starts a conversation (or uses one it already has):

```bash
curl -s -X POST "$CONVERGER/api/v1/converger/conversations" \
  -H "Authorization: Bearer $USER_TOKEN"
# {"conversationId": "...", "token": "<conversation token>", "expires_in": 1800, "streamUrl": "..."}
```

Converger tokens expire after 30 minutes (legacy tokens: 60). Renew with `POST /api/v1/converger/tokens/refresh`
before `expires_in` runs out. See the [client API](client-api.md).

`user.id` becomes the token's `user_id` claim. It is the sender of everything the client sends over the socket
and its socket identity ([ADR-0020](../adr/0020-per-subject-socket-ids-and-presence.md)), like `user_id` in
`POST /api/v1/tokens`.

## 2. The socket

| | Legacy | Converger API |
| --- | --- | --- |
| URL | `wss://HOST/socket/websocket?token=...&vsn=2.0.0` | `wss://HOST/socket/converger/websocket?token=...&vsn=2.0.0` |
| Topic | `conversation:<id>` | `converger:conversation:<id>` |
| Join payload | `{"last_activity_id": "<uuid>"}` (optional) | `{"watermark": "<watermark>"}` (optional) |
| Activities arrive as | `new_activity`, one canonical activity | `activitySet` `{activities: [...], watermark, has_more}` |
| Replay cap signal | `replay_truncated` `{has_more, last_activity_id}` | `has_more: true` on the replayed `activitySet`; fetch the rest over REST |
| Send | push `new_activity` | push `postActivity` |
| Send idempotency | `idempotency_key` (any string up to 255 bytes) | `clientId` (1 to 128 of `A-Z a-z 0-9 . _ : ~ -`) |
| Send reply | `{"id", "seq"}` | `{"id", "seq", "watermark"}` |
| Delivery receipts | `delivery_status` | `deliveryStatus` frames, plus read receipts, `typing` and `presence` ([WebSocket](../websocket.md#5a-receipts-typing-and-presence)) |

### Activity fields

| Legacy (`new_activity`) | Converger API (`activitySet.activities[]`) |
| --- | --- |
| `id`, `type`, `text`, `attachments` | same |
| `sender` | `from.id` |
| `metadata` | `channelData` |
| `inserted_at` | `timestamp` |
| `conversation_id` | `conversationId` |
| `seq` | not in the activity: it is in the `watermark` (opaque) |
| `idempotency_key`, `tenant_id`, `status`, `delivery_status` | not exposed |

### Sending

```js
// legacy
channel.push("new_activity", { text: "hi", idempotency_key: key })
  .receive("ok", ({ id, seq }) => {});

// Converger API
channel.push("postActivity", { type: "message", text: "hi", clientId: key })
  .receive("ok", ({ id, seq, watermark }) => {})
  .receive("error", ({ reason }) => {});
```

`postActivity` takes `type` (default `message`), `text`, `attachments`, `channelData` and `replyToId`
([references](../concepts/activities.md#references-replies-reactions-edits-and-deletes)). The sender is the
token's `user_id`; without one, `from.id`, else `"user"`. Errors: `invalid_activity` (with `errors` per field),
`conversation_closed`, `rate_limited` (with `retry_after_ms`, shared with REST's `activity_create` limit).
Keep the `clientId` when re-sending after a timeout or reconnect; use a new one per message.

### Resuming

Keep the `watermark` of the last `activitySet` (or `postActivity` reply) you processed and pass it in the join
payload. The `phoenix` client accepts a function for the join params, so every rejoin sends the latest value:

```js
let watermark = null;
const channel = socket.channel(`converger:conversation:${id}`, () => (watermark ? { watermark } : {}));
channel.on("activitySet", (set) => {
  watermark = set.watermark;
  set.activities.forEach(render); // de-duplicate by id
});
```

A legacy client that only stored the last activity id has no watermark for the first rejoin after the switch;
fetch the history once with `GET /api/v1/converger/conversations/:id/activities` and keep its `watermark`.

The bundled [`converger_js`](https://github.com/AimTune/converger/tree/main/converger_js) client does all of the
above.

## 3. Server-side calls with a channel token

A channel token in `x-channel-token` authenticates as the whole tenant. Use the tenant API key (`x-api-key`)
instead; it works on every tenant API route and is not deprecated. The only routes that required a channel token
were `POST /api/v1/conversations` and `POST /api/v1/tokens`; replace them as in step 1.

End-user tokens (conversation tokens from `POST /api/v1/tokens`, Converger API tokens) are no longer accepted in
`x-channel-token` at all: they used to act as the whole tenant. If you sent one there, switch to the
[client API](client-api.md) with a Converger token.
