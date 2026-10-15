---
title: "ADR-0039: WhatsApp rich outbound messages and synchronous inbound media download"
sidebar_label: "0039 WhatsApp media and templates"
description: One shared planner turns an activity into WhatsApp messages (template, media, interactive, location, contacts) for both providers, inbound media is downloaded into Converger storage before the activity is created, and templates are listed through a cached tenant endpoint.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-11 |
| **Issue** | [#37](https://github.com/AimTune/converger/issues/37) |
| **Pull request** | [#134](https://github.com/AimTune/converger/pull/134) |
| **Related** | [ADR-0007](0007-attachment-storage-with-hand-written-signing.md), [ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md), [ADR-0015](0015-per-message-idempotent-inbound-batches.md), [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md), [ADR-0036](0036-rich-activity-model.md), [ADR-0038](0038-adapter-behaviour-v2-and-config-driven-registry.md) |

## Context and problem statement

Both WhatsApp adapters sent every activity as `type: "text"`. Attachments were silently lost (an attachment-only
activity was sent with a `null` body), a message to a user who had not written in 24 hours failed without saying why,
and there was no way to send a template, the only message WhatsApp accepts outside that window. Inbound images, voice
notes and documents arrived as stubs carrying a provider media id that only the channel's credentials can resolve, and
that Meta turns into a download URL valid for a few minutes. Consumers of the activity (a bot behind a webhook channel,
a WebSocket client) had no file to show.

The issue asks for: outbound media, templates, interactive messages, location and contacts on both providers; inbound
media in Converger storage with a real `contentUrl`; template listing; and a non-retryable `outside_window` error.

## Decision drivers

- No message is lost: a failed media download must not drop or block the inbound message.
- Consumers get a usable `contentUrl` on the activity they receive, not a provider reference they cannot resolve.
- Meta and Infobip must render the same activity the same way; the rules should live in one place.
- Provider credentials are never sent to a URL taken from a webhook body without checking it.
- Files are stored with the same checks as client uploads (size, sniffed type, tenant allowlist).
- No new infrastructure and no schema change.

## Considered options

For outbound:

1. **A shared planner, provider renderers** - `Converger.Channels.WhatsApp.Outbound` turns an activity into a list of
   parts; each adapter renders the parts in its request shape.
2. **Each adapter maps activities itself** - two copies of the template, caption and card rules.
3. **One WhatsApp message per activity** - first attachment only, the rest dropped or rejected.

For inbound media:

4. **Synchronous download before the activity is created** - in the webhook request, through a new optional
   `fetch_media/2` adapter callback.
5. **Asynchronous download in an Oban job after creation** - the activity is created with a stub and rewritten later.
6. **Keep stubs** and leave downloading to consumers.

### Pros and cons of the options

#### Option 1: shared planner

- Good, because the caption, template and card rules are written and tested once.
- Good, because a third WhatsApp provider only writes renderers.
- Bad, because the planner's vocabulary (parts) is one more internal shape.

#### Option 2: per-adapter mapping

- Good, because each adapter is self-contained.
- Bad, because the rules drift between providers; the same activity would look different on Meta and Infobip.

#### Option 3: one message per activity

- Good, because one delivery is exactly one provider message.
- Bad, because activities may carry up to 10 attachments; dropping them is the bug being fixed, and rejecting them makes
  multi-attachment activities undeliverable on WhatsApp.

#### Option 4: synchronous download

- Good, because the activity is created with its final attachments: every channel, webhook and socket gets the
  `contentUrl` in the same delivery, and nothing is rewritten after the fact.
- Good, because the duplicate check runs first, so a re-delivered webhook does not download again.
- Bad, because the webhook response waits for the download (bounded by a 10 s timeout per file and the upload size
  limit).

#### Option 5: asynchronous download

- Good, because the webhook is acknowledged at once.
- Bad, because the activity has already been delivered with a stub by the time the file exists; consumers would need an
  update event and a second delivery, and activities are append-only (edits are new activities, ADR-0036).
- Bad, because Meta's download URL may expire before a backed-up queue gets to the job.

#### Option 6: keep stubs

- Good, because nothing changes.
- Bad, because consumers cannot resolve the media without the channel's credentials, which they must not have.

## Decision

Chosen options: **"A shared planner, provider renderers"** and **"Synchronous download before the activity is
created"**.

Outbound, `Converger.Channels.WhatsApp.Outbound.parts/1` decides what an activity becomes:

- `metadata.template` (`name`, `language`, `components`; Infobip may add `templateData`) is a template message, and the
  text and attachments are ignored.
- Otherwise each attachment is one message: `application/vnd.converger.card.buttons` and `.card.list` become
  interactive messages (validated: 1 to 3 buttons, 1 to 10 list rows), location and contacts attachments become their
  messages, and anything with a `contentUrl` or provider media id becomes image, video, audio or document by content
  type (`channelData.whatsappType` overrides, for stickers). The text is the caption of the first image, video or
  document or the body of the first interactive message, else a text message sent first.
- Media sources: a Converger upload (tenant-checked) is uploaded to Meta's Media API, and sent to Infobip as a signed
  storage or CDN URL (with local-disk storage there is none, so the delivery fails permanently with that reason); a
  provider media id is reused; any other `http(s)` URL is sent as a link.
- The parts are sent in order in one delivery attempt; the first message id is the `provider_message_id`, and every id
  is kept in the delivery metadata. A failure after the first part fails the delivery, and the retry resends the earlier
  parts (at-least-once).
- Meta error `131047` (more than 24 hours since the user's last message), synchronous or in a failed status, becomes a
  permanent `outside_window: ...` error that tells the caller to send a template.

Inbound, `Converger.Inbound.Media.store/3` runs after the duplicate check and conversation resolution, before
`create_client_activity/2`. For each attachment without `contentUrl` it calls the adapter's optional
`fetch_media/2`, stores the bytes with `Converger.Uploads.create_attachment/3`, and rewrites the attachment
(`contentUrl`, sniffed `contentType`, `size`). The stored file is linked to the activity, or deleted when the activity
is not created. A failure keeps the stub with `channelData.downloadError`. Downloads are streamed and stopped at the
upload size limit (`Converger.Channels.MediaDownload`). Meta resolves the media id with the access token; Infobip
fetches the webhook's media URL with the API key only when its host is the channel's `base_url` host. Channels opt out
with `download_media: false`.

Templates are listed by a second optional callback, `list_templates/1`, behind `GET /api/v1/channels/:id/templates`,
cached per node in ETS for 5 minutes (`Converger.Channels.Templates`). Meta needs a new optional config key, `waba_id`.

## Consequences

### Positive

- Attachments, templates, interactive messages, locations and contacts reach WhatsApp on both providers.
- Inbound media is a normal Converger attachment: authorized downloads, signed URLs and CDNs apply, and the bytes
  outlive the provider's retention.
- A message outside the 24-hour window is dead-lettered once with an actionable reason instead of being retried.
- The adapter behaviour gains two optional callbacks any channel can implement (Telegram, Slack and email media).

### Negative and trade-offs

- A media webhook is acknowledged later, by up to the download timeout per file. Very slow provider downloads end as
  stubs with `downloadError`, not as lost messages.
- Multi-part activities are at-least-once on WhatsApp: a partial failure resends the parts that were already sent.
- Infobip outbound media from uploads needs cloud storage or a CDN.
- Interactive messages use interim card content types until typed messages exist (#68).
- The template cache is per node; a channel update clears it only on the node that handled it, other nodes refresh
  within the TTL.

### Follow-ups

- [#68](https://github.com/AimTune/converger/issues/68): typed cards and quick replies replace the card attachments.
- Native outbound reactions, edits and quoted replies (`context.message_id`) on WhatsApp.
- Infobip's 24-hour window error code, once confirmed, mapped to `outside_window` like Meta's.

## Implementation

- Planner: [`lib/converger/channels/whatsapp/outbound.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/whatsapp/outbound.ex).
- Renderers, media upload, `fetch_media/2`, `list_templates/1`, `131047` mapping:
  [`whatsapp_meta.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/whatsapp_meta.ex) and
  [`whatsapp_infobip.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/whatsapp_infobip.ex).
- Callbacks and dispatch: `fetch_media/2`, `list_templates/1` in
  [`lib/converger/channels/adapter.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapter.ex).
- Inbound download: [`lib/converger/inbound/media.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/inbound/media.ex),
  called from `Converger.Inbound`; bounded download in
  [`lib/converger/channels/media_download.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/media_download.ex).
- Templates: [`lib/converger/channels/templates.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/templates.ex)
  and `ConvergerWeb.ChannelTemplateController`.
- Tests: `test/converger/channels/whatsapp/outbound_test.exs`,
  `test/converger_web/controllers/whatsapp_meta_media_test.exs` and
  `test/converger_web/controllers/whatsapp_infobip_media_test.exs` (Req.Test fixtures for both providers: upload and
  send of an image, inbound image download, templates, interactive messages, the 24-hour window).

## Links

- [WhatsApp channels](../channels/whatsapp.md)
- [Tenant API: channel message templates](../api/tenant-api.md#channel-message-templates)
- [Writing an adapter: inbound media](../channels/writing-an-adapter.md#inbound-media)
- [Storage: channel media](../storage.md#channel-media)
- [WhatsApp Cloud API: media](https://developers.facebook.com/docs/whatsapp/cloud-api/reference/media),
  [messages](https://developers.facebook.com/docs/whatsapp/cloud-api/reference/messages),
  [error codes](https://developers.facebook.com/docs/whatsapp/cloud-api/support/error-codes)
