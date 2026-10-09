---
title: Tenant API
description: Reference for the server-to-server tenant API under /api/v1 - conversation tokens, conversations, activities and routing rules.
sidebar_position: 2
---

The tenant API is the server-to-server API under `/api/v1`. Your backend, bots and agent tools use it to
open conversations, post and read activities, close and reopen conversations, and manage routing rules. It
authenticates with the tenant API key (`x-api-key`) or a channel token (`x-channel-token`); see
[authentication](overview.md#authentication). Shared conventions (errors, rate limits, pagination, idempotency)
are described in the [overview](overview.md).

:::warning
`x-channel-token`, `POST /api/v1/tokens` and the channel-token route `POST /api/v1/conversations` are deprecated
([#23](https://github.com/AimTune/converger/issues/23)). They keep working until removal, no earlier than two
minor releases and six months after #23, and every use logs a warning and adds `Deprecation` and `Link` response
headers. Use `x-api-key` for server-to-server calls (it is not deprecated) and the [client API](client-api.md) for
end-user clients. See [migrating from the legacy surfaces](migrating-from-legacy.md).

`x-channel-token` accepts only channel tokens. End-user tokens (conversation tokens from `POST /api/v1/tokens` and
Converger API tokens) are refused with `401`.
:::

Controllers: [`ConvergerWeb.TokenController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/token_controller.ex),
[`ConversationController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/conversation_controller.ex),
[`ActivityController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/activity_controller.ex),
[`RoutingRuleController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/routing_rule_controller.ex).

## Endpoints

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| `POST` | `/api/v1/tokens` | `x-channel-token` | Deprecated. Issue a conversation token for the legacy WebSocket |
| `POST` | `/api/v1/conversations` | `x-channel-token` | Deprecated. Create a conversation on the token's channel |
| `GET` | `/api/v1/conversations` | `x-api-key` only | List conversations (keyset-paginated, filterable) |
| `GET` | `/api/v1/conversations/:id` | `x-api-key` or `x-channel-token` | Get a conversation |
| `POST` | `/api/v1/conversations/:conversation_id/close` | `x-api-key` or `x-channel-token` | Close a conversation |
| `POST` | `/api/v1/conversations/:conversation_id/reopen` | `x-api-key` or `x-channel-token` | Reopen a conversation |
| `POST` | `/api/v1/conversations/:conversation_id/activities` | `x-api-key` or `x-channel-token` | Post an activity |
| `GET` | `/api/v1/conversations/:conversation_id/activities` | `x-api-key` or `x-channel-token` | List activities (watermark-paginated) |
| `GET` | `/api/v1/routing_rules` | `x-api-key` or `x-channel-token` | List routing rules |
| `GET` | `/api/v1/routing_rules/:id` | `x-api-key` or `x-channel-token` | Get a routing rule |
| `POST` | `/api/v1/routing_rules` | `x-api-key` or `x-channel-token` | Create a routing rule |
| `PATCH` / `PUT` | `/api/v1/routing_rules/:id` | `x-api-key` or `x-channel-token` | Update a routing rule |
| `DELETE` | `/api/v1/routing_rules/:id` | `x-api-key` or `x-channel-token` | Delete a routing rule |
| `GET` | `/api/v1/channels/:channel_id/delivery` | `x-api-key` or `x-channel-token` | Channel delivery state (circuit breaker, rate limit) |
| `POST` | `/api/v1/channels/:channel_id/pause` | `x-api-key` or `x-channel-token` | Pause outbound deliveries of a channel |
| `POST` | `/api/v1/channels/:channel_id/resume` | `x-api-key` or `x-channel-token` | Resume deliveries (also closes an open breaker) |

On the routes marked `x-api-key` or `x-channel-token`, only the `x-channel-token` option is deprecated.

The inbound webhook routes `/api/v1/channels/:channel_id/inbound` and `/status` share the `/api/v1` scope but are
called by providers, not by tenants; see [inbound webhooks](inbound.md).

Every resource is tenant-scoped. A conversation, routing rule or channel that belongs to another tenant is reported as `404`,
exactly like one that does not exist. A malformed UUID in the path returns `400 {"errors": {"detail": "Bad Request"}}`.

The examples use these shell variables:

```bash
export CONVERGER=http://localhost:4000
export API_KEY=cvg_live_...          # tenant API key
export CHANNEL_TOKEN=eyJhbGciOi...   # channel token from the admin panel
```

## Resources

### Conversation

Rendered by [`ConvergerWeb.ConversationJSON`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/conversation_json.ex):

```json
{
  "id": "3f6d1c2e-8a4b-4f1e-9c51-0e6a2b7d9f10",
  "status": "active",
  "metadata": {},
  "channel_id": "9b1f3a52-6c0d-4e2b-8f7a-1d2c3b4a5e6f",
  "tenant_id": "c2a4e6f8-1b3d-4f5a-9c7e-2d4f6a8b0c1e",
  "participant_id": "5e7a9c1b-3d5f-4a7c-9e1b-3d5f7a9c1b3d",
  "participant": {
    "id": "5e7a9c1b-3d5f-4a7c-9e1b-3d5f7a9c1b3d",
    "external_id": "16505551234",
    "display_name": "Sheena"
  },
  "inserted_at": "2026-10-09T12:00:00.123456Z",
  "updated_at": "2026-10-09T12:05:41.004512Z"
}
```

| Field | Notes |
| --- | --- |
| `status` | `active` (open, accepts activities) or `closed` |
| `metadata` | Free-form JSON object |
| `participant_id`, `participant` | The external party (for example a WhatsApp number), set by inbound participant resolution ([ADR-0016](../adr/0016-participant-based-conversation-resolution.md)). `participant` is `null` when there is none, and also in responses that do not load it (create, close, reopen). |
| `updated_at` | Bumped by every new activity; the inactivity expiry uses it as the last-activity time |

### Activity

Rendered by [`ConvergerWeb.ActivityJSON`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/activity_json.ex)
from the canonical serializer [`Converger.Activities.Serializer`](https://github.com/AimTune/converger/blob/main/lib/converger/activities/serializer.ex)
([ADR-0004](../adr/0004-single-canonical-activity-serializer.md)). This is the same map that outbound webhooks
receive and that the legacy WebSocket channel pushes.

```json
{
  "id": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
  "type": "message",
  "sender": "bot",
  "text": "We are open 9 to 5.",
  "attachments": [],
  "metadata": {},
  "idempotency_key": "reply-7781",
  "seq": 3,
  "conversation_id": "3f6d1c2e-8a4b-4f1e-9c51-0e6a2b7d9f10",
  "tenant_id": "c2a4e6f8-1b3d-4f5a-9c7e-2d4f6a8b0c1e",
  "inserted_at": "2026-10-09T12:05:41.004512Z"
}
```

| Field | Set by | Notes |
| --- | --- | --- |
| `type` | client | `message` (default), `event`, `typing`, `conversationUpdate`, `endOfConversation` |
| `text` | client | Up to 65,536 bytes |
| `attachments` | client | Array of objects (at most 10, each at most 4,096 bytes as JSON). Converger does not interpret them beyond size checks; the client API upload produces `{"contentType", "contentUrl", "name", "size"}` entries. |
| `metadata` | client | JSON object, at most 16,384 bytes |
| `sender` | server | From the request's `sender` field on this API (default `"user"`); `"system"` for lifecycle events |
| `idempotency_key` | server | From the `x-idempotency-key` header |
| `seq` | server | Per-conversation sequence number, gap-free, starting at 1 ([ADR-0006](../adr/0006-per-conversation-seq-and-opaque-watermarks.md)) |
| `inserted_at` | server | Server timestamp; a client-supplied value is ignored |

### Routing rule

Rendered by [`ConvergerWeb.RoutingRuleJSON`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/routing_rule_json.ex):

```json
{
  "id": "7c9e1a3b-5d7f-4b9d-8f1a-3c5e7a9b1d3f",
  "name": "whatsapp-to-crm",
  "source_channel_id": "9b1f3a52-6c0d-4e2b-8f7a-1d2c3b4a5e6f",
  "target_channel_ids": ["0d2f4b6a-8c0e-4a2c-9e4b-6d8f0a2c4e6b"],
  "enabled": true,
  "tenant_id": "c2a4e6f8-1b3d-4f5a-9c7e-2d4f6a8b0c1e",
  "inserted_at": "2026-10-09T12:00:00Z",
  "updated_at": "2026-10-09T12:00:00Z"
}
```

Routing rule timestamps have second precision; conversation and activity timestamps have microseconds. See
[routing rules](../concepts/routing-rules.md) for how rules select delivery targets.

## Tokens

### Issue a conversation token (deprecated)

`POST /api/v1/tokens`

Issues a token for an end user to join the legacy WebSocket channel `conversation:<id>` on `/socket/websocket`.
This endpoint and the legacy socket are deprecated. New clients should use the [client API](client-api.md) and its
socket instead; see [migrating from the legacy surfaces](migrating-from-legacy.md).

**Auth:** `x-channel-token` header only (no `x-api-key`); it must hold a channel token. The token's channel must be
the conversation's channel, and the conversation's tenant must be `active`.

**Rate limit:** `token_create`, 10 per minute per client IP.

| Body field | Type | Required | Notes |
| --- | --- | --- | --- |
| `conversation_id` | UUID | yes | |
| `user_id` | string | yes | Becomes the token's `sub` claim |

```bash
curl -s -X POST "$CONVERGER/api/v1/tokens" \
  -H "content-type: application/json" \
  -H "x-channel-token: $CHANNEL_TOKEN" \
  -d '{"conversation_id": "3f6d1c2e-8a4b-4f1e-9c51-0e6a2b7d9f10", "user_id": "user-123"}'
```

`201 Created`:

```json
{ "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...", "expires_in": 3600 }
```

| Status | Body | Cause |
| --- | --- | --- |
| `400` | `{"error": "Missing x-channel-token header"}` | No channel token |
| `400` | `{"errors": {"detail": "Bad Request"}}` | `conversation_id` or `user_id` missing, or `conversation_id` not a UUID |
| `401` | `{"errors": {"detail": "Unauthorized"}}` | Channel token invalid or expired, or not a channel token (for example a conversation token or Converger API token) |
| `403` | `{"errors": {"detail": "Forbidden"}}` | Token's channel differs from the conversation's channel, or tenant not active |
| `404` | `{"errors": {"detail": "Not Found"}}` | Unknown conversation |
| `429` | rate limit body | See [rate limiting](overview.md#rate-limiting) |

## Conversations

### Create a conversation (deprecated)

`POST /api/v1/conversations`

Creates a conversation on the channel named in the channel token. The tenant and channel come from the token and
cannot be set in the body.
This route is deprecated because it authenticates only with `x-channel-token`. End-user clients should create
conversations with the [client API](client-api.md).

**Auth:** `x-channel-token` only, holding a channel token (end-user tokens are refused with `401`). The channel
must belong to the token's tenant and be `active`.

| Body field | Type | Required | Notes |
| --- | --- | --- | --- |
| `status` | string | no | `active` (default) or `closed` |
| `metadata` | object | no | Free-form JSON |

```bash
curl -s -X POST "$CONVERGER/api/v1/conversations" \
  -H "content-type: application/json" \
  -H "x-channel-token: $CHANNEL_TOKEN" \
  -d '{"metadata": {"order_id": "A-1001"}}'
```

`201 Created`, with the conversation in `data` (`participant` is `null`):

```json
{
  "data": {
    "id": "3f6d1c2e-8a4b-4f1e-9c51-0e6a2b7d9f10",
    "status": "active",
    "metadata": { "order_id": "A-1001" },
    "channel_id": "9b1f3a52-6c0d-4e2b-8f7a-1d2c3b4a5e6f",
    "tenant_id": "c2a4e6f8-1b3d-4f5a-9c7e-2d4f6a8b0c1e",
    "participant_id": null,
    "participant": null,
    "inserted_at": "2026-10-09T12:00:00.123456Z",
    "updated_at": "2026-10-09T12:00:00.123456Z"
  }
}
```

| Status | Body | Cause |
| --- | --- | --- |
| `400` | `{"error": "Missing x-channel-token header"}` | No channel token |
| `400` | `{"error": "Channel is inactive"}` | The token's channel is disabled |
| `401` | `{"errors": {"detail": "Unauthorized"}}` | Invalid or expired token, channel not found for the tenant, or an invalid body (for example an unknown `status`); the controller currently maps every other failure to `401` |

### List conversations

`GET /api/v1/conversations`

The tenant's conversations, newest first, keyset-paginated on `(inserted_at, id)`, with the participant loaded.
See [keyset cursors](overview.md#keyset-cursors-conversations).

**Auth:** `x-api-key` only. A channel token is authenticated but answered `403`, because the list exposes other
end users' conversations.

| Query param | Notes |
| --- | --- |
| `limit` | Default `50`, max `500` |
| `cursor` | `meta.next_cursor` of the previous page |
| `status` | `active` or `closed` |
| `channel_id` | UUID; anything else returns `400 {"error": "Invalid channel_id"}` |
| `external_id` | The participant's provider id on the conversation's channel, for example a WhatsApp number |

```bash
curl -s "$CONVERGER/api/v1/conversations?status=active&external_id=16505551234&limit=20" \
  -H "x-api-key: $API_KEY"
```

`200 OK`:

```json
{
  "data": [
    {
      "id": "3f6d1c2e-8a4b-4f1e-9c51-0e6a2b7d9f10",
      "status": "active",
      "metadata": { "source": "inbound_webhook" },
      "channel_id": "9b1f3a52-6c0d-4e2b-8f7a-1d2c3b4a5e6f",
      "tenant_id": "c2a4e6f8-1b3d-4f5a-9c7e-2d4f6a8b0c1e",
      "participant_id": "5e7a9c1b-3d5f-4a7c-9e1b-3d5f7a9c1b3d",
      "participant": { "id": "5e7a9c1b-3d5f-4a7c-9e1b-3d5f7a9c1b3d", "external_id": "16505551234", "display_name": "Sheena" },
      "inserted_at": "2026-10-09T12:00:00.123456Z",
      "updated_at": "2026-10-09T12:05:41.004512Z"
    }
  ],
  "meta": { "next_cursor": null, "has_more": false, "limit": 20 }
}
```

To fetch the next page, repeat the request with `cursor=<meta.next_cursor>` and the same filters.

| Status | Body | Cause |
| --- | --- | --- |
| `400` | `{"error": "Invalid cursor"}` | Malformed `cursor` |
| `400` | `{"error": "Invalid channel_id"}` | `channel_id` is not a UUID |
| `401` | `{"error": "Unauthorized: ..."}` | No or invalid credentials |
| `403` | `{"errors": {"detail": "Forbidden"}}` | Authenticated with `x-channel-token` instead of `x-api-key` |

### Get a conversation

`GET /api/v1/conversations/:id`

```bash
curl -s "$CONVERGER/api/v1/conversations/3f6d1c2e-8a4b-4f1e-9c51-0e6a2b7d9f10" \
  -H "x-api-key: $API_KEY"
```

`200 OK` with `{"data": <conversation>}`, participant loaded. `404` when the conversation does not exist or belongs
to another tenant.

### Close and reopen

`POST /api/v1/conversations/:conversation_id/close`
`POST /api/v1/conversations/:conversation_id/reopen`

A closed conversation rejects new activities with `409` until it is reopened. Both operations are idempotent:
closing a closed conversation (or reopening an open one) returns it unchanged and emits nothing. A real transition
appends a `conversationUpdate` activity with sender `"system"`, so connected clients learn about it in-band:

```json
{
  "type": "conversationUpdate",
  "sender": "system",
  "metadata": { "event": "conversation_closed", "status": "closed", "reason": "manual" }
}
```

(`event` is `conversation_reopened` on reopen.) The status change takes the conversation row lock, so an activity
is either committed before the close or rejected after it, and the close event is the last activity of the closed
conversation ([ADR-0017](../adr/0017-conversation-lifecycle-enforced-under-the-seq-lock.md)). Open conversations are
also closed automatically after 24 hours without activity (`config :converger, :conversation_inactivity_hours`,
checked hourly), with `reason: "expired"`. See [conversations](../concepts/conversations.md).

```bash
curl -s -X POST "$CONVERGER/api/v1/conversations/3f6d1c2e-8a4b-4f1e-9c51-0e6a2b7d9f10/close" \
  -H "x-api-key: $API_KEY"
```

`200 OK`:

```json
{
  "data": {
    "id": "3f6d1c2e-8a4b-4f1e-9c51-0e6a2b7d9f10",
    "status": "closed",
    "metadata": {},
    "channel_id": "9b1f3a52-6c0d-4e2b-8f7a-1d2c3b4a5e6f",
    "tenant_id": "c2a4e6f8-1b3d-4f5a-9c7e-2d4f6a8b0c1e",
    "participant_id": null,
    "participant": null,
    "inserted_at": "2026-10-09T12:00:00.123456Z",
    "updated_at": "2026-10-09T12:30:00.000000Z"
  }
}
```

`participant` is always `null` in close and reopen responses, even when `participant_id` is set. Errors: `404` for an
unknown or foreign conversation.

## Activities

### Post an activity

`POST /api/v1/conversations/:conversation_id/activities`

Persists an activity and enqueues its deliveries in the same transaction (transactional outbox,
[ADR-0001](../adr/0001-transactional-outbox-with-oban.md)), then broadcasts it to connected clients. The activity is
routed to the conversation's channel and to the targets of matching routing rules; see
[activity flow](../architecture/activity-flow.md).

**Rate limit:** `activity_create`, 100 per second per tenant (shared with the client API).

| Header | Notes |
| --- | --- |
| `x-idempotency-key` | Optional. Repeating a request with the same key returns the original activity (`201`) and creates nothing. Unique per conversation. |

| Body field | Type | Notes |
| --- | --- | --- |
| `type` | string | Default `message` |
| `text` | string | |
| `attachments` | array of objects | |
| `metadata` | object | |
| `sender` | string | Sender id stored on the activity, for example `"bot"` or an agent id. Default `"user"`. Server-to-server only: the tenant API trusts the caller to name the sender. |

Any other field (`tenant_id`, `conversation_id`, `idempotency_key`, `seq`, `inserted_at`) is ignored
([ADR-0005](../adr/0005-separate-client-and-system-changesets.md)).

```bash
curl -s -X POST "$CONVERGER/api/v1/conversations/3f6d1c2e-8a4b-4f1e-9c51-0e6a2b7d9f10/activities" \
  -H "content-type: application/json" \
  -H "x-api-key: $API_KEY" \
  -H "x-idempotency-key: reply-7781" \
  -d '{"type": "message", "sender": "bot", "text": "We are open 9 to 5."}'
```

`201 Created`:

```json
{
  "data": {
    "id": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
    "type": "message",
    "sender": "bot",
    "text": "We are open 9 to 5.",
    "attachments": [],
    "metadata": {},
    "idempotency_key": "reply-7781",
    "seq": 3,
    "conversation_id": "3f6d1c2e-8a4b-4f1e-9c51-0e6a2b7d9f10",
    "tenant_id": "c2a4e6f8-1b3d-4f5a-9c7e-2d4f6a8b0c1e",
    "inserted_at": "2026-10-09T12:05:41.004512Z"
  }
}
```

| Status | Body | Cause |
| --- | --- | --- |
| `404` | `{"errors": {"detail": "Not Found"}}` | Unknown or foreign conversation |
| `409` | `{"error": "conversation_closed", "detail": "Conversation is closed"}` | Conversation is closed |
| `422` | `{"errors": {"type": ["is invalid"]}}` | Validation failed: unknown `type`, `text` over 65,536 bytes, too many or too large attachments, `metadata` too large |
| `429` | rate limit body | Tenant's `activity_create` limit exceeded |
| `503` | `{"error": "Activity could not be accepted, please retry"}` | Deliveries could not be enqueued; nothing was stored. Retry with the same idempotency key. |

Example `422` bodies:

```json
{ "errors": { "text": ["should be at most 65536 byte(s)"] } }
```

```json
{ "errors": { "attachments": ["attachment 0 is 4112 bytes, max is 4096"] } }
```

### List activities

`GET /api/v1/conversations/:conversation_id/activities`

One page of the conversation's activities, oldest first, after an optional watermark. See
[sequence watermarks](overview.md#sequence-watermarks-activities).

| Query param | Notes |
| --- | --- |
| `limit` | Default `100`, max `1000` |
| `watermark` | `meta.watermark` of the previous page. Omit to start at the first activity. |

```bash
curl -s "$CONVERGER/api/v1/conversations/3f6d1c2e-8a4b-4f1e-9c51-0e6a2b7d9f10/activities?limit=2" \
  -H "x-api-key: $API_KEY"
```

`200 OK`:

```json
{
  "data": [
    {
      "id": "0f1e2d3c-4b5a-4968-8776-655443322110",
      "type": "message",
      "sender": "16505551234",
      "text": "What are your hours?",
      "attachments": [],
      "metadata": {},
      "idempotency_key": "wamid.HBgLMTY1MDM4Nzk0MzkVAgASGBQzQTRB",
      "seq": 1,
      "conversation_id": "3f6d1c2e-8a4b-4f1e-9c51-0e6a2b7d9f10",
      "tenant_id": "c2a4e6f8-1b3d-4f5a-9c7e-2d4f6a8b0c1e",
      "inserted_at": "2026-10-09T12:04:10.551200Z"
    },
    {
      "id": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
      "type": "message",
      "sender": "bot",
      "text": "We are open 9 to 5.",
      "attachments": [],
      "metadata": {},
      "idempotency_key": "reply-7781",
      "seq": 2,
      "conversation_id": "3f6d1c2e-8a4b-4f1e-9c51-0e6a2b7d9f10",
      "tenant_id": "c2a4e6f8-1b3d-4f5a-9c7e-2d4f6a8b0c1e",
      "inserted_at": "2026-10-09T12:05:41.004512Z"
    }
  ],
  "meta": { "watermark": "c2VxOjI", "has_more": true, "limit": 2 }
}
```

Continue with `?watermark=c2VxOjI` until `has_more` is `false`. When there is nothing new, `data` is empty and
`meta.watermark` echoes the watermark you sent (`null` if you sent none), so the same request can be used to poll.

| Status | Body | Cause |
| --- | --- | --- |
| `400` | `{"error": "Invalid watermark"}` | Malformed watermark |
| `404` | `{"errors": {"detail": "Not Found"}}` | Unknown or foreign conversation |

## Routing rules

A routing rule copies the activities of a source channel's conversations to one or more target channels. Changes
made through this API are recorded in the audit log with actor type `tenant_api`.

### Validation

| Rule | Error (`422`, field) |
| --- | --- |
| `name`, `source_channel_id`, `target_channel_ids` are required | `can't be blank` |
| `name` is unique per tenant | `name: has already been taken` |
| 1 to 20 targets | `target_channel_ids: should have at least 1 item(s)` / `at most 20 item(s)` |
| The source is not among the targets | `target_channel_ids: cannot include the source channel` |
| All channels belong to the tenant | `target_channel_ids: all channels must belong to the same tenant` |
| The source channel can receive (`inbound` or `duplex` mode) | `source_channel_id: source channel is outbound-only and cannot receive inbound messages` |
| No target is `inbound`-only | `target_channel_ids: these target channels are inbound-only and cannot deliver outbound: <names>` |
| Enabled rules form no cycle | `target_channel_ids: would create a routing cycle` |

### List routing rules

`GET /api/v1/routing_rules`

Returns all of the tenant's rules sorted by name, without pagination (hard cap: `lookup_limit`, default 1000).

```bash
curl -s "$CONVERGER/api/v1/routing_rules" -H "x-api-key: $API_KEY"
```

`200 OK`: `{"data": [<routing rule>, ...]}`.

### Get a routing rule

`GET /api/v1/routing_rules/:id`

`200 OK` with `{"data": <routing rule>}`; `404` for an unknown or foreign rule.

### Create a routing rule

`POST /api/v1/routing_rules`

The attributes must be wrapped in a `routing_rule` object; a body without it returns `400`.

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `name` | string | yes | Unique per tenant |
| `source_channel_id` | UUID | yes | |
| `target_channel_ids` | array of UUIDs | yes | 1 to 20 |
| `enabled` | boolean | no | Default `true` |

```bash
curl -s -X POST "$CONVERGER/api/v1/routing_rules" \
  -H "content-type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{
    "routing_rule": {
      "name": "whatsapp-to-crm",
      "source_channel_id": "9b1f3a52-6c0d-4e2b-8f7a-1d2c3b4a5e6f",
      "target_channel_ids": ["0d2f4b6a-8c0e-4a2c-9e4b-6d8f0a2c4e6b"]
    }
  }'
```

`201 Created` with `{"data": <routing rule>}`. Validation errors return `422`:

```json
{ "errors": { "target_channel_ids": ["would create a routing cycle"] } }
```

### Update a routing rule

`PATCH /api/v1/routing_rules/:id` (or `PUT`)

Same `routing_rule` wrapper; only the fields you send change. All validations run again (the rule being updated
is excluded from the cycle check).

```bash
curl -s -X PATCH "$CONVERGER/api/v1/routing_rules/7c9e1a3b-5d7f-4b9d-8f1a-3c5e7a9b1d3f" \
  -H "content-type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{"routing_rule": {"enabled": false}}'
```

`200 OK` with `{"data": <routing rule>}`; `404` for an unknown or foreign rule; `422` on validation errors.

### Delete a routing rule

`DELETE /api/v1/routing_rules/:id`

```bash
curl -s -X DELETE "$CONVERGER/api/v1/routing_rules/7c9e1a3b-5d7f-4b9d-8f1a-3c5e7a9b1d3f" \
  -H "x-api-key: $API_KEY"
```

`204 No Content` with an empty body; `404` for an unknown or foreign rule.

## Channel delivery state

Each channel has a delivery circuit breaker, can be paused by hand, and may have an outbound rate limit. The full
behaviour is described in [Delivery: flow control](../delivery.md#flow-control-circuit-breaker-rate-limits-and-tenant-fairness).

### Get the delivery state

`GET /api/v1/channels/:channel_id/delivery`

```bash
curl -s "$CONVERGER/api/v1/channels/$CHANNEL_ID/delivery" -H "x-api-key: $API_KEY"
```

```json
{
  "data": {
    "channel_id": "5f0c...",
    "circuit_state": "open",
    "circuit_changed_at": "2026-10-09T12:05:00.000000Z",
    "consecutive_failures": 7,
    "rate_limit": {"limit": 80, "scale_ms": 1000},
    "parked_deliveries": 1423
  }
}
```

| Field | Meaning |
| --- | --- |
| `circuit_state` | `closed` (flowing), `open` (breaker open, deliveries parked), `half_open` (one probe in flight) or `paused` (manually paused) |
| `circuit_changed_at` | Time of the last transition, `null` if the breaker never changed |
| `consecutive_failures` | Transient failures since the last success |
| `rate_limit` | Effective limit (the channel's `rate_limit` or the adapter default), `null` when unlimited |
| `parked_deliveries` | Delivery jobs currently parked for this channel |

### Pause and resume deliveries

`POST /api/v1/channels/:channel_id/pause` parks new and pending deliveries of the channel (`status: "paused"`) until
it is resumed. Inbound webhooks and WebSocket traffic are not affected. `POST /api/v1/channels/:channel_id/resume`
closes the breaker, whether it was paused or open, and releases every parked delivery right away.

```bash
curl -s -X POST "$CONVERGER/api/v1/channels/$CHANNEL_ID/pause" -H "x-api-key: $API_KEY"
curl -s -X POST "$CONVERGER/api/v1/channels/$CHANNEL_ID/resume" -H "x-api-key: $API_KEY"
```

Both return `200 OK` with the delivery state above, are idempotent, and are written to the audit log as
`pause_deliveries` / `resume_deliveries` (actor `tenant_api`). An unknown or foreign channel returns `404`.

## Related

- [REST API overview](overview.md)
- [Client API](client-api.md)
- [Inbound webhooks](inbound.md)
- [Activities](../concepts/activities.md), [conversations](../concepts/conversations.md), [routing rules](../concepts/routing-rules.md)
