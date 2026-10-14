---
title: Slack
description: Configuration, Slack app setup, signature verification, conversation scopes, message mapping, files, Block Kit cards and error handling of the slack channel adapter.
sidebar_position: 2.5
---

The `slack` adapter connects a Slack app to Converger: Slack's **Events API** brings messages in, the
**Web API** sends replies out, and every inbound request is verified with the app's **signing secret**.
It supports the modes `inbound`, `outbound` and `duplex`. Source:
[`lib/converger/channels/adapters/slack.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/slack.ex)
and the modules under `slack/`. The decisions behind it are in
[ADR-0040](../adr/0040-slack-adapter-message-refs-conversation-scopes-and-in-band-challenge.md).

## Setting up the Slack app

1. Create an app at [api.slack.com/apps](https://api.slack.com/apps) and install it in your workspace.
2. **OAuth & Permissions**, bot token scopes:
   - `chat:write` (replies, edits and deletes);
   - `channels:history`, `groups:history`, `im:history`, `mpim:history` (message events in public
     channels, private channels, DMs and group DMs; pick the ones you need);
   - `app_mentions:read` (`app_mention` events);
   - `reactions:read` (reaction events);
   - `files:read` (only with `download_files: true`) and `files:write` (outbound files).
3. Create the Converger channel (below) with the **Bot User OAuth Token** (`xoxb-...`) and the
   **Signing Secret** (Basic Information, App Credentials).
4. **Event Subscriptions**: enable, and set the Request URL to
   `https://<your-host>/api/v1/channels/<channel id>/inbound`. Slack sends a signed `url_verification`
   request, which Converger answers with its `challenge`. Subscribe to the bot events `message.channels`
   (and `message.groups`, `message.im`, `message.mpim` as needed), `app_mention`, `reaction_added` and
   `reaction_removed`.
5. **Interactivity & Shortcuts** (only for card buttons): enable, with the same Request URL.
6. Invite the bot to the channels it should read and write (`/invite @your-app`).

## Configuration

The `config` map is encrypted at rest; `bot_token` and `signing_secret` are also redacted in audit logs
and masked in the admin UI ([ADR-0012](../adr/0012-secrets-at-rest-and-audit-redaction.md)). The keys
are the adapter's `config_schema/0`:

| Key | Required | Description |
| --- | --- | --- |
| `bot_token` | yes | Bot User OAuth Token; must start with `xoxb-`. Sent as `Authorization: Bearer` on every Web API call. |
| `signing_secret` | yes | The app's signing secret; verifies `X-Slack-Signature`. |
| `channel` | no | Default Slack channel id (for example `C0123456789`) for activities in conversations without a Slack participant, such as conversations started from the API. |
| `app_id` | no | When set, events and interactions whose `api_app_id` differs are acknowledged and ignored. |
| `conversation_scope` | no | `thread` (default), `channel` or `user`: what one Converger conversation is. See [Conversations](#conversations). |
| `download_files` | no | `true` stores files shared in Slack as Converger uploads. See [Files](#files). |
| `conversation_idle_timeout_seconds` | no | Positive integer: after this much inactivity an inbound message starts a new conversation instead of joining the participant's active one. |
| `unsupported_activities` | no | `downgrade` (default) or `skip`: what to do with activity types Slack does not render natively (reactions, events). |

A missing key fails with `slack config missing: bot_token, signing_secret`; a user token fails with
`slack config 'bot_token' must be a bot token (xoxb-...)`.

```json
{
  "bot_token": "xoxb-1234-5678-abcdef",
  "signing_secret": "8f742231b10e8888abcd99yyyzzz85a5",
  "channel": "C0123456789",
  "conversation_scope": "thread"
}
```

## Inbound

### Signature: `X-Slack-Signature`

Slack signs every request:

```http
X-Slack-Request-Timestamp: 1531420618
X-Slack-Signature: v0=<hex HMAC-SHA256 of "v0:<timestamp>:<raw body>", keyed with the signing secret>
```

Converger recomputes the HMAC over the exact raw body and compares in constant time. The timestamp must
be within the inbound signature tolerance of the server clock (300 seconds by default,
`config :converger, :inbound_signature_tolerance_seconds`), so a captured request replayed more than
5 minutes later is rejected.

| Situation | Result |
| --- | --- |
| Valid signature, fresh timestamp | accepted |
| Wrong signature (other secret, tampered body) | `401`, always |
| Timestamp older or newer than the tolerance, or not a number | `401`, always |
| No `X-Slack-Signature` header | treated as missing: `401` when `require_signature` is `true` (the default), accepted with a deprecation warning otherwise |

The generic `x-converger-signature` header is not accepted on a `slack` channel. See
[Inbound signatures](overview.md#inbound-signatures).

### URL verification

When the Request URL is saved, Slack posts:

```json
{ "token": "...", "challenge": "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P", "type": "url_verification" }
```

Once the signature is verified, Converger answers `200 {"challenge": "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P"}`
and creates nothing. This is the adapter's `inbound_challenge/2` callback, see
[Writing an adapter](writing-an-adapter.md).

### Responses and retries

The adapter has the `:provider_ack` capability: once a request is handled it gets `200`, even when a
message was rejected permanently, because Slack retries non-`2xx` answers and disables event delivery
for apps that keep failing. Slack also retries callbacks that take longer than 3 seconds; retries
(`X-Slack-Retry-Num`) are recognised by the idempotency key and counted as `duplicates`.

### Message mapping

| Slack | Activity | `reply_to_id` |
| --- | --- | --- |
| `message` (plain, `file_share`, `thread_broadcast`) | `message` | the thread root, for a reply in a thread |
| `app_mention` | `message` (a duplicate of the `message` event of the same message, if both are subscribed) | as above |
| `message` / `message_changed` | `messageUpdate` with the new text | the edited message |
| `message` / `message_deleted` | `messageDelete` | the deleted message |
| `reaction_added` | `messageReaction`, text `:<name>:` (for example `:thumbsup:`) | the reacted-to message |
| `reaction_removed` | `messageReaction` with empty text | the reacted-to message |
| `block_actions` (a click on a card button) | `message` whose text is the button value | the message with the card |
| `block_actions` on a button of a [typed message](#typed-messages) | the normalised answer: `text` = the action's value (or label), `metadata.action` with `source: "button"` | the typed message |

Ignored, with `200`: messages from bots (`bot_id` set, or subtype `bot_message`), which includes
Converger's own replies; other `message` subtypes (joins, topic changes, ...); other event types;
`app_rate_limited` notices.

A Slack message is identified by `"<channel>:<ts>"`. That is the inbound idempotency key (edits use
`"<channel>:<ts>:edit:<edited ts>"`, deletes `"<channel>:<ts>:delete"`, reactions the `event_id`) and
the `provider_message_id` of outbound deliveries, so a reply, reaction, edit or delete resolves to the
activity it refers to whether that message came from Slack or was posted by Converger. When the target is
unknown (sent before the channel existed), reactions, edits and deletes are kept as `event` activities.

The activity `sender` is the Slack user id (`U...`). Metadata carries `slack_channel`, `slack_ts`,
`slack_thread_ts`, `slack_team`, `slack_user`, `slack_event_type` (`message`, `app_mention`,
`message.message_changed`, ...), `slack_event_id` and `slack_channel_type`; a reaction adds
`reaction: {name, message_id}`, a button click `interactive_reply: {type, id, title, payload}`. The text is
Slack `mrkdwn` as sent, including mentions such as `<@U0123>`.

### Conversations

Inbound messages find their conversation through the participant ([participants](../concepts/participants.md)),
whose `external_id` depends on `conversation_scope`:

| `conversation_scope` | Participant `external_id` | One conversation per | Replies go to |
| --- | --- | --- | --- |
| `thread` (default) | `"<channel>:<thread root ts>"` | Slack thread; a top-level message starts a thread rooted at itself | that thread |
| `channel` | `"<channel>"` | Slack channel | the channel, top level |
| `user` | `"<channel>:<user>"` | user in a channel | the channel, top level |

Changing the scope of a live channel starts new conversations for new messages; existing participants
keep their ids. In the `thread` scope, a reaction joins the conversation of the reacted-to message when
Converger knows it.

### Files

A message with files gets one attachment per file (at most 10) with `contentType`, `name`, `size` and
`channelData: {provider: "slack", fileId, urlPrivate, urlPrivateDownload, permalink, fileAccess}`. Slack
file URLs are private: fetching them needs the bot token (`Authorization: Bearer <bot_token>`) and the
`files:read` scope.

With `download_files: true`, each file is downloaded during the webhook request (through `files.info`
first when Slack sent only a stub, `file_access: "check_file_info"`), checked against the upload size
limit and the tenant's MIME allowlist, and stored as a Converger upload. The attachment then gets
`contentUrl: "/api/v1/converger/attachments/<id>"` (see [storage](../storage.md)). A file that cannot be
downloaded keeps its Slack reference and a warning is logged. Downloads count against Slack's 3 second
budget; a slow one makes Slack retry, which is recognised as a duplicate. Asynchronous rehosting is a
follow-up.

## Outbound

### Target

The Slack channel and thread are taken from, in order:

1. activity metadata `slack_channel` and `slack_thread_ts`;
2. the conversation's participant on this channel (see the table above);
3. for an activity with `reply_to_id`, the channel and thread of the activity it replies to;
4. the config's default `channel` (top level).

So a bot or agent replying in a conversation started from Slack (for example a WebSocket client) needs no
Slack ids: the reply goes into the same thread. Without any channel the delivery fails **permanently**
(`no Slack channel: ...`).

### What is sent

`capabilities/0` declares `activity_types: ["message", "messageUpdate", "messageDelete"]`:

| Activity | Web API |
| --- | --- |
| `message` | `chat.postMessage` with `text`, `thread_ts` and, for card attachments, `blocks`; then the file attachments, see below |
| `messageUpdate` | `chat.update` of the Slack message of `reply_to_id`, with the new text and blocks |
| `messageDelete` | `chat.delete` of the Slack message of `reply_to_id` |

`messageUpdate` and `messageDelete` work only on messages this channel posted (Slack does not let a bot
change a user's message); for any other target they fail permanently. Other types follow
`unsupported_activities`: with `downgrade` (default) a `messageReaction` is sent as text
(`"<sender> reacted with <emoji>"`). Outbound reactions are a follow-up.

The delivery is marked `sent` with metadata `slack_channel`, `slack_ts`, `slack_thread_ts`, the
`provider_message_id` `"<channel>:<ts>"` and, with files, `slack_file_ids`.

### Cards as Block Kit

`application/vnd.converger.card.*` attachments (`{title, subtitle?, image?, text?, buttons?}`, see the
[protocol messages](../protocol/messages.md)) become Block Kit:

- a `section` with `*title*`, the subtitle and the text as `mrkdwn`, and the image as its accessory
  (an `image` block when there is no text);
- an `actions` block with one button per card button: a button with a `url` opens it, any other sends its
  `value` (JSON-encoded when it is not a string, the label when there is none) back as a `block_actions`
  interaction, which arrives as an inbound `message` (enable Interactivity).

Slack's limits are applied by truncation: 3000 characters per section, 75 per button label, 2000 per
value, 25 buttons per card and 50 blocks per message. `text` stays the notification fallback.

### Typed messages

The adapter renders typed messages ([#68](https://github.com/AimTune/converger/issues/68),
[messages.md section 5](../protocol/messages.md),
[ADR-0064](../adr/0064-per-channel-rendering-of-typed-messages-and-normalised-answers.md)) and declares
`message_types: text quick-reply buttons card carousel interrupt image file video audio`:

- `text` + `actions`, `quick-reply`, `buttons` and `interrupt` (without `tool` / `event`): a `section` with
  `data.text` (an interrupt's `payload.title`) and an `actions` block, one button per action (`action_id`
  `converger_a_<index>`); `url` actions open their link;
- `card`: a section as for card attachments, then its buttons; `carousel`: `data.text`, then one section and
  actions block per card;
- `image`, `file`, `video`, `audio`: uploaded as files (see below), the caption as the message text;
- `location`, `contact`, `genui` (when the stream is done) and unknown types: text.

A button's `value` is the answer key `a:<activity id>:<index>`; a click comes back as the normalised answer
([messages.md section 6](../protocol/messages.md)) with `metadata.action = {label, value, source: "button"}` and
`reply_to_id` on the typed message. A reply such as `2` within 24 hours of an actionable message picks its second
numbered action (`source: "numeric"`).

### Files (`files.uploadV2`)

Attachments with a `contentUrl` (other than cards) are sent as Slack files, in three steps:

1. for each file, the bytes are fetched, `files.getUploadURLExternal` returns an upload URL and the bytes
   are uploaded. Nothing is visible in Slack yet;
2. the text is posted with `chat.postMessage` (skipped for a message that has only files);
3. `files.completeUploadExternal` shares the files in the same channel and thread.

A `contentUrl` of a Converger upload (`/api/v1/converger/attachments/<id>`) is read from storage; any
other `http(s)` URL is fetched through the SSRF guard (private, loopback and link-local targets are
refused, as for [webhooks](../webhooks.md)). Files larger than the upload size limit fail permanently. A
failure in step 1 is retried without leaving anything in Slack; a failure in step 3 retries the whole
delivery and can post the text twice (a duplicate is preferred over a lost file).

### Errors and retries

Slack answers most failures with `200 {"ok": false, "error": "<code>"}`:

| Outcome | Classification |
| --- | --- |
| `ok: false` with `ratelimited`, `internal_error`, `fatal_error`, `service_unavailable`, `request_timeout` | retryable |
| `ok: false` with any other code (`invalid_auth`, `channel_not_found`, `not_in_channel`, `msg_too_long`, `cant_update_message`, ...) | permanent: dead-lettered after one attempt, `last_error` is `Slack chat.postMessage failed: <code>` |
| HTTP `429` | retryable; `Retry-After` sets the delay of the next attempt |
| HTTP `408`, `425`, `5xx`, transport errors | retryable |
| Other HTTP `4xx` | permanent |

The adapter's default request timeout is 10 s (`retry_policy/0`, overridable per channel). It defines no
default rate limit: Slack's `chat.postMessage` limit is about one message per second per Slack channel,
with bursts, which a per-Converger-channel limit cannot express; `429` responses are honoured instead.
Set the channel's `rate_limit` if one app serves a single busy channel. Tests inject Req options through
`config :converger, :slack_req_options`.

### Health probe

A `slack` channel without deliveries in the health window is probed with `auth.test` (5 s timeout, no
retry): a revoked or invalid token shows up as `degraded`. See [health probes](overview.md#health-probes).
