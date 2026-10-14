---
title: WhatsApp (Meta Cloud API and Infobip)
description: Configuration, message mapping, webhook verification, delivery receipts and error handling of the whatsapp_meta and whatsapp_infobip channel adapters.
sidebar_position: 2
---

Converger ships two WhatsApp adapters:

- `whatsapp_meta`: Meta's WhatsApp Cloud API (Graph API), [`lib/converger/channels/adapters/whatsapp_meta.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/whatsapp_meta.ex).
- `whatsapp_infobip`: WhatsApp through Infobip, [`lib/converger/channels/adapters/whatsapp_infobip.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/whatsapp_infobip.ex).

Both support the modes `inbound`, `outbound` and `duplex`; send text, media (image, video, audio, document, sticker), template (HSM), interactive (reply buttons, lists), location and contacts messages; download inbound media into Converger storage; parse every message and receipt of a batched webhook; and attach inbound messages to the sender's conversation through participants. The shared inbound endpoints, signature policy and batch semantics are described in [Channels and adapters](overview.md#inbound-endpoints); this page covers what is specific to WhatsApp.

## Configuration

The `config` map is encrypted at rest (see [ADR-0012](../adr/0012-secrets-at-rest-and-audit-redaction.md)). Keys named `access_token`, `api_key`, `verify_token` and `app_secret` are also redacted in audit logs and masked in the admin UI. The keys below are the adapters' `config_schema/0`, which validates the config and generates the admin form ([ADR-0038](../adr/0038-adapter-behaviour-v2-and-config-driven-registry.md)).

### `whatsapp_meta`

| Key | Required | Description |
| --- | --- | --- |
| `phone_number_id` | yes | The WhatsApp Business phone number id; outbound messages are posted to `/{phone_number_id}/messages`. |
| `access_token` | yes | Graph API access token, sent as `Authorization: Bearer <token>`. |
| `verify_token` | yes | Any string you choose; Meta sends it back in the webhook verification `GET`. |
| `app_secret` | when `require_signature` is `true` (the default) | The Meta app secret; used to verify `X-Hub-Signature-256`. Without it the channel changeset fails with `whatsapp_meta config missing: app_secret (required when require_signature is true)`. |
| `graph_api_version` | no | Overrides the Graph API version for this channel, for example `v26.0`. |
| `waba_id` | no | The WhatsApp Business Account id. Needed only to list templates with [`GET /api/v1/channels/:id/templates`](../api/tenant-api.md#channel-message-templates). |
| `download_media` | no | `true` (default) or `false`. With `false`, inbound media stays a stub with the provider media id and is not downloaded. See [inbound media download](#inbound-media-download). |
| `conversation_idle_timeout_seconds` | no | Positive integer. After this much inactivity an inbound message starts a new conversation instead of joining the participant's active one. |
| `unsupported_activities` | no | `downgrade` (default) or `skip`: what to do with activity types WhatsApp cannot render natively (reactions, edits, deletes, events). See [What is sent](#what-is-sent). |

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

### Health probe (`whatsapp_meta`)

Every five minutes, a `whatsapp_meta` channel without deliveries in the last hour is probed with `GET https://graph.facebook.com/<version>/<phone_number_id>?fields=id` and its access token. A `200` stores `healthy`; anything else stores `degraded`, so an expired or revoked token shows up on the dashboard (and in a tenant health alert) before the next message fails. See [health probes](overview.md#health-probes).

### `whatsapp_infobip`

| Key | Required | Description |
| --- | --- | --- |
| `base_url` | yes | Your Infobip API base URL, for example `https://xxxxx.api.infobip.com` (no trailing slash; the adapter appends paths such as `/whatsapp/1/message/text`). |
| `api_key` | yes | Infobip API key, sent as `Authorization: App <api_key>`. |
| `sender` | yes | The WhatsApp sender number registered with Infobip, used as `from`. |
| `download_media` | no | Same as for Meta. |
| `conversation_idle_timeout_seconds` | no | Same as for Meta. |
| `unsupported_activities` | no | Same as for Meta. |

A missing key fails with `whatsapp_infobip config missing: ...`; a `base_url` that is not an `http`/`https` URL fails with `whatsapp_infobip config 'base_url' must be a valid HTTP/HTTPS URL`, and one the SSRF guard blocks with `whatsapp_infobip config base_url is not allowed: ...`.

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

A `200` response is a success. The `wamid` (`messages[0].id`) is stored as the delivery's `provider_message_id`, which later receipts are matched against; the delivery metadata also gets `whatsapp_message_id` and `whatsapp_message_ids` (every message the activity became, see [several messages per activity](#several-messages-per-activity)).

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

Any `2xx` is a success. The response's `messageId` (or `messages[0].messageId` for templates) is stored as the delivery's `provider_message_id`; the delivery metadata also gets `infobip_message_id` and `infobip_message_ids`.

### What is sent

`message` activities are sent natively (`capabilities/0` of both adapters has `:media`, `:templates` and `activity_types: ["message"]`). `Converger.Channels.WhatsApp.Outbound` plans the WhatsApp messages an activity becomes, and each adapter renders them in its provider's request shape ([ADR-0039](../adr/0039-whatsapp-rich-outbound-and-inbound-media-download.md)):

1. If `metadata.template` is set, the activity is one [template message](#templates-hsm); its `text` and `attachments` are ignored.
2. Otherwise each attachment, in order, becomes one message:

   | Attachment `contentType` | WhatsApp message |
   | --- | --- |
   | `application/vnd.converger.card.buttons` | [interactive reply buttons](#interactive-messages) |
   | `application/vnd.converger.card.list` | [interactive list](#interactive-messages) |
   | `application/vnd.converger.location` | location, from `content` `{latitude, longitude, name?, address?}` |
   | `application/vnd.converger.contacts` | contacts, from `content` `[{name, phones: ["+44..."]}]` |
   | `image/*`, `video/*`, `audio/*`, anything else with a source | [media](#media): image, video, audio or document |
   | other `application/vnd.converger.card.*` types | not sent (the text still is) |
   | an attachment without `contentUrl` or provider media id | not sent |

3. The activity's `text` becomes the caption of the first image, video or document, or the body of the first interactive message. If nothing takes it (no attachments, or only audio, stickers, locations or contacts), it is sent first as a text message.

An activity that ends up with nothing to send (no text and no sendable attachment) fails permanently with `nothing to send: the activity has no text and no sendable attachments`.

Other activity types follow the channel's `unsupported_activities`: with `downgrade` (default) a `messageReaction` is sent as `"<sender> reacted with <emoji>"`, a `messageUpdate` as `"(edited) <text>"`, a `messageDelete` as `"<sender> deleted a message"` and an `event` as its text; `typing`, removed reactions and events without text are not sent. With `skip` none of them are. Native outbound reactions and edits are not implemented.

### Media

The media kind comes from the attachment's `contentType` (`image/*` → image, `video/*` → video, `audio/*` → audio, anything else → document). Set `channelData.whatsappType` to `"sticker"` (or any other kind) to override it, for example for a WebP sticker. A document also gets its `name` as filename.

Where the file comes from:

| Attachment | `whatsapp_meta` | `whatsapp_infobip` |
| --- | --- | --- |
| `contentUrl` is a Converger upload (`/api/v1/converger/attachments/:id`, absolute on this server or a path) | read from storage and uploaded with `POST /<version>/<phone_number_id>/media` (multipart), then sent by media `id` | sent with `mediaUrl` set to a signed storage or CDN URL. With the local-disk storage backend there is no URL Infobip can reach: the delivery fails permanently (`Infobip fetches media by URL, and attachment ... has no public URL`); use a cloud backend or a CDN ([storage](../storage.md)) |
| `channelData.providerMediaId` with `channelData.provider` equal to the channel type (an inbound media stub of the same provider) | sent by media `id` | sent with `channelData.providerMediaUrl` |
| any other `http`/`https` `contentUrl` | sent as `link`; WhatsApp fetches it | sent as `mediaUrl` |

The Converger upload must belong to the channel's tenant; otherwise the delivery fails permanently (`attachment <id> not found`), so an activity cannot make Converger send another tenant's file. A failed Media API upload is classified like a message send (`4xx` permanent, `429`/`5xx` retried).

An image uploaded to Converger and sent to Meta, as two requests:

```http
POST https://graph.facebook.com/v26.0/106540352242922/media
authorization: Bearer <access_token>
content-type: multipart/form-data; boundary=...

messaging_product=whatsapp, type=image/png, file=<bytes of photo.png>
```

```json
{
  "messaging_product": "whatsapp",
  "recipient_type": "individual",
  "to": "16505551234",
  "type": "image",
  "image": { "id": "<media id from the upload>", "caption": "our new color" }
}
```

The same activity on Infobip is `POST <base_url>/whatsapp/1/message/image` with `{"from", "to", "content": {"mediaUrl": "<signed URL>", "caption": "our new color"}}`; the other kinds use `/whatsapp/1/message/video`, `/audio`, `/document` (with `filename`) and `/sticker`.

### Templates (HSM)

Outside the 24-hour customer-service window WhatsApp only accepts template messages. Send one by putting the template in the activity metadata:

```json
{
  "type": "message",
  "text": "Your order 42 has shipped",
  "metadata": {
    "template": {
      "name": "order_update",
      "language": "en_US",
      "components": [
        { "type": "body", "parameters": [{ "type": "text", "text": "42" }] }
      ]
    }
  }
}
```

| Field | Rule |
| --- | --- |
| `name` | Required, the template name as approved by WhatsApp. |
| `language` | Required, a language code (`"en_US"`) or `{"code": "en_US"}`. |
| `components` | Optional list, in the [Cloud API template components](https://developers.facebook.com/docs/whatsapp/cloud-api/reference/messages#template-object) shape. |
| `templateData` | Infobip only, optional: sent as Infobip's `templateData` as is (header media, buttons). Without it the body placeholders are taken from the `text` of the `body` component's parameters, in order. |

The `text` is not sent to WhatsApp; it is what Converger stores and shows to other channels, so set it to the rendered message. An invalid template (`name` or `language` missing, `components` not a list) fails permanently.

- Meta: `{"type": "template", "template": {"name", "language": {"code"}, "components"}}` to `/messages`.
- Infobip: `POST <base_url>/whatsapp/1/message/template` with `{"messages": [{"from", "to", "content": {"templateName", "templateData", "language"}}]}`.

List a channel's approved templates with [`GET /api/v1/channels/:id/templates`](../api/tenant-api.md#channel-message-templates).

### Interactive messages

Reply buttons and lists can also be sent as card attachments (the format before [typed messages](#typed-messages)):

```json
{
  "text": "Do you want to confirm the order?",
  "attachments": [
    {
      "contentType": "application/vnd.converger.card.buttons",
      "content": {
        "footer": "Reply within 24 hours",
        "buttons": [
          { "id": "confirm", "title": "Confirm" },
          { "id": "cancel", "title": "Cancel" }
        ]
      }
    }
  ]
}
```

```json
{
  "contentType": "application/vnd.converger.card.list",
  "content": {
    "body": "Pick a size",
    "button": "Sizes",
    "sections": [
      {
        "title": "In stock",
        "rows": [
          { "id": "s", "title": "Small", "description": "36-38" },
          { "id": "m", "title": "Medium" }
        ]
      }
    ]
  }
}
```

| Card | Rules |
| --- | --- |
| both | `body` defaults to the activity `text`, one of the two is required; `header` and `footer` are optional text |
| `buttons` | 1 to 3 buttons, each with a `title`; `id` defaults to the title |
| `list` | `button` (the label of the list button) is required; 1 to 10 rows in total, each with a `title`; `id` defaults to the title |

A card that breaks these rules fails the delivery permanently with the reason. The user's choice comes back as an inbound `message` whose `text` is the button or row title and whose `metadata.interactive_reply.id` is the `id` you set (see [inbound message mapping](#inbound-message-mapping)). Meta gets `{"type": "interactive", "interactive": {"type": "button" | "list", ...}}`; Infobip gets `/whatsapp/1/message/interactive/buttons` or `/interactive/list`.

### Typed messages

Both adapters render typed messages ([#68](https://github.com/AimTune/converger/issues/68), [messages.md section 5](../protocol/messages.md), [ADR-0064](../adr/0064-per-channel-rendering-of-typed-messages-and-normalised-answers.md)); they declare `message_types: text quick-reply buttons card carousel interrupt image file video audio location contact`. Send these instead of card attachments:

| Typed message | Sent as |
| --- | --- |
| `text` + `actions`, `quick-reply`, `buttons`, `interrupt` (without `tool` / `event`) | 1 to 3 answerable actions: reply buttons (titles cut to 20 characters); 4 to 10: a list message (button `Options`, row titles cut to 24 characters, the full label up to 72 as row description); more than 10: a text with a numbered list. The body is `data.text` (an interrupt's `payload.title`), else the stored text fallback, cut to 1024 characters; `url` actions are appended to it as `label: url` |
| `card` | its image as an image message (no caption), then its title, subtitle and text with its buttons as above; without buttons, the image with that text as caption (or a text message) |
| `carousel` | `data.text` as a text message, then each card as above (at most 10) |
| `image`, `file`, `video`, `audio` | an image, document, video or audio message (caption from `caption` / `text`); Converger uploads are sent through the Media API |
| `location`, `contact` | a location or contacts message |
| `genui` | one text message when the stream is done (its text chunks) |
| `tool_call` | nothing, unless the channel sets `show_tool_traces` |

Every button and row id is the answer key `a:<activity id>:<index>`. When the user taps one, the inbound message (`button_reply` or `list_reply`) becomes the normalised answer: `text` is the action's value (or its label), `metadata.action = {label, value, source: "button" | "list"}` and `reply_to_id` is the typed message ([messages.md section 6](../protocol/messages.md)); `metadata.interactive_reply` is kept as well. A reply such as `2` within 24 hours of an actionable message picks its second numbered action (`source: "numeric"`).

### Several messages per activity

WhatsApp carries one piece of content per message, so an activity with several attachments (or text that cannot be a caption) is sent as several messages, in order, within one delivery attempt. The first message's id is the delivery's `provider_message_id`, so its receipts update the delivery; the metadata lists every id. If a later message fails, the delivery fails and its retry sends the earlier messages again: the user may see them twice (at-least-once). Send one attachment per activity when that matters.

### 24-hour window

WhatsApp accepts free-form messages only within 24 hours of the user's last message. A free-form message after that fails with Cloud API error `131047`; the Meta adapter reports it as a **permanent** error (no retries) with the reason:

```text
outside_window: the customer has not messaged in the last 24 hours, so WhatsApp only accepts template messages; send an approved template in metadata.template (...)
```

The Cloud API usually accepts the request (`200`) and reports `131047` later in a `failed` status webhook; the same text then becomes the delivery's `last_error` (see [Meta statuses](#meta-statuses)). If it is returned synchronously, the delivery is dead-lettered at once. Infobip reports window violations in its own failed delivery reports; their `error.description` becomes `last_error`.

### Errors and retries

Both adapters return `Converger.Channels.DeliveryError` ([ADR-0019](../adr/0019-per-channel-retry-policy-delivery-error-and-lifeline.md)):

| Outcome | Classification | Effect |
| --- | --- | --- |
| No recipient | permanent | dead-lettered after one attempt |
| Invalid template or interactive card, nothing to send, unknown or foreign Converger attachment, Converger attachment without a public URL (Infobip) | permanent | dead-lettered after one attempt, with the reason as `last_error` |
| Cloud API error `131047` (outside the [24-hour window](#24-hour-window)) | permanent | dead-lettered after one attempt; `last_error` starts with `outside_window:` |
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

Every `entry[]`, every `changes[]` and every `value.messages[]` is parsed; items that are not objects are skipped. `profile_name` comes from the `contacts[]` entry whose `wa_id` equals `from` (or the only contact, if there is exactly one). Keys with `nil` values are dropped from `metadata`. Additional metadata keys: `reply_to` (`context.id` of a reply) and `forwarded` (`context.forwarded`). A reply's `context.id` is also resolved to the activity's `reply_to_id` when it names a message Converger knows in the same conversation (an inbound message by its `wamid`, or an outbound one by its delivery's `provider_message_id`).

| Meta `type` | Activity `type` | `text` | Attachments / extra metadata |
| --- | --- | --- | --- |
| `text` | `message` | `text.body` | none |
| `image`, `audio`, `video`, `document`, `sticker` | `message` | `caption` or `""` | one attachment stub: `contentType` (`mime_type`, default `application/octet-stream`), `name` (`filename`), and `channelData` `{provider: "whatsapp_meta", providerMediaId, sha256, voice, animated}` |
| `location` | `message` | `name, address` | attachment `application/vnd.converger.location` with `content` `{latitude, longitude, name, address, url}` |
| `contacts` | `message` | contact names, comma separated | attachment `application/vnd.converger.contacts` with `content` `[{name, phones}]` |
| `interactive` (`button_reply`, `list_reply`) | `message` | reply `title` | `metadata.interactive_reply` `{type, id, title, description}` |
| `button` (template quick reply) | `message` | `button.text` | `metadata.interactive_reply` `{type: "button", payload}` |
| `reaction` | `messageReaction` | the emoji (`null` when the user removed the reaction) | `reply_to_id` is the reacted-to activity (resolved from `reaction.message_id`); `metadata.reaction` `{message_id, emoji}`. When the reacted-to message is unknown to Converger the activity is an `event` instead, with the same metadata |
| `system` | `event` | `system.body` | none |
| anything else (`unsupported`, `order`, future types) | `message` | `text.body` or `""` | none; read `metadata.whatsapp_type` |

Unknown types are kept as activities rather than dropped, so no message is silently lost. The adapter parses media into a stub with the provider media id; before the activity is created the file is downloaded into Converger storage and the stub gets a `contentUrl` (see [inbound media download](#inbound-media-download)).

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

becomes an activity with `text: "look"` and, once the file is stored:

```json
[
  {
    "contentType": "image/jpeg",
    "contentUrl": "https://converger.example.com/api/v1/converger/attachments/7f1c2a9e-4b1d-4c3e-9f5a-1b2c3d4e5f60",
    "size": 48213,
    "channelData": {
      "provider": "whatsapp_meta",
      "providerMediaId": "media-42",
      "sha256": "abc"
    }
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
| `IMAGE`, `VIDEO`, `AUDIO`, `VOICE`, `DOCUMENT`, `STICKER` | `message` | `caption` or `""` | attachment stub: `contentType` (`mimeType`, or `image/*`, `video/*`, `audio/*`, `application/octet-stream`, `image/webp`), `name`, and `channelData` `{provider: "whatsapp_infobip", providerMediaId, providerMediaUrl}` (`providerMediaUrl` is `message.url`) |
| `LOCATION` | `message` | `name, address` | attachment `application/vnd.converger.location` |
| `INTERACTIVE_BUTTON_REPLY`, `INTERACTIVE_LIST_REPLY`, `BUTTON` | `message` | `title` or `text` | `metadata.interactive_reply` `{type, id, title, description, payload}` |
| anything else (`CONTACT`, `ORDER`, `UNSUPPORTED`, future types) | `message` | `message.text` or `""` | none |

Results that are delivery reports (see below) are skipped by `parse_inbound/2`. A body without a `results` list returns `400` (`unable to parse Infobip webhook payload`).

### Inbound media download

WhatsApp media ids are only usable with the channel's credentials, and Meta's download URLs expire after a few minutes. So before an inbound media message becomes an activity, `Converger.Inbound.Media` downloads each media stub with the adapter's `fetch_media/2` and stores it like a client upload (`Converger.Uploads.create_attachment/3`: size limit, sniffed MIME type, tenant allowlist; [storage](../storage.md)). The stored file belongs to the conversation and is linked to the activity; the attachment gets:

| Key | Value |
| --- | --- |
| `contentUrl` | `<public URL>/api/v1/converger/attachments/<id>`, served like any upload |
| `contentType` | the type sniffed from the bytes (for example `audio/ogg` for a voice note) |
| `size` | bytes |
| `name` | the WhatsApp `filename`, when it has one |
| `channelData` | kept as parsed (`provider`, `providerMediaId`, `providerMediaUrl`, ...) |

| Provider | Download |
| --- | --- |
| `whatsapp_meta` | `GET /<version>/<media id>` with the access token returns a short-lived URL and the file size; a file over the upload limit is not fetched; the URL is then fetched with the same token. |
| `whatsapp_infobip` | `GET` of the message `url` with `Authorization: App <api_key>`, **only** when the URL is `https` on the host of the channel's `base_url`. The URL comes from the webhook body, so the API key is never sent to any other host. |

Downloads are streamed and stopped at the upload size limit (`UPLOAD_MAX_BYTES`, default 10 MB). Each request times out after 10 seconds (`config :converger, Converger.Channels.MediaDownload, timeout_ms: 10_000`).

A download that fails never loses the message: the activity is created with the stub as parsed and `channelData.downloadError` set to the reason (`too_large`, `unsupported_type: application/zip`, `http_error: 404`, a transport error, or a host mismatch). Because the download happens while the webhook request is handled, a media message takes longer to acknowledge (at most the download timeout per file); if the provider gives up and re-delivers, the message is recognised by its id. A re-delivered webhook does not download again: known message ids are skipped before any download.

Set `download_media: false` in the channel config to skip downloads and keep stubs (for example when a bot fetches media itself).

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
| `failed` with `errors[0].code` `131047` | `failed`; `last_error` is the `outside_window: ...` text of the [24-hour window](#24-hour-window) |
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

When a WebSocket participant of a conversation types or reads ([WebSocket](../websocket.md#5a-receipts-typing-and-presence)), the `whatsapp_meta` adapter tells the WhatsApp user through the Cloud API (`send_typing/2` and `send_read_receipt/2`, see [ADR-0032](../adr/0032-transient-conversation-signals.md)). Both calls are `POST /<graph_api_version>/<phone_number_id>/messages` with the channel's `access_token`, and both need the `wamid` of a message the WhatsApp user sent (an inbound activity's `idempotency_key`); without one nothing is sent.

| Signal | Request body | Message used |
| --- | --- | --- |
| `typing` with `isTyping: true` | `{"messaging_product": "whatsapp", "status": "read", "message_id": "<wamid>", "typing_indicator": {"type": "text"}}` | the user's latest inbound message |
| `read {watermark}` | `{"messaging_product": "whatsapp", "status": "read", "message_id": "<wamid>"}` | the user's latest inbound message with `seq` up to the watermark; WhatsApp marks it and every earlier message read |

WhatsApp shows the indicator for up to 25 seconds or until the next message is sent, so `isTyping: false` sends nothing and a participant that keeps typing refreshes it at most every 20 seconds. The typing indicator also marks that message as read (Cloud API behaviour). These calls are best effort: they are not retried, and a failure is logged as `Forwarding a conversation signal failed`. `whatsapp_infobip` does not support typing or read receipts.

## Planned

- Native outbound reactions and edits, and outbound replies quoting a message (`context.message_id`).
- Image headers on interactive messages for cards (today the card image is a separate image message).
- Infobip health probe (`health_probe/1`), so idle Infobip channels report a status like Meta ones do.
