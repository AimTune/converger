---
title: Tenant API
description: Reference for the server-to-server tenant API under /api/v1 - conversation tokens, conversations, activities, routing rules, dead-letter deliveries and platform event webhooks.
sidebar_position: 2
---

The tenant API is the server-to-server API under `/api/v1`. Your backend, bots and agent tools use it to
open conversations, post and read activities, close and reopen conversations, manage routing rules, and inspect and replay failed deliveries. It
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
[`RoutingRuleController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/routing_rule_controller.ex),
[`DeliveryController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/delivery_controller.ex),
[`WebhookSubscriptionController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/webhook_subscription_controller.ex),
[`WebhookEventController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/webhook_event_controller.ex).

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
| `POST` | `/api/v1/routing_rules/dry_run` | `x-api-key` or `x-channel-token` | Dry-run routing for an activity (nothing is stored or sent) |
| `GET` | `/api/v1/deliveries` | `x-api-key` only | List deliveries, e.g. the dead-letter queue (keyset-paginated, filterable) |
| `POST` | `/api/v1/deliveries/:id/retry` | `x-api-key` only | Replay one dead letter |
| `POST` | `/api/v1/channels/:channel_id/deliveries/retry` | `x-api-key` only | Replay a channel's dead letters |
| `GET` | `/api/v1/channels/:channel_id/delivery` | `x-api-key` or `x-channel-token` | Channel delivery state (circuit breaker, rate limit) |
| `POST` | `/api/v1/channels/:channel_id/pause` | `x-api-key` or `x-channel-token` | Pause outbound deliveries of a channel |
| `POST` | `/api/v1/channels/:channel_id/resume` | `x-api-key` or `x-channel-token` | Resume deliveries (also closes an open breaker) |
| `GET` | `/api/v1/channels/:channel_id/templates` | `x-api-key` or `x-channel-token` | List the provider message templates (WhatsApp HSM) of a channel, cached |
| `GET` | `/api/v1/channels/:channel_id/outbox` | `x-api-key` or `x-channel-token` | Poll the outbox of an `http_pull` channel; a `watermark` acknowledges the previous page ([HTTP pull](../channels/http-pull.md)) |
| `POST` | `/api/v1/channels/:channel_id/outbox/ack` | `x-api-key` or `x-channel-token` | Acknowledge an `http_pull` outbox up to a watermark |
| `GET` | `/api/v1/webhook_event_types` | `x-api-key` only | The [platform event](../platform-webhooks.md) catalog |
| `GET` | `/api/v1/webhook_subscriptions` | `x-api-key` only | List platform webhook subscriptions |
| `POST` | `/api/v1/webhook_subscriptions` | `x-api-key` only | Create a subscription (returns its secret once) |
| `GET` | `/api/v1/webhook_subscriptions/:id` | `x-api-key` only | Get a subscription |
| `PATCH` / `PUT` | `/api/v1/webhook_subscriptions/:id` | `x-api-key` only | Update a subscription |
| `DELETE` | `/api/v1/webhook_subscriptions/:id` | `x-api-key` only | Delete a subscription and its event log |
| `POST` | `/api/v1/webhook_subscriptions/:id/rotate_secret` | `x-api-key` only | Generate a new signing secret (returned once) |
| `GET` | `/api/v1/webhook_events` | `x-api-key` only | The webhook event log (keyset-paginated, filterable) |
| `GET` | `/api/v1/webhook_events/:id` | `x-api-key` only | Get an event with its payload |
| `POST` | `/api/v1/webhook_events/:id/redeliver` | `x-api-key` only | Redeliver a dead-lettered event |

On the routes marked `x-api-key` or `x-channel-token`, only the `x-channel-token` option is deprecated.

The inbound webhook routes `/api/v1/channels/:channel_id/inbound` and `/status` share the `/api/v1` scope but are
called by providers, not by tenants; see [inbound webhooks](inbound.md).

