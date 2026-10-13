---
title: Platform event webhooks
sidebar_label: Platform event webhooks
sidebar_position: 7
description: Tenant-level webhook subscriptions for activity, delivery, conversation, channel and participant events - event catalog, payloads, signature verification, retries, dead letters and retention.
---

# Platform event webhooks

A tenant can subscribe one or more URLs to **platform events**: every activity, delivery status changes, conversation
lifecycle, channel health and circuit breaker transitions, and participant opt-outs. Converger POSTs each event as
signed JSON, retries failures under the shared retry policy, and keeps a 7-day event log with a per-subscription
dead-letter queue and a "redeliver" action.

This is different from a [`webhook` channel](webhooks.md): a channel is a delivery target for the activities of the
conversations routed to it, while a subscription is a tenant-wide feed of what happens on the platform. Use a
subscription to mirror activities into your CRM, alert on `delivery.failed` or `channel.circuit_opened`, or close a
ticket on `conversation.closed`, without creating a channel per conversation.

The decision record is [ADR-0053](adr/0053-platform-event-webhooks.md).

## Subscriptions

A subscription has:

| Field | Notes |
| --- | --- |
| `url` | `http` or `https`. Private, loopback and link-local targets are rejected, like webhook channels ([SSRF guard](webhooks.md#ssrf-protection)). |
| `events` | Event types from the [catalog](#event-catalog), or `"*"` for every type. At least one. |
| `secret` | Signing secret (`whsec_...`). Generated when not given, at least 16 characters. Returned only when the subscription is created or its secret rotated. Encrypted at rest. |
| `enabled` | `false` stops new events; queued events of a disabled subscription are dead-lettered. |
| `headers` | Extra request headers (string values), for example `authorization`. Encrypted at rest; the API returns only their names. `host`, `content-length`, `content-type`, hop-by-hop headers and `x-converger-*` are reserved. |
| `description` | Free text. |
| `managed_by` | Read-only. `alert_webhook_url` for the subscription that mirrors the tenant's legacy alert URL ([below](#the-legacy-alert_webhook_url)). |

Manage subscriptions with the [tenant API](api/tenant-api.md#platform-event-webhooks), in the tenant portal
(**Webhooks**, owners and admins; members and viewers can look) or in the admin panel (**Webhooks**, super admins
and admins). Both UIs can also rotate a subscription's signing secret (shown once) and page through the event log. Every change is audit-logged (`resource_type: "webhook_subscription"`). The endpoints are in the
[OpenAPI document](api/openapi.md) (tag `Webhooks`) and answer errors with the [error envelope](api/errors.md), for
example `422 validation_failed` with the invalid fields in `details`.

## Event catalog

Every type below is emitted today. Events are produced from the same hooks that already broadcast these changes to
WebSocket clients, after the change is committed.

| Type | When | `data` |
| --- | --- | --- |
| `activity.created` | Every new activity, from any channel, the API or the system (including `conversationUpdate` lifecycle activities) | The canonical activity: `id`, `type`, `sender`, `text`, `attachments`, `metadata`, `idempotency_key`, `seq`, `reply_to_id`, `edited_at`, `deleted_at`, `conversation_id`, `tenant_id`, `inserted_at` |
| `delivery.sent` | A delivery left Converger (the adapter accepted it, or a client acknowledged it) | [Delivery data](#delivery-data) |
| `delivery.delivered` | The provider reported the message delivered | [Delivery data](#delivery-data) |
| `delivery.read` | The provider reported the message read | [Delivery data](#delivery-data) |
| `delivery.failed` | A delivery was dead-lettered (retries exhausted, permanent error, middleware halt) or the provider reported it failed | [Delivery data](#delivery-data) |
| `conversation.created` | A conversation was created (API, client API or inbound resolution) | [Conversation data](#conversation-data) |
| `conversation.closed` | A conversation was closed by hand or by the inactivity expiry | [Conversation data](#conversation-data) plus `reason` (`manual`, `expired`, ...) |
| `conversation.reopened` | A closed conversation was reopened | [Conversation data](#conversation-data) plus `reason` |
| `channel.health_changed` | The health check (every 5 minutes) found a different status than the previous one | `channel_id`, `channel_name`, `channel_type`, `tenant_id`, `previous_status`, `status`, `failure_rate`, `total_deliveries`, `failed_deliveries`, `checked_at` |
| `channel.circuit_opened` | The channel's delivery circuit breaker opened (health `unhealthy`, consecutive failures, or a failed half-open probe) | `channel_id`, `channel_name`, `channel_type`, `tenant_id`, `circuit_state: "open"`, `reason`, `changed_at` |
| `channel.circuit_closed` | A probe succeeded and the breaker closed | Same as `channel.circuit_opened`, `circuit_state: "closed"` |
| `participant.opted_out` | A participant opted out (for example an SMS `STOP`); opting out again sends nothing | `participant_id`, `channel_id`, `external_id`, `display_name`, `opted_out_at` |

A manual pause or resume of a channel is not an event. `GET /api/v1/webhook_event_types` returns the catalog.

### Delivery data

```json
{
  "delivery_id": "1c2d3e4f-...", "activity_id": "9b2f6c1e-...", "conversation_id": "3a4b5c6d-...",
  "channel_id": "0d2f4b6a-...", "status": "failed", "attempts": 5,
  "last_error": "webhook returned 503: ...", "provider_message_id": null,
  "sent_at": null, "delivered_at": null, "read_at": null, "updated_at": "2026-10-12T10:00:00.000000Z"
}
```

### Conversation data

```json
{
  "conversation_id": "3a4b5c6d-...", "status": "closed", "channel_id": "0d2f4b6a-...",
  "origin_channel_id": "0d2f4b6a-...", "participant_id": null, "metadata": {},
  "inserted_at": "2026-10-12T09:00:00Z", "updated_at": "2026-10-12T10:00:00.000000Z", "reason": "manual"
}
```

## Requests

```http
POST /converger-events HTTP/1.1
content-type: application/json
user-agent: Converger-Webhooks/1
x-converger-event: delivery.failed
x-converger-event-id: 5f0c1d2e-0000-4000-8000-00000000e001
x-converger-delivery-id: 8e7d6c5b-...
x-converger-signature: t=1760263200,v1=872ae23f...

{"id":"5f0c1d2e-...","type":"delivery.failed","created_at":"2026-10-12T10:00:00.000000Z","tenant_id":"7a1b2c3d-...","data":{...}}
```

| Header | Meaning |
| --- | --- |
| `x-converger-event` | The event type. |
| `x-converger-event-id` | The occurrence (`id` in the body). The same for every subscription that receives it. |
| `x-converger-delivery-id` | This subscription's copy of the event (the event log row). Stable across retries and redeliveries: use it to deduplicate. |
| `x-converger-signature` | `t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>`. |

The body is the envelope `{id, type, created_at, tenant_id, data}`. Answer with any `2xx` within the receive timeout
(10 s by default); the response body is ignored (at most 64 KB is read). Redirects are not followed: a `3xx` is a
failure. Events can arrive out of order and more than once (a timeout after the receiver processed the request is
retried), so make handlers idempotent on `x-converger-delivery-id` and order by the timestamps in `data` when it
matters.

## Verifying the signature

The scheme is the one used by [webhook channels](webhooks.md#verifying-the-signature) and inbound requests, so the same
code verifies all of them: split the header, check that `t` is within your tolerance (300 s recommended), compute
`HMAC-SHA256(secret, "<t>.<raw body>")` over the **raw** request body and compare it in constant time with `v1`.

### Test vector

```
secret:  whsec_test_secret
t:       1760263200
body:    {"id":"5f0c1d2e-0000-4000-8000-00000000e001","type":"delivery.failed","created_at":"2026-10-12T10:00:00.000000Z","tenant_id":"7a1b2c3d-0000-4000-8000-0000000000aa","data":{"delivery_id":"1c2d3e4f-0000-4000-8000-0000000000d1","status":"failed"}}
header:  t=1760263200,v1=872ae23fc46fdd161ee57bef17465a858512ed24dd3e70d131d2ea2729f4c206
```

### Node.js

```js
const crypto = require("crypto");

function verify(secret, header, rawBody, toleranceSeconds = 300) {
  const parts = Object.fromEntries(header.split(",").map((p) => p.trim().split("=", 2)));
  const t = Number(parts.t);
  if (!Number.isInteger(t) || Math.abs(Date.now() / 1000 - t) > toleranceSeconds) return false;
  const expected = crypto.createHmac("sha256", secret).update(`${t}.${rawBody}`).digest("hex");
  const given = Buffer.from(parts.v1 || "", "utf8");
  return given.length === expected.length && crypto.timingSafeEqual(given, Buffer.from(expected));
}
```

### Python

```python
import hashlib, hmac, time

def verify(secret: str, header: str, raw_body: bytes, tolerance: int = 300) -> bool:
    parts = dict(p.strip().split("=", 1) for p in header.split(","))
    t = int(parts.get("t", "0"))
    if abs(time.time() - t) > tolerance:
        return False
    expected = hmac.new(secret.encode(), f"{t}.".encode() + raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, parts.get("v1", ""))
```

### Elixir

```elixir
def verify(secret, header, raw_body, tolerance \\ 300) do
  parts = header |> String.split(",") |> Map.new(&(&1 |> String.trim() |> String.split("=", parts: 2) |> List.to_tuple()))
  t = String.to_integer(parts["t"])
  expected = :crypto.mac(:hmac, :sha256, secret, "#{t}.#{raw_body}") |> Base.encode16(case: :lower)

  abs(System.system_time(:second) - t) <= tolerance and
    Plug.Crypto.secure_compare(expected, parts["v1"] || "")
end
```

Rotating the secret (`POST /api/v1/webhook_subscriptions/:id/rotate_secret`) takes effect for the next attempt,
including retries of events already queued; accept both secrets for a while if you rotate without downtime.

## Retries and dead letters

Each event is delivered by an Oban job (`Converger.Workers.WebhookEventWorker`, queue `webhooks`) under the
**shared retry policy** (`config :converger, :retry_policy`, see
[delivery retries](delivery.md#retry-policy)): by default 5 attempts with exponential backoff (`base_ms * 3^attempt`,
capped at one hour). A receiver's `Retry-After` overrides the backoff for the next attempt.

| Outcome | Result |
| --- | --- |
| `2xx` | `delivered` |
| `408`, `425`, `429`, `5xx`, timeout, connection error, DNS failure | Retried; `pending` with `attempts`, `last_error` and `response_status` |
| Other `4xx`, `3xx`, blocked target (SSRF guard) | Dead-lettered at once (`failed`) |
| Last allowed attempt fails | Dead-lettered (`failed`) |
| The subscription was disabled or deleted meanwhile | Dead-lettered (`failed`, `subscription disabled`), or removed with the subscription |

A dead-lettered event stays in the log with its last error and HTTP status. **Redeliver** it from the portal or
admin page, or with `POST /api/v1/webhook_events/:id/redeliver`: it goes back to `pending` with `attempts` reset and a
new job, keeps its `x-converger-delivery-id`, and the action is audit-logged (`action: "redeliver"`). Only `failed`
events can be redelivered; any other status is `409` with the code `not_failed` in the [error envelope](api/errors.md).

Telemetry: `[:converger, :webhooks, :emitted]` (`count`), `[:converger, :webhooks, :delivered]`,
`[:converger, :webhooks, :failed]` (a retried attempt) and `[:converger, :webhooks, :dead_lettered]`, with
`tenant_id`, `subscription_id` and `type` metadata.

## Retention

The event log (`webhook_events`) keeps 7 days. The daily `PruneWorker` (01:30 UTC) deletes older rows in batches;
change the window with `WEBHOOK_EVENT_RETENTION_DAYS` (`0` keeps events forever). See
[retention](operations/retention.md#pruning-other-tables).

## The legacy `alert_webhook_url`

`tenants.alert_webhook_url` used to receive unsigned, fire-and-forget health and circuit breaker alerts. It is now a
subscription with `managed_by: "alert_webhook_url"` on `channel.health_changed`, `channel.circuit_opened` and
`channel.circuit_closed`:

- the migration created one for every tenant that had the URL set;
- setting, changing or clearing the URL in the admin tenant form keeps that subscription in sync;
- its requests keep the **legacy body** (`{"event": "channel_health_changed", "new_status": ..., ...}` and
  `{"event": "channel.circuit_opened", "reason": ..., "changed_at": ...}`, see
  [channel health](channels/overview.md#channel-health)), so existing receivers keep working, but they are now signed
  (with a generated secret, which an admin can rotate through the API), retried and logged;
- like before, a breaker re-opened by a failed probe is not sent to it.

## Configuration

| Setting | Default | Notes |
| --- | --- | --- |
| `config :converger, :platform_webhooks, enabled:` | `true` | `false` stops emitting events (subscriptions are kept). |
| `config :converger, :platform_webhooks, connect_timeout:` | `5000` | Connect timeout, ms. |
| `config :converger, :platform_webhooks, receive_timeout:` | `10000` | Response timeout, ms. |
| `config :converger, :platform_webhooks, max_response_bytes:` | `65536` | Response bytes read. |
| `config :converger, :retry_policy` | 5 attempts, exponential, 10 s base | Shared with channel deliveries. |
| `WEBHOOK_EVENT_RETENTION_DAYS` | `7` | Event log retention (`Converger.Retention`, `webhook_event_days`). |
| `WEBHOOK_ALLOWED_TARGETS`, `WEBHOOK_ALLOW_PRIVATE_TARGETS` | unset | SSRF guard escape hatches, shared with webhook channels. |
| Oban queue `webhooks` | 10 | Concurrency of event delivery. |

## Related

- [Tenant API: platform event webhooks](api/tenant-api.md#platform-event-webhooks)
- [Outbound webhooks (channel adapter)](webhooks.md)
- [Delivery pipeline and retries](delivery.md)
- [ADR-0053](adr/0053-platform-event-webhooks.md), [ADR-0014](adr/0014-webhook-ssrf-guard-and-outbound-signing.md)
