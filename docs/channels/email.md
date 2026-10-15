---
title: Email
description: Configuration, outbound threading, inbound provider webhooks, reply resolution, quote stripping and bounce handling of the email channel adapter.
sidebar_position: 2.7
---

The `email` channel type sends activities as email and turns inbound email into activities. Outbound mail goes
through [Swoosh](https://hexdocs.pm/swoosh) to SMTP, Amazon SES, SendGrid, Mailgun or Postmark. Inbound mail
arrives through the providers' parse webhooks or as a raw `message/rfc822` body. Bounces and spam complaints mark
the delivery `failed`.

A participant is a normalized email address (`Jane <Jane@Example.com>` and `jane@example.com` are the same
participant). A reply to an email Converger sent lands in the conversation that email came from, even when that
conversation started on another channel (for example an agent answering a web chat by email).

Source: [`lib/converger/channels/adapters/email.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/email.ex)
and [`lib/converger/channels/email/`](https://github.com/AimTune/converger/tree/main/lib/converger/channels/email).
Design: [ADR-0042](../adr/0042-email-adapter-threading-by-message-id-and-provider-webhooks.md).

## Configuration

| Key | Required | Meaning |
| --- | --- | --- |
| `provider` | yes | Outbound provider: `smtp`, `ses`, `sendgrid`, `mailgun` or `postmark`. |
| `from` | yes | Sender, `Support <support@example.com>` or a bare address. Its domain is the domain of the `Message-ID`s Converger generates. |
| `reply_to` | no | `Reply-To` header. |
| `subject_template` | no | Subject of an email that does not reply to an inbound email. `{{conversation_id}}` and `{{sender}}` are replaced. Default `New message`. |
| `inbound_provider` | no | `ses`, `sendgrid`, `mailgun`, `postmark` or `rfc822`. Defaults to `provider`, and to `rfc822` when `provider` is `smtp`. |
| `inbound_secret` | no (secret) | Password of the basic auth credentials in the webhook URL (`sendgrid`, `postmark`, `rfc822`). |
| `max_attachment_bytes` | no | Total size of the files attached to one outbound email. Default: the upload size limit ([storage](../storage.md)). API only. |
| `conversation_idle_timeout_seconds` | no | As for every inbound channel, see [ADR-0016](../adr/0016-participant-based-conversation-resolution.md). |

Provider credentials:

| Provider | Keys |
| --- | --- |
| `smtp` | `smtp_host` (required), `smtp_port` (default `587`), `smtp_username`, `password` (secret), `smtp_ssl` (`true` for implicit TLS on port 465; otherwise STARTTLS is required). Authentication is used when `smtp_username` is set. |
| `ses` | `aws_region`, `aws_access_key_id`, `aws_access_key_secret` (secret). Sent with `SendRawEmail`. |
| `sendgrid` | `api_key` (secret) |
| `mailgun` | `api_key` (secret, the private API key), `mailgun_domain`, `mailgun_region` (`us`, the default, or `eu`) |
| `postmark` | `api_key` (secret, the server token) |

Inbound authentication:

| Inbound provider | Key |
| --- | --- |
| `ses` | `ses_topic_arn` (required): the SNS topic of the receipt rule. Messages of any other topic are rejected. |
| `mailgun` | `mailgun_signing_secret` (required, secret): the HTTP webhook signing key. |
| `sendgrid`, `postmark`, `rfc822` | `inbound_secret` for basic auth, or the generic `x-converger-signature`. |

`validate_config/1` checks the provider names, the `from` address, the keys the chosen providers need and the
Mailgun region. The SMTP host goes through the same SSRF guard as webhook URLs
([ADR-0014](../adr/0014-webhook-ssrf-guard-and-outbound-signing.md)) when the channel is saved and again before
each send: a private, loopback or link-local host is rejected unless allowed by `config :converger, :webhook`.

Example (Postmark both ways):

```json
{
  "name": "support-mail",
  "type": "email",
  "mode": "duplex",
  "config": {
    "provider": "postmark",
    "from": "ACME Support <support@acme.example>",
    "api_key": "server-token",
    "inbound_secret": "a-long-random-password"
  }
}
```

The HTTP providers send through `Swoosh.ApiClient.Req` (`config :swoosh, :api_client`, set in `dev` and `prod`).

## Outbound

The adapter delivers activities of type `message`. Other types are downgraded to text or skipped
([activities](../concepts/activities.md#delivery-to-channels)).

**Recipient**, in order: the activity's `metadata.email_to`, `metadata.to`, the conversation's participant on this
channel, the sender of the latest inbound email of the conversation. Without one the delivery fails permanently.

**Message-ID.** Every email gets `<converger.<activity id>@<from domain>>`. The id is deterministic, so a retried
delivery sends the same id and the recipient's mail client can tell the copies apart. The delivery stores:

- `provider_message_id`: the id the provider returned (SES `MessageId`, SendGrid `X-Message-Id`, Mailgun `id`,
  Postmark `MessageID`, without angle brackets), or the generated `Message-ID` for SMTP. Status events are matched
  on it.
- `metadata.email_message_id`: the generated `Message-ID`.

**Threading.** When the conversation holds an inbound email (on any email channel), the email replies to the
latest one: `In-Reply-To` is its `Message-ID`, `References` its references plus that id (the last 20), and the
subject is `Re: <its subject>`.

**Subject**, in order: the activity's `metadata.email_subject`, `Re: <subject>` of the thread, the rendered
`subject_template`.

**Body.** A text part (the activity text, then a `name: url` line per linked attachment) and an HTML part (the
escaped text with line breaks, then a link per linked attachment).

**Typed messages** ([#68](https://github.com/AimTune/converger/issues/68),
[ADR-0064](../adr/0064-per-channel-rendering-of-typed-messages-and-normalised-answers.md)). The adapter declares
`message_types: text quick-reply buttons card carousel interrupt image file video audio`. A message with actions
(`text` + `actions`, `quick-reply`, `buttons`, `card`, `carousel`, `interrupt` without `tool` / `event`) is rendered
by `Converger.Channels.RichContent`: the text part is the prompt, the answerable actions as a numbered list
(`1. Track an order`) and `label: url` lines for links; the HTML part has the prompt as paragraphs, the actions as an
`<ol>`, links as links and card images inline. A carousel is one block per card, numbering continuing across cards.
The user answers by reply mail: a reply whose text is just a number (`2`) within 24 hours becomes the normalised
answer (`metadata.action` with `source: "email"`, `reply_to_id` on the offering message,
[messages.md section 6](../protocol/messages.md)). Media types are sent as attachments or links as above; location
and contact as text with a map link or the numbers; a GenUI stream as one email when it is done.

**Attachments.** An attachment whose `contentUrl` is a Converger upload of the channel's tenant
(`/api/v1/converger/attachments/:id`) is read from storage and attached, while the total stays under
`max_attachment_bytes`. Every other attachment, and uploads over the budget, are linked.

**Errors.** HTTP providers: `408`, `425`, `429` and `5xx` are retried, other statuses fail permanently. SES:
`Throttling`, `ServiceUnavailable`, `InternalFailure` and `RequestExpired` are retried, other error codes fail
permanently. SMTP: a permanent (`5xx`) failure is not retried; connection errors and temporary failures are.

## Inbound

Point the provider at the channel's inbound URL, `https://<host>/api/v1/channels/<channel id>/inbound`. Status
events can go to the same URL or to `.../status`. With basic auth, put the credentials in the URL:
`https://converger:<inbound_secret>@<host>/api/v1/channels/<channel id>/inbound` (any user name).

| Provider | Setup | What Converger reads |
| --- | --- | --- |
| Amazon SES | A receipt rule with an **SNS action** (encoding UTF-8 or Base64) publishing to a topic, and an HTTPS subscription of the topic to the inbound URL. For bounces, complaints and deliveries, set the identity's SNS notification topics (the same topic works). | SNS `Notification`s: `Received` carries the raw message in `content`; `Bounce`, `Complaint` and `Delivery` are status events. The `SubscriptionConfirmation` is confirmed automatically. An S3 action does not embed the message and is not supported. |
| SendGrid | Inbound Parse webhook (with or without "POST the raw, full MIME message"); Event Webhook for status events. | The raw `email` field, or `from`, `to`, `cc`, `subject`, `text`, `html`, `headers` and the `attachmentN` files. Event Webhook arrays (`delivered`, `open`, `bounce`, `dropped`, `spamreport`). |
| Mailgun | A route with `forward("<inbound URL>")` (or `store(notify=...)`); webhooks for `delivered`, `opened`, `permanent_fail` and `complained`. | `body-mime` when present, otherwise the parsed fields (`from`, `To`, `Cc`, `subject`, `Message-Id`, `In-Reply-To`, `References`, `body-plain`, `body-html`, `stripped-text`, `message-headers`, `attachment-N`). Webhook `event-data`; temporary failures are ignored because Mailgun retries them. |
| Postmark | Inbound webhook of the inbound stream; Delivery, Bounce, Spam Complaint and Open webhooks. | `RawEmail` when included, otherwise `FromFull`, `ToFull`, `CcFull`, `Subject`, `Headers`, `TextBody`, `HtmlBody`, `StrippedTextReply` and `Attachments`. `RecordType` webhooks. |
| `rfc822` | Anything that can POST a raw message: an LMTP / SMTP bridge, a mail server pipe, a script. | The request body (`Content-Type: message/rfc822` or any type other than JSON, form or multipart), up to the upload size limit plus 1 MB. A JSON or form body with a `raw` or `email` field works too. |

Every provider's inbound request is answered `200` once handled (`:provider_ack`), so a message rejected
permanently is not retried for days.

### Signatures

- **SES (SNS).** The request is rejected (`401`) unless its `TopicArn` is `ses_topic_arn`, its `SigningCertURL` is an
  `https://sns.<region>.amazonaws.com/....pem` URL and the RSA signature (`SignatureVersion` 1 or 2) verifies over
  the canonical SNS string. AWS signs messages of every topic, so the topic check is what ties the endpoint to your
  account. Certificates are cached per URL.
- **Mailgun.** `signature` is `HMAC-SHA256(mailgun_signing_secret, timestamp + token)`, read from the form fields of
  a route or the `signature` object of a webhook. A request without a valid signature gets `401`, whatever
  `require_signature` says.
- **SendGrid, Postmark, rfc822.** Basic auth with `inbound_secret` (a wrong password gets `401`), or the generic
  `x-converger-signature` over the raw body. A request with neither is subject to the channel's
  `require_signature` setting ([inbound signatures](overview.md#inbound-signatures)). Multipart bodies (SendGrid)
  are not available raw, so use basic auth there.

### Message mapping

| Activity field | Value |
| --- | --- |
| `sender`, participant `external_id` | The normalized `From` address. The display name becomes the participant's `display_name`. |
| `text` | The reply without quoted history and signature: the provider's stripped text when it has one (Mailgun `stripped-text`, Postmark `StrippedTextReply`), otherwise the plain-text part (or the HTML part converted to text) cut by the [reply parser](#quote-and-signature-stripping). At most 60,000 bytes. |
| `attachments` | Each attached file is stored as a Converger upload of the tenant (size limit and MIME allowlist of [storage](../storage.md)) and referenced by its `contentUrl`. At most 10; files that are rejected or over the count are listed in `metadata.email.skipped_attachments`. |
| `idempotency_key` | The `Message-ID`, without angle brackets. A webhook delivered twice creates one activity, and stores its files once. |
| `reply_to_id` | The activity of the `In-Reply-To` message, when it is in the same conversation. |
| `metadata.email` | `message_id`, `subject`, `from`, `from_name`, `to`, `cc` (20 each), `in_reply_to`, `references` (last 20), `provider`, `auto_submitted` (an auto-reply), `skipped_attachments`. |
| `metadata.channelData` | When stripping removed something: `provider`, `fullText` (the unstripped text, at most 8,000 bytes) and `fullTextTruncated`. |

The raw MIME message and the HTML part are not stored on the activity: the activity metadata is limited to 16 KB.

Inbound email whose `From` is the channel's own `from` address (a copy of an outbound email, a forwarding loop) and
email without a `From` address are skipped.

### Reply resolution

An inbound email carries the ids of the messages it answers in `In-Reply-To` and `References`. The adapter passes
them to `Converger.Inbound` as `thread_refs` (each id, and its local part for providers that rewrite the
`Message-ID`: SES sends `<ses-id@email.amazonses.com>`) and `thread_activity_ids` (activity ids decoded from
Converger's own `Message-ID`s). The conversation is, in order:

1. the active conversation of the first referenced message that went through **this channel**: an inbound email
   (by idempotency key) or an outbound one (by its delivery's provider message id, or by the activity id of its
   `Message-ID` with a delivery on this channel), whatever channel that conversation started on;
2. the sender's active conversation on the channel, or a new one ([ADR-0016](../adr/0016-participant-based-conversation-resolution.md)).

A reply to a closed or expired conversation starts a new one. Only messages that went through the channel count,
so a forged `In-Reply-To` cannot put a message into a conversation the sender never received mail from.

When the reply joins another channel's conversation, its sender is also recorded as a participant of the email
channel. The pipeline never delivers a message to a channel on which its sender is a participant, so a routing rule
from the web chat channel to the email channel mails the agent's answers to the customer but not the customer's own
reply.

### Quote and signature stripping

`Converger.Channels.Email.ReplyParser` cuts the text at the first line that starts quoted history:

- an attribution line: `On <date>, <name> wrote:` (also wrapped over two lines), and the German (`Am ... schrieb`),
  French (`Le ... a écrit :`), Spanish (`El ... escribió:`), Dutch (`Op ... geschreven:`) and Turkish
  (`... şunu yazdı:`) forms;
- an Outlook header block (`From:` followed by `Sent:` or `Date:`), `-----Original Message-----`,
  `---------- Forwarded message ----------` or a line of underscores;
- a `>` quoted line;

and at the first signature marker: the `-- ` delimiter, `Sent from my ...` or `Get Outlook for ...`. When nothing
would be left, the whole text is kept.

## Bounces, complaints and receipts

| Event | Delivery status | `last_error` |
| --- | --- | --- |
| SES `Delivery`, SendGrid `delivered`, Mailgun `delivered`, Postmark `Delivery` | `delivered` | |
| SendGrid `open`, Mailgun `opened`, Postmark `Open` (open tracking) | `read` | |
| SES `Bounce` | `failed` | `bounce: <bounceType>: <bounceSubType>: <diagnosticCode>` |
| SendGrid `bounce`, `dropped` | `failed` | `<type>: <reason>` |
| Mailgun `failed` with `severity: permanent` | `failed` | `bounce: <delivery-status description or message>` |
| Postmark `Bounce` | `failed` | `bounce: <Type>: <Description>` |
| SES `Complaint`, SendGrid `spamreport`, Mailgun `complained`, Postmark `SpamComplaint` | `failed` | `complaint[: <feedback type>]` |
| A delivery status notification received as mail (`multipart/report; report-type=delivery-status`), any inbound provider | `failed` | `bounce: <Status>: <Diagnostic-Code>` |

Events are matched to deliveries by provider message id on the reporting channel. SendGrid's `sg_message_id` is cut
at the first `.` to match the `X-Message-Id` stored when sending. A delivery status notification is matched by the
`Message-ID` of the original message in its `text/rfc822-headers` or `message/rfc822` part, which is the
`provider_message_id` of SMTP deliveries. A failure after `delivered` still marks the delivery `failed` (a late
bounce or a complaint); a status never moves back from `read`.

## Limitations

- No health probe: SMTP and the HTTP providers have no cheap "is this account valid" call shared by all of them.
  Channel health comes from the delivery failure rate.
- SES inbound needs the SNS action, which embeds messages up to 150 KB. Larger messages need an S3 action, which is
  not supported.
- The SMTP host is checked against the SSRF guard, but the connection is not pinned to the checked address
  (unlike webhook requests).
- SendGrid's signed Event Webhook (ECDSA) and Postmark's IP allowlist are not checked; use basic auth.
- Outbound email is plain: the HTML part is the escaped text; typed messages add numbered lists, links and card
  images, but there is no styled card layout, and card attachments are downgraded to text. Buttons as links to a
  Converger reply endpoint are Planned ([#68](https://github.com/AimTune/converger/issues/68)).

## Testing

`config :converger, :email_swoosh_adapter` replaces the provider's Swoosh adapter for every email channel (the test
config uses `Swoosh.Adapters.Test`, so sent mail arrives in the test process). `config :converger,
:email_req_options` adds `Req` options to the SNS certificate and subscription requests (`Req.Test` plugs). See
[`test/converger_web/controllers/email_inbound_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/email_inbound_test.exs).