Every resource is tenant-scoped. A conversation, routing rule or channel that belongs to another tenant is reported as `404`,
exactly like one that does not exist. A malformed UUID in the path returns `400 bad_request`.

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
  "origin_channel_id": "9b1f3a52-6c0d-4e2b-8f7a-1d2c3b4a5e6f",
  "tenant_id": "c2a4e6f8-1b3d-4f5a-9c7e-2d4f6a8b0c1e",
  "participant_id": "5e7a9c1b-3d5f-4a7c-9e1b-3d5f7a9c1b3d",
  "participant": {
    "id": "5e7a9c1b-3d5f-4a7c-9e1b-3d5f7a9c1b3d",
    "external_id": "16505551234",
    "display_name": "Sheena",
    "opted_out_at": null
  },
  "inserted_at": "2026-10-09T12:00:00.123456Z",
  "updated_at": "2026-10-09T12:05:41.004512Z"
}
```

| Field | Notes |
| --- | --- |
| `status` | `active` (open, accepts activities) or `closed` |
| `metadata` | Free-form JSON object |
| `origin_channel_id` | The channel the conversation started on. Activities written from another channel (an agent console) go back to it ([reply-back routing](../concepts/routing-rules.md#how-activities-fan-out)). |
| `channels` | Only on `GET /api/v1/conversations/:id`: the channels the conversation spans, `[{"channel_id", "role", "participant_id", "inserted_at"}]`, role `origin`, `target` or `member` ([Conversations](../concepts/conversations.md#channels-of-a-conversation)). |
| `participant_id`, `participant` | The external party (for example a WhatsApp number), set by inbound participant resolution ([ADR-0016](../adr/0016-participant-based-conversation-resolution.md)). `participant` is `null` when there is none, and also in responses that do not load it (create, close, reopen). `participant.opted_out_at` is set while the participant has opted out (an SMS `STOP`, see [Participants](../concepts/participants.md#opt-out)). |
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
  "reply_to_id": null,
  "edited_at": null,
  "deleted_at": null,
  "conversation_id": "3f6d1c2e-8a4b-4f1e-9c51-0e6a2b7d9f10",
  "tenant_id": "c2a4e6f8-1b3d-4f5a-9c7e-2d4f6a8b0c1e",
  "inserted_at": "2026-10-09T12:05:41.004512Z"
}
```

