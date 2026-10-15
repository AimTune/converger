---
title: Instagram Direct
description: Configuration, Meta app setup for Facebook Login or Instagram Login, webhook signature, message mapping, media and receipts of the instagram channel adapter.
sidebar_position: 2.2
---

The `instagram` adapter connects the Direct messages of an Instagram professional account to Converger
([`lib/converger/channels/adapters/instagram.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/instagram.ex)).
It supports the modes `inbound`, `outbound` and `duplex`. Instagram messaging runs on the Messenger Platform, so the
adapter shares its webhook parsing, Send API code, signature check and media downloads with
[Facebook Messenger](messenger.md) (and the Graph code with [WhatsApp](whatsapp.md)); this page lists the
differences. See [ADR-0048](../adr/0048-additional-adapters-shared-meta-code-bot-framework-jwt-and-pull-outbox.md).

## Setup

Meta offers two ways to reach Instagram messaging. Pick the one your app uses:

| | Instagram API with Facebook Login | Instagram API with Instagram Login |
| --- | --- | --- |
| Account | Instagram professional account linked to a Facebook Page | Instagram professional account |
| Token | Page access token (`instagram_basic`, `instagram_manage_messages`, `pages_messaging`) | Instagram user access token (`instagram_business_basic`, `instagram_business_manage_messages`) |
| `api_host` | `graph.facebook.com` (default) | `graph.instagram.com` |
| `account_id` | the Page id | the Instagram account id |

1. Add the Instagram product to your Meta app and generate the token.
2. Create the channel:

   ```json
   {
     "name": "Instagram DMs",
     "type": "instagram",
     "mode": "duplex",
     "config": {
       "account_id": "17841400000000001",
       "access_token": "IGQV...",
       "api_host": "graph.instagram.com",
       "verify_token": "a-long-random-string",
       "app_secret": "0123456789abcdef0123456789abcdef"
     }
   }
   ```

3. Set the webhook callback URL to `https://<PHX_HOST>/api/v1/channels/<channel id>/inbound` with the channel's
   `verify_token`, and subscribe to `messages`, `messaging_postbacks`, `message_reactions` and `messaging_seen`.

## Configuration

| Key | Required | Description |
| --- | --- | --- |
| `account_id` | yes | Numeric id the Send API is called on (`/<version>/<account_id>/messages`). |
| `access_token` | yes (secret) | Page token or Instagram user token. |
| `api_host` | no | `graph.facebook.com` (default) or `graph.instagram.com`. No other host is accepted, so the token cannot be sent elsewhere. |
| `verify_token` | yes (secret) | Webhook subscription check. |
| `app_secret` | when `require_signature` is `true` | Signs every webhook (`X-Hub-Signature-256`). |
| `graph_api_version` | no | Default `v26.0`. |
| `download_media` | no | Default `true`. |

## Differences from Messenger

- Webhooks must have `object: "instagram"`.
- **Story replies and mentions**: `message.reply_to.story` (`url`, `id`) is kept in `metadata.story`; a
  `story_mention`, `ig_reel` or `share` attachment with a URL is downloaded like other media (story media expire
  after 24 hours).
- **Unsends** (`is_deleted`) become `messageDelete`.
- **Receipts**: Instagram read events name the message (`read.mid`), so they mark that delivery `read`.
- **Text** is split into messages of at most 500 characters (Instagram limits a text message to 1000 bytes).
- **Media**: Instagram fetches attachments from a URL; a file stored in Converger cannot be uploaded and fails the
  delivery permanently (`Instagram API cannot fetch Converger attachment ...`). Send media with a public
  `contentUrl`.
- **Rate limit**: default `100/s` (Instagram's Send API limit per professional account for text); set the channel's
  `rate_limit` to change it.
- **Errors**: rate-limit code `80002` is retried, like the codes listed for [Messenger](messenger.md#errors).

Outbound messages, quick replies, message tags (`metadata.message_tag`, for example `HUMAN_AGENT`), the 24-hour
window error, metadata keys and the health probe (`GET /<version>/<account_id>?fields=id`) work as described for
[Messenger](messenger.md#outbound).

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

[`instagram_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/adapters/instagram_test.exs)
stubs the Graph API through `config :converger, :instagram_req_options`.
