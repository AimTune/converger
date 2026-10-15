---
title: SMS (Twilio, Vonage)
description: Configuration, outbound sending, inbound webhooks, delivery receipts, signature verification, E.164 numbers, segment limits and STOP / START opt-out of the Twilio and Vonage SMS adapters.
sidebar_position: 2.8
---

Two channel types send and receive SMS:

- `sms_twilio`: Twilio Programmable Messaging (SMS and MMS).
- `sms_vonage`: the Vonage Messages API (SMS).

Both are duplex. An inbound SMS creates or joins the sender's conversation (the participant is the sender's number in
E.164), a reply in that conversation is sent back to the number, and the provider's delivery receipts move the
delivery to `delivered` (or `failed`). A participant who texts `STOP` is opted out: later deliveries to them fail
immediately, without calling the provider, until they text `START`.

Source: [`lib/converger/channels/adapters/sms_twilio.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/sms_twilio.ex),
[`lib/converger/channels/adapters/sms_vonage.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/sms_vonage.ex)
and the shared [`lib/converger/channels/sms.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/sms.ex).
Design: [ADR-0045](../adr/0045-sms-adapters-opt-out-flag-and-twilio-signature-urls.md).

## Twilio (`sms_twilio`)

### Configuration

| Key | Required | Meaning |
| --- | --- | --- |
| `account_sid` | yes | Account SID (`AC...`). |
| `auth_token` | yes (secret) | Auth token. Authenticates API calls and signs webhooks (`X-Twilio-Signature`). |
| `from` | one of the two | Sender: a Twilio number in E.164, a short code or an alphanumeric sender id. |
| `messaging_service_sid` | one of the two | Send through a Messaging Service (`MG...`) instead of `from`. Wins when both are set. |
| `webhook_base_url` | no | The public base URL Twilio calls, when it is not the server's own URL (`PHX_HOST`). Used for the status callback URL and for signature checks. |
| `default_country_code` | no | Country code for national numbers (`0...`), for example `1` or `90`. |
| `max_segments` | no | Longest text, in segments, the channel sends. Default `10`. |
| `conversation_idle_timeout_seconds` | no | As for every inbound channel, see [ADR-0016](../adr/0016-participant-based-conversation-resolution.md). |

### Twilio console setup

On the phone number (or the Messaging Service), set **A message comes in** to `POST`
`https://<host>/api/v1/channels/<channel_id>/inbound`. Status callbacks need no setup: Converger sends
`StatusCallback=https://<host>/api/v1/channels/<channel_id>/status` with every message.

### Outbound

`POST https://api.twilio.com/2010-04-01/Accounts/<account_sid>/Messages.json`, form encoded, basic auth
`account_sid:auth_token`, with `To`, `Body`, `From` or `MessagingServiceSid`, and `StatusCallback`.

- The recipient is the activity metadata `to` (or `recipient_phone`), else the conversation's participant on this
  channel. It is normalized to E.164 (see [Phone numbers](#phone-numbers)); a recipient that is not a phone number
  fails permanently.
- Attachments with an absolute `http(s)` `contentUrl` are sent as MMS media (`MediaUrl`, at most 10). Twilio
  downloads them itself, so they must be publicly reachable. Other attachments are not sent.
- The returned `sid` becomes the delivery's `provider_message_id`, and `num_segments` its `sms_segments` metadata.
- Twilio error `21610` (the recipient texted STOP to this sender) marks the participant opted out and fails the
  delivery permanently. Other `4xx` errors are permanent; `408`, `425`, `429` and `5xx` are retried (see
  [Delivery](../delivery.md)).

### Inbound

Twilio's messaging webhook is form encoded, one message per request. The activity gets:

| Activity field | From |
| --- | --- |
| `sender`, participant `external_id` | `From`, in E.164 |
| `text` | `Body` |
| `attachments` | `MediaUrl<n>` / `MediaContentType<n>` (MMS): `contentUrl` is Twilio's media URL. Twilio serves it with HTTP basic auth when media authentication is enabled on the account. |
| `metadata` (`channelData`) | `twilio_message_sid`, `to`, `sms_segments` (`NumSegments`), `from_country`, `messaging_service_sid` |
| `idempotency_key` | `MessageSid`: a re-delivered webhook creates no second activity |

The response is an empty TwiML document (`<Response></Response>`, `text/xml`), so Twilio sends no automatic reply
and does not log a content-type error. Replies go through the pipeline like on every other channel.

### Delivery receipts

Status callbacks (`MessageStatus`) update the delivery whose `provider_message_id` is the `MessageSid`:

| Twilio | Delivery |
| --- | --- |
| `queued`, `accepted`, `scheduled`, `sending` | acknowledged without an update (the delivery is already `sent`) |
| `sent` | `sent` |
| `delivered` | `delivered` |
| `read` | `read` |
| `undelivered`, `failed`, `canceled` | `failed`, with `Twilio error <ErrorCode>: <ErrorMessage>` as `last_error` |

### Signature (`X-Twilio-Signature`)

Twilio signs each request with the auth token: Base64 of the HMAC-SHA1 of the full request URL followed by every
POST parameter, sorted by name, as name and value concatenated. The URL Twilio used is not visible to the adapter
behind a proxy, so the signature is checked against the channel's `inbound` and `status` URLs on each of:

1. the channel's `webhook_base_url`;
2. the server URL (`PHX_HOST`, `ConvergerWeb.Endpoint.url/0`);
3. the request's `Host` header, with `X-Forwarded-Proto` (default `https`).

Only a holder of the auth token can produce a matching signature for any of them. With `require_signature: true`
(the default for new channels) unsigned requests are rejected; see [Channels](overview.md#per-channel-enforcement).

### Health probe

`GET /2010-04-01/Accounts/<account_sid>.json` with the channel's credentials.

## Vonage (`sms_vonage`)

### Configuration

| Key | Required | Meaning |
| --- | --- | --- |
| `from` | yes | Sender: a Vonage number (E.164, with or without `+`) or an alphanumeric sender id. |
| `api_key`, `api_secret` | one auth mode | Basic auth. `api_secret` is a secret. |
| `application_id`, `private_key` | one auth mode | A Vonage application: each request carries an RS256 JWT signed with the application's private key (PEM, a secret). Wins when both modes are configured. |
| `signature_secret` | with `require_signature` (secret) | The account's signature secret, which signs webhooks. |
| `default_country_code` | no | Country code for national numbers. |
| `max_segments` | no | Longest text, in segments, the channel sends. Default `10`. |
| `conversation_idle_timeout_seconds` | no | As for every inbound channel. |

### Vonage dashboard setup

On the application (Messages capability), set **Inbound URL** to `https://<host>/api/v1/channels/<channel_id>/inbound`
and **Status URL** to `https://<host>/api/v1/channels/<channel_id>/status`, both `POST`. Link the `from` number to
the application. Signed webhooks use the account's signature secret, set as `signature_secret`.

### Outbound

`POST https://api.nexmo.com/v1/messages` with `{"message_type": "text", "channel": "sms", "to", "from", "text",
"client_ref"}`. `to` is E.164 without the `+`, and `client_ref` is the activity id. The returned `message_uuid` is
the delivery's `provider_message_id`. Vonage does not return a segment count; `sms_segments` is computed by
Converger. Attachments are not sent (SMS only); an empty text fails permanently.

### Inbound

The Messages API inbound webhook is JSON, one message per request: `from` becomes the sender and participant (E.164),
`text` the text, `message_uuid` the idempotency key, and `sms.num_messages` the `sms_segments` metadata
(`vonage_message_uuid`, `to` and `timestamp` are kept too).

### Delivery receipts

| Vonage `status` | Delivery |
| --- | --- |
| `submitted` | `sent` |
| `delivered` | `delivered` |
| `read` | `read` |
| `rejected`, `undeliverable` | `failed`, with `Vonage: <error title>: <error detail>` as `last_error` |

### Signature (`Authorization: Bearer`)

Vonage signs each webhook with a JWT (HS256, keyed with the signature secret) in the `Authorization` header. Its
`payload_hash` claim is the SHA-256 (hex) of the request body. Converger checks both, so a valid token cannot carry
another body. The token's `iat` is not checked; re-delivered webhooks are idempotent.

### Health probe

With an API key and secret, `GET https://rest.nexmo.com/account/get-balance`. With an application, the probe only
checks that the private key signs a JWT: Vonage has no credential-check endpoint for applications.

## Phone numbers

Participants and recipients are E.164 (`+` and 8 to 15 digits). Spaces, dashes, dots and parentheses are removed,
a `00` prefix becomes `+`, and digits without `+` are taken as international (Vonage sends numbers that way). A
national number (leading `0`) needs `default_country_code`. An inbound sender that is not a phone number (a short
code, an alphanumeric id) is kept as it is.

## Segments and length limits

A single SMS holds 160 GSM-7 characters, or 70 UCS-2 characters when the text has any character outside the GSM-7
alphabet (an emoji, `ı`, `ş`). A longer text is split into segments of 153 GSM-7 or 67 UCS-2 characters. Characters
of the GSM-7 extension table (`€`, `[`, `{`, `|`...) take two, and emoji outside the Basic Multilingual Plane take
two UCS-2 units. Every segment is billed, so a text longer than the channel's `max_segments` (default 10, about
1,530 GSM-7 or 670 UCS-2 characters) fails permanently with
`text is <n> <encoding> segments, the channel allows <max> (config max_segments)` instead of being sent.

## Typed messages and numeric replies

Neither SMS adapter declares `message_types` ([#68](https://github.com/AimTune/converger/issues/68),
[ADR-0064](../adr/0064-per-channel-rendering-of-typed-messages-and-normalised-answers.md)): a typed message is sent as
its text rendering ([messages.md section 5](../protocol/messages.md)). A message with actions becomes its prompt and a
numbered list, for example

```text
How can I help?
1. Track an order
2. Talk to a human
Pricing: https://example.com/pricing
```

A card is its title, subtitle, text and image URL before its list; a carousel one such block per card, numbering
continuing; media are their caption and absolute URL (typed media are not sent as MMS); a location is its name and a
map link; a contact its name and numbers. The list counts towards `max_segments` like any text.

The user answers with the number. A reply that is only a number (`2`, `2.` or `2)`) within 24 hours of the
conversation's most recent actionable message becomes the normalised answer: `text` is the action's value (or its
label), `metadata.action = {label, value, source: "numeric"}` and `reply_to_id` the offering message
([messages.md section 6](../protocol/messages.md)). Any other text, or a number out of range, stays as it was.

## Opt-out (STOP / START)

An inbound message whose whole text (trimmed, any case) is an opt-out keyword opts the participant out; an opt-in
keyword opts them back in:

| Kind | Keywords |
| --- | --- |
| Opt-out | `STOP`, `STOPALL`, `UNSUBSCRIBE`, `CANCEL`, `END`, `QUIT`, `OPTOUT`, `REVOKE` |
| Opt-in | `START`, `YES`, `UNSTOP`, `OPTIN` |

On Twilio, the `OptOutType` parameter (`STOP` or `START`, sent with Advanced Opt-Out and custom keywords) takes
precedence over the text; `HELP` stays an ordinary message.

The message is stored as an `event` activity with `channelData.smsOptOut` set to `stop` or `start`, so agents and
target channels see it. The participant's `opted_out_at` is set (or cleared) before the activity is created, so a
re-delivered webhook never loses the opt-out. While `opted_out_at` is set, every delivery to that participant on
that channel is marked `failed` with `recipient <number> opted out`, without calling the provider and without
counting against the channel's circuit breaker (see [Participants](../concepts/participants.md#opt-out)).

Twilio and Vonage also block numbers that opted out at the carrier level. Converger's flag keeps conversations and
agents in line with that, and Twilio's error `21610` sets the flag if the opt-out happened elsewhere.

## Rate limits

The adapters set no default rate limit: provider throughput depends on the number type (long code, toll-free, short
code) and the account. Set the channel's `rate_limit` (for example `"1/s"` for a US long code), see
[Rate limits](../delivery.md#rate-limits).

## Configuration in the application

`config :converger, :sms_req_options` is merged into every Twilio and Vonage request (tests use it to plug in
`Req.Test`).
