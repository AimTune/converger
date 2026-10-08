---
title: Inbound webhooks
description: Reference for the provider-facing endpoints that receive messages and delivery receipts - signatures, the Meta verification handshake, payloads, responses and per-message idempotency.
sidebar_position: 4
---

Inbound webhooks are how messages and delivery receipts from outside systems enter Converger: WhatsApp Cloud API
(Meta), Infobip, or your own services posting to a generic webhook channel. Each channel has its own URL, and requests
are authenticated by a signature over the raw body, not by an API key. All three endpoints are handled by
[`ConvergerWeb.InboundController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/inbound_controller.ex).
How each channel type parses its payload is covered in [channels](../channels/overview.md).

## Endpoints

| Method | Path | Purpose | Rate limited |
| --- | --- | --- | --- |
| `GET` | `/api/v1/channels/:channel_id/inbound` | Webhook verification handshake (Meta) | no |
| `POST` | `/api/v1/channels/:channel_id/inbound` | Messages, and status updates sent to the same URL | `inbound` bucket |
| `POST` | `/api/v1/channels/:channel_id/status` | Delivery and read receipts only | `inbound` bucket |

`:channel_id` is the channel's UUID; a malformed id returns `400 {"errors": {"detail": "Bad Request"}}`. The
channel must exist (`404`) and be `active` (`400 {"error": "Channel is inactive"}`).

**Rate limit:** `inbound`, 500 requests per second per channel by default, counted on the path's `channel_id`
before the channel is loaded or the signature is checked, so a flood is rejected cheaply. Tenants can override it
through `tenants.limits`; see [rate limiting](overview.md#rate-limiting).

Which channel types accept which requests:

| Channel type | Messages on `/inbound` | Signature scheme |
| --- | --- | --- |
| `webhook` | yes (modes `inbound`, `duplex`) | `x-converger-signature` |
| `whatsapp_meta` | yes (modes `inbound`, `duplex`) | `x-hub-signature-256` (Meta app secret) |
| `whatsapp_infobip` | yes (modes `inbound`, `duplex`) | `x-converger-signature` |
| `echo`, `websocket` | no: `400` with the adapter's message | `x-converger-signature` |

A channel in `outbound` mode answers messages with `400 {"error": "Channel does not accept inbound messages"}`.
If the same request also carried status updates, those are applied and the request is acknowledged with `200`,
dropping the messages. The `/status` endpoint works for every mode, so outbound-only channels can still receive
receipts.

## Signatures

Every `POST` is verified over the exact bytes received. The body is cached by
[`ConvergerWeb.CacheBodyReader`](https://github.com/AimTune/converger/blob/main/lib/converger_web/cache_body_reader.ex)
for every path under `/api/v1/channels/`, before JSON parsing. Design and rollout are recorded in
[ADR-0009](../adr/0009-inbound-signature-scheme-and-per-channel-enforcement.md).

### Generic scheme: `x-converger-signature`

Used by every channel type without a provider-native scheme
([`Converger.Channels.InboundSignature`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/inbound_signature.ex)):

```http
x-converger-signature: t=1760011200,v1=5f2c0e8a4b...e91d
```

- `t` is the Unix time in seconds when the request was signed.
- `v1` is the lowercase hex HMAC-SHA256 of `"<t>.<raw body>"`, keyed with the channel `secret`.
- Several `v1=` values may be sent (`t=...,v1=<new>,v1=<old>`); the request is accepted if any of them matches,
  which allows rotating the secret without downtime.
- `t` must be within 300 seconds of the server clock in either direction
  (`config :converger, :inbound_signature_tolerance_seconds`), which limits replay of captured requests.

This is the same format Converger uses to sign its outbound webhooks, so one implementation serves both directions;
see [outbound webhooks](../webhooks.md) for verification snippets.

Signing a request with `openssl`:

```bash
SECRET='channel-secret'
BODY='{"sender":"crm-42","text":"Hello from the CRM","idempotency_key":"evt-1001"}'
T=$(date +%s)
SIG=$(printf '%s.%s' "$T" "$BODY" | openssl dgst -sha256 -hmac "$SECRET" -hex | sed 's/^.* //')

curl -s -X POST "$CONVERGER/api/v1/channels/$CHANNEL_ID/inbound" \
  -H "content-type: application/json" \
  -H "x-converger-signature: t=$T,v1=$SIG" \
  --data-raw "$BODY"
```

Sign the exact bytes you send: re-serializing the JSON after signing (key order, whitespace) breaks the signature.

The legacy format `x-converger-signature: sha256=<hex HMAC-SHA256 of the raw body>` has no timestamp and no replay
protection. It is recognised but treated like a missing signature (see below).

### WhatsApp Meta: `x-hub-signature-256`

`whatsapp_meta` channels verify Meta's own header, `x-hub-signature-256: sha256=<hex HMAC-SHA256 of the raw body>`,
keyed with the channel config's `app_secret`. The generic header is not accepted in its place. A channel with
`require_signature: true` cannot be saved without an `app_secret`.

### Enforcement: `require_signature`

Each channel has a `require_signature` flag (default `true` for new channels; toggled per channel in the admin
panel).

| Request | `require_signature: true` | `require_signature: false` |
| --- | --- | --- |
| Valid current signature | accepted | accepted |
| Signature present but invalid (wrong secret, tampered body, malformed header, timestamp out of tolerance) | `401` | `401` |
| No signature (or Meta channel without `app_secret`) | `401` | accepted, logged as `DEPRECATED` |
| Legacy `sha256=` generic signature | `401` | accepted, logged as `DEPRECATED` |

A rejected signature returns:

```json
{ "errors": { "detail": "Unauthorized" } }
```

`require_signature: false` exists for channels created before signatures were enforced. Unsigned requests will be
rejected in a future release, so sign requests and enable the flag.

## Meta verification handshake

`GET /api/v1/channels/:channel_id/inbound`

When you register the callback URL in the Meta app dashboard, Meta sends a `GET` with `hub.mode`, `hub.verify_token`
and `hub.challenge`. For a `whatsapp_meta` channel, Converger compares `hub.verify_token` with the channel config's
`verify_token` (constant-time):

| Case | Response |
| --- | --- |
| Token matches | `200`, body is the `hub.challenge` value verbatim (plain text) |
| Token missing or different | `403`, body `Verification failed` |
| Any other channel type | `200`, body `ok` |

```bash
curl -s "$CONVERGER/api/v1/channels/$CHANNEL_ID/inbound?hub.mode=subscribe&hub.verify_token=my-verify-token&hub.challenge=1158201444"
# 1158201444
```

The handshake is not signed and not rate limited. `hub.mode` is not checked.

## Messages: `POST /inbound`

The channel's adapter parses the body into a list of messages (and, for providers that mix them, status updates).
Messages are then processed in order; see [idempotency and batches](#idempotency-and-batches).

### Generic webhook payload

A `webhook` channel carries one message per request
([`Converger.Channels.Adapters.Webhook`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/webhook.ex)):

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `text` | string | | Aliases: `message`, `body` (first present wins) |
| `sender` | string | `"external"` | Alias: `from`. Stored as the activity's `sender`. |
| `type` | string | `message` | Activity type, validated like any activity |
| `attachments` | array | `[]` | Attachment objects (size limits as for activities) |
| `metadata` | object | `{}` | |
| `idempotency_key` | string | | Makes re-delivery safe; see below |
| `conversation_id` | UUID | | Post into this conversation (it must belong to the channel's tenant) |
| `external_id` | string | | The external party's id. Without `conversation_id`, messages with the same `external_id` join that participant's active conversation. |
| `display_name` | string | | Participant display name, stored with `external_id` |

A `message` with neither text nor attachments is rejected with `422`:

```json
{ "error": "Inbound message has no text and no attachments" }
```

A body that contains `status` together with `delivery_id` or `provider_message_id` is treated as a status update
instead of a message (see [status updates](#status-updates)).

```bash
curl -s -X POST "$CONVERGER/api/v1/channels/$CHANNEL_ID/inbound" \
  -H "content-type: application/json" \
  -H "x-converger-signature: t=$T,v1=$SIG" \
  --data-raw '{"sender":"crm-42","text":"Hello from the CRM","external_id":"customer-981","display_name":"Ada","idempotency_key":"evt-1001"}'
```

### Conversation resolution

For each message, in order of precedence:

1. An explicit `conversation_id` in the request (tenant-scoped). Unknown: `404`. Closed:
   `409 {"error": "conversation_closed", "detail": "Conversation is closed"}`.
2. A participant (`external_id` for generic webhooks; the sender's phone number for WhatsApp): the participant's
   active conversation on this channel, or a new one. A closed conversation is never reused; the next message starts
   a new conversation for the same participant. See [ADR-0016](../adr/0016-participant-based-conversation-resolution.md)
   and [participants](../concepts/participants.md).
3. Otherwise, a new conversation without participant, with `metadata: {"source": "inbound_webhook"}`. Every such
   message starts its own conversation.

### Provider payloads

`whatsapp_meta` accepts Cloud API webhook bodies (`{"object": "whatsapp_business_account", "entry": [...]}`) and
`whatsapp_infobip` accepts Infobip's `{"results": [...]}` bodies. One request can carry several messages, and for
Meta also `statuses` alongside them. The sender is the phone number, the provider message id (`wamid...` for Meta,
`messageId` for Infobip) becomes the activity's idempotency key, and media arrive as attachment stubs. Field mapping
is documented per adapter in [WhatsApp](../channels/whatsapp.md). A body the adapter cannot parse at all returns
`400` with a message such as `{"error": "unable to parse WhatsApp Meta webhook payload"}`. A well-formed body
without messages (for example a statuses-only Meta webhook) is acknowledged with `200`.

### Response

```json
{
  "status": "accepted",
  "activity_id": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
  "activity_ids": ["a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"],
  "duplicates": 0,
  "rejected": 0,
  "receipts_processed": 0
}
```

| Field | Meaning |
| --- | --- |
| `activity_id` | First accepted activity (created or duplicate), `null` if none |
| `activity_ids` | All accepted activities, in message order. Duplicates report the id of the existing activity. |
| `duplicates` | Messages already known by their idempotency key |
| `rejected` | Messages rejected permanently (invalid activity or participant) and skipped |
| `receipts_processed` | Status updates in the same request that matched a known delivery |

Status codes:

| Status | When |
| --- | --- |
| `201 Created` | Generic channel types, at least one new activity created |
| `200 OK` | Generic channel types with only duplicates; `whatsapp_meta` and `whatsapp_infobip` always, once the request has been handled (also when messages were rejected), because those providers retry any non-200 response |
| `200 OK` with only `status` and `receipts_processed` | Status-only request |
| `422` | Generic channel types where every message was rejected: the first rejection's changeset errors, for example `{"errors": {"type": ["is invalid"]}}`; or the empty-message error above |
| `503` | A transient failure (delivery jobs could not be enqueued): `{"error": "Activity could not be accepted, please retry"}`. The provider should re-deliver. |

## Status updates

Delivery receipts update the status of an outbound [delivery](../concepts/deliveries.md). They arrive either at
`POST /status` or, for providers that use one URL for everything (WhatsApp), mixed into `POST /inbound`. Status
updates in an `/inbound` request are applied best-effort before its messages.

Generic payload (`webhook` channels, and the shape for `/status` on every generic-signed channel type):

| Field | Required | Notes |
| --- | --- | --- |
| `status` | yes | `sent`, `delivered`, `read` or `failed` |
| `provider_message_id` | one of the two | The id the provider returned when Converger sent the message, scoped to this channel |
| `delivery_id` | one of the two | Converger's delivery id, as sent in the outbound `x-converger-delivery-id` header |
| `timestamp` | no | ISO 8601 or Unix seconds; sets `sent_at` / `delivered_at` / `read_at` |
| `error` | no | Stored as the delivery's `last_error` for `failed` |

```bash
BODY='{"delivery_id":"6b1d...","status":"read","timestamp":"2026-10-09T12:07:00Z"}'
T=$(date +%s)
SIG=$(printf '%s.%s' "$T" "$BODY" | openssl dgst -sha256 -hmac "$SECRET" -hex | sed 's/^.* //')

curl -s -X POST "$CONVERGER/api/v1/channels/$CHANNEL_ID/status" \
  -H "content-type: application/json" \
  -H "x-converger-signature: t=$T,v1=$SIG" \
  --data-raw "$BODY"
```

`200 OK`:

```json
{ "status": "accepted", "receipts_processed": 1 }
```

Statuses only move forward (`pending`, `sent`, `delivered`, `read`): a `delivered` that arrives after `read` is
ignored, and `failed` is applied unless the delivery was already `read`. A receipt for an unknown message is not an
error; it is just not counted, so `receipts_processed` can be `0` with a `200`. Ignored stale receipts for a known
delivery are counted as processed.

:::warning
Send `/status` only bodies the channel's adapter recognises as status updates. A body that is not one (for a generic
channel: missing `status` or both identifiers) is currently not handled gracefully and results in a server error.
:::

## Idempotency and batches

Providers retry webhooks (Meta for days) and batch several messages into one request. Converger therefore treats a
batch as a sequence of independent, idempotent messages rather than as one transaction
([ADR-0015](../adr/0015-per-message-idempotent-inbound-batches.md)):

- Each message is processed in order, in its own transaction (activity plus its delivery jobs,
  [ADR-0001](../adr/0001-transactional-outbox-with-oban.md)).
- Before anything else, a message's idempotency key is looked up across all conversations of the channel. A known
  key counts as handled (`duplicates`) and reports the existing activity id, even if that conversation has been closed
  since.
- A message rejected permanently (invalid activity or participant) is logged and skipped (`rejected`); retrying it
  would never succeed.
- A transient failure stops processing and returns an error, so the provider re-delivers the whole batch. Messages
  committed before the failure are recognised as duplicates on re-delivery and the remaining ones are created, in
  order.

Idempotency keys:

| Channel type | Key |
| --- | --- |
| `whatsapp_meta` | The message `id` (`wamid...`) |
| `whatsapp_infobip` | `messageId` |
| `webhook` | The optional `idempotency_key` body field. Without it, a re-delivered request creates a second activity. |

Re-sending the same generic message with the same `idempotency_key` returns `200` (instead of `201`) with
`duplicates: 1` and the original `activity_id`.

## Errors

| Status | Body | Cause |
| --- | --- | --- |
| `400` | `{"errors": {"detail": "Bad Request"}}` | `channel_id` is not a UUID |
| `400` | `{"error": "Channel is inactive"}` | Channel disabled |
| `400` | `{"error": "Channel does not accept inbound messages"}` | Channel mode is `outbound` |
| `400` | `{"error": "<adapter message>"}` | Payload not parseable by the channel type, or a channel type without inbound support |
| `401` | `{"errors": {"detail": "Unauthorized"}}` | Signature invalid, or missing / legacy on a `require_signature` channel |
| `403` | `Verification failed` (text) | Meta handshake with a wrong `hub.verify_token` |
| `404` | `{"errors": {"detail": "Not Found"}}` | Unknown channel, or unknown `conversation_id` |
| `409` | `{"error": "conversation_closed", "detail": "Conversation is closed"}` | Explicit `conversation_id` of a closed conversation |
| `422` | `{"error": "Inbound message has no text and no attachments"}` or changeset errors | Invalid generic message |
| `429` | `{"error": "Too many requests. Please try again later."}` + `retry-after` | Channel's `inbound` limit exceeded |
| `503` | `{"error": "Activity could not be accepted, please retry"}` | Transient failure; re-deliver |

## Related

- [Channels overview](../channels/overview.md), [WhatsApp](../channels/whatsapp.md)
- [Outbound webhooks](../webhooks.md) (same signature format)
- [ADR-0009](../adr/0009-inbound-signature-scheme-and-per-channel-enforcement.md), [ADR-0015](../adr/0015-per-message-idempotent-inbound-batches.md), [ADR-0016](../adr/0016-participant-based-conversation-resolution.md)
- [REST API overview](overview.md)
