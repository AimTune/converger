---
title: Telegram
description: Configuration, webhook registration, secret token verification, message mapping, media and inline keyboards of the telegram channel adapter.
sidebar_position: 2.5
---

The `telegram` adapter connects a Telegram bot to Converger
([`lib/converger/channels/adapters/telegram.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/telegram.ex)).
It supports the modes `inbound`, `outbound` and `duplex`. Inbound updates arrive on the Bot API webhook; outbound
activities are sent with Bot API methods (`sendMessage`, `sendPhoto`, `sendDocument`, `sendChatAction`). The shared
inbound endpoint, signature policy and response codes are described in
[Channels and adapters](overview.md#inbound-endpoints); this page covers what is specific to Telegram.

## Setup

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy its token.
2. Create the channel (admin **Channels** page or `POST /api/v1/channels`) with type `telegram`, mode `duplex`, the
   bot token and a secret token you choose:

   ```json
   {
     "name": "Support bot",
     "type": "telegram",
     "mode": "duplex",
     "config": {
       "bot_token": "7000000001:AAF...",
       "secret_token": "a-long-random-string_1"
     }
   }
   ```

3. Click **Register webhook** next to the channel in the admin channel list. It calls
   [`setWebhook`](https://core.telegram.org/bots/api#setwebhook) with the channel's inbound URL
   (`https://<PHX_HOST>/api/v1/channels/<id>/inbound`), the `secret_token` and the `allowed_updates`, and writes a
   `register_webhook` audit log entry. Telegram only accepts public HTTPS URLs on ports 443, 80, 88 or 8443, so this
   works once Converger runs behind its public host; a Bot API error (for example `An HTTPS URL must be provided for
   webhook`) is shown in the flash message.
4. Route the channel to an agent console (a `websocket` channel) or a bot with a routing rule. Replies posted to the
   conversation are delivered back to the same Telegram chat.

You can also call `setWebhook` yourself; set `secret_token` to the channel's `secret_token` and include
`message_reaction` in `allowed_updates` if you want reactions (Telegram does not send them by default).

## Configuration

The `config` map is encrypted at rest, and `bot_token` and `secret_token` are masked in the admin UI and redacted in
audit logs (keys ending in `_token`, [ADR-0012](../adr/0012-secrets-at-rest-and-audit-redaction.md)).

| Key | Required | Description |
| --- | --- | --- |
| `bot_token` | yes | The bot token from @BotFather. Part of every Bot API URL (`/bot<token>/<method>`). |
| `secret_token` | when `require_signature` is `true` (the default) | 1 to 256 characters of `A-Z`, `a-z`, `0-9`, `_` and `-`. Telegram sends it in `X-Telegram-Bot-Api-Secret-Token` with every update. |
| `parse_mode` | no | `MarkdownV2`, `Markdown` or `HTML`: the `parse_mode` of outbound `sendMessage` calls. Empty (default) sends plain text. With a parse mode the text must be valid for it (Telegram rejects unescaped `MarkdownV2` with `400`, which is permanent). |
| `allowed_updates` | no | Comma-separated update types passed to `setWebhook`. Default `message,edited_message,callback_query,message_reaction`. |
| `conversation_idle_timeout_seconds` | no | As for every inbound channel: after this much inactivity a message starts a new conversation. |
| `unsupported_activities` | no | `downgrade` (default) or `skip` for activity types Telegram does not render natively. See [what is sent](#outbound-messages). |

To use a [self-hosted Bot API server](https://github.com/tdlib/telegram-bot-api) instead of `https://api.telegram.org`, the operator sets it for all Telegram channels:

```elixir
config :converger, Converger.Channels.Adapters.Telegram, api_base_url: "https://bots.internal.example"
```

It is not a channel setting on purpose: a tenant-supplied URL would receive the bot token and could point Converger at internal hosts (see [SSRF protection](../webhooks.md#ssrf-protection)).

## Inbound

### Secret token

Every request to the channel's inbound URL is checked by `verify_inbound_signature/3`:

| Channel `secret_token` | `X-Telegram-Bot-Api-Secret-Token` | Result |
| --- | --- | --- |
| set | equal (constant-time compare) | accepted |
| set | different | `401` |
| set | missing | `401` |
| not set | any | the channel's `require_signature` decides: rejected (`401`) when `true`, accepted with a deprecation warning when `false` |

A channel with `require_signature: true` cannot be saved without a `secret_token`.

### Update mapping

Telegram sends one [`Update`](https://core.telegram.org/bots/api#update) per request. Handled requests are always
answered `200` (`:provider_ack`), because Telegram re-delivers any other answer.

| Update | Activity | Notes |
| --- | --- | --- |
| `message` | `message` | Text, or the caption of a media message. |
| `edited_message` | `messageUpdate` of the original message | `reply_to_id` is the original's activity; each `edit_date` is a separate edit. |
| `callback_query` (inline button press) | `event` with `text` = the button's callback data | `metadata.name` is `telegram.callback_query`; `reply_to_id` is the message that carried the button. The query is answered (`answerCallbackQuery`) in the background so the client stops its spinner. |
| `message_reaction` | `messageReaction` with `text` = the emoji | An empty `new_reaction` (reaction removed) gives an empty `text`. Custom-emoji and paid reactions keep their raw `new_reaction` in `metadata.reaction`. |
| anything else (`my_chat_member`, `channel_post`, ...) | none | Answered `200` with no activity. |

A reply, edit or reaction whose target Converger has not seen (sent before the channel existed) is stored as an
`event`, as for every adapter ([inbound references](../concepts/activities.md#inbound-references)).

**Message ids.** Telegram message ids are unique only within a chat, so Converger names a message
`"<chat_id>:<message_id>"`. Inbound messages use it as `idempotency_key` (a re-delivered update is a duplicate), and
outbound deliveries store it as `provider_message_id`; replies, edits and reactions find their target by it. Edits use
`"<chat_id>:<message_id>:edit:<edit_date>"`, callback queries `callback:<id>` and reactions `update:<update_id>`.

**Participant and sender.** The participant is the **chat**: `external_id` is `chat.id` (negative for groups and
channels), so the reply goes to the chat the message came from. `display_name` is the sender's first and last name
(or `username`, or the group title). The activity `sender` is the user's id (`from.id`); in a private chat it equals
`chat.id`.

**Metadata.** `telegram_update_id`, `telegram_message_id`, `telegram_chat_id`, `telegram_chat_type`,
`telegram_user_id`, `username`, `language_code`, `timestamp` (Unix seconds), `reply_to` (replied-to message id),
`media_group_id` (albums) and `edit_date` (edits), when present.

### Media

Photos (the largest size), documents, audio, voice notes, videos, video notes, animations and stickers become one
attachment each. The adapter downloads the file with [`getFile`](https://core.telegram.org/bots/api#getfile) and
stores it as a Converger upload, so the attachment's `contentUrl` is `/api/v1/converger/attachments/<id>` and its
`contentType` is the sniffed MIME type. The Bot API download URL contains the bot token and is never stored.

```json
{
  "contentType": "image/jpeg",
  "contentUrl": "/api/v1/converger/attachments/2f0c...",
  "size": 48213,
  "channelData": {
    "provider": "telegram",
    "kind": "photo",
    "fileId": "AgACAgQAAxkBAAM...",
    "fileUniqueId": "AQAD...",
    "width": 1280,
    "height": 960
  }
}
```

The file is **not** downloaded (the attachment keeps `channelData.fileId` and has no `contentUrl`) when it is larger
than the upload limit (`max_file_size`, at most the Bot API's 20 MB), when its type is not in the tenant's upload
allowlist, when the download fails, or when the update is a re-delivery of a message Converger already has. A failed
download is logged and never drops the message. Locations become `application/vnd.converger.location` attachments
and shared contacts `application/vnd.converger.contacts`, as on WhatsApp.

## Outbound messages

Activities reach the adapter through the delivery pipeline, when the Telegram channel is the conversation's channel or
the target of a routing rule.

**Recipient.** The activity metadata key `chat_id`, else the `external_id` of the conversation's participant on this
channel. Without either the delivery fails permanently (`no recipient: ...`). The inbound key `telegram_chat_id` is
deliberately not used, so a message routed from one bot to another is never sent to a chat of the wrong bot.

**What is sent**, in order:

1. every attachment with a `contentUrl`: `image/*` (except GIF) with `sendPhoto`, anything else with `sendDocument`,
   with the attachment `name` as caption. An absolute URL is passed to Telegram, which fetches it. A Converger upload
   (`/api/v1/converger/attachments/<id>`, or that path on Converger's own host) is not reachable by Telegram, so its
   bytes are read from storage and uploaded (`multipart/form-data`);
2. the activity `text` with `sendMessage` (and the channel's `parse_mode`). Without text, the title, subtitle and text
   of the card attachments are sent instead;
3. the buttons of `application/vnd.converger.card.*` attachments become an
   [inline keyboard](https://core.telegram.org/bots/api#inlinekeyboardmarkup) on the last message, one button per row:

| Card button | Telegram button |
| --- | --- |
| `{"type": "openUrl", "title": "Track", "value": "https://..."}` | URL button |
| any other type (`postBack`, `imBack`, ...) | callback button with `callback_data` = `value` (or `title`); pressing it sends a `callback_query`, which comes back as an `event` |

Telegram limits callback data to 64 bytes; a button whose data is longer is dropped with a warning.

The delivery's `provider_message_id` is the `"<chat_id>:<message_id>"` of the last message sent, and its metadata
gets `telegram_messages` (how many were sent). If a later message of the same activity fails, the retry sends the
whole activity again.

Native activity types: `message`. Reactions, edits and deletes from other channels are downgraded to text (or skipped)
per `unsupported_activities`.

**Typing.** A typing signal from a WebSocket participant calls `sendChatAction` with `typing`. Telegram shows it for
about five seconds or until the next message, so `isTyping: false` makes no call. Telegram bots cannot mark user
messages as read, so read receipts are not forwarded.

**Delivery receipts.** The Bot API reports no delivery or read status; deliveries stay `sent`.

### Errors and limits

Bot API errors are classified from the HTTP status, with the Bot API `description` as the reason:

| Status | Example | Retried |
| --- | --- | --- |
| `400` | `Bad Request: chat not found`, invalid `MarkdownV2` | no |
| `401`, `403`, `404` | invalid token, `Forbidden: bot was blocked by the user` | no |
| `429` | `Too Many Requests: retry after 7` | yes, after `parameters.retry_after` seconds |
| `5xx`, transport errors | | yes, with the channel's backoff |

The default outbound rate limit is `30/s` (the Bot API's per-bot limit); set the channel's `rate_limit` to change it
([circuit breaker and rate limit](../delivery.md#circuit-breaker)).

### Health probe

A Telegram channel without recent deliveries is probed with `getMe` (5 second timeout, no retry), which catches a
revoked token. See [health probes](overview.md#health-probes).

## Testing

`test/fixtures/telegram/*.json` holds `Update` payloads in the Bot API's shape (text, reply, group message, edit,
callback query, reaction, photo, voice, document, `my_chat_member`). In the test environment every Bot API call goes to
the Req.Test stub `Converger.Channels.Adapters.Telegram` (`config :converger, :telegram_req_options`). The adapter
tests are in
[`telegram_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/adapters/telegram_test.exs),
and the end-to-end flow (Telegram to an agent console and back, secret token, media download, the admin button) in
[`telegram_channel_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/integration/telegram_channel_test.exs).

See [ADR-0041](../adr/0041-telegram-adapter-chat-scoped-ids-and-stored-media.md) for the design decisions.