| Field | Set by | Notes |
| --- | --- | --- |
| `type` | client | `message` (default), `event`, `typing`, `messageReaction`, `messageUpdate`, `messageDelete`, `conversationUpdate`, `endOfConversation` ([types](../concepts/activities.md#types)) |
| `text` | client | Up to 65,536 bytes |
| `attachments` | client | Array of attachment objects (at most 10, each at most 4,096 bytes as JSON). Each needs a `contentType`; `contentUrl`, `name`, `size`, `thumbnailUrl`, `content` and `channelData` are optional and other keys are dropped ([attachment schema](../concepts/activities.md#attachments)). |
| `reply_to_id` | client | Optional: the activity of this conversation this one replies to, reacts to, edits or deletes ([references](../concepts/activities.md#references-replies-reactions-edits-and-deletes)) |
| `edited_at`, `deleted_at` | server | Set on a message once a `messageUpdate` / `messageDelete` for it is accepted |
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
  "conditions": {"all": [{"field": "type", "op": "eq", "value": "message"}]},
  "transformations": [],
  "priority": 100,
  "stop_processing": false,
  "tenant_id": "c2a4e6f8-1b3d-4f5a-9c7e-2d4f6a8b0c1e",
  "inserted_at": "2026-10-09T12:00:00Z",
  "updated_at": "2026-10-09T12:00:00Z"
}
```

Routing rule timestamps have second precision; conversation and activity timestamps have microseconds. See
[routing rules](../concepts/routing-rules.md) for how rules select delivery targets.

### Delivery

Rendered by [`ConvergerWeb.DeliveryJSON`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/delivery_json.ex):

```json
{
  "id": "1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f",
  "activity_id": "0e7d4c1a-2b3c-4d5e-8f6a-7b8c9d0e1f2a",
  "channel_id": "0d2f4b6a-8c0e-4a2c-9e4b-6d8f0a2c4e6b",
  "status": "failed",
  "attempts": 5,
  "last_error": "webhook returned HTTP 503",
  "provider_message_id": null,
  "sent_at": null,
  "delivered_at": null,
  "read_at": null,
  "retry_count": 0,
  "retried_by": null,
  "retried_at": null,
  "payload": {
    "id": "0e7d4c1a-2b3c-4d5e-8f6a-7b8c9d0e1f2a",
    "type": "message",
    "sender": "user-1",
    "text": "Where is my order?",
    "attachments": [],
    "metadata": { "api_key": "[REDACTED]" },
    "idempotency_key": null,
    "seq": 12,
    "conversation_id": "3f6d2c1e-8a4b-4c3d-9e2f-1a0b9c8d7e6f",
    "tenant_id": "c2a4e6f8-1b3d-4f5a-9c7e-2d4f6a8b0c1e",
    "inserted_at": "2026-10-09T12:00:00.123456Z"
  },
  "inserted_at": "2026-10-09T12:00:00.200000Z",
  "updated_at": "2026-10-09T12:04:31.900000Z"
}
```

`payload` is the canonical activity the delivery carries, with sensitive keys (`api_key`, `password`, `*_token`,
...) replaced by `"[REDACTED]"`. It is the stored activity, before the channel's middleware transformed its copy.
`retry_count`, `retried_by` (`"<actor type>:<actor id>"`) and `retried_at` record manual replays. See
[deliveries](../concepts/deliveries.md) for the statuses.

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

| Status | Error (`code: message`) | Cause |
| --- | --- | --- |
| `400` | `bad_request: Missing x-channel-token header` | No channel token |
| `400` | `bad_request` | `conversation_id` or `user_id` missing, or `conversation_id` not a UUID |
| `401` | `unauthorized` | Channel token invalid or expired, or not a channel token (for example a conversation token or Converger API token) |
| `403` | `forbidden` | Token's channel differs from the conversation's channel, or tenant not active |
| `404` | `not_found` | Unknown conversation |
| `429` | `rate_limited` | See [rate limiting](overview.md#rate-limiting) |

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

| Status | Error (`code: message`) | Cause |
| --- | --- | --- |
| `400` | `bad_request: Missing x-channel-token header` | No channel token |
| `400` | `channel_inactive` | The token's channel is disabled |
| `401` | `unauthorized` | Invalid or expired token, channel not found for the tenant, or an invalid body (for example an unknown `status`); the controller currently maps every other failure to `401` |

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
| `channel_id` | UUID; anything else returns `400 bad_request: Invalid channel_id` |
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
      "participant": { "id": "5e7a9c1b-3d5f-4a7c-9e1b-3d5f7a9c1b3d", "external_id": "16505551234", "display_name": "Sheena", "opted_out_at": null },
      "inserted_at": "2026-10-09T12:00:00.123456Z",
      "updated_at": "2026-10-09T12:05:41.004512Z"
    }
  ],
  "meta": { "next_cursor": null, "has_more": false, "limit": 20 }
}
```

To fetch the next page, repeat the request with `cursor=<meta.next_cursor>` and the same filters.

| Status | Error (`code: message`) | Cause |
| --- | --- | --- |
| `400` | `bad_request: Invalid cursor` | Malformed `cursor` |
| `400` | `bad_request: Invalid channel_id` | `channel_id` is not a UUID |
| `401` | `unauthorized` | No or invalid credentials |
| `403` | `forbidden` | Authenticated with `x-channel-token` instead of `x-api-key` |

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
[ADR-0001](../adr/0001-transactional-outbox-with-oban.md)), then broadcasts it to connected clients. The activity has no
source channel, so it is routed in the inbound direction: to the conversation's origin channel and to the targets of
the origin channel's matching routing rules ([routing rules](../concepts/routing-rules.md#how-activities-fan-out),
[activity flow](../architecture/activity-flow.md)).

**Rate limit:** `activity_create`, 100 per second per tenant (shared with the client API).

| Header | Notes |
| --- | --- |
| `x-idempotency-key` | Optional. Repeating a request with the same key returns the original activity (`201`) and creates nothing. Unique per conversation. |

| Body field | Type | Notes |
| --- | --- | --- |
| `type` | string | Default `message` |
| `text` | string | |
| `attachments` | array of objects | Each needs a `contentType` |
| `metadata` | object | |
| `reply_to_id` | string | An activity of this conversation; required for `messageReaction`, `messageUpdate`, `messageDelete` |
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
    "reply_to_id": null,
    "edited_at": null,
    "deleted_at": null,
    "conversation_id": "3f6d1c2e-8a4b-4f1e-9c51-0e6a2b7d9f10",
    "tenant_id": "c2a4e6f8-1b3d-4f5a-9c7e-2d4f6a8b0c1e",
    "inserted_at": "2026-10-09T12:05:41.004512Z"
  }
}
```

| Status | Error (`code: message`) | Cause |
| --- | --- | --- |
| `404` | `not_found` | Unknown or foreign conversation |
| `409` | `conversation_closed` | Conversation is closed |
| `422` | `invalid_message` with `details` `{"type": ["is invalid"]}` | Validation failed: unknown or internal `type`, `text` over 65,536 bytes, too many or too large attachments, an attachment without `contentType`, `metadata` too large, an invalid `reply_to_id` (unknown, in another conversation, editing someone else's message) |
| `429` | `rate_limited` | Tenant's `activity_create` limit exceeded |
| `503` | `unavailable` | Deliveries could not be enqueued; nothing was stored. Retry with the same idempotency key. |

Example `422` bodies:

```json
{ "error": { "code": "invalid_message", "message": "Invalid message", "details": { "text": ["should be at most 65536 byte(s)"] }, "request_id": "GBHDfGZ0bW5Sl2YAAAEB" } }
```

```json
{ "error": { "code": "invalid_message", "message": "Invalid message", "details": { "attachments": ["attachment 0 is 4112 bytes, max is 4096"] }, "request_id": "GBHDfGZ0bW5Sl2YAAAEB" } }
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
      "reply_to_id": null,
      "edited_at": null,
      "deleted_at": null,
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
      "reply_to_id": null,
      "edited_at": null,
      "deleted_at": null,
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

| Status | Error (`code: message`) | Cause |
| --- | --- | --- |
| `400` | `invalid_watermark` | Malformed watermark |
| `404` | `not_found` | Unknown or foreign conversation |

## Routing rules

A routing rule copies the activities of a source channel's conversations to one or more target channels, optionally
only when its conditions match, in priority order, with its own transformations; see
[Routing rules](../concepts/routing-rules.md). Changes made through this API are recorded in the audit log with actor
type `tenant_api`.

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
| Valid conditions | `conditions: <path>: <reason>`, for example `conditions.all[0]: unknown field channel (use ...)` or `conditions: regex is longer than 256 bytes` |
| Valid transformations | `transformations: unknown middleware type: foo` |
| Priority from -1,000,000 to 1,000,000 | `priority: must be less than or equal to 1000000` |

### List routing rules

`GET /api/v1/routing_rules`

Returns all of the tenant's rules sorted by name (evaluation order is by `priority`, see [Routing rules](../concepts/routing-rules.md#priority-and-stop_processing)), without pagination (hard cap: `lookup_limit`, default 1000).

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
| `conditions` | object or array | no | Default `{}` (every activity). A predicate, an `all` / `any` / `not` group, or an array (shorthand for `all`); see [Conditions](../concepts/routing-rules.md#conditions) |
| `transformations` | array | no | Default `[]`. Middleware chain for this rule's targets, run after the target channel's own ([middleware](../concepts/middleware.md)) |
| `priority` | integer | no | Default `100`; lower is evaluated first |
| `stop_processing` | boolean | no | Default `false`; when this rule matches, later rules are not evaluated |

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
{ "error": { "code": "validation_failed", "message": "Validation failed", "details": { "target_channel_ids": ["would create a routing cycle"] }, "request_id": "GBHDfGZ0bW5Sl2YAAAEB" } }
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

### Dry-run routing

`POST /api/v1/routing_rules/dry_run`

Shows which rules match an activity and what each target channel would receive, without storing or sending anything.
It runs the same planning and transformation code as a real delivery ([Dry-run](../concepts/routing-rules.md#dry-run)).
The body is not wrapped:

| Field | Type | Notes |
| --- | --- | --- |
| `activity` | object | Required. `type` (default `message`), `text`, `sender` (default `user`), `metadata`, `attachments`, `reply_to_id`; validated like a posted activity (`422` on errors) |
| `source_channel_id` | UUID | The channel the activity arrives on. Required without `conversation_id`; defaults to the conversation's origin |
| `conversation_id` | UUID | Optional: an existing conversation, whose origin, metadata and participant are used |
| `origin_channel_id` | UUID | Without `conversation_id`: the origin of the new conversation (default: the source channel). A different channel makes the activity a reply |
| `conversation` | object | Without `conversation_id`: `{"metadata": {...}}` for `conversation.metadata.*` conditions |
| `participant` | object | Without `conversation_id`: `{"external_id", "display_name", "metadata"}`, the participant on the origin channel |
| `at` | string | ISO 8601 time for `time.*` conditions (default: now) |

```bash
curl -s -X POST "$CONVERGER/api/v1/routing_rules/dry_run" \
  -H "content-type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{
    "source_channel_id": "9b1f3a52-6c0d-4e2b-8f7a-1d2c3b4a5e6f",
    "activity": {"text": "upgrade me", "sender": "16505551234", "metadata": {"vip": true}}
  }'
```

`200 OK`:

```json
{
  "data": {
    "direction": "inbound",
    "origin_channel_id": "9b1f3a52-6c0d-4e2b-8f7a-1d2c3b4a5e6f",
    "source_channel_id": "9b1f3a52-6c0d-4e2b-8f7a-1d2c3b4a5e6f",
    "rule_source_channel_id": "9b1f3a52-6c0d-4e2b-8f7a-1d2c3b4a5e6f",
    "at": "2026-10-12T09:30:00.000000Z",
    "activity": { "type": "message", "text": "upgrade me", "sender": "16505551234", "metadata": {"vip": true}, "...": "..." },
    "rules": [
      {"id": "7c9e...", "name": "vip", "priority": 10, "stop_processing": true, "result": "matched",
       "conditions": {"field": "metadata.vip", "op": "eq", "value": true},
       "target_channel_ids": ["0d2f..."], "transformations": [{"type": "add_prefix", "prefix": "[VIP] "}]},
      {"id": "1a3c...", "name": "everything", "priority": 100, "stop_processing": false, "result": "skipped",
       "conditions": {}, "target_channel_ids": ["4b6d..."], "transformations": []}
    ],
    "matched_rule_ids": ["7c9e..."],
    "targets": [
      {"channel_id": "9b1f...", "channel_name": "wa-support", "channel_type": "whatsapp_meta", "reason": "origin",
       "rule_ids": [], "excluded": "echo", "outcome": "excluded", "detail": null, "payload": null},
      {"channel_id": "0d2f...", "channel_name": "vip-alerts", "channel_type": "webhook", "reason": "rule",
       "rule_ids": ["7c9e..."], "excluded": null, "outcome": "deliver", "detail": null,
       "payload": {"text": "[VIP] upgrade me", "metadata": {"vip": true}, "...": "..."}}
    ]
  }
}
```

| Field | Notes |
| --- | --- |
| `direction` | `inbound` (arrives on the origin channel) or `reply` (arrives on another channel: goes back to the origin) |
| `rule_source_channel_id` | The channel whose rules were evaluated: the origin for `inbound`, the arrival channel for `reply` |
| `rules[].result` | `matched`, `not_matched`, or `skipped` (after a matching `stop_processing` rule) |
| `targets[].reason` | `origin`, `reply_back`, `source_hub` (a replying `websocket` channel), or `rule` (with `rule_ids`) |
| `targets[].outcome` | `deliver` (with `payload`: the canonical activity after the type downgrade, the channel's middleware and the rules' transformations), `halted` (a middleware halted, `detail` says why), `skipped` (the channel cannot take the type), or `excluded` (`excluded` is `echo`, `inactive`, `inbound_only`, `not_deliverable` or `unsupported_activity`) |

Errors: `400 bad_request: activity is required`, `400 bad_request: source_channel_id or conversation_id is required`,
`400 bad_request: at must be an ISO 8601 date-time`, `404` for an unknown or foreign channel or conversation, `422`
for an invalid activity.

## Deliveries

Inspect and replay dead letters: deliveries that ended `failed` after their retries ran out, a permanent provider
error or a middleware halt. These endpoints require the tenant API key (`x-api-key`); a channel token gets `403`,
since deliveries expose the payloads of every conversation. Fix the cause (for example the channel's webhook URL)
before replaying. The rules are described in [Replaying dead letters](../delivery.md#replaying-dead-letters).

### List deliveries

`GET /api/v1/deliveries`

The tenant's deliveries (through their channel), most recently changed first, keyset-paginated on
`(updated_at, id)`. All filters are optional:

| Param | Meaning |
| --- | --- |
| `status` | `pending`, `paused`, `sent`, `delivered`, `read` or `failed`. Use `failed` for the dead-letter queue, `paused` for deliveries parked by a [circuit breaker or pause](#channel-delivery-state). |
| `channel_id` | Only this channel's deliveries. |
| `activity_id` | Only this activity's deliveries. |
| `from`, `to` | Bounds on `updated_at` (the time of the last status change, so the failure time of a dead letter), inclusive. ISO 8601 datetimes, or dates: `from=2026-10-01` starts at 00:00 UTC, `to=2026-10-01` ends at 23:59:59.999999 UTC. |
| `limit`, `cursor` | [Pagination](overview.md#pagination). |

```bash
curl -s "$CONVERGER/api/v1/deliveries?status=failed&channel_id=0d2f4b6a-8c0e-4a2c-9e4b-6d8f0a2c4e6b&from=2026-10-01" \
  -H "x-api-key: $API_KEY"
```

```json
{
  "data": [ { "id": "1c2d3e4f-...", "status": "failed", "attempts": 5, "last_error": "webhook returned HTTP 503", "payload": { "...": "..." } } ],
  "meta": { "next_cursor": null, "has_more": false, "limit": 50 }
}
```

An invalid filter returns `400 bad_request: Invalid <param>`.

### Retry a delivery

`POST /api/v1/deliveries/:id/retry`

Moves a `failed` delivery back to `pending`, resets `attempts` to `0`, records `retried_by` and `retried_at`,
increments `retry_count`, writes an audit log entry and enqueues a delivery job, in one transaction.

```bash
curl -s -X POST "$CONVERGER/api/v1/deliveries/1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f/retry" \
  -H "x-api-key: $API_KEY"
```

`202 Accepted` with the [delivery](#delivery) (`"status": "pending"`, `"attempts": 0`). The job runs
asynchronously; follow the outcome with `GET /api/v1/deliveries?activity_id=...` or the `delivery_status` event on
the conversation.

| Status | Body | When |
| --- | --- | --- |
| `202` | `{"data": {...}}` | Re-enqueued |
| `400` | `channel_inactive` | The delivery's channel is disabled; enable it first |
| `404` | `not_found` | Unknown delivery, or one of another tenant |
| `409` | `not_failed` | The delivery is not (or no longer) `failed` |

### Retry a channel's dead letters

`POST /api/v1/channels/:channel_id/deliveries/retry`

Replays every `failed` delivery of the channel, oldest failure first. Optional body (or query) params narrow it
down: `from`, `to` and `activity_id` (same format as the list filters), and `limit` (at most the server's
`bulk_retry_limit`, default 10 000, which is also the default). Each delivery gets exactly one job: concurrent calls
never replay the same delivery twice, and a delivery that fails again while the call runs is not picked up again.

```bash
curl -s -X POST "$CONVERGER/api/v1/channels/0d2f4b6a-8c0e-4a2c-9e4b-6d8f0a2c4e6b/deliveries/retry" \
  -H "x-api-key: $API_KEY" -H "content-type: application/json" \
  -d '{"from": "2026-10-09T00:00:00Z"}'
```

```json
{ "data": { "retried": 412, "has_more": false } }
```

`has_more: true` means the limit was reached and more dead letters match: call again. `400 Channel is inactive`
for a disabled channel, `404` for an unknown or foreign channel.

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

## Channel message templates

`GET /api/v1/channels/:channel_id/templates`

Lists the message templates (WhatsApp HSM) the channel's provider account has, so a bot can pick an approved template
for a message outside WhatsApp's 24-hour window. Converger proxies the provider's own list
([ADR-0039](../adr/0039-whatsapp-rich-outbound-and-inbound-media-download.md)):

| Channel type | Provider call | Needs |
| --- | --- | --- |
| `whatsapp_meta` | `GET https://graph.facebook.com/<version>/<waba_id>/message_templates`, following `paging.next` for up to 10 pages of 100 | the channel config key `waba_id` |
| `whatsapp_infobip` | `GET <base_url>/whatsapp/2/senders/<sender>/templates` | |

```bash
curl -s "$CONVERGER/api/v1/channels/$CHANNEL_ID/templates" -H "x-api-key: $API_KEY"
```

```json
{
  "data": [
    {
      "id": "1234567890",
      "name": "order_update",
      "language": "en_US",
      "status": "APPROVED",
      "category": "UTILITY",
      "components": [{"type": "BODY", "text": "Your order {{1}} has shipped."}]
    }
  ],
  "cached": false,
  "fetched_at": "2026-10-11T12:00:00.000000Z"
}
```

Each entry keeps the provider's field values: Meta templates have `id`, `name`, `language`, `status`, `category` and
`components`; Infobip templates have `id`, `name`, `language`, `status`, `category` and `structure`.

The list is cached per node for 5 minutes (`config :converger, Converger.Channels.Templates, ttl_ms: 300_000`);
`cached` says whether this response came from the cache. Add `?refresh=true` to skip the cache, for example right after
a template was approved. Updating the channel clears its cache on the node that handled the update; other nodes pick up
the change within the TTL. Failed listings are not cached.

| Status | Error (`code: message`) | Cause |
| --- | --- | --- |
| `200` | the list above | |
| `404` | `not_found` | Unknown channel, or a channel of another tenant |
| `422` | `unsupported_channel_type: Channel type echo has no message templates` | The channel's adapter does not list templates |
| `422` | `invalid_channel_config: whatsapp_meta config 'waba_id' (WhatsApp Business Account id) is required to list templates` | `whatsapp_meta` channel without `waba_id` |
| `502` | `upstream_unavailable: WhatsApp API returned 401: ...` | The provider call failed (expired token, wrong account, timeout) |

How to send a template is described in [WhatsApp: templates](../channels/whatsapp.md#templates-hsm).

## Platform event webhooks

Tenant-level subscriptions to [platform events](../platform-webhooks.md) (activities, delivery status,
conversation lifecycle, channel health and circuit breaker, opt-outs) and their event log. These endpoints require
the tenant API key (`x-api-key`); a channel token gets `403`. Changes are audit-logged
(`resource_type: "webhook_subscription"`, `"webhook_event"`). Errors follow the shared conventions: `422` with
`{"errors": {...}}` for validation, `404` for an unknown id or one of another tenant.

### Subscription

```json
{
  "id": "6b1c...", "tenant_id": "3f2a...", "url": "https://crm.example.com/converger",
  "description": "CRM sync", "events": ["delivery.failed", "conversation.closed"], "enabled": true,
  "header_names": ["authorization"], "managed_by": null,
  "inserted_at": "2026-10-12T10:00:00.000000Z", "updated_at": "2026-10-12T10:00:00.000000Z"
}
```

`secret` is included only in the responses of create and `rotate_secret`. Header values are never returned.

### List the event types

`GET /api/v1/webhook_event_types` returns `{"data": ["activity.created", "delivery.sent", ...]}`.

### Create a subscription

`POST /api/v1/webhook_subscriptions`

```bash
curl -s -X POST "$CONVERGER/api/v1/webhook_subscriptions" \
  -H "x-api-key: $API_KEY" -H "content-type: application/json" \
  -d '{"webhook_subscription": {
        "url": "https://crm.example.com/converger",
        "events": ["delivery.failed", "conversation.closed"],
        "description": "CRM sync",
        "headers": {"authorization": "Bearer crm-token"}
      }}'
```

`201` with the subscription and its `secret` (`whsec_...`). Store the secret: it is not shown again. `url`
(`http`/`https`, public targets only), `events` (catalog types or `"*"`, at least one), `secret` (optional, at least
16 characters), `enabled`, `headers` (string values; `host`, `content-length`, `content-type`, hop-by-hop headers and
`x-converger-*` are reserved) and `description` are accepted. `422` lists invalid fields, for example
`{"errors": {"events": ["unknown event types: bogus.event"]}}`.

### List, get, update and delete

- `GET /api/v1/webhook_subscriptions`, `GET /api/v1/webhook_subscriptions/:id`
- `PATCH /api/v1/webhook_subscriptions/:id` with `{"webhook_subscription": {...}}` (same fields as create; a
  `secret` here is ignored, use `rotate_secret`)
- `DELETE /api/v1/webhook_subscriptions/:id`: `204`, the subscription's event log goes with it.

The subscription with `managed_by: "alert_webhook_url"` mirrors the tenant's alert URL; the admin tenant form
overwrites its URL ([details](../platform-webhooks.md#the-legacy-alert_webhook_url)).

### Rotate the secret

`POST /api/v1/webhook_subscriptions/:id/rotate_secret` returns the subscription with a new `secret`. The next
attempt of every queued event is signed with it.

### List events

`GET /api/v1/webhook_events`

The tenant's events, newest first, keyset-paginated on `(inserted_at, id)`. Events are kept 7 days.

| Param | Meaning |
| --- | --- |
| `subscription_id` | Only this subscription's events. |
| `status` | `pending` (queued or retrying), `delivered` or `failed` (dead-lettered). |
| `type` | One event type, e.g. `delivery.failed`. |
| `limit`, `cursor` | [Pagination](overview.md#pagination). |

```json
{
  "data": [
    {
      "id": "8e7d...", "event_id": "5f0c...", "subscription_id": "6b1c...", "type": "delivery.failed",
      "status": "failed", "attempts": 5, "last_error": "webhook returned 503: \"\"", "response_status": 503,
      "payload": { "delivery_id": "1c2d...", "status": "failed" },
      "delivered_at": null, "redelivered_at": null,
      "inserted_at": "2026-10-12T10:00:00.000000Z", "updated_at": "2026-10-12T11:21:00.000000Z"
    }
  ],
  "meta": { "next_cursor": null, "has_more": false, "limit": 50 }
}
```

`400` for an invalid `status`, `subscription_id` or cursor. `GET /api/v1/webhook_events/:id` returns one event.

### Redeliver an event

`POST /api/v1/webhook_events/:id/redeliver`

Moves a `failed` event back to `pending` with `attempts` reset, enqueues a new delivery job and writes an audit
entry (`action: "redeliver"`). The receiver gets the same `x-converger-delivery-id`.

| Status | Body | When |
| --- | --- | --- |
| `202` | `{"data": {...}}` | Re-enqueued (the event may already show its new outcome) |
| `404` | `{"errors": {"detail": "Not Found"}}` | Unknown event, or one of another tenant |
| `409` | `{"error": "not_failed", "detail": "Only failed events can be redelivered"}` | The event is not `failed` |

## Related

- [REST API overview](overview.md)
- [Platform event webhooks](../platform-webhooks.md)
- [Client API](client-api.md)
- [Inbound webhooks](inbound.md)
- [Activities](../concepts/activities.md), [conversations](../concepts/conversations.md), [routing rules](../concepts/routing-rules.md), [deliveries](../concepts/deliveries.md)
