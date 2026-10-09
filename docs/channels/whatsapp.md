---
title: WhatsApp (Meta Cloud API and Infobip)
description: Configuration, message mapping, webhook verification, delivery receipts and error handling of the whatsapp_meta and whatsapp_infobip channel adapters.
sidebar_position: 2
---

Converger ships two WhatsApp adapters:

- `whatsapp_meta`: Meta's WhatsApp Cloud API (Graph API), [`lib/converger/channels/adapters/whatsapp_meta.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/whatsapp_meta.ex).
- `whatsapp_infobip`: WhatsApp through Infobip, [`lib/converger/channels/adapters/whatsapp_infobip.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/whatsapp_infobip.ex).

Both support the modes `inbound`, `outbound` and `duplex`, send **text** messages, parse every message and receipt of a batched webhook, and attach inbound messages to the sender's conversation through participants. The shared inbound endpoints, signature policy and batch semantics are described in [Channels and adapters](overview.md#inbound-endpoints); this page covers what is specific to WhatsApp.

## Configuration

The `config` map is encrypted at rest (see [ADR-0012](../adr/0012-secrets-at-rest-and-audit-redaction.md)). Keys named `access_token`, `api_key`, `verify_token` and `app_secret` are also redacted in audit logs and masked in the admin UI.

### `whatsapp_meta`

| Key | Required | Description |
| --- | --- | --- |
| `phone_number_id` | yes | The WhatsApp Business phone number id; outbound messages are posted to `/{phone_number_id}/messages`. |
| `access_token` | yes | Graph API access token, sent as `Authorization: Bearer <token>`. |
| `verify_token` | yes | Any string you choose; Meta sends it back in the webhook verification `GET`. |
| `app_secret` | when `require_signature` is `true` (the default) | The Meta app secret; used to verify `X-Hub-Signature-256`. Without it the channel changeset fails with `whatsapp_meta config missing: app_secret (required when require_signature is true)`. |
| `graph_api_version` | no | Overrides the Graph API version for this channel, for example `v26.0`. |
| `conversation_idle_timeout_seconds` | no | Positive integer. After this much inactivity an inbound message starts a new conversation instead of joining the participant's active one. |

A missing required key fails validation with `whatsapp_meta config missing: phone_number_id, access_token` (listing every missing key). Values must be non-empty strings.

Example:

```json
{
  "phone_number_id": "106540352242922",
  "access_token": "EAAG...",
  "verify_token": "a-long-random-string",
  "app_secret": "<meta app secret>"
}
```

### `whatsapp_infobip`

| Key | Required | Description |
| --- | --- | --- |
| `base_url` | yes | Your Infobip API base URL, for example `https://xxxxx.api.infobip.com` (no trailing slash; the adapter appends `/whatsapp/1/message/text`). |
| `api_key` | yes | Infobip API key, sent as `Authorization: App <api_key>`. |
| `sender` | yes | The WhatsApp sender number registered with Infobip, used as `from`. |
| `conversation_idle_timeout_seconds` | no | Same as for Meta. |

A missing key fails with `whatsapp_infobip config missing: ...`.

## Graph API version

The Meta adapter resolves the version per request, in this order:

1. the channel config key `graph_api_version`;
2. the application config:

   ```elixir
   config :converger, Converger.Channels.Adapters.WhatsAppMeta, graph_api_version: "v26.0"
   ```

3. the built-in default, `v26.0` (the latest version when it was set on 2026-07-29).

There is no environment variable for it; set it in a config file or per channel.

## Outbound messages

Activities reach the adapter only through the delivery pipeline ([ADR-0003](../adr/0003-pipeline-is-the-only-delivery-path.md)), when the WhatsApp channel is the conversation's channel (mode `outbound` or `duplex`) or the target of a routing rule. Lifecycle events (conversation closed or reopened) are never sent to WhatsApp.

### Recipient

The recipient phone number is taken from, in order:

1. `activity.metadata["recipient_phone"]`;
2. `activity.metadata["to"]`;
3. the `external_id` of the conversation's participant, if that participant belongs to this channel (`Converger.Participants.recipient_for/2`).

So a bot replying in a conversation that was started by an inbound WhatsApp message needs no extra metadata: the reply goes back to the number that wrote in. Without any recipient the delivery fails **permanently** (`no recipient: set activity metadata 'recipient_phone' or 'to', or reply in a conversation with a participant on this channel`) and is dead-lettered after one attempt.

### Meta request

```http
POST https://graph.facebook.com/v26.0/106540352242922/messages
authorization: Bearer <access_token>
content-type: application/json
```

```json
{
  "messaging_product": "whatsapp",
  "recipient_type": "individual",
  "to": "16505551234",
  "type": "text",
  "text": { "body": "Yes, it also comes in blue." }
}
```

A `200` response is a success. The adapter returns `{:ok, %{whatsapp_message_id: messages[0].id}}`, and the `wamid` is stored as the delivery's `provider_message_id`, which later receipts are matched against.

### Infobip request

```http
POST https://xxxxx.api.infobip.com/whatsapp/1/message/text
authorization: App <api_key>
content-type: application/json
```

```json
{
  "from": "447860099299",
  "to": "5511999999999",
  "content": { "text": "Your order has shipped." }
}
```

Any `2xx` is a success. `messages[0].messageId` from the response is stored as the delivery's `provider_message_id` (returned as `infobip_message_id`).

### What is sent

Only `activity.text` is sent, as a text message. Attachments, templates (HSM), interactive messages, locations and contacts are not sent yet: Planned ([#37](https://github.com/AimTune/converger/issues/37)). An activity with attachments and no text is still sent as a text message, with a `null` body, and its attachments are lost.

### Errors and retries

Both adapters return `Converger.Channels.DeliveryError` ([ADR-0019](../adr/0019-per-channel-retry-policy-delivery-error-and-lifeline.md)):

| Outcome | Classification | Effect |
| --- | --- | --- |
| No recipient | permanent | dead-lettered after one attempt |
| `400`, `401`, `403`, `404` and every other `4xx` except the ones below | permanent | dead-lettered after one attempt; `last_error` is `WhatsApp API returned 400: ...` or `Infobip API returned 400: ...` |
| `408`, `425`, `429`, any `5xx` | retryable | retried with the channel's backoff; a `Retry-After` header (seconds or HTTP date) sets the delay of the next attempt |
| Transport error (timeout, connection refused, DNS) | retryable | retried |

The request timeout is the channel's retry policy `timeout_ms` (global default 15 000 ms; neither WhatsApp adapter defines its own default). Tests inject Req options, for example `plug: {Req.Test, MyTest}`, through `config :converger, :whatsapp_req_options`.

Note that a non-`200` success code from Meta (for example `201`) is not treated as success by the Meta adapter.

## Inbound webhooks

Point the provider at:

```text
https://<your-host>/api/v1/channels/<channel id>/inbound
```

The channel must be `active` and in mode `inbound` or `duplex` to accept messages. Receipts are accepted in every mode, so an `outbound` channel can still receive delivery reports. When a request on an outbound-only channel carries both receipts and messages, the receipts are applied and the messages are dropped with a warning.

WhatsApp channels always get `200` once a request has been handled, including when individual messages were rejected permanently. Meta retries non-`200` responses for days, and retrying cannot fix a rejected message.

### Meta webhook verification (`GET`)

When you register the callback URL in the Meta app dashboard, Meta sends:

```http
GET /api/v1/channels/<channel id>/inbound?hub.mode=subscribe&hub.verify_token=a-long-random-string&hub.challenge=1158201444
```

If `hub.verify_token` equals the channel's `verify_token` (constant-time comparison), Converger answers `200` with the `hub.challenge` value as the body. Otherwise it answers `403 Verification failed`. `hub.mode` is not checked. For other channel types the same `GET` returns `200 ok`; an unknown channel returns `404`, an inactive one `400`.

### Inbound signature: `X-Hub-Signature-256`

The Meta adapter implements `verify_inbound_signature/3`. Meta signs every webhook `POST` with:

```http
X-Hub-Signature-256: sha256=<hex HMAC-SHA256 of the raw body, keyed with the app secret>
```

Converger recomputes the HMAC over the exact raw request bytes with `config["app_secret"]` and compares in constant time (the header value is lowercased first).

| Situation | Result |
| --- | --- |
| Header valid | accepted |
| Header present but wrong (other secret, tampered body) | `401`, always |
| Header missing, or no `app_secret` configured | treated as "missing": `401` when `require_signature` is `true`, accepted with a deprecation warning when it is `false` |

The generic `x-converger-signature` header is **not** accepted in place of Meta's header on a `whatsapp_meta` channel. Because the default `require_signature: true` cannot work without the app secret, the channel changeset requires `app_secret` in that case. See [ADR-0009](../adr/0009-inbound-signature-scheme-and-per-channel-enforcement.md).

### Infobip and signatures

:::warning
The Infobip adapter does not implement a provider-native signature check. Infobip channels use the generic `x-converger-signature` scheme (`t=<unix seconds>,v1=<hex HMAC-SHA256 of "<t>.<raw body>">`, keyed with the channel `secret`; see [Inbound signatures](overview.md#inbound-signatures)). Infobip itself does not send that header, so either put a relay in front of Converger that signs forwarded requests with the channel secret, or create the channel with `require_signature: false`, which accepts unsigned requests with a deprecation warning and will stop working when unsigned requests are rejected in a future release.
:::

## Inbound message mapping

Both adapters return one parsed message per provider message, in payload order. Each message carries its provider id as `idempotency_key` and a `participant` with the sender's phone number as `external_id`.

### Meta Cloud API payload

A real Cloud API webhook (the fixture used in `test/converger_web/controllers/inbound_signature_test.exs`):

```json
{
  "object": "whatsapp_business_account",
  "entry": [
    {
      "id": "102290129340398",
      "changes": [
        {
          "value": {
            "messaging_product": "whatsapp",
            "metadata": {
              "display_phone_number": "15550783881",
              "phone_number_id": "106540352242922"
            },
            "contacts": [
              { "profile": { "name": "Sheena Nelson" }, "wa_id": "16505551234" }
            ],
            "messages": [
              {
                "from": "16505551234",
                "id": "wamid.HBgLMTY1MDM4Nzk0MzkVAgASGBQzQTRBNjU5OUFFRTAzODEwMTQ0RgA=",
                "timestamp": "1749416383",
                "type": "text",
                "text": { "body": "Does it come in another color?" }
              }
            ]
          },
          "field": "messages"
        }
      ]
    }
  ]
}
```

It is parsed into:

```json
{
  "sender": "16505551234",
  "text": "Does it come in another color?",
  "type": "message",
  "attachments": [],
  "idempotency_key": "wamid.HBgLMTY1MDM4Nzk0MzkVAgASGBQzQTRBNjU5OUFFRTAzODEwMTQ0RgA=",
  "metadata": {
    "whatsapp_message_id": "wamid.HBgLMTY1MDM4Nzk0MzkVAgASGBQzQTRBNjU5OUFFRTAzODEwMTQ0RgA=",
    "whatsapp_type": "text",
    "timestamp": "1749416383",
    "phone_number_id": "106540352242922",
    "profile_name": "Sheena Nelson"
  },
  "participant": { "external_id": "16505551234", "display_name": "Sheena Nelson" }
}
```

Every `entry[]`, every `changes[]` and every `value.messages[]` is parsed; items that are not objects are skipped. `profile_name` comes from the `contacts[]` entry whose `wa_id` equals `from` (or the only contact, if there is exactly one). Keys with `nil` values are dropped from `metadata`. Additional metadata keys: `reply_to` (`context.id` of a reply) and `forwarded` (`context.forwarded`).

| Meta `type` | Activity `type` | `text` | Attachments / extra metadata |
| --- | --- | --- | --- |
| `text` | `message` | `text.body` | none |
| `image`, `audio`, `video`, `document`, `sticker` | `message` | `caption` or `""` | one attachment stub: `contentType` (`mime_type`, default `application/octet-stream`), `name` (`filename`), `provider: "whatsapp_meta"`, `providerMediaId`, `sha256`, `voice`, `animated` |
| `location` | `message` | `name, address` | attachment `application/vnd.converger.location` with `content` `{latitude, longitude, name, address, url}` |
| `contacts` | `message` | contact names, comma separated | attachment `application/vnd.converger.contacts` with `content` `[{name, phones}]` |
| `interactive` (`button_reply`, `list_reply`) | `message` | reply `title` | `metadata.interactive_reply` `{type, id, title, description}` |
| `button` (template quick reply) | `message` | `button.text` | `metadata.interactive_reply` `{type: "button", payload}` |
| `reaction` | `event` | the emoji | `metadata.reaction` `{message_id, emoji}` |
| `system` | `event` | `system.body` | none |
| anything else (`unsupported`, `order`, future types) | `message` | `text.body` or `""` | none; read `metadata.whatsapp_type` |

Unknown types are kept as activities rather than dropped, so no message is silently lost. Media attachments are **stubs**: they carry the provider media id but no downloadable `contentUrl`. Downloading inbound media into Converger storage is Planned ([#37](https://github.com/AimTune/converger/issues/37)).

An image message, for example:

```json
{
  "from": "16505551234",
  "id": "wamid.image-1",
  "timestamp": "1749416383",
  "type": "image",
  "image": { "mime_type": "image/jpeg", "sha256": "abc", "id": "media-42", "caption": "look" }
}
```

becomes an activity with `text: "look"` and:

```json
[
  {
    "contentType": "image/jpeg",
    "provider": "whatsapp_meta",
    "providerMediaId": "media-42",
    "sha256": "abc"
  }
]
```

A body without an `entry` list is not a Cloud API webhook and returns `400` (`unable to parse WhatsApp Meta webhook payload`). A well-formed payload with no messages and no statuses (for example an `account_update` field) is acknowledged with `200`.

### Infobip payload

Infobip batches inbound messages in `results`:

```json
{
  "results": [
    {
      "from": "5511999999999",
      "to": "447860099299",
      "integrationType": "WHATSAPP",
      "receivedAt": "2026-02-27T12:00:00.000+0000",
      "messageId": "ib-1",
      "message": { "type": "TEXT", "text": "one" },
      "contact": { "name": "Frank" }
    }
  ],
  "messageCount": 1,
  "pendingMessageCount": 0
}
```

Parsed into `sender: "5511999999999"`, `text: "one"`, `idempotency_key: "ib-1"`, a participant `{external_id: "5511999999999", display_name: "Frank"}` and `metadata` with `infobip_message_id`, `whatsapp_type` (lowercased Infobip type), `received_at`, `profile_name` and `reply_to` (`message.context.id`).

| Infobip `message.type` | Activity `type` | `text` | Attachments / extra metadata |
| --- | --- | --- | --- |
| `TEXT` (default) | `message` | `message.text` | none |
| `IMAGE`, `VIDEO`, `AUDIO`, `VOICE`, `DOCUMENT`, `STICKER` | `message` | `caption` or `""` | attachment stub: `contentType` (`mimeType`, or `image/*`, `video/*`, `audio/*`, `application/octet-stream`, `image/webp`), `name`, `provider: "whatsapp_infobip"`, `providerMediaId`, `providerMediaUrl` (`message.url`) |
| `LOCATION` | `message` | `name, address` | attachment `application/vnd.converger.location` |
| `INTERACTIVE_BUTTON_REPLY`, `INTERACTIVE_LIST_REPLY`, `BUTTON` | `message` | `title` or `text` | `metadata.interactive_reply` `{type, id, title, description, payload}` |
| anything else (`CONTACT`, `ORDER`, `UNSUPPORTED`, future types) | `message` | `message.text` or `""` | none |

Results that are delivery reports (see below) are skipped by `parse_inbound/2`. A body without a `results` list returns `400` (`unable to parse Infobip webhook payload`).

## Delivery receipts

Receipts update the delivery whose `provider_message_id` matches, scoped to the channel. Progression is monotonic: a late `delivered` after `read` is ignored, `failed` is applied unless the delivery is already `read`. Receipts for unknown message ids are skipped (`receipts_processed` does not count them). Updated deliveries are broadcast on PubSub.

### Meta statuses

Meta sends receipts to the same `/inbound` URL, in `value.statuses[]`, possibly mixed with messages in one request:

```json
{
  "entry": [
    {
      "changes": [
        {
          "value": {
            "statuses": [
              {
                "id": "wamid.err",
                "status": "failed",
                "timestamp": "1709035200",
                "recipient_id": "5511999999999",
                "errors": [{ "title": "Message expired", "code": 131026 }]
              }
            ]
          }
        }
      ]
    }
  ]
}
```

| Meta `status` | Converger status |
| --- | --- |
| `sent` | `sent` |
| `delivered` | `delivered` |
| `read` | `read` |
| `failed` | `failed`; `errors[0].title` becomes `last_error` |
| anything else | `sent` |

`timestamp` (Unix seconds) sets `sent_at`, `delivered_at` or `read_at`.

### Infobip delivery reports

A result is a delivery report when its `status` is an object with a `groupName`:

```json
{
  "results": [
    {
      "messageId": "msg-err",
      "to": "5511999999999",
      "status": { "groupName": "REJECTED" },
      "error": { "description": "Invalid number" },
      "doneAt": "2026-02-27T12:00:00Z"
    }
  ]
}
```

| Infobip `status.groupName` | Converger status |
| --- | --- |
| `PENDING` | `sent` |
| `DELIVERED` | `delivered` |
| `SEEN` | `read` |
| `REJECTED`, `UNDELIVERABLE` | `failed`; `error.description` becomes `last_error` |
| anything else | `sent` |

The timestamp is `doneAt`, or `sentAt` when `doneAt` is absent. Reports can be posted to `/inbound` or to `/api/v1/channels/<channel id>/status`.

## Batches and idempotency

Before [#15](https://github.com/AimTune/converger/issues/15) both adapters parsed only the first message of a webhook and silently dropped the rest. Today every message and every status of a batch is processed ([ADR-0015](../adr/0015-per-message-idempotent-inbound-batches.md)):

- Each message is created in its own transaction, in payload order.
- The idempotency key is the provider message id: the `wamid` (`messages[].id`) for Meta, `messageId` for Infobip. Before creating an activity, the controller looks the key up across all conversations of the channel; a hit counts as a duplicate and returns the existing activity id.
- A re-delivered webhook therefore creates no new activities (`"duplicates": 3` for a three-message batch sent twice), and a batch that failed half way is completed on re-delivery: the first messages are duplicates, the rest are created.
- A permanently invalid message (for example text over the 65 536 byte limit) is skipped and counted in `rejected`; the request still returns `200`.
- A transient failure stops the batch with an error status, so the provider re-delivers.

Response for a three-message Meta batch:

```json
{
  "status": "accepted",
  "activity_id": "5d1f...",
  "activity_ids": ["5d1f...", "a2c9...", "e07b..."],
  "duplicates": 0,
  "rejected": 0,
  "receipts_processed": 0
}
```

## Participants and conversations

WhatsApp never sends a Converger `conversation_id`. Since [#16](https://github.com/AimTune/converger/issues/16) ([ADR-0016](../adr/0016-participant-based-conversation-resolution.md)) inbound messages are attached through participants:

1. The participant `(channel_id, external_id = sender phone number)` is upserted, with `display_name` from the WhatsApp profile name.
2. The participant's most recent `active` conversation on the channel is reused, unless it has been idle longer than `conversation_idle_timeout_seconds`.
3. Otherwise a new conversation is created for the participant.

Closed or expired conversations never receive new inbound activities; a new conversation is started instead. Resolution is concurrency-safe: the upsert locks the participant row until the transaction commits, so concurrent messages from the same number share one conversation.

Replies use the same link in the other direction: the outbound recipient defaults to the participant's `external_id`. An inbound message from the participant is never delivered back to the participant's own channel, so a duplex WhatsApp channel does not echo the user's message to them.

## Testing locally

```bash
APP_SECRET='<meta app secret>'
CHANNEL_ID='<channel id>'
BODY='{"object":"whatsapp_business_account","entry":[{"id":"1","changes":[{"field":"messages","value":{"messaging_product":"whatsapp","metadata":{"phone_number_id":"106540352242922"},"contacts":[{"profile":{"name":"Sheena"},"wa_id":"16505551234"}],"messages":[{"from":"16505551234","id":"wamid.local-1","timestamp":"1749416383","type":"text","text":{"body":"hello"}}]}}]}]}'

SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$APP_SECRET" | sed 's/^.*= //')

curl -sS "http://localhost:4000/api/v1/channels/$CHANNEL_ID/inbound" \
  -H 'content-type: application/json' \
  -H "x-hub-signature-256: sha256=$SIG" \
  --data-raw "$BODY"
```

Sending the same request twice returns `"duplicates": 1` the second time.

## Typing indicator and read receipts (`whatsapp_meta`)

When a WebSocket participant of a conversation types or reads ([WebSocket](../websocket.md#5a-receipts-typing-and-presence)), the `whatsapp_meta` adapter tells the WhatsApp user through the Cloud API (`send_typing/2` and `send_read_receipt/2`, see [ADR-0027](../adr/0027-transient-conversation-signals.md)). Both calls are `POST /<graph_api_version>/<phone_number_id>/messages` with the channel's `access_token`, and both need the `wamid` of a message the WhatsApp user sent (an inbound activity's `idempotency_key`); without one nothing is sent.

| Signal | Request body | Message used |
| --- | --- | --- |
| `typing` with `isTyping: true` | `{"messaging_product": "whatsapp", "status": "read", "message_id": "<wamid>", "typing_indicator": {"type": "text"}}` | the user's latest inbound message |
| `read {watermark}` | `{"messaging_product": "whatsapp", "status": "read", "message_id": "<wamid>"}` | the user's latest inbound message with `seq` up to the watermark; WhatsApp marks it and every earlier message read |

WhatsApp shows the indicator for up to 25 seconds or until the next message is sent, so `isTyping: false` sends nothing and a participant that keeps typing refreshes it at most every 20 seconds. The typing indicator also marks that message as read (Cloud API behaviour). These calls are best effort: they are not retried, and a failure is logged as `Forwarding a conversation signal failed`. `whatsapp_infobip` does not support typing or read receipts.

## Planned

- Outbound media, templates (HSM), interactive messages, location and contacts; inbound media download; 24-hour window errors: Planned ([#37](https://github.com/AimTune/converger/issues/37)).
- Adapter-declared capabilities and config schemas: Planned ([#36](https://github.com/AimTune/converger/issues/36)).
