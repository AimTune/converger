---
title: Facebook Messenger
description: Configuration, Meta app setup, webhook signature, message mapping, media, quick replies, message tags and receipts of the messenger channel adapter.
sidebar_position: 2.1
---

The `messenger` adapter connects a Facebook Page's Messenger inbox to Converger
([`lib/converger/channels/adapters/messenger.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/messenger.ex)).
It supports the modes `inbound`, `outbound` and `duplex`. Inbound messages arrive on the Messenger Platform webhook;
replies are sent with the Send API. The shared inbound endpoint, signature policy and response codes are described in
[Channels and adapters](overview.md#inbound-endpoints).

Messenger, [Instagram](instagram.md) and [WhatsApp](whatsapp.md) are the same Graph API family. Their webhook
signature, `hub.challenge` handshake, Graph error classification and media downloads are one module
([`Converger.Channels.Meta.Graph`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/meta/graph.ex)),
and Messenger and Instagram share the Messenger Platform parsing and Send API code
([`Converger.Channels.Meta.Messaging`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/meta/messaging.ex)).
See [ADR-0048](../adr/0048-additional-adapters-shared-meta-code-bot-framework-jwt-and-pull-outbox.md).

## Setup

1. In the [Meta developer dashboard](https://developers.facebook.com/apps), create an app (type **Business**) and add
   the **Messenger** product. Connect the Facebook Page and generate a **Page access token** with the
   `pages_messaging` permission (a token of a system user does not expire).
2. Create the channel with type `messenger`, mode `duplex`, the Page id, the token, a verify token you choose and the
   app secret (**App settings > Basic**):

   ```json
   {
     "name": "Support Page",
     "type": "messenger",
     "mode": "duplex",
     "config": {
       "page_id": "104512345678901",
       "page_access_token": "EAAG...",
       "verify_token": "a-long-random-string",
       "app_secret": "0123456789abcdef0123456789abcdef"
     }
   }
   ```

3. Under **Messenger > Settings > Webhooks**, set the callback URL to
   `https://<PHX_HOST>/api/v1/channels/<channel id>/inbound` and the verify token to the channel's `verify_token`. Meta
   calls `GET` on it with `hub.challenge`, which Converger echoes when the token matches.
4. Subscribe the Page to the webhook fields `messages`, `messaging_postbacks`, `message_reactions`,
   `message_deliveries` and `message_edits`.
5. Route the channel to an agent console or a bot with a routing rule.

## Configuration

The `config` map is encrypted at rest; `page_access_token`, `verify_token` and `app_secret` are masked in the admin
UI and redacted in audit logs ([ADR-0012](../adr/0012-secrets-at-rest-and-audit-redaction.md)).

| Key | Required | Description |
| --- | --- | --- |
| `page_id` | yes | The numeric Page id. The Send API is called on `/<version>/<page_id>/messages`. |
| `page_access_token` | yes | Page access token with `pages_messaging`. |
| `verify_token` | yes | Echo check of the webhook subscription (`hub.verify_token`). |
| `app_secret` | when `require_signature` is `true` (the default) | Signs every webhook (`X-Hub-Signature-256`). |
| `graph_api_version` | no | Default `v26.0`, or `config :converger, Converger.Channels.Adapters.Messenger, graph_api_version: "..."`. |
| `download_media` | no | `false` keeps inbound attachments as provider references instead of storing them. Default `true`. |
| `conversation_idle_timeout_seconds`, `unsupported_activities` | no | As for every channel. |

## Inbound

Webhooks with `object: "page"` are accepted; any other object is a `400`. Every `entry[].messaging[]` event is
handled in order, and handled requests are always answered `200` (`:provider_ack`). The signature is
`X-Hub-Signature-256`, checked exactly as for WhatsApp ([WhatsApp](whatsapp.md#inbound-signature-x-hub-signature-256)).

| Event | Activity | Notes |
| --- | --- | --- |
| `message` | `message` | `text`; attachments become attachments (below); `quick_reply.payload` goes to `metadata.quick_reply_payload`; `reply_to.mid` resolves `reply_to_id`. |
| `message` with `is_echo` | none | The Page's own messages (including Converger's replies) come back as echoes and are skipped. |
| `message` with `is_deleted` | `messageDelete` of the original | |
| `message_edit` | `messageUpdate` of the original | Each `num_edit` is a separate edit. |
| `postback` (a button press) | `message` with `text` = the button title | `metadata.interactive_reply` = `{type: "postback", title, payload}`. |
| `reaction` | `messageReaction` with `text` = the emoji | `unreact` gives an empty `text`. |
| `delivery`, `read`, `optin`, `referral`, ... | none | `delivery` is a receipt (below). |

- **Participant and sender**: the Page-scoped id (PSID) of the sender. Replies go to it.
- **Idempotency**: the message `mid` (edits `<mid>:edit:<n>`, reactions `reaction:<mid>:<sender>:<action>:<timestamp>`).
- **Metadata**: `mid`, `messenger_recipient_id` (the Page), `timestamp` (Unix milliseconds), `quick_reply_payload`,
  `reply_to`.

### Media

`image`, `video`, `audio` and `file` attachments carry a CDN URL. The URL is checked by the
[SSRF guard](../webhooks.md#ssrf-protection) and the file downloaded (bounded by the upload limit) and stored as a
Converger upload, so the attachment's `contentUrl` is `/api/v1/converger/attachments/<id>` and `channelData` keeps
`provider`, `kind` and `providerMediaUrl`. A failed download keeps the stub with `channelData.downloadError`; the
message is never dropped. A `location` attachment becomes `application/vnd.converger.location`, and a shared link
(`fallback`) is appended to the text. Other attachment types are kept as
`application/vnd.converger.messenger.<type>` with the raw payload as `content`.

## Outbound

**Recipient.** The activity metadata key `recipient_id` (a PSID), else the conversation's participant on this channel.

**What is sent**, in order:

1. every file attachment as an attachment message (`image`, `video`, `audio` or `file` from the content type): an
   absolute URL is sent as `payload.url` for Meta to fetch, and a Converger upload is sent as the file itself
   (`multipart/form-data`, `filedata`);
2. the text (the activity `text`, else the card texts; location and contacts as a line each), split into messages of
   at most 2000 characters;
3. the buttons of card attachments as [quick replies](https://developers.facebook.com/docs/messenger-platform/send-messages/quick-replies)
   on the last text message (at most 13, titles cut at 20 characters, the payload is the button `id` or `value`).
   `openUrl` buttons are appended to the text as `title: url`.

The delivery's `provider_message_id` is the `message_id` of the last message; every id is in
`meta_message_ids`. Messages are sent with `messaging_type: "RESPONSE"`. Outside the 24-hour standard messaging
window, set `metadata.message_tag` (for example `HUMAN_AGENT`, which allows 7 days) to send with
`messaging_type: "MESSAGE_TAG"`.

**Receipts.** `delivery` events mark the deliveries of their `mids` `delivered`. Messenger read receipts carry only a
`watermark` timestamp, not a message id, and are ignored.

### Errors

| Graph error | Retried |
| --- | --- |
| code `10` / subcode `2018278` (outside the 24-hour window) | no: `outside_window: ... set metadata.message_tag` |
| codes `4`, `17`, `32`, `613`, `80006` (rate limits), `1`, `2` (transient) | yes, whatever the HTTP status |
| other `4xx` (invalid recipient, `190` expired token, `551` user unavailable) | no |
| `5xx`, transport errors | yes |

### Health probe

`GET /<version>/<page_id>?fields=id` with the Page token (5 seconds, no retry) catches an expired or revoked token.

## Typed messages

The adapter declares `message_types: image file video audio` ([#68](https://github.com/AimTune/converger/issues/68),
[ADR-0064](../adr/0064-per-channel-rendering-of-typed-messages-and-normalised-answers.md)): typed media arrive as
file attachments and are sent as described above. Every other typed message is sent as its text rendering
([messages.md section 5](../protocol/messages.md)): the prompt with its actions as a numbered list
(`1. Track an order`), links as `label: url`, cards as text blocks; native quick replies or buttons for typed
messages are a follow-up. A reply that is only a number (`2`) within 24 hours of the conversation's most recent
actionable message becomes the normalised answer, with `metadata.action` (`source: "numeric"`) and `reply_to_id`
([messages.md section 6](../protocol/messages.md)).

## Testing

The adapter tests
([`messenger_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/adapters/messenger_test.exs))
stub the Graph API with `Req.Test` through `config :converger, :messenger_req_options`.
