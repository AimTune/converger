---
title: "ADR-0048: Additional adapters with shared Meta Graph code, Bot Framework JWT validation, user participants with reply targets, and a watermark-acknowledged pull outbox"
sidebar_label: "0048 Additional adapters"
description: Messenger and Instagram share the Graph and Messenger Platform code with WhatsApp; Teams validates Bot Framework JWTs against cached OpenID keys and posts only to allowlisted service URLs; Discord and Teams participants are users whose reply target lives in participant metadata; Discord interactions are answered through inbound_response/2; http_pull channels keep deliveries pending in an outbox acknowledged by served-only watermarks.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-12 |
| **Issue** | [#44](https://github.com/AimTune/converger/issues/44) |
| **Pull request** | [#139](https://github.com/AimTune/converger/pull/139) |
| **Related** | [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0009](0009-inbound-signature-scheme-and-per-channel-enforcement.md), [ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md), [ADR-0016](0016-participant-based-conversation-resolution.md), [ADR-0038](0038-adapter-behaviour-v2-and-config-driven-registry.md), [ADR-0039](0039-whatsapp-rich-outbound-and-inbound-media-download.md), [ADR-0045](0045-sms-adapters-opt-out-flag-and-twilio-signature-urls.md) |

## Context and problem statement

Issue [#44](https://github.com/AimTune/converger/issues/44) collects adapters requested less often than the v3.2
ones: Discord, Microsoft Teams (Bot Framework), Facebook Messenger, Instagram Direct, Viber, MQTT, gRPC streaming and a
generic "HTTP pull" channel. This change delivers the six that need no new dependency (Discord, Teams, Messenger,
Instagram, Viber, HTTP pull) at the standard of the existing adapters; MQTT and gRPC streaming need an MQTT client,
`grpc` and protobuf code generation, and stay planned.

Five questions did not have an answer in the existing code:

1. **Meta code reuse.** Messenger and Instagram are the same Graph API family as WhatsApp Meta: the same
   `X-Hub-Signature-256` webhook signature, `hub.challenge` handshake, error codes and media downloads. Messenger and
   Instagram also share one webhook shape (`entry[].messaging[]`) and one Send API. Copying `whatsapp_meta.ex` three
   times would triple every fix.
2. **Bot Framework authentication.** Teams posts Activities with a JWT signed by rotating Microsoft keys, and replies
   go to a `serviceUrl` taken from the request. Validating the token needs the OpenID metadata and keys, cached; the
   reply needs an OAuth client-credentials token, cached; and a `serviceUrl` is an SSRF vector if it is ever trusted
   without checks.
3. **Where replies go when the participant is not the sender.** The pipeline never echoes an inbound message back to
   its author by comparing the activity `sender` with the conversation participant's `external_id`
   ([ADR-0016](0016-participant-based-conversation-resolution.md)). On Discord and Teams the natural reply address is a
   channel or conversation, not the user: making that the participant would break the echo rule (every slash command
   would be posted back to Discord), and making the user the participant leaves no place for the reply address.
4. **Request-dependent answers.** Discord requires an interaction response within three seconds whose type depends on
   the interaction (a message for a slash command, a deferred update for a button), and Teams expects an invoke
   response for `adaptiveCard/action`. `inbound_response/1` ([ADR-0045](0045-sms-adapters-opt-out-flag-and-twilio-signature-urls.md))
   sees only the channel.
5. **Pull delivery without data loss.** An `http_pull` integrator polls `GET /channels/:id/outbox?watermark=`. The
   outbox must be paginated, acknowledged by a watermark, and must never acknowledge an item the consumer has not
   seen, even when deliveries commit out of order.

## Decision drivers

- No new dependencies (Ed25519 through `:crypto`, JWTs through the existing `joken`, HTTP through `Req`).
- Every adapter keeps the behaviour of [ADR-0038](0038-adapter-behaviour-v2-and-config-driven-registry.md): one
  module plus one registry line, no type lists elsewhere, admin forms from `config_schema/0`.
- No data loss: a failed media download, an unknown event or a lost poll never drops a message.
- Provider credentials never reach a host the operator did not allow.

## Considered options

1. **Meta: copy the WhatsApp code** into each adapter, or **extract it**: `Converger.Channels.Meta.Graph`
   (version, request options, signature, handshake, error classification, media) for all three, and
   `Converger.Channels.Meta.Messaging` (Messenger Platform parsing and Send API) for Messenger and Instagram, driven by
   a per-adapter spec (object, host, account id, token, limits).
2. **Teams auth: validate with Joken against keys refetched on every request**, or **cache the OpenID keys and OAuth
   tokens in a per-node ETS cache**, refetching keys on an unknown `kid` at most once per cooldown.
3. **Reply targets: the channel or conversation as participant** (and a new echo rule), or **the user as participant
   with the reply target in participant metadata**, merged on every inbound message.
4. **Request-dependent answers: answer inside `parse_inbound/2`** (side effects in a parser), or **an optional
   `inbound_response/2`** that gets the params and takes precedence over `inbound_response/1`.
5. **Pull outbox: a new outbox table**, or **the existing delivery rows**: the adapter returns `{:pending, meta}` with
   the canonical activity in `meta`, the outbox lists pending handed-off deliveries by `(inserted_at, id)`, and a
   watermark acknowledges only deliveries that were served.

### Pros and cons of the options

#### Extracting the Meta code

- Good, because signature, handshake, error codes and media live in one place; Messenger and Instagram are two thin
  modules (config schema, spec, callbacks).
- Good, because WhatsApp gains the shared rate-limit classification (Graph codes `4`, `17`, `32`, `613` and its own
  `130429`, `131048`, `131056` are now retried although Meta answers them with `400`).
- Bad, because a change to the shared module touches three adapters; the shared tests and the WhatsApp suite guard it.

#### Cached Bot Framework keys and tokens

- Good, because the hot path (every Teams message) does no HTTP besides the request itself.
- Good, because an unknown `kid` (Microsoft rotates keys) is picked up without a restart, and the cooldown keeps a
  flood of forged tokens from turning Converger into an amplifier against the metadata endpoint.
- Bad, because a new process (`Converger.Channels.TokenCache`, an ETS owner) joins the supervision tree; a node that
  restarts pays one fetch per entry.

#### Users as participants, reply target in metadata

- Good, because the echo rule keeps working unchanged: `sender` equals the participant's `external_id`.
- Good, because each Teams or Discord user gets their own Converger conversation, and the reply goes to where the user
  last wrote (a personal chat, a group chat, a channel thread). `upsert_participant/2` now merges `metadata` over the
  stored keys on conflict, which no existing adapter relied on (they send no participant metadata).
- Bad, because messages one user writes in two Teams conversations share one Converger conversation; replies follow
  the latest one.

#### `inbound_response/2`

- Good, because parsing stays free of side effects and the response is only sent after the activity is stored
  (Discord's three-second budget is ample for one transaction).
- Bad, because the behaviour grows a second arity; the dispatcher prefers `/2` and falls back to `/1`.

#### Pull outbox on delivery rows

- Good, because there is no new table, no new retention rule and no new partition key: outbox items are deliveries,
  partitioned and retained with their activities ([ADR-0034](0034-monthly-partitioning-and-per-tenant-retention.md)),
  visible in the delivery tools and metrics. The `{:pending, meta}` hand-off already exists for WebSocket channels.
- Good, because the payload is stored at hand-off, after middleware, so the outbox serves exactly what a webhook would
  have received.
- Bad, because a watermark based on `(inserted_at, id)` alone can skip a delivery that commits late with an earlier
  position. Hence the **served-only** rule below.

## Decision

Chosen: option 1b (extract), 2b (cached), 3b (users as participants), 4b (`inbound_response/2`) and 5b (delivery
rows with served-only watermarks).

**Watermark semantics.** `GET /outbox` first acknowledges the request's watermark, then returns the oldest pending
handed-off deliveries of the channel (`limit` + 1 to compute `has_more`) and stamps the returned ones with
`metadata.outbox_served_at`. A watermark is the opaque `(inserted_at, id)` of the last served item. Acknowledging it
marks `sent` every pending delivery of the channel **at or before that position that has `outbox_served_at`**. A
delivery that committed after the page was read, with an earlier position, was never served, so it is not
acknowledged; the listing has no lower bound, so the next page returns it. The consumer gets at least once delivery,
with `served_before: true` marking redeliveries. One consumer per channel is supported; independent consumers use
separate channels.

**Bot Framework rules.** RS256 only; `kid` must name a key of the metadata's `jwks_uri`, endorsed for the activity's
`channelId` when the key lists endorsements; `iss` `https://api.botframework.com`; `aud` the channel's `app_id`;
five minutes of skew; the `serviceurl` claim must equal the Activity's `serviceUrl`. Outbound requests go only to
`https` service URLs on the `service_url_hosts` allowlist that `Converger.Channels.UrlGuard` also accepts, and inline
Teams images are fetched with the bot token only from those hosts.

**Signatures always enforced where the provider always signs.** Viber, Discord and Teams reject a missing signature or
token even on channels with `require_signature: false`, like Telegram once a secret token is set
([ADR-0041](0041-telegram-adapter-chat-scoped-ids-and-stored-media.md)).

**Provider media URLs from payloads** (Messenger, Instagram, Viber, Teams files) are downloaded through
`MediaDownload.get_public/2`, which runs the SSRF guard first: a forged payload on an unsigned channel cannot make
Converger fetch an internal address.

## Consequences

### Positive

- Six new channel types with signature verification, receipts where the provider has them, error classification,
  health probes, encrypted secrets and admin forms, and no new dependency.
- Outbound keys never reuse inbound metadata keys (`target_channel_id`, `target_conversation_id`,
  `recipient_id`), so an activity routed between two channels of the same type is never sent by the wrong bot.

### Negative and trade-offs

- Instagram, Viber and Teams cannot send files stored in Converger (their APIs fetch from a URL, and the Teams file
  consent flow is not implemented): such deliveries fail permanently with a clear reason.
- Discord inbound covers interactions only; plain channel messages need the Gateway WebSocket.
- Messenger read receipts (watermark timestamps) are ignored.

### Follow-ups

- [#44](https://github.com/AimTune/converger/issues/44): MQTT and gRPC streaming adapters, Discord Gateway inbound.

## Implementation

- Shared Meta code: [`lib/converger/channels/meta/graph.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/meta/graph.ex),
  [`lib/converger/channels/meta/messaging.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/meta/messaging.ex);
  adapters `messenger.ex`, `instagram.ex`; `whatsapp_meta.ex` now uses `Meta.Graph`.
- Teams: [`lib/converger/channels/teams/auth.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/teams/auth.ex),
  `teams.ex`, [`lib/converger/channels/token_cache.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/token_cache.ex).
- Discord (`discord.ex`, Ed25519 through `:crypto.verify/5`), Viber (`viber.ex`).
- Shared outbound reading: [`lib/converger/channels/chat_content.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/chat_content.ex).
- `inbound_response/2`: `Converger.Channels.Adapter` and `ConvergerWeb.InboundController`.
- Participant metadata merge and `Participants.participant_for/2`: `lib/converger/participants.ex`.
- Pull outbox: `http_pull.ex`, [`lib/converger/channels/outbox.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/outbox.ex),
  `Deliveries.outbox_page/2` and `Deliveries.acknowledge_outbox/2`, `ConvergerWeb.ChannelOutboxController`.
- Tests: one suite per adapter under `test/converger/channels/adapters/` (Req.Test stubs, generated Ed25519 and RSA
  keys) and `test/converger_web/controllers/channel_outbox_controller_test.exs` (including a late-committed delivery
  behind the watermark).

## Links

- [Channels and adapters](../channels/overview.md), [Discord](../channels/discord.md),
  [Microsoft Teams](../channels/teams.md), [Messenger](../channels/messenger.md), [Instagram](../channels/instagram.md),
  [Viber](../channels/viber.md), [HTTP pull](../channels/http-pull.md)
- [Bot Framework authentication](https://learn.microsoft.com/azure/bot-service/rest-api/bot-framework-rest-connector-authentication)
- [Discord interactions](https://discord.com/developers/docs/interactions/receiving-and-responding)
