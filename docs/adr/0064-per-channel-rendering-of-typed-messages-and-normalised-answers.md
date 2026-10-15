---
title: "ADR-0064: Per-channel rendering of typed messages and normalised answers"
sidebar_label: "0064 Channel rendering and answers"
description: End-user adapters render typed messages natively where their provider can (WhatsApp, Telegram, Slack, email), every other channel gets a numbered-list text, and every answer comes back as one normalised user turn.
---

| | |
| --- | --- |
| **Status** | Accepted; the `genui` joining rule (a chunk id seen again replaces its element) is superseded by [ADR-0072](0072-genui-text-runs-concatenate-when-joined.md) |
| **Date** | 2026-10-14 |
| **Issue** | [#68](https://github.com/AimTune/converger/issues/68) |
| **Pull request** | (this PR) |
| **Related** | [ADR-0036](0036-rich-activity-model.md), [ADR-0039](0039-whatsapp-rich-outbound-and-inbound-media-download.md), [ADR-0062](0062-typed-message-payloads-on-message-activities.md) |

## Context and problem statement

Since [ADR-0062](0062-typed-message-payloads-on-message-activities.md) a `message` activity can carry a typed
Protocol v1 message (`message_type` + `payload`): `buttons`, `quick-reply`, `card`, `carousel`, media,
`interrupt`, `genui` chunks and so on. End-user channels (WhatsApp, Telegram, Slack, email, SMS, ...) only
received its plain text fallback: an agent's buttons became `"Track | Pricing"` on WhatsApp, and there was no
way for the user to answer them other than typing. [#68](https://github.com/AimTune/converger/issues/68) asks
for the per-channel downgrade matrix of
[messages.md section 5](../protocol/messages.md) and for answers that reach the
agent in one shape whatever the channel (section 6).

Two hard constraints shape the answer path. Telegram's `callback_data` is at most 64 bytes, so a button cannot
carry an arbitrary action value (interrupt values are JSON objects). And a numeric reply (`"2"`) on SMS has no
reference to the message it answers.

## Decision drivers

- One answer shape for agents and bots, whatever the channel: `text`, `metadata.action`, `reply_to_id`.
- No new storage: the offering activity already holds the actions losslessly.
- Reuse what the adapters already render (legacy attachments, card buttons, Block Kit) instead of a second
  rendering path per adapter.
- Every channel gets something usable, even when its provider has no buttons.

## Considered options

1. **Opaque answer keys naming the stored activity**: every native button carries `a:<activity id>:<index>`,
   resolved by loading the activity; numeric replies match the latest actionable message.
2. **A server-side answer table** keyed by a short random token per button.
3. **Action values in the button payloads**, as the legacy card buttons do.

### Pros and cons of the options

#### Option 1

- Good, because the key is at most 41 bytes, fits every provider (Telegram 64, WhatsApp ids 256 / 200, Slack
  values 2000) and needs no new table or expiry.
- Good, because the value, the full label and non-string values come from the stored payload, so truncated
  labels and JSON values survive.
- Bad, because the key reveals the activity id to the provider; it is checked against the conversation, so it
  cannot be used to answer another conversation's message.

#### Option 2

- Good, because keys are shorter and opaque.
- Bad, because it adds a table, a write per rendered button and a retention policy for data the activity
  already holds.

#### Option 3

- Good, because it needs no lookup.
- Bad, because values over 64 bytes and non-string values cannot travel on Telegram, and truncated labels lose
  the full label.

## Decision

Chosen option: **"Opaque answer keys naming the stored activity"**.

- Adapters declare what they render natively in `capabilities/0` (`message_types:`). On end-user channels
  (adapters that list `activity_types`) `Converger.Activities.Downgrade` decides per typed message:
  - `tool_call`: only with `show_tool_traces` (unchanged);
  - `genui`: nothing until the stream's `done` chunk, then one text message with the latest content of each
    `text` chunk of the stream (a chunk id seen again replaces its element), joined by blank lines; `ui` and
    `event` chunks are never sent;
  - `interrupt` with a `tool` or an `event`: skipped (the client runtime answers those);
  - a declared type: delivered natively. Media (`image`, `file`, `video`, `audio`), `location` and `contact`
    are handed to the adapter as the legacy attachment it already renders (`contentUrl`,
    `application/vnd.converger.location`, `.contacts`); actionable types keep `message_type` and `payload`;
  - anything else: a plain `message` with the text rendering of `Converger.Channels.RichContent`: the prompt,
    the answerable actions as a numbered list (`1. Track an order`), links as `label: url`, cards as blocks,
    media as caption and link.
- `Converger.Channels.RichContent` is the one place that reads typed payloads for channels: the flat, indexed
  action list (`index` for answer keys, `number` for numbered lists; links have no number), prompts, cards, text
  and HTML rendering, attachments, answer keys and label truncation.
- Native renderers (WhatsApp Cloud and Infobip via `Converger.Channels.WhatsApp.Outbound`, Telegram, Slack Block
  Kit, email) put the answer key `a:<activity id>:<index>` in the button id, row id, `callback_data` or button
  value. Inbound parsers that see a key add `"answer" => %{"ref", "source", "label"}` to the message.
- `Converger.Inbound.Answers` runs on every inbound message before it becomes an activity: a key that names an
  answerable action of an activity of the same conversation becomes `text` (the action's string `value`, else
  its `label`), `metadata.action = {label, value, source}` and `reply_to_id`; an unresolvable key keeps the
  provider's label as text. A numeric reply on a channel that does not forward the canonical activity picks the
  numbered action of the most recent actionable message of the conversation sent by someone else, at most 24
  hours old; otherwise it stays plain text. Messages that already carry `metadata.action` (WebSocket clients)
  are left as they are.
- Interrupt answers keep `reply_to_id` on the interrupt activity; converting them to `resume` for the bot is a
  separate step of the bot relay.

## Consequences

### Positive

- An agent sends one `buttons` message; the web widget shows chips, WhatsApp interactive buttons, Telegram an
  inline keyboard, Slack buttons, email and SMS a numbered list, and every answer arrives in the same shape.
- No migration and no new state: answers resolve from the stored payload.
- Telegram also gained `sendVideo`, `sendAudio` / `sendVoice`, `sendLocation` and `sendContact` for legacy
  attachments.

### Negative and trade-offs

- A numeric reply that was meant as a number ("2" as a quantity) within 24 hours of an actionable message is
  read as an answer; the agent still sees `metadata.action.source = "numeric"` and can tell.
- A key resolves only while the offering activity exists and is in the same conversation: after retention
  removed it, or once a new conversation started, a tap arrives as plain text (the provider's label).
- Messenger, Instagram, Viber, Discord and Teams render actions as numbered text, not their native quick
  replies or buttons, and SMS (Twilio, Vonage) sends media as links in the text.
- GenUI streams cost one query per `done` chunk for each end-user channel planned.

### Follow-ups

- Native quick replies / buttons on Messenger, Instagram, Viber, Discord and Teams (their `ChatContent.buttons`
  path can carry answer keys).
- Interrupt answers forwarded to the bot as `resume` (bot relay, #68).
- Email reply links to a Converger endpoint (messages.md section 5, opt-in).

## Implementation

- `lib/converger/channels/rich_content.ex`: shared reading and rendering.
- `lib/converger/activities/downgrade.ex`: the per-type plan for end-user channels.
- `lib/converger/inbound/answers.ex`, called from `Converger.Inbound`: answer normalisation;
  `Converger.Activities.recent_typed_messages/5`, `get_conversation_activity/2`, `genui_stream_payloads/2`.
- `lib/converger/channels/whatsapp/outbound.ex` (both WhatsApp adapters), `adapters/telegram.ex`,
  `adapters/slack/blocks.ex`, `adapters/slack/events.ex`, `email/outbound.ex`, and the `message_types:` entries
  of every end-user adapter.
- Tests: `test/converger/channels/rich_content_test.exs`, `test/converger/inbound/answers_test.exs` (keys,
  numeric matching and the 24-hour window), `test/converger/activities/typed_message_test.exs` (downgrade and
  GenUI), and the adapter tests of WhatsApp, Telegram, Slack and email.

## Links

- [Rich message vocabulary](../protocol/messages.md), sections 5 and 6
- [Activities](../concepts/activities.md#typed-messages)
- [WhatsApp](../channels/whatsapp.md), [Telegram](../channels/telegram.md), [Slack](../channels/slack.md),
  [email](../channels/email.md), [SMS](../channels/sms.md)
