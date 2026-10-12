---
title: "ADR-0045: SMS adapters with a participant opt-out flag, candidate URLs for Twilio signatures and provider-specific inbound responses"
sidebar_label: "0045 SMS adapters"
description: Twilio and Vonage SMS channels share E.164 normalisation, segment limits and STOP / START keywords; opt-out is a participant column the pipeline checks before every delivery, Twilio signatures are checked against the channel's candidate public URLs, and adapters may answer inbound requests with their own body (TwiML).
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-12 |
| **Issue** | [#41](https://github.com/AimTune/converger/issues/41) |
| **Pull request** | to be linked |
| **Related** | [ADR-0009](0009-inbound-signature-scheme-and-per-channel-enforcement.md), [ADR-0016](0016-participant-based-conversation-resolution.md), [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md), [ADR-0031](0031-per-channel-circuit-breaker-rate-limit-and-tier-queues.md), [ADR-0038](0038-adapter-behaviour-v2-and-config-driven-registry.md) |

## Context and problem statement

Issue [#41](https://github.com/AimTune/converger/issues/41) adds SMS through Twilio and Vonage: outbound messages,
inbound webhooks with signature verification, delivery receipts, MMS media on Twilio, segment counts, E.164
numbers and the STOP / START opt-out that carriers require. The acceptance criteria: an inbound SMS creates a
participant-scoped conversation, the reply is delivered and its receipt moves the delivery to `delivered`; and a
`STOP` marks the participant opted out so later deliveries fail fast with a clear reason.

Three parts did not fit the adapter behaviour as it was ([ADR-0038](0038-adapter-behaviour-v2-and-config-driven-registry.md)):

1. **Opt-out is state, not a message.** A `STOP` has to change what the pipeline does with every later delivery to
   that person, on any route that targets the SMS channel, and it must survive webhook re-delivery.
2. **Twilio signs the URL.** `X-Twilio-Signature` is an HMAC-SHA1 over the full URL Twilio called plus the sorted
   form parameters. `verify_inbound_signature/3` receives the channel, the headers and the raw body, not the URL,
   and behind a proxy the URL the server sees is not the one Twilio used anyway.
3. **Twilio expects TwiML.** The inbound controller answers every handled request with a JSON summary. Twilio logs
   error 12300 (invalid content type) for every inbound message that gets a JSON answer.

## Decision drivers

- An opt-out must never be lost, including when the provider re-delivers the `STOP` webhook.
- A delivery to an opted-out number must not reach the provider, must not be retried and must not count as a
  provider failure in the circuit breaker.
- Signature checks must not weaken: only a holder of the auth token may get a request accepted.
- Keep the behaviour small; prefer optional callbacks with defaults ([ADR-0038](0038-adapter-behaviour-v2-and-config-driven-registry.md)).
- No new dependency: `Req` for HTTP, `Joken` (already used for API tokens) for Vonage JWTs.

## Considered options

Opt-out storage:

1. **A nullable `opted_out_at` column on `participants`, checked by the pipeline** before every delivery.
2. **A key in `participants.metadata`.**
3. **Adapter-only check**: each SMS adapter looks the number up and returns a permanent error.

Twilio's URL:

4. **Pass the request URL to adapters** (a new callback arity or a request map).
5. **Candidate URLs in the adapter**: the channel's `inbound` and `status` paths on a configurable
   `webhook_base_url`, the server URL and the request `Host`.

Twilio's response body:

6. **An optional `inbound_response/1` callback** returning `{content_type, body}`, used for `200` answers.
7. **Special-case the type in the controller.**

### Pros and cons of the options

#### Option 1: `opted_out_at` column, pipeline check

- Good, because it is queryable, typed, and serialised with the conversation's participant for agents.
- Good, because the pipeline check runs before downgrade, middleware and the adapter: no provider call, no circuit
  breaker sample, no retry, and it covers every adapter (a future WhatsApp opt-out can reuse it).
- Bad, because it costs a migration (metadata-only: nullable, no default) and one lookup per delivery.

#### Option 2: metadata key

- Good, because it needs no migration.
- Bad, because metadata is free-form JSON, overwritten by upserts in other code paths, and awkward to query.

#### Option 3: adapter-only check

- Good, because it is local to the SMS adapters.
- Bad, because the adapter's error goes through `normalize_error/1` and the circuit breaker records the attempt as a
  provider outcome; and each adapter would repeat the lookup.

#### Option 4: request URL for adapters

- Good, because it is exact.
- Bad, because it changes a callback every adapter implements (or adds a second one) for one provider, and the URL
  the server sees behind a TLS-terminating proxy is still not the URL Twilio signed.

#### Option 5: candidate URLs

- Good, because it needs no behaviour change and handles proxies: `webhook_base_url` states the public URL
  explicitly, and `Host` plus `X-Forwarded-Proto` covers the common proxy setup.
- Good, because security is unchanged: every candidate is checked with the auth token, so a forger still needs it.
- Bad, because a signature for the channel's `status` URL is also accepted on `inbound` (and the other way round).
  Both endpoints of one channel run the same handler, so this lets nothing new through.

#### Option 6: `inbound_response/1`

- Good, because it is optional, with the JSON summary as the default, and other providers that care about the
  answer body can use it.
- Bad, because it adds a callback.

#### Option 7: special case in the controller

- Bad, because the controller would name a channel type again, which [ADR-0038](0038-adapter-behaviour-v2-and-config-driven-registry.md)
  removed.

## Decision

Chosen options: **1**, **5** and **6**.

- **Opt-out.** `participants.opted_out_at` (`utc_datetime_usec`, nullable, never cast). The SMS adapters mark a
  parsed message whose whole text is an opt-out keyword (`STOP`, `STOPALL`, `UNSUBSCRIBE`, `CANCEL`, `END`, `QUIT`,
  `OPTOUT`, `REVOKE`) or opt-in keyword (`START`, `YES`, `UNSTOP`, `OPTIN`) with `"opt_out": "stop" | "start"`,
  turn it into an `event` activity and set `channelData.smsOptOut`. Twilio's `OptOutType` wins over the text.
  `Converger.Inbound` calls `Participants.set_opted_out/3` **before** creating the activity: if the activity insert
  fails, the provider re-delivers and the idempotent flag is set again; the other order would turn the re-delivery
  into a duplicate and lose the opt-out. `Pipeline.deliver/2` checks `Participants.opted_out_recipient/2` (the
  conversation participant on the target channel and an explicit `metadata.to` / `recipient_phone`) first and marks
  the delivery `failed` with `recipient <id> opted out`, returned as `{:error, {:halted, reason}}` (not retried). The
  SMS adapters check their normalised recipient again, and Twilio's error `21610` sets the flag when the opt-out
  happened outside Converger.
- **Twilio signatures.** `SmsTwilio.verify_inbound_signature/3` accepts a signature over
  `<base>/api/v1/channels/<id>/{inbound,status}` for each base of: the channel's `webhook_base_url`,
  `ConvergerWeb.Endpoint.url/0`, and `X-Forwarded-Proto` (default `https`) plus `Host`. The parameters come from the
  raw body (`URI.query_decoder/1`, sorted). Vonage needs no URL: its JWT (HS256, `signature_secret`) carries a
  `payload_hash` of the body, which is required.
- **Inbound response.** New optional callback `c:Converger.Channels.Adapter.inbound_response/1` returns
  `{content_type, body}`; the controller sends it for every `200` answer of that channel (messages and receipts).
  `201` answers stay JSON. `sms_twilio` returns an empty TwiML `<Response></Response>` as `text/xml`.
- **Shared SMS rules** live in `Converger.Channels.Sms`: E.164 normalisation (with a per-channel
  `default_country_code` for national numbers), GSM-7 / UCS-2 segment counting (153 / 67 per concatenated part,
  extension characters and astral emoji count twice) and a per-channel `max_segments` (default 10). A text over
  the limit fails permanently instead of being sent and billed.
- **Types** are `sms_twilio` and `sms_vonage` (provider second, like `whatsapp_meta`), registered as built-ins.
  Vonage supports basic auth and application JWTs (RS256 via Joken; the PEM is decoded on config validation, since
  Joken builds signers lazily).

## Consequences

### Positive

- Both acceptance criteria hold and are tested end to end (`test/converger_web/controllers/sms_inbound_test.exs`).
- Every channel type gets the opt-out check for free; agents see `participant.opted_out_at` on the conversation.
- An opted-out recipient never reaches the provider and never trips the circuit breaker.

### Negative and trade-offs

- One extra lookup per delivery (the recipient's participant), for every channel type.
- An operator cannot clear `opted_out_at` through the API yet; only an opt-in keyword from the participant clears it.
- Twilio MMS only sends absolute public URLs; attachments stored in Converger (signed download paths) are not sent.
- The Vonage JWT's `iat` is not checked; replays are bounded by the body hash and by idempotency keys.
- Inbound media URLs on Twilio may require HTTP basic auth to download (account setting); they are stored as is.

### Follow-ups

- An API to set or clear a participant's opt-out (for opt-outs collected outside SMS).
- Download inbound MMS media into Converger storage, as planned for WhatsApp in [#37](https://github.com/AimTune/converger/issues/37).

## Implementation

- [`lib/converger/channels/sms.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/sms.ex): E.164, segments, keywords.
- [`lib/converger/channels/adapters/sms_twilio.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/sms_twilio.ex),
  [`lib/converger/channels/adapters/sms_vonage.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/sms_vonage.ex).
- `Converger.Participants.set_opted_out/3`, `opted_out?/2`, `opted_out_recipient/2`; `Converger.Inbound` applies
  `"opt_out"`; `Converger.Pipeline.deliver/2` checks it.
- `Converger.Channels.Adapter.inbound_response/1` and `ConvergerWeb.InboundController`.
- Migration [`20261012100000_add_opted_out_at_to_participants`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261012100000_add_opted_out_at_to_participants.exs).
- Tests: `test/converger/channels/sms_test.exs`, `test/converger/channels/adapters/sms_twilio_test.exs`,
  `test/converger/channels/adapters/sms_vonage_test.exs`, `test/converger_web/controllers/sms_inbound_test.exs`.

## Links

- [SMS (Twilio, Vonage)](../channels/sms.md), [Participants](../concepts/participants.md#opt-out),
  [Channels](../channels/overview.md), [Delivery pipeline](../architecture/delivery-pipeline.md)
- [Twilio webhook security](https://www.twilio.com/docs/usage/webhooks/webhooks-security),
  [Vonage signed webhooks](https://developer.vonage.com/en/getting-started/concepts/webhooks#validating-signed-webhooks)
