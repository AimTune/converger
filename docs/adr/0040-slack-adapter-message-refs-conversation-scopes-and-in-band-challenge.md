---
title: "ADR-0040: Slack adapter with channel:ts message refs, configurable conversation scopes and an in-band challenge callback"
sidebar_label: "0040 Slack adapter"
description: Slack messages are identified by "<channel>:<ts>", the participant external id selects a thread, channel or user conversation, url_verification is answered by a new optional inbound_challenge/2 callback, and files are staged before the message is posted.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-11 |
| **Issue** | [#39](https://github.com/AimTune/converger/issues/39) |
| **Pull request** | (this PR) |
| **Related** | [ADR-0009](0009-inbound-signature-scheme-and-per-channel-enforcement.md), [ADR-0015](0015-per-message-idempotent-inbound-batches.md), [ADR-0016](0016-participant-based-conversation-resolution.md), [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md), [ADR-0038](0038-adapter-behaviour-v2-and-config-driven-registry.md) |

## Context and problem statement

Issue [#39](https://github.com/AimTune/converger/issues/39) adds a `slack` channel: Events API callbacks
in, Web API calls out, verified with the app's signing secret. Slack differs from the WhatsApp providers
the adapter behaviour was shaped by in four ways that need a decision:

1. **Message identity.** A Slack message is identified by its `ts`, which is unique only within a Slack
   channel. Edits (`chat.update`), deletes (`chat.delete`), thread replies (`thread_ts`) and reactions
   (`item.ts`) all name a message by channel and `ts`. The same message can also arrive twice: as a
   `message` event and as an `app_mention` event, with different `event_id`s, and Slack retries any
   callback that is not answered with `2xx` within 3 seconds.
2. **What a conversation is.** One Slack app serves many channels and threads, and people talk in
   threads. Converger finds the conversation of an inbound message through the participant's
   `external_id` ([ADR-0016](0016-participant-based-conversation-resolution.md)), one active
   conversation per participant and channel. The issue asks for "conversation per Slack thread or per
   channel (configurable)" and a participant id built from channel and user.
3. **The handshake.** Slack verifies a Request URL with a signed `POST`
   `{"type": "url_verification", "challenge": "..."}` to the same URL as the events, and expects the
   challenge back. The only handshake hook, `verify_subscription/2`, answers a `GET` (Meta's
   `hub.challenge`).
4. **Files.** `files.upload` is retired; the replacement (`files.uploadV2` in Slack's SDKs) is three
   calls: get an upload URL, upload the bytes, complete the upload, which shares the files. The
   completion does not return the `ts` of the message it posts.

## Decision drivers

- No message is lost and none is duplicated by Slack's retries or by the `message` / `app_mention` pair.
- Replies, edits and deletes written by any client of a conversation must reach the right Slack
  thread, without the client knowing Slack ids.
- Reuse the participant model and the existing inbound path; no Slack-specific code outside the adapter
  other than generic behaviour callbacks.
- Signature checks run before anything else answers, including the handshake.

## Considered options

### Message identity

1. **`"<channel>:<ts>"` as the idempotency key of inbound messages and the provider message id of
   outbound deliveries** - one string resolves references in both directions.
2. **Slack `event_id` as the idempotency key** - unique per event, but the `app_mention` copy of a
   message gets a different id (duplicate activity), and edits / reactions name `ts`, not the event.
3. **`ts` alone** - collides across channels.

### Conversations

1. **Encode the scope in the participant `external_id`**: `"<channel>:<thread root ts>"` (thread),
   `"<channel>"` (channel) or `"<channel>:<user>"` (user), chosen by the channel config key
   `conversation_scope`; the Slack user is the activity `sender`.
2. **Participant = channel + user always, thread in metadata** - every thread of a user would land in
   one conversation, and a thread with several people in several conversations.
3. **A Slack-specific conversation lookup** - a second resolution path next to ADR-0016.

### Handshake

1. **A new optional callback `inbound_challenge/2`**, called by the inbound controller after the
   signature check and before parsing; `{:ok, body}` is returned as JSON.
2. **Answer from `parse_inbound/2`** - parsing returns messages, not responses; the controller would
   have to special-case a return value.
3. **A separate Slack route** - a second inbound endpoint and signature path for one provider.

### Outbound files

1. **Stage, post, share**: fetch and upload every file (invisible in Slack), post the text with
   `chat.postMessage` (which returns the `ts` the delivery is keyed by), then complete the upload into
   the same channel and thread.
2. **Text as the upload's `initial_comment`** - one visible step, but no `ts`, so the message could
   never be edited, deleted or replied to, and Block Kit is not available there.

## Decision

- **Message identity: option 1.** The inbound idempotency key and the outbound `provider_message_id`
  are both `"<channel>:<ts>"`. A retried callback and the `app_mention` of a `message` are duplicates of
  one activity ([ADR-0015](0015-per-message-idempotent-inbound-batches.md)); a thread reply, a reaction,
  an edit or a delete names its target as `reply_to_provider_id = "<channel>:<ts>"`, which resolves to
  an inbound activity or to an outbound one through its delivery. Edits are keyed by
  `"<channel>:<ts>:edit:<edited.ts>"` and deletes by `"<channel>:<ts>:delete"`, reactions by their
  `event_id`.
- **Conversations: option 1**, `conversation_scope` `thread` (default), `channel` or `user`. Outbound
  delivery reads the participant back: the part after `:` is a thread `ts` when it looks like one
  (`\d+.\d+`), else a user id. Precedence for the target is activity metadata (`slack_channel`,
  `slack_thread_ts`), the participant, the thread of the activity replied to, the config's default
  `channel`. A reaction names only channel and `ts`, not the thread, so in the thread scope it joins the
  conversation of the reacted-to activity when Converger knows it.
- **Handshake: option 1.** `inbound_challenge/2` is optional; without it nothing changes.
- **Files: option 1.** A failure while staging leaves nothing in Slack and is retried cleanly. A failure
  after the post (completion fails) is retried as a whole and can post the text twice; we accept a
  possible duplicate over a lost file.
- **Bots are ignored inbound** (`bot_id` or subtype `bot_message`), which drops Converger's own
  replies and avoids loops between bots. Unknown subtypes and event types are acknowledged and dropped.
- **Errors.** Slack answers most failures with `200 {"ok": false}`. `ratelimited`, `internal_error`,
  `fatal_error`, `service_unavailable` and `request_timeout` are retryable; other error codes are
  permanent. HTTP `429` honours `Retry-After` ([ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md)).
  The adapter declares `:provider_ack`, so handled requests always get `200` and Slack does not
  retry, or disable the subscription for, permanently rejected messages.

## Consequences

### Positive

- One reference format serves idempotency, threading, reactions, edits and deletes.
- Thread-per-conversation fits how Slack is used, and needs no change to conversation resolution.
- Any adapter with an in-band handshake (Slack today; Discord interactions or Teams later) can use
  `inbound_challenge/2`.

### Negative and trade-offs

- Changing `conversation_scope` on a live channel starts new conversations: existing participants keep
  their old external ids.
- In the thread scope, a reaction to a message Converger never saw starts a conversation for that
  message's `ts`, which may be a reply inside a thread (the event does not name the root).
- Inbound files are references by default. `download_files: true` stores them as Converger uploads
  inside the webhook request, which counts against Slack's 3 second budget; a slow download makes Slack
  retry, which idempotency absorbs.
- Messages from other bots are dropped too; integrations between bots through Converger need a config
  switch later.
- Slack does not let a bot edit or delete a user's message, so `messageUpdate` / `messageDelete` of an
  activity that did not come from this channel's deliveries fail permanently.

### Follow-ups

- Asynchronous rehosting of inbound files, outside the webhook request.
- Display names through `users.info` (with caching); today the participant has none.
- Outbound reactions (`reactions.add`), which need a mapping from emoji to Slack names.

## Implementation

- [`lib/converger/channels/adapters/slack.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/slack.ex):
  the adapter (config schema, outbound, signature, challenge, health probe).
- [`slack/events.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/slack/events.ex):
  Events API and `block_actions` parsing, conversation scopes.
- [`slack/api.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/slack/api.ex):
  Web API calls and error classification.
- [`slack/blocks.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/slack/blocks.ex):
  card attachments as Block Kit.
- [`slack/files.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/slack/files.ex):
  the three-step upload and inbound rehosting.
- `Converger.Channels.Adapter.inbound_challenge/2` and its call in `ConvergerWeb.InboundController.create/2`.
- Tests: `test/converger/channels/adapters/slack_test.exs` (parsing, signatures, Block Kit, errors) and
  `test/converger_web/controllers/slack_inbound_test.exs` (signed requests end to end, replay
  rejection, a WebSocket-side reply delivered into the Slack thread, edit and delete, files).

## Links

- [Slack channel](../channels/slack.md)
- [Channels and adapters](../channels/overview.md)
- Slack: [Verifying requests from Slack](https://api.slack.com/authentication/verifying-requests-from-slack),
  [Events API](https://api.slack.com/apis/events-api),
  [Uploading files](https://api.slack.com/messaging/files#uploading_files)
