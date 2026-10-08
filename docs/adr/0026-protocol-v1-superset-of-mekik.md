---
title: "ADR 0026: Converger Protocol v1 is a superset profile of mekik/1"
---

# ADR 0026: Converger Protocol v1 is a superset profile of mekik/1

- **Status:** Proposed
- **Date:** 2026-10-09
- **Issues:** [#21](https://github.com/AimTune/converger/issues/21) (spec),
  [#63](https://github.com/AimTune/converger/issues/63) (mekik/1 compatibility),
  [#68](https://github.com/AimTune/converger/issues/68) (rich message vocabulary)
- **PR:** the pull request that adds `docs/protocol/v1.md`
- **Spec:** [Converger Protocol v1](../protocol/v1.md), [Rich message vocabulary](../protocol/messages.md)

## Context

Converger's WebSocket wire format was implicit in `ConvergerChannel` and `ConversationChannel`:
Phoenix framing, `activitySet` frames, an opaque base64 watermark, no acks, no error codes, no
version. The #21 draft proposed its own frames (`activitySet`, `ack`, `send`, `resume {watermark}`).

Two sibling projects already define most of it. mekik/1 (`AimTune/mekik`, `PROTOCOL.md`) has a
`hello`/`welcome` handshake, a persistent frame envelope with a per-conversation `seq`, replay after
a watermark, interrupts and an open rich message rule, with two implementations held together by
golden fixtures. chativa (`AimTune/chativa`) renders typed messages and parses mekik frames with
`@chativa/connector-mekik`. If Converger diverged, every chativa user would need a third connector,
and a mekik bot could not sit behind Converger without a translation layer tracking two specs.
#63 decided that Converger Protocol v1 is a superset profile of mekik/1. Writing the spec required
further decisions that the issues left open; they are recorded here.

## Considered options

1. **Own protocol** (the #21 draft): full freedom, but a third dialect for chativa and a
   translation layer for mekik bots.
2. **mekik/1 unchanged**: maximum compatibility, but no acks, receipts, presence, agent sockets
   or hub error codes.
3. **Superset profile of mekik/1** (chosen): identical where mekik/1 defines something, additive
   elsewhere, with every addition ignorable under mekik/1's unknown-field and unknown-frame rule.

## Decision

Option 3, with these specific choices:

1. **Version negotiation.** `welcome.data.protocol` is `"converger/1"` and `compat` lists
   `"mekik/1"`. Native endpoint: subprotocol `converger.v1`; a client offering no subprotocol is
   accepted with mekik/1 semantics. Phoenix binding: `vsn` stays the Phoenix serializer version,
   and `protocol: "converger/1"` in the join payload selects v1 (event `frame`); without it the
   legacy `activitySet` shape continues.
2. **`from` keeps mekik's two values.** `"user"` or `"bot"`, relative to the end user, so chativa
   renders the right side. Hub roles (`user`, `bot`, `agent`, `system`) and the sender id go in an
   optional `sender` object.
3. **mekik-native persistent frames get no Converger fields.** `tool_call`, `skill`, `genui`,
   `interrupt` and `interrupt_resolved` keep exactly mekik's shape (no `id`, `from` or `timestamp`
   added), so relayed frames round-trip byte-identically except `seq`, which is renumbered into the
   conversation's seq space. They are addressed by `(conversationId, seq)`.
4. **No `send` frame.** A user turn is mekik's typed message frame (`text`, generalised to every
   message type) with an optional `clientId`. **`resume {watermark}` is renamed `sync`**, because
   mekik's `resume` answers interrupts.
5. **Watermark = integer `seq`.** `welcome.data.watermark` is the conversation's head seq. A missing
   watermark means 0 (full, bounded replay) as in mekik/1, unlike today's live-only Converger
   behaviour. Migration: v3.0 (#22) emits integers in v1 frames and in REST, and accepts integers,
   decimal strings and both legacy base64url forms; one minor release later only integers are
   accepted. The forms are unambiguous (base64url watermarks start with a letter).
6. **Bounded replay without breaking mekik clients.** The server replays in batches of
   `ws_replay_limit` (100) up to `replayMax` (10 000) per handshake, then sends `replayTruncated`;
   the REST activity list with `has_more` covers the rest. mekik clients see a full replay in
   practice.
7. **Gaps.** The server fills gaps itself (Phoenix PubSub is at-most-once): a live frame beyond
   `last + 1` makes it read the missing range from the database first. Clients that stamp every send
   with `clientId` can also detect gaps and `sync`. mekik clients (no `clientId`, no echo of their own
   turn) only track the highest `seq`.
8. **Acks and dedupe.** `ack {clientId, id, seq, timestamp}` only for sends with a `clientId`.
   `clientId` is stored as the existing activity idempotency key (unique per conversation), so a
   retransmission returns the original ack with `duplicate: true`. At most 32 unacked sends per
   connection.
9. **Errors.** mekik's `error {code, message}` plus `number` (ranges: 1xxx protocol, 2xxx auth,
   3xxx limits, 4xxx conversation state, 5xxx relayed from the bot, 9xxx server), `retryable`,
   `retryAfterMs`, `clientId`. Close codes: 4401 for `unauthorized` and `token_expired` (so mekik
   connectors' auth providers refresh), 4403 inactive channel, 4408 idle, 1012 draining.
10. **Mid-session token refresh** with an `auth` frame (`tokenRefreshed` reply); on expiry
    `token_expired` and close 4401, and the client reconnects with the same watermark.
11. **Legacy activity types.** `message` becomes `text` (attachments carried verbatim until #28),
    `event` and `conversationUpdate` are persistent Converger frame types, `endOfConversation`
    maps to `conversationUpdate`, and typing activities persisted before #25 are delivered as
    `typing` frames that carry a `seq` (`isTyping: false` on replay), so no seq is ever skipped.
12. **Channel-scoped sockets.** An explicit `scope: "channel"` claim (not just a token without
    `conversation_id`, which today is used by end-user widgets) enables `{conversationId, frame}`
    multiplexing; the envelope has no `type`, which distinguishes it from bare connection frames.
    Resume with `hello.watermarks` or an enveloped `sync`.
13. **Message vocabulary.** chativa's type names and `data` fields win where they exist (for
    example card actions are `buttons`, not `actions`); Converger adds only optional fields (a
    card body is `text`). `data.text` is the universal fallback (chativa's fallback renderer shows
    it); `data.extensions` is the namespaced provider escape hatch; unknown renderer-named types
    are stored opaquely.
14. **Schemas** are JSON Schema 2020-12 under `priv/protocol/v1` with `$id`s under
    `https://converger.aimtune.dev/schemas/protocol/v1/`, validated in CI by `test/protocol`
    (JSV, test-only dependency).

## Consequences

- An unmodified `@chativa/connector-mekik` can connect to the native endpoint once #22 ships;
  chativa needs no Converger-specific connector.
- Converger cannot change any mekik/1-defined shape without breaking that promise; changes go
  through mekik first or become additive Converger fields.
- Clients of the REST API see the watermark become an integer in v3.0 (a JSON type change),
  announced in the changelog; old watermarks keep working for one more release.
- The turn lock stays with the bot; Converger only relays `busy` and `interrupted`.
- Two socket stacks and the legacy shapes stay until #23 and the deprecation window ends.
- Still open, for the owner: the native endpoint path; whether chativa's outgoing `id` should
  count as a `clientId` for mekik clients; the numbers in the limits table; how agent sockets
  discover conversations they missed while disconnected.
