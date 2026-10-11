---
title: "ADR-0042: Email adapter with Message-ID threading, thread-first conversation resolution and provider webhooks"
sidebar_label: "0042 Email adapter"
description: The email channel sends through Swoosh with a deterministic Message-ID per activity, resolves a reply to the conversation of the message it answers before the participant's, and reads inbound mail and bounces from the providers' webhooks or a raw rfc822 body.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-12 |
| **Issue** | [#40](https://github.com/AimTune/converger/issues/40) |
| **Pull request** | [#133](https://github.com/AimTune/converger/pull/133) |
| **Related** | [ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md), [ADR-0015](0015-per-message-idempotent-inbound-batches.md), [ADR-0016](0016-participant-based-conversation-resolution.md), [ADR-0038](0038-adapter-behaviour-v2-and-config-driven-registry.md), [ADR-0040](0040-slack-adapter-message-refs-conversation-scopes-and-in-band-challenge.md) |

## Context and problem statement

Converger shipped `Swoosh` and an unused `Converger.Mailer`, but no email channel ([#40](https://github.com/AimTune/converger/issues/40)).
Email differs from the messaging channels in four ways that shape the adapter:

- **Threads, not chats.** A customer can hold several conversations with the same address at once, and a
  reply names the message it answers (`In-Reply-To`, `References`). The participant-based resolution of
  [ADR-0016](0016-participant-based-conversation-resolution.md) (one active conversation per participant and
  channel) would merge them. And the conversation an email belongs to may live on another channel, for example
  an agent answering a web chat by email: the acceptance criterion is "a reply to an outbound email lands in the
  originating conversation".
- **Many providers.** Tenants send through SMTP, Amazon SES, SendGrid, Mailgun or Postmark, and each provider
  has its own inbound format (SNS notifications, multipart Inbound Parse, Mailgun route fields, Postmark JSON)
  and its own authentication (an AWS signature, an HMAC in the payload, nothing but basic auth).
- **Providers rewrite ids.** SES replaces the `Message-ID` header with `<ses-id@email.amazonses.com>`; the other
  providers keep it but report status events by their own id.
- **Failures arrive late.** A bounce or a spam complaint can come minutes or days after the provider accepted
  the mail, as a webhook event or as a bounce email (a delivery status notification).

## Decision drivers

- A reply must reach the conversation of the message it answers, across channels.
- A forged header must not let a sender write into a conversation they were never part of.
- One adapter for all providers; no new infrastructure (no IMAP poller, no SMTP server in the release).
- Inbound webhooks are retried by every provider: duplicates must be harmless (ADR-0015).
- Bounces and complaints must end in `failed` with a readable reason.

## Considered options

For conversation resolution:

1. **Participant only** (ADR-0016 as is) - the reply goes to the sender's active conversation on the email channel.
2. **Plus-addressing** - send from `support+<conversation id>@domain` and resolve by the recipient address.
3. **Message-ID threading in `Converger.Inbound`** - the adapter passes the referenced message ids; inbound
   resolution tries them before the participant.

For outbound ids:

1. **Provider id only** as `provider_message_id`.
2. **Our own deterministic `Message-ID`** only.
3. **Both**: our `Message-ID` on the email (and in the delivery metadata), the provider's id as
   `provider_message_id`.

### Pros and cons of the options

#### Participant only

- Good, because nothing changes.
- Bad, because parallel threads with one address merge, and a reply to an email sent from a web chat
  conversation never reaches that conversation.

#### Plus-addressing

- Good, because it survives clients that drop `In-Reply-To`.
- Bad, because it needs catch-all or plus-address routing at every provider, exposes conversation ids in
  addresses that get copied around, and breaks when the customer starts a new mail to the address they saved.

#### Message-ID threading

- Good, because it is how mail clients thread; it needs no provider setup; the resolution step is generic
  (`thread_refs`, `thread_activity_ids`), so other threaded channels can use it.
- Bad, because a client that drops the headers (rare) falls back to participant resolution.

## Decision

**Message-ID threading**, with **both** ids:

- Every outbound email gets `Message-ID: <converger.<activity id>@<from domain>>`, deterministic so a retried
  delivery sends the same id. The delivery's `provider_message_id` is the provider's id (SES `MessageId`,
  SendGrid `X-Message-Id`, Mailgun `id`, Postmark `MessageID`), or our `Message-ID` for SMTP, because status
  events are reported by the provider id.
- An inbound email's parsed message carries `thread_refs` (the `In-Reply-To` and `References` ids, most recent
  first, each also as its local part, which is the SES id when SES rewrote the header) and `thread_activity_ids`
  (activity ids decoded from our own `Message-ID` form). `Converger.Inbound` resolves the conversation as:
  explicit `conversation_id`, then the active conversation of the first referenced message **that went through
  this channel** (an inbound activity by idempotency key, an outbound one by provider message id, or an
  activity with a delivery on the channel), then the participant (ADR-0016), then a new conversation. Restricting
  references to messages of the channel means a forged `In-Reply-To` only reaches conversations whose mail the
  sender could have received.
- A reply resolved into another channel's conversation records its sender as a participant of the email channel,
  and the pipeline's no-echo rule now drops every target channel on which the sender is a participant (not only
  the conversation participant's own channel). Without it, a routing rule from a web chat channel to the email
  channel would mail the customer their own reply. The cost: an agent whose `sender` string equals the address of
  a participant of the email channel would not get their messages mailed through that channel.
- An outbound email in a conversation that holds an inbound email replies to the latest one (`In-Reply-To`,
  `References`, `Re: <subject>`), so the customer's client threads it.

Inbound is one adapter with an `inbound_provider` (`ses`, `sendgrid`, `mailgun`, `postmark`, `rfc822`), chosen
by config rather than by sniffing the payload, so a request cannot pick the provider whose check is weakest.
Authentication per provider: the SNS signature **and** a configured topic ARN for SES (AWS signs every topic's
messages, so the signature alone proves nothing about the tenant), the payload HMAC for Mailgun (checked in
`parse_inbound/2` and `parse_status_update/2` because it lives in the form fields, not the raw body of a
multipart request), and basic auth or the generic signature for the others. The controller now reads bodies that
`Plug.Parsers` leaves unread (SNS posts JSON as `text/plain`, and raw `message/rfc822`) into `raw_body` and the
`_body` param, bounded like multipart uploads.

MIME parsing uses the [`mail`](https://hex.pm/packages/mail) library; quoted history and signatures are cut by
line heuristics (`talon`-style); attachments become tenant uploads. Bounce and complaint events, and delivery
status notifications received as mail, become `failed` status updates with the reason in `last_error`.

## Consequences

### Positive

- Replies land in the originating conversation for every provider, including SES's rewritten ids, and parallel
  threads with one customer stay apart.
- The thread step in `Converger.Inbound` is generic: any adapter can pass provider ids its messages reply to.
- Duplicate webhooks create one activity and store attachments once (the idempotency key is checked before
  files are stored).
- Delivery health and the dead-letter tools work for email like for the other external channels.

### Negative and trade-offs

- `gen_smtp` (needed by the SMTP and SES adapters of Swoosh) and `mail` are new dependencies.
- The raw message and HTML are not kept on the activity (metadata is limited to 16 KB); `channelData.fullText`
  keeps up to 8 KB of the unstripped text.
- The SMTP host is checked by the SSRF guard but the connection is not pinned to the checked address.
- SES inbound requires the SNS receipt action (messages up to 150 KB); the S3 action is not supported.
- Quote stripping is heuristic; unusual clients or languages keep part of the quote (the full text stays in
  `channelData`).

### Follow-ups

- Verify SendGrid's signed Event Webhook (ECDSA) natively.
- An SES S3 action reader, and an LMTP bridge for self-hosted mail (the `rfc822` endpoint is ready for it).
- Rendered HTML templates and cards as HTML.

## Implementation

- [`Converger.Channels.Adapters.Email`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/email.ex):
  config schema and validation, delivery, inbound mapping, authentication.
- [`Converger.Channels.Email`](https://github.com/AimTune/converger/tree/main/lib/converger/channels/email):
  `Address` (address and id normalization), `Mime` (MIME and delivery status parsing), `ReplyParser`,
  `Providers` (per-provider mail and events), `SNS` (signature, topic, subscription confirmation), `Outbound`
  (Swoosh email, threading headers, attachments, provider config).
- [`Converger.Inbound`](https://github.com/AimTune/converger/blob/main/lib/converger/inbound.ex): the thread
  resolution step; [`Converger.Deliveries.delivered_conversation_id/2`](https://github.com/AimTune/converger/blob/main/lib/converger/deliveries.ex).
- [`Converger.Pipeline`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline.ex): the no-echo rule over
  target channels (`Converger.Participants.channels_with_participant/2`).
- [`ConvergerWeb.InboundController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/inbound_controller.ex):
  `read_unparsed_body` plug.
- Tests: [`email_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/adapters/email_test.exs),
  [`parsing_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/email/parsing_test.exs) and
  [`email_inbound_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/email_inbound_test.exs)
  (end to end per provider: replies, duplicates, closed conversations, forged references, SNS signatures and
  subscription, Mailgun signatures, bounces and complaints).

## Links

- [Email](../channels/email.md), [Channels and adapters](../channels/overview.md), [Inbound API](../api/inbound.md)
- [RFC 5322 section 3.6.4](https://www.rfc-editor.org/rfc/rfc5322#section-3.6.4) (identification fields),
  [RFC 3464](https://www.rfc-editor.org/rfc/rfc3464) (delivery status notifications)
- [Verifying Amazon SNS message signatures](https://docs.aws.amazon.com/sns/latest/dg/sns-verify-signature-of-message.html)
