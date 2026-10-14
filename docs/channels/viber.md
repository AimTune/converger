---
title: Viber
description: Configuration, webhook registration, X-Viber-Content-Signature verification, message mapping, keyboards, media, subscriptions and receipts of the viber channel adapter.
sidebar_position: 2.85
---

The `viber` adapter connects a Viber bot to Converger
([`lib/converger/channels/adapters/viber.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/viber.ex)).
It supports the modes `inbound`, `outbound` and `duplex`, on the
[Viber REST Bot API](https://developers.viber.com/docs/api/rest-bot-api/): callbacks arrive on the channel's inbound
URL, replies are sent with `send_message`.

## Setup

1. Create a bot in the [Viber Admin Panel](https://partners.viber.com/) and copy its authentication token.
2. Create the channel:

   ```json
   {
     "name": "Viber bot",
     "type": "viber",
     "mode": "duplex",
     "config": {
       "auth_token": "445da6az1s345z78-dazcczb2542zv51a-e0vc5fva17480im9",
       "sender_name": "Acme Support"
     }
   }
   ```

3. Click **Register webhook** next to the channel in the admin channel list. It calls `set_webhook` with
   `https://<PHX_HOST>/api/v1/channels/<id>/inbound` and the events `delivered`, `seen`, `failed`, `subscribed`,
   `unsubscribed` and `conversation_started`. Viber checks the URL with a signed `webhook` callback first, so this
   works once Converger is reachable on public HTTPS with a valid certificate.

## Configuration

| Key | Required | Description |
| --- | --- | --- |
| `auth_token` | yes (secret) | Bot token: sent as `X-Viber-Auth-Token` and the key of `X-Viber-Content-Signature`. |
| `sender_name` | yes | Sender name shown with every message, at most 28 characters. |
| `sender_avatar` | no | Avatar URL shown with every message. |
| `download_media` | no | `false` keeps inbound media as provider URLs. Default `true`. |
| `conversation_idle_timeout_seconds`, `unsupported_activities` | no | As for every channel. |

The operator can point all Viber channels at another API base (`config :converger, Converger.Channels.Adapters.Viber,
api_base_url: "..."`); it is not a channel setting because the URL receives the token.

## Inbound

**Signature.** Every callback carries `X-Viber-Content-Signature`, the hex HMAC-SHA256 of the raw body keyed with the
`auth_token`, compared in constant time. A wrong or missing signature is a `401`, whatever `require_signature` says.

| Callback | Activity | Notes |
| --- | --- | --- |
| `message` (`text`) | `message` | Keyboard button presses arrive as text messages whose text is the button's `ActionBody`. |
| `message` (`picture`, `video`, `file`, `sticker`) | `message` with one attachment | The media URL is checked by the [SSRF guard](../webhooks.md#ssrf-protection), downloaded and stored; `channelData` keeps `provider`, `kind`, `providerMediaUrl`. |
| `message` (`location`) | `message` with an `application/vnd.converger.location` attachment | |
| `message` (`contact`) | `message` with an `application/vnd.converger.contacts` attachment | |
| `message` (`url`) | `message` with the URL as text | |
| `conversation_started` | `event`, `metadata.name` = `viber.conversation_started` | The user opened the chat (`context` and `subscribed` in metadata). Viber allows a single message to a user who has not subscribed. |
| `subscribed` | `event` `viber.subscribed` | Opts the participant in again. |
| `unsubscribed` | `event` `viber.unsubscribed` | Opts the participant out: later deliveries to them fail immediately (`recipient <id> opted out`), as for an SMS `STOP`. |
| `webhook` | none | The `set_webhook` check, answered `200`. |
| `delivered`, `seen`, `failed` | none | Receipts (below). |

The participant and sender are the Viber user id (`sender.id`), with the user's name as display name. The
idempotency key is the `message_token`. Metadata: `viber_message_token`, `viber_type`, `timestamp`, `language`,
`country`, `tracking_data`.

## Outbound

**Recipient.** The activity metadata key `recipient_id`, else the conversation's participant on this channel.

**What is sent**, one `send_message` call per message, in order:

1. every file attachment with an absolute `contentUrl`: JPEG, PNG and GIF images as `picture` (the attachment `name`
   as caption), videos as `video` and other files as `file` when the attachment has a `size`, else as a `url` message.
   Viber fetches the URL itself; a file stored in Converger cannot be sent (permanent error);
2. locations as `location` and contacts as `contact` messages;
3. the text (the activity `text`, else the card texts) as `text` messages of at most 7000 characters.

The buttons of card attachments become a [keyboard](https://developers.viber.com/docs/tools/keyboards/) on the last
message: `reply` buttons whose `ActionBody` is the button `id` or `value`, and `open-url` buttons for `openUrl`.

The delivery's `provider_message_id` is the `message_token` of the last message (all of them in
`viber_message_tokens`).

**Receipts.** `delivered` marks the delivery `delivered`, `seen` marks it `read`, and `failed` marks it `failed` with
Viber's `desc`.

### Errors

Viber answers `200` with a `status` in the body:

| `status` | Meaning | Retried |
| --- | --- | --- |
| `0` | ok | |
| `12` | too many requests | yes |
| `1` to `11`, `13` to `24` | invalid URL, invalid token, bad or missing data, receiver not registered or not subscribed, account blocked or suspended, ... | no |
| other | general error | yes |

Non-`200` answers follow the HTTP status (`429` and `5xx` are retried).

### Health probe

`get_account_info` (5 seconds, no retry) catches an invalid token.

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

[`viber_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/adapters/viber_test.exs)
stubs the Bot API through `config :converger, :viber_req_options`.
