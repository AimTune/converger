---
title: Rich message vocabulary
sidebar_position: 2
description: Typed message payloads compatible with chativa and mekik/1, and how each channel downgrades them.
---

# Rich message vocabulary (Converger Protocol v1)

> **Status: draft for review (#68).** This page specifies the message types that travel as
> persistent message frames of [Converger Protocol v1](./v1.md): their names, `data` shapes,
> limits, the escape hatches, and how each channel adapter downgrades what it cannot render.
> The activity model underneath (a closed set of activity types, validated attachments, reactions,
> edits, deletes and replies) is **Implemented (#28)**, see
> [activities](../concepts/activities.md) and [ADR-0036](../adr/0036-rich-activity-model.md).
> Storing the typed message payloads of this page is **Implemented (#68)** (section 4,
> [ADR-0062](../adr/0062-typed-message-payloads-on-message-activities.md)); channels without a native
> renderer get a numbered-list text, native per-channel rendering and answer normalisation are
> **Implemented (#68)** (sections 5 and 6, [ADR-0064](../adr/0064-per-channel-rendering-of-typed-messages-and-normalised-answers.md)).

The schemas are in
[`priv/protocol/v1/messages/`](https://github.com/AimTune/converger/tree/main/priv/protocol/v1/messages);
they are the source of truth for SDK type generation (#67) and for chativa's schema-drift tests.

## 1. Rules

1. **chativa-compatible names and shapes.** Where chativa already has a renderer (`text`,
   `quick-reply`, `buttons`, `card`, `carousel`, `image`, `file`, `video`, `genui`) the type name
   and `data` fields are chativa's (and mekik's typed `mekik.messages.*` catalog), unchanged.
   Converger only **adds optional fields**, which renderers ignore.
2. **One envelope.** Every message is a message frame: `{type, id, seq, from, data, timestamp}`
   plus the optional Converger fields of [v1.md section 5.1](./v1.md#51-persistent-and-transient-frames).
   A client sends the same `type` and `data` (without `id`, `seq`, `from`, `timestamp`).
3. **`data.text` is the universal fallback.** Any message type MAY carry `data.text`, a plain-text
   rendering. chativa renders an unknown type with its text renderer, which shows `data.text`, so
   senders SHOULD set it on types chativa does not render yet (`audio`, `location`, `contact`)
   and on custom types.
4. **`extensions` is the escape hatch.** `data.extensions` is an object keyed by namespace
   (`whatsapp`, `telegram`, `email`, `x-yourcompany`, ...). An adapter MAY use its own namespace
   to send provider features this vocabulary does not model (a WhatsApp template, Telegram
   `parse_mode`). Renderers and other adapters ignore it. At most 8 KiB.
5. **Open renderer-named types.** A `type` that is not in this vocabulary and not a reserved
   frame type ([v1.md section 5.5](./v1.md#55-unknown-frames-and-reserved-names)) is a valid
   message (mekik/1 section 4.5): lowercase letters, digits, `_` and `-`, up to 64 characters, with
   an object `data`. Converger stores and relays it without validating `data`, counts it in the
   `converger.activities.unknown_type` metric, and downgrades it to `data.text` on channels
   (or skips it when there is none).
6. **Limits.** A message frame is at most 128 KiB; `text` at most 64 KiB of UTF-8; other prose
   fields at most 4 KiB; labels at most 256 characters; at most 10 actions, buttons or cards. The
   schemas carry every limit. Channel limits are stricter and handled by the downgrade (section 5).

Actions (chips and buttons) everywhere share one shape, the union of chativa's and mekik's
`MessageAction`:

| field | type | meaning |
| --- | --- | --- |
| `label` | string, required | visible text |
| `value` | any JSON, optional | the answer; omitted means `label`. Outside interrupts it SHOULD be a string, because chativa sends it as the reply text |
| `url` | URL, optional | the action opens this link instead of answering |

## 2. Message types

### text

`{text, urls?, previewVariant?, streaming?, attachments?, extensions?}`. Chips go in the
frame-level `actions` field: chativa's `parseChatFrame` turns a bot `text` frame with `actions`
into a quick-reply with the chips kept after the tap. `attachments` only carries legacy
Converger attachments (section 7).

```json schema=frames/server/message.schema.json
{ "type": "text", "id": "m-1", "seq": 3, "from": "bot", "data": { "text": "Your order shipped. Track it?" }, "actions": [{ "label": "Track", "value": "/track ORD-42" }, { "label": "No thanks" }], "timestamp": 1750000000000 }
```

### quick-reply

`{text, actions, keepActions?}`: a prompt with inline chips.

```json schema=frames/server/message.schema.json
{ "type": "quick-reply", "id": "m-2", "seq": 4, "from": "bot", "data": { "text": "Was this helpful?", "actions": [{ "label": "Yes", "value": "yes" }, { "label": "No", "value": "no" }] }, "timestamp": 1750000000000 }
```

### buttons

`{text?, persistent?, buttons}`: a vertical list of buttons. One-time by default; with
`persistent: true` the user can change the selection.

```json schema=frames/server/message.schema.json
{ "type": "buttons", "id": "m-3", "seq": 5, "from": "bot", "data": { "text": "How can I help?", "buttons": [{ "label": "Track an order", "value": "/track" }, { "label": "Talk to a human", "value": "/agent" }, { "label": "Pricing", "url": "https://example.com/pricing" }] }, "timestamp": 1750000000000 }
```

### card

`{title, subtitle?, image?, text?, buttons?}`. `text` (the card body) is a Converger addition;
chativa's card renderer does not show it yet, so essentials belong in `title` and `subtitle`. Card
actions are called `buttons`, as in chativa and mekik.

```json schema=frames/server/message.schema.json
{ "type": "card", "id": "card-ORD-1", "seq": 6, "from": "bot", "data": { "title": "ORD-1", "subtitle": "249.90 USD", "image": "https://example.com/ord-1.png", "buttons": [{ "label": "Track", "value": "/track ORD-1" }] }, "timestamp": 1750000000000 }
```

### carousel

`{text?, cards}`: 1 to 10 cards, each a `card` payload.

```json schema=frames/server/message.schema.json
{ "type": "carousel", "id": "m-5", "seq": 7, "from": "bot", "data": { "cards": [{ "title": "Basic", "subtitle": "9 USD / month", "buttons": [{ "label": "Pick", "value": "basic" }] }, { "title": "Pro", "subtitle": "29 USD / month", "buttons": [{ "label": "Pick", "value": "pro" }] }] }, "timestamp": 1750000000000 }
```

### image, file, video, audio

Media point at a URL: an absolute `https` URL or a Converger attachment URL from
`POST /api/v1/converger/conversations/ID/upload` (**Implemented**). chativa fields: image
`{src, alt?, caption?}`, file `{url, name, size?, mimeType?}`, video `{src, poster?, caption?}`.
Converger adds `mimeType`, `size`, `width`, `height`, `durationMs` where they apply. `audio`
`{src, caption?, mimeType?, size?, durationMs?, voice?}` is Converger-defined, modelled on `video`.

```json schema=frames/server/message.schema.json
{ "type": "image", "id": "m-6", "seq": 8, "from": "bot", "data": { "src": "https://example.test/receipt.png", "caption": "Your receipt" }, "timestamp": 1750000000000 }
```

```json schema=frames/server/message.schema.json
{ "type": "file", "id": "m-7", "seq": 9, "from": "user", "data": { "url": "/api/v1/converger/attachments/9b7c4c1e-5a5f-4a0e-9a53-0e8d2f3f1a10", "name": "invoice.pdf", "size": 48213, "mimeType": "application/pdf" }, "timestamp": 1750000000000 }
```

```json schema=frames/server/message.schema.json
{ "type": "video", "id": "m-8", "seq": 10, "from": "bot", "data": { "src": "https://example.com/howto.mp4", "poster": "https://example.com/howto.jpg", "caption": "How to reset your router" }, "timestamp": 1750000000000 }
```

```json schema=frames/server/message.schema.json
{ "type": "audio", "id": "m-9", "seq": 11, "from": "user", "data": { "src": "/api/v1/converger/attachments/0f2b1a77-3c55-4a0d-8d0e-6c1f8f6e9c21", "mimeType": "audio/ogg", "voice": true, "durationMs": 4200, "text": "[voice message]" }, "timestamp": 1750000000000 }
```

### location

`{latitude, longitude, name?, address?, url?}`, Converger-defined.

```json schema=frames/server/message.schema.json
{ "type": "location", "id": "m-10", "seq": 12, "from": "user", "data": { "latitude": 41.0082, "longitude": 28.9784, "name": "Head office", "text": "Head office (41.0082, 28.9784)" }, "timestamp": 1750000000000 }
```

### contact

`{name, organization?, phones?: [{number, label?}], emails?: [{address, label?}], url?}`,
Converger-defined; the arrays map onto WhatsApp contacts and vCard.

```json schema=frames/server/message.schema.json
{ "type": "contact", "id": "m-11", "seq": 13, "from": "bot", "data": { "name": "Support desk", "phones": [{ "number": "+90 212 000 00 00", "label": "work" }], "text": "Support desk: +90 212 000 00 00" }, "timestamp": 1750000000000 }
```

## 3. Agent-runtime frames

These are mekik/1 frames, adopted unchanged ([v1.md section 14](./v1.md#14-mekik1-compatibility)).
They are persistent but not message frames: they have no `from` or `timestamp`.

### tool_call

`{type, seq, data: ToolCall}`, upserted by `data.id` as it advances `running` to `completed` or
`error`. Never delivered to end-user channels unless the channel enables `show_tool_traces`.

```json schema=frames/server/tool_call.schema.json
{ "type": "tool_call", "seq": 11, "data": { "id": "t1", "name": "get_order", "status": "running", "params": { "id": "ORD-42" } } }
```

### genui

`{type, seq, streamId, done, chunk}`; `chunk` is chativa's `AIChunk` (`ui`, `text` or `event`). A
chunk whose id is already on screen updates that element in place.

```json schema=frames/server/genui.schema.json
{ "type": "genui", "seq": 13, "streamId": "stream-1", "done": false, "chunk": { "type": "ui", "component": "order-card", "props": { "id": "ORD-42", "total": 249.9 }, "id": 1 } }
```

### interrupt and interrupt_resolved

`interrupt {type, seq, id, data: {payload, ui?, actions?, event?, tool?}}` pauses the bot until a
`resume` answers it; `interrupt_resolved {type, seq, id, data: {answer?}}` closes it for every tab
and every replay. Without `ui`, `event` or `tool` a client offers `actions` as chips, or default
Approve and Cancel.

```json schema=frames/server/interrupt.schema.json
{ "type": "interrupt", "seq": 7, "id": "approve/0:interrupt#0", "data": { "payload": { "title": "249.90 TRY refund" }, "actions": [{ "label": "Approve", "value": { "approved": true } }, { "label": "Reject", "value": { "approved": false } }] } }
```

```json schema=frames/server/interrupt_resolved.schema.json
{ "type": "interrupt_resolved", "seq": 8, "id": "approve/0:interrupt#0", "data": { "answer": { "approved": true } } }
```

`skill` (mekik/1 section 12.5) is adopted the same way.

## 4. Storage: **Implemented (#68)**

- `activities.type` stays Converger's closed activity vocabulary (#28): an unknown activity type is
  rejected with `422`. A frame of any message type, and a mekik-native frame (`tool_call`, `genui`,
  `interrupt`, `interrupt_resolved`, `skill`), is stored as a `message` activity with
  `message_type` (the frame type) and `payload` (the typed payload), [ADR-0062](../adr/0062-typed-message-payloads-on-message-activities.md).
  A `text` frame whose `data` has only `text` (and `attachments`) and no `actions` keeps the plain
  columns (`message_type` is null), as before.
- The typed payload is stored losslessly. For message frames it is every top-level field except
  `type`, `seq` and the envelope the server owns (`from`, `timestamp`, `sender`, `metadata`,
  `clientId`, `replyTo`, `meta`): `data`, `actions` and any unknown field. A bot's message `id` is
  kept; a client's `id` is its clientId and is not. For mekik-native frames it is every top-level field
  except `type` and `seq` (`genui` keeps `streamId`, `done` and `chunk` at the top level).
  Re-serialising a stored frame gives canonical JSON identical to what was received, except `seq`
  and, on message frames, the server's `timestamp` and the additive `sender`. The vendored mekik/1
  fixtures are tested this way (`test/protocol/mekik_storage_round_trip_test.exs`, #63).
- `activities.text` stays a denormalised column for search and channel fallbacks. When the sender
  gives no `text` it is filled from `data.text`, a caption, a title, the action labels, or an
  interrupt's `payload.title`. Tool traces, GenUI chunks, skills and resolved interrupts have none.
- Known types are validated against these schemas on write; failures draw `invalid_message`
  (WebSocket) or `422 invalid_message` (REST) with per-field `details`, for example
  `{"payload": ["data/buttons/0: property 'label' is required"]}`. A whole frame is at most 128 KiB
  (`max_payload_bytes`). Unknown renderer-named types are stored opaquely (rule 5) and counted in
  `converger.activities.unknown_type.count`.
- Clients send rich types as frames on the native endpoint and the Phoenix binding (`frame` event).
  The REST APIs take `messageType` and `payload` (Converger API) or `message_type` and `payload`
  (tenant API) next to `type: "message"`, and return them on every activity (null for plain
  messages).

```json schema=frames/client/message.schema.json
{ "type": "location", "clientId": "c-18", "data": { "latitude": 41.0082, "longitude": 28.9784, "name": "Head office" } }
```

## 5. Per-channel downgrade matrix: **Implemented (#68)**, with the exceptions listed below

Each adapter declares what it renders natively through `capabilities/0`: activity types since #28
(an `activity_types: [...]` entry, unsupported types downgraded to text or skipped per channel), and
message types with a `message_types: [...]` entry (or `:all`). Without one, an adapter that lists its
`activity_types` (an end-user channel) renders no message type natively, and every other adapter
(WebSocket, webhook, brokers, HTTP pull) receives typed messages as they are
([ADR-0064](../adr/0064-per-channel-rendering-of-typed-messages-and-normalised-answers.md)).

On an end-user channel the pipeline (`Converger.Activities.Downgrade`) decides per typed message:

- `tool_call`: only with `show_tool_traces`, as a `name: status` line;
- `genui`: nothing until the stream's `done` chunk, then one text message with the latest content of
  each `text` chunk of the stream (a chunk id seen again replaces its element), joined by blank lines;
  `ui` and `event` chunks are never sent;
- `interrupt` with a `tool` or an `event`: skipped;
- a type the adapter declares: delivered natively. Media (`image`, `file`, `video`, `audio`),
  `location` and `contact` reach the adapter as the legacy attachment it already renders (`contentUrl`,
  `application/vnd.converger.location`, `application/vnd.converger.contacts`); actionable types keep
  their `message_type` and `payload`;
- anything else: a plain `message` with the text rendering: the prompt, the answerable actions as a
  numbered list (`1. Track an order`), links as `label: url`, a card as its title, subtitle, text and
  image link, a carousel one such block per card (numbering continues), media as caption and link,
  location as name and map link, contact as name and numbers; else the stored text fallback (section 4),
  or nothing.

Native buttons carry an opaque answer key `a:<activity id>:<index>` (at most 41 bytes) as the button
id, row id, `callback_data` or button value; the action value stays in the stored payload and the
answer is resolved from it (section 6).

The target matrix:

| type | web (chativa) | WhatsApp | Telegram | email | SMS |
| --- | --- | --- | --- | --- | --- |
| `text` + `actions` | quick-reply chips | 1 to 3 actions: reply buttons; 4 to 10: list message; more: numbered text | inline keyboard | text + numbered list; `url` actions as links | text + numbered list |
| `quick-reply` | native | as `text` + `actions` | inline keyboard (or reply keyboard via `extensions.telegram`) | numbered list | numbered list |
| `buttons` | native | as `text` + `actions` | inline keyboard, one button per row | numbered list, links as links | numbered list |
| `card` | native | image with caption (`title`, `subtitle`, `text`) then the buttons as reply buttons or a list | `sendPhoto` with caption and inline keyboard | HTML card with links | `title` - `subtitle`, then a numbered list; image as a link |
| `carousel` | native | one card message per card (at most 10) or a list message of titles | one photo message per card, or a media group followed by a keyboard | HTML grid | numbered list of titles |
| `image` | native | image message | `sendPhoto` | inline image | link (MMS where supported) |
| `file` | native | document message | `sendDocument` | attachment | link |
| `video` | native | video message | `sendVideo` | link with poster | link |
| `audio` | `data.text` fallback until chativa renders audio | audio message (voice note when `voice`) | `sendVoice` or `sendAudio` | attachment | link |
| `location` | `data.text` fallback | location message | `sendLocation` | map link | `name` + map link |
| `contact` | `data.text` fallback | contacts message | `sendContact` | vCard attachment | name + numbers |
| `tool_call` | native trace | not delivered | not delivered | not delivered | not delivered |
| `genui` | native | text chunks joined into one text message when the stream is `done`; `ui` chunks skipped | same as WhatsApp | same as WhatsApp | same as WhatsApp |
| `interrupt` | native (form or chips) | `actions` as for `text` + `actions`; `payload.title` or `data.text` as the prompt; skipped when it has `tool` or `event` | same rule | same rule | same rule |
| unknown type | `data.text` | `data.text`, else skipped | `data.text`, else skipped | `data.text`, else skipped | `data.text`, else skipped |


### What each channel does today

| channel | `message_types` | rendering |
| --- | --- | --- |
| WebSocket, webhook, brokers, HTTP pull | `:all` | the typed message as it is |
| WhatsApp Cloud (`whatsapp_meta`) and Infobip (`whatsapp_infobip`) | actionable types, media, `location`, `contact` | 1 to 3 answerable actions: reply buttons; 4 to 10: a list message (button `Options`, row titles cut to 24 characters with the full label, up to 72, as the row description); more: numbered text. Links are appended to the body as `label: url`; the body is the prompt, else the stored fallback, cut to 1024. A card is its image (no caption) then its text with its buttons; a card without actions is its image with the text as caption (or the text alone). A carousel is its `data.text`, then one card after the other (at most 10). Media, location and contacts as messages; audio is an audio message (no voice-note flag) |
| Telegram | actionable types, media, `location`, `contact` | the prompt with an inline keyboard, one button per row, links as URL buttons; a card is `sendPhoto` with its text as caption (cut to 1024) and its keyboard, or a text message without image; a carousel is its `data.text`, then one message per card (no media groups). Media: `sendPhoto`, `sendDocument`, `sendVideo`, `sendAudio`, `sendVoice` (audio with `voice: true`), `sendLocation`, `sendContact` (one per contact with a phone number); the caption follows as a text message. No reply keyboards |
| Slack | actionable types, media | Block Kit: a `section` with the prompt and an `actions` block (labels cut to 75 characters, at most 25 buttons per block, 50 blocks); a card is a section with the image as accessory; a carousel one section and actions block per card. Media as uploaded files. Location and contact as text |
| Email | actionable types, media | the text rendering above as the text part, and HTML with paragraphs, an `<ol>` of the answerable actions, links and card images; answered by reply mail (a numeric reply). Media as attachments or links. Location and contact as text (no vCard) |
| Messenger, Instagram, Viber, Discord, Teams | media | media as their file attachments; everything else as the text rendering (numbered list), not as native quick replies or buttons |
| SMS (Twilio, Vonage) | none | the text rendering, media as links (no MMS for typed media) |

`tool_call` is shown on end-user channels only when the channel config enables
`show_tool_traces`, and then as a one-line text (`name: status`).

Provider limits the downgrade enforces (current published limits; adapters keep them in one place):

- **WhatsApp Cloud API**: at most 3 reply buttons with titles up to 20 characters; list messages
  with at most 10 rows, row titles up to 24 characters; interactive body up to 1024 characters.
  Longer labels are truncated with an ellipsis and the full label is kept for answer matching.
- **Telegram Bot API**: `callback_data` up to 64 bytes, so the adapter sends the opaque answer key
  and the action value stays server-side (in the stored payload); text up to 4096 characters, captions
  up to 1024.
- **Slack**: 3000 characters per section, 75 per button label, 25 buttons per actions block, 50
  blocks per message.
- **SMS**: 160 GSM-7 or 70 UCS-2 characters per segment; numbered lists are not shortened and URLs are
  not shortened by Converger.
- **Email**: HTML plus a plain-text alternative with a numbered list answered by reply mail. Buttons
  as links to a Converger reply endpoint (opt-in per channel) are **Planned (#68)**.

## 6. Answers come back as one shape: **Implemented (#68)**; interrupt `resume` **Planned (#68)**

Whatever the channel, a user's answer to an actionable message (a tapped chip, a list choice, an
inline keyboard press, a numeric reply "2", a reply mail) is normalised to an ordinary user turn:

```json schema=frames/client/message.schema.json
{ "type": "text", "data": { "text": "/track" }, "metadata": { "action": { "label": "Track an order", "value": "/track", "source": "button" } }, "replyTo": { "id": "m-3", "seq": 5 } }
```

- `data.text` is the action's `value` when it is a string, else its `label` (mekik/1 and chativa rule).
- `metadata.action` keeps `{label, value, source}`, with `source` one of `button`, `list`,
  `keyboard`, `numeric`, `email`, `web`; non-string values survive here. An action without `value`
  has its `label` as value.
- `replyTo` (`reply_to_id`) names the message that offered the action.
- A WhatsApp button (`button`) or list reply (`list`), a Telegram `callback_query` (`keyboard`) and a
  Slack `block_actions` click (`button`) carry the answer key of section 5. It must name an answerable
  action of an activity of the same conversation; otherwise the message keeps the provider's button
  title as its text, without `metadata.action`. Telegram callbacks with an answer key are `message`
  activities, other callbacks stay `event`s.
- A numeric reply (`2`, `2.` or `2)`, without attachments) on a channel that does not forward the
  canonical activity is matched against the most recent actionable message of the conversation sent
  by someone else, at most 24 hours old: the action with that number in its numbered list (links are
  not numbered). Out of range, older or without such a message, it is plain text. Its source is
  `numeric`, or `email` on an email channel.
- Web clients send the answer themselves: a `text` frame with `metadata.action` and `replyTo` is stored
  as it is.
- **Planned (#68):** if the answered message is, or belongs to, an open `interrupt`, the hub converts
  the answer to `resume {answers: {INTERRUPT_ID: value}}` for the bot channel (mekik-compatible) and
  stores the user turn as usual. Today the user turn is stored with `reply_to_id` on the interrupt
  activity and `metadata.action`. Otherwise it is an ordinary turn for the agent or bot.

So an agent sends one `buttons` message and receives the same normalised turn from the web widget,
WhatsApp, Telegram, Slack and email.

## 7. Today and migration

**Implemented** (#28): activities have a `type` (`message`, `event`, `typing`, `messageReaction`,
`messageUpdate`, `messageDelete`, `conversationUpdate`, `endOfConversation`, internal `deliveryReceipt`),
`text`, validated `attachments` (at most 10, 4 KiB each, `contentType` required), `metadata` (16 KiB)
and `replyToId` / `editedAt` / `deletedAt`. The Converger API shows them as
`{id, type, from, text, timestamp, attachments, conversationId, channelData, replyToId, editedAt, deletedAt}`
([`activity.schema.json`](https://github.com/AimTune/converger/blob/main/priv/protocol/v1/activity.schema.json)).
WhatsApp inbound buttons arrive as `message` activities with the button payload in `metadata`,
reactions as `messageReaction` referencing the reacted-to activity.

With #68 the activity model gains typed payloads (section 4). Existing `message` activities are
presented as `text` frames carrying their attachments ([v1.md section 5.4](./v1.md#54-activities-as-frames));
typed writes store `message_type` and `payload`. REST keeps the current shape and adds `messageType` and
`payload` as additive fields (null for plain messages).
