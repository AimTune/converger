---
title: "ADR-0041: Telegram adapter with chat-scoped message ids, a strict secret token and media stored as uploads"
sidebar_label: "0041 Telegram adapter"
description: Telegram messages are named "<chat_id>:<message_id>", a configured secret token is always enforced, inbound files are copied into Converger's storage so the bot token never leaks, and webhook registration is an optional adapter callback behind an admin button.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-11 |
| **Issue** | [#38](https://github.com/AimTune/converger/issues/38) |
| **Pull request** | [#132](https://github.com/AimTune/converger/pull/132) |
| **Related** | [ADR-0007](0007-attachment-storage-with-hand-written-signing.md), [ADR-0009](0009-inbound-signature-scheme-and-per-channel-enforcement.md), [ADR-0015](0015-per-message-idempotent-inbound-batches.md), [ADR-0016](0016-participant-based-conversation-resolution.md), [ADR-0036](0036-rich-activity-model.md), [ADR-0038](0038-adapter-behaviour-v2-and-config-driven-registry.md) |

## Context and problem statement

Telegram is the cheapest real duplex channel to support (free, webhook based, no approval) and the first
channel built on adapter behaviour v2 ([ADR-0038](0038-adapter-behaviour-v2-and-config-driven-registry.md)).
Issue [#38](https://github.com/AimTune/converger/issues/38) asks for messages, edits, button presses, reactions
and media inbound; text, photos, documents, inline keyboards and typing outbound; and an admin button that
registers the webhook. Four properties of the Bot API do not fit the WhatsApp-shaped assumptions of the
existing adapters:

1. **Message ids are per chat.** `message_id` is a small integer unique only within its chat. Converger
   finds the target of a reply, edit or reaction by a provider id that must be unique per channel
   (`Activities.get_activity_by_provider_message_id/2` looks at inbound idempotency keys and outbound
   `provider_message_id`s). An edit also carries the **same** `message_id` as the original.
2. **Authentication is a shared secret, not a signature.** `setWebhook` takes a `secret_token`, and Telegram
   echoes it in `X-Telegram-Bot-Api-Secret-Token`. The generic policy
   ([ADR-0009](0009-inbound-signature-scheme-and-per-channel-enforcement.md)) treats a missing signature as
   acceptable on channels with `require_signature: false`.
3. **File URLs contain the bot token.** `getFile` returns a path to be fetched from
   `https://api.telegram.org/file/bot<token>/<path>`. Storing that URL in an attachment publishes the token to
   every consumer of the conversation.
4. **The webhook is registered by an API call** (`setWebhook`), not in a provider console, and the issue wants
   it in the admin UI. No adapter callback existed for it.

## Decision drivers

- Replies, edits and reactions must resolve to the right activity, and a re-delivered update must never
  create a second one (no data loss, no duplicates).
- The bot token must not appear in stored activities, delivery errors or traces.
- An invalid secret must be rejected with `401` (acceptance criterion).
- Nothing outside the adapter may learn about Telegram (ADR-0038: no type lists outside adapters).

## Considered options

For message ids:

1. **`"<chat_id>:<message_id>"` as the provider id everywhere** (inbound idempotency key, outbound
   `provider_message_id`, reference targets); edits keyed by `edit_date`.
2. **`update_id` as the idempotency key**, and a separate lookup for references.
3. **Raw `message_id`**.

For media:

1. **Download with `getFile` and store as a Converger upload** during the inbound request.
2. **Store `file_id` only**, and add a proxy endpoint that resolves it on read.
3. **Store the Bot API file URL**.

For the secret token: (a) generic policy only, or (b) a configured `secret_token` is always enforced.

For webhook registration: (a) a Telegram-specific admin button, or (b) an optional
`register_webhook/2` adapter callback and a generic button.

### Pros and cons of the options

#### Message ids: chat-scoped key (1)

- Good, because the existing reference resolution and idempotency work unchanged; outbound and inbound
  messages share one naming scheme.
- Bad, because the key is a Telegram convention that consumers must understand (documented).

#### Message ids: `update_id` (2)

- Good, because it is globally unique per bot.
- Bad, because replies and reactions name a `message_id`, not an `update_id`, so a second index would be
  needed; outbound messages have no `update_id` at all.

#### Message ids: raw `message_id` (3)

- Bad, because two chats' message `41` collide: a re-delivered message from one chat would be taken as a
  duplicate of another chat's message.

#### Media: store as upload (1)

- Good, because the token never leaves the adapter, the attachment is served like any other upload
  (signed URLs, CDN, retention), and Telegram's file links (valid for one hour) do not expire under it.
- Bad, because the webhook request does one or two extra HTTP calls per media message, and the tenant's upload
  allowlist and size limit apply.

#### Media: `file_id` plus proxy (2)

- Good, because the request path stays fast.
- Bad, because it is a new authenticated endpoint, the file depends on the bot staying valid, and every read
  hits Telegram.

#### Media: Bot API URL (3)

- Bad, because it leaks the bot token. Rejected.

## Decision

- **Message ids**: option 1. Inbound messages use `"<chat_id>:<message_id>"` as `idempotency_key`; outbound
  deliveries return it as `provider_message_id`; replies (`reply_to_message`), edits and reactions set it as
  `reply_to_provider_id`. Edits are keyed `"<chat>:<message>:edit:<edit_date>"`, so a re-delivered edit is a
  duplicate and a second edit is not; callback queries use `callback:<id>` and reactions `update:<update_id>`.
- **Participant**: the chat (`chat.id`) is the participant's `external_id`, so replies go to the chat the
  message came from (a private chat, group or channel); the user id (`from.id`) is the activity `sender`.
- **Secret token**: option (b). When the channel has a `secret_token`, a missing or different header is
  `{:error, _}` (`401`) regardless of `require_signature`; only a channel without a secret falls back to the
  generic policy, and `require_signature: true` makes `secret_token` required (`required: :with_signature`).
  A configured secret that requests may omit protects nothing.
- **Media**: option 1, best effort. The adapter downloads the largest photo size or the file, stores it with
  `Uploads.create_attachment/3` and sets `contentUrl` to `/api/v1/converger/attachments/<id>`; the Telegram
  `file_id` stays in `channelData`. A file over the limit, of a type the tenant does not allow, a failed
  download, or a re-delivered message keeps only the `file_id`: the message is never dropped because of its
  media.
- **Outbound files**: a Converger upload is not reachable by Telegram, so its bytes are uploaded
  (`multipart/form-data`); other URLs are passed to Telegram to fetch.
- **Webhook registration**: option (b). A new optional callback
  `register_webhook(channel, inbound_url)` (`Adapter.register_webhook/2`, `Channels.register_webhook/3`), and
  the admin channel list shows **Register webhook** for every adapter that implements it. Successful calls are
  audited as `register_webhook`.
- **HTTP client**: the adapter calls `Req` directly, not `Converger.HTTP`, because the bot token is part of
  every Bot API URL and `OpentelemetryReq` records the URL (`url.full`) on the client span. Error reasons use
  the Bot API `description`, never the URL.
- **Bot API base URL**: application config only
  (`config :converger, Converger.Channels.Adapters.Telegram, api_base_url: ...`, for a self-hosted Bot API
  server), not a channel setting: a tenant-supplied URL would receive the bot token and would need the SSRF
  guard ([ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md)).

## Consequences

### Positive

- The acceptance flow works without changes to the pipeline, the inbound controller or reference resolution.
- No stored activity, delivery error or trace contains the bot token.
- The next adapter with programmatic webhook registration (Slack, Viber, Messenger) gets the admin button by
  implementing one callback.

### Negative and trade-offs

- Inbound media costs one `getFile` call and a download inside the webhook request (up to 20 MB). Telegram
  waits for the response, but very large files slow down the bot's update stream; the upload size limit
  caps it.
- `answerCallbackQuery` runs as a fire-and-forget task from `parse_inbound/2`, which is otherwise pure: a
  re-delivered callback query is answered twice (harmless; Telegram ignores the second answer).
- An activity with several attachments becomes several Telegram messages. If one fails after others were
  sent, the retry sends all of them again (Telegram has no idempotency key for sends).
- Card buttons follow the hero-card shape (`title`, `text`, `buttons[{type, title, value}]`) until the rich
  message vocabulary ([#68](https://github.com/AimTune/converger/issues/68)) defines one.

### Follow-ups

- [#68](https://github.com/AimTune/converger/issues/68): typed buttons and cards; map them to inline keyboards.
- Native outbound edits (`editMessageText`) and reactions (`setMessageReaction`) once the target's
  provider id is passed to `deliver_activity/2`.
- Albums (`media_group_id`) arrive as one activity per photo; grouping them is not planned yet.

## Implementation

- [`lib/converger/channels/adapters/telegram.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/telegram.ex):
  the adapter (config schema, `parse_inbound/2`, `verify_inbound_signature/3`, `deliver_activity/2`,
  `send_typing/2`, `health_probe/1`, `register_webhook/2`).
- [`lib/converger/channels/adapter.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapter.ex):
  `register_webhook/2` callback and dispatcher; `telegram` in the built-in registry.
- [`lib/converger/channels.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels.ex):
  `register_webhook/3` with the audit entry; `register_webhook` added to the audit actions.
- [`lib/converger_web/live/admin/channel_live.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/live/admin/channel_live.ex):
  the **Register webhook** button.
- Tests: `test/converger/channels/adapters/telegram_test.exs` (fixtures in `test/fixtures/telegram/`) and
  `test/converger_web/integration/telegram_channel_test.exs` (Telegram to a WebSocket console and back,
  `401` on an invalid or missing secret, media download, edits and reactions, the admin button).

## Links

- [Telegram channel](../channels/telegram.md)
- [Channels and adapters](../channels/overview.md), [Writing an adapter](../channels/writing-an-adapter.md)
- [Telegram Bot API](https://core.telegram.org/bots/api): `Update`, `setWebhook`, `getFile`,
  `InlineKeyboardMarkup`
