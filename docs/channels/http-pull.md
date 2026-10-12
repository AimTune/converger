---
title: HTTP pull (outbox)
description: The http_pull channel type, an outbound-only channel whose activities the integrator polls from GET /api/v1/channels/:id/outbox with watermark acknowledgement and no data loss.
sidebar_position: 2.9
---

The `http_pull` channel type is the pull counterpart of the [webhook](../webhooks.md) channel: instead of Converger
posting each activity to the integrator, the integrator polls the channel's **outbox**. It is meant for systems behind
firewalls that accept no inbound connections. The channel is outbound only (mode `outbound`).

Source: [`lib/converger/channels/adapters/http_pull.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/http_pull.ex),
[`lib/converger/channels/outbox.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/outbox.ex),
[`lib/converger_web/controllers/channel_outbox_controller.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/channel_outbox_controller.ex).
Design: [ADR-0048](../adr/0048-additional-adapters-shared-meta-code-bot-framework-jwt-and-pull-outbox.md).

## Setup

Create the channel with type `http_pull` and mode `outbound` (no config keys), then route conversations to it with a
routing rule, as you would a webhook channel:

```json
{ "name": "ERP outbox", "type": "http_pull", "mode": "outbound" }
```

## How it works

1. The pipeline delivers an activity to the channel like to any other: middleware runs, then the adapter stores the
   canonical activity JSON (the same shape as the webhook body and the REST API) in the delivery and returns
   `{:pending, ...}`. The delivery stays `pending` and is never retried: it is in the outbox.
2. The integrator polls the outbox. Each page lists pending deliveries oldest first and returns a **watermark**.
3. The next poll sends that watermark back. Everything up to it that was served is acknowledged (the deliveries
   become `sent`) and the next page is returned.

Lifecycle events (conversation closed and reopened) go to the outbox too, as for webhooks.

## API

Both endpoints are tenant API endpoints, authenticated with the tenant's `x-api-key` like the other channel APIs.
The channel must belong to the tenant (`404` otherwise) and be an `http_pull` channel (`422` otherwise).

### `GET /api/v1/channels/:channel_id/outbox`

| Parameter | Default | Description |
| --- | --- | --- |
| `watermark` | none | The watermark of the previous page: acknowledges it, then returns the next page. Omit it on the first poll. |
| `limit` | `50` | Page size, 1 to 200 (larger values are capped at 200). |

```bash
curl -s "https://converger.example.com/api/v1/channels/$CHANNEL_ID/outbox?watermark=$WATERMARK" \
  -H "x-api-key: $API_KEY"
```

```json
{
  "data": [
    {
      "delivery_id": "6f1c...",
      "queued_at": "2026-10-12T10:00:00.000000Z",
      "served_before": false,
      "activity": {
        "id": "0b4c...",
        "type": "message",
        "conversation_id": "9a7e...",
        "sender": "+15550100",
        "text": "Where is my order?",
        "seq": 3,
        "attachments": [],
        "metadata": {}
      }
    }
  ],
  "watermark": "djE6MTc2MDI2MzIwMDAwMDAwMDo2ZjFj...",
  "has_more": false,
  "acknowledged": 1
}
```

- `watermark` names the position of the last item of the page; an empty page returns the watermark you sent.
- `has_more` is `true` when more items wait after this page: poll again at once with the new watermark.
- `acknowledged` is how many deliveries the watermark you sent acknowledged.
- `served_before` is `true` for an item an earlier poll already returned and that was not acknowledged (a redelivery):
  deduplicate by `delivery_id` or `activity.id`.

### `POST /api/v1/channels/:channel_id/outbox/ack`

Acknowledges without fetching, for example after the last page: `{"watermark": "..."}` answers
`{"acknowledged": 3}`. A missing or malformed watermark is a `400`.

## Delivery guarantees

- **At least once.** An item leaves the outbox only when a watermark at or after it is sent back. A consumer that
  crashes after fetching and before acknowledging gets the same items again (`served_before: true`).
- **No skipped items.** A watermark acknowledges only items that were actually served. A delivery committed late, with
  an earlier position than items already served (concurrent transactions), was never served, so the watermark does
  not acknowledge it and the next page returns it.
- **Order.** Items are ordered by when their delivery was created. Within one conversation that follows `seq` in
  practice; use `activity.seq` when strict per-conversation order matters.
- **One consumer per channel.** A watermark acknowledges what any poller was served, so two independent consumers
  of one channel would acknowledge each other's items. Give each consumer its own `http_pull` channel (and routing
  rule).
- **Retention.** Unacknowledged items are kept like other deliveries and fall under the tenant's
  [retention](../operations/retention.md); poll more often than the retention window.

Deliveries in the outbox count as `pending` in the delivery metrics and the dead-letter tools ignore them. The
channel has no health probe and no provider rate limit; the circuit breaker never opens, because a hand-off cannot
fail.
