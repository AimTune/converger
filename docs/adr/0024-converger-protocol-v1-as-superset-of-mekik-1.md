---
title: "ADR-0024: Converger Protocol v1 is a superset profile of mekik/1"
sidebar_label: "0024 Protocol v1 and mekik/1"
description: Converger Protocol v1 is identical to mekik/1 wherever mekik/1 defines something and only adds hub-specific frames, so unmodified mekik clients such as chativa's connector-mekik can talk to Converger.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#63](https://github.com/AimTune/converger/issues/63) |
| **Pull request** | none yet (spec in [#21](https://github.com/AimTune/converger/issues/21)) |
| **Related** | [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0017](0017-conversation-lifecycle-enforced-under-the-seq-lock.md), [ADR-0018](0018-keyset-pagination.md), [ADR-0020](0020-per-subject-socket-ids-and-presence.md), [ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md) |

WebSocket is Converger's primary client channel, but its wire format is implicit in `ConvergerChannel` and `ConversationChannel`. Converger Protocol v1 (spec in progress, [#21](https://github.com/AimTune/converger/issues/21), [#63](https://github.com/AimTune/converger/issues/63)) will be the written contract. This ADR records the decision, taken in [#63](https://github.com/AimTune/converger/issues/63), about **what that protocol is based on**. The decision is accepted; the specification and the server implementation are not written yet, so everything below that describes v1 behaviour is planned.

## Context and problem statement

Two sibling projects already define most of what [#21](https://github.com/AimTune/converger/issues/21) needs:

- **mekik** (`AimTune/mekik`, protocol `mekik/1`): JSON frames over WebSocket with a `type` discriminator; a `hello` -> `welcome` handshake carrying `userId`, `conversationId`, `watermark` and `token`; persistent frames with a 1-based, strictly monotonic, gap-free per-conversation `seq`, replayed after a watermark; transient frames (`welcome`, `run`, `error`); identity optionally in the query string for sticky routing; auth rejection as `error{unauthorized}` plus close code `4401`. Two implementations (TypeScript and .NET) are kept byte-identical by golden fixtures.
- **chativa** (`AimTune/chativa`): the chat widget. Its shared frame parser handles `text`, `typing`, `tool_call`, `genui`, `text` with `actions`, `genui_event` and `survey`, and `@chativa/connector-mekik` already implements reconnect with jitter, an offline queue, localStorage resume, auth providers, client tools and skills.

Converger's own draft for [#21](https://github.com/AimTune/converger/issues/21) independently proposed `activitySet`, `ack` and `resume` frames and kept the base64 opaque watermark from [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md). Today the Converger API socket (`/socket/converger`, topic `converger:conversation:<id>`) uses Phoenix Channel framing and pushes `activitySet {activities, watermark, has_more}` frames.

If Converger's protocol diverges from mekik/1, every chativa user needs a third connector, and a mekik bot cannot sit behind Converger without a translation layer that has to track two moving specifications. The failure mode is concrete: the same team would maintain two protocols that mean the same thing, and every feature (resume, rich frames, interrupts) would be implemented and tested twice.

## Decision drivers

- Unmodified mekik clients (`@chativa/connector-mekik`) must work against Converger.
- A mekik bot must be able to run behind Converger with Converger as transcript, `seq` and auth authority ([#64](https://github.com/AimTune/converger/issues/64)).
- Converger's hub features (acks, delivery receipts, presence, lifecycle, channel-scoped agent sockets) must still be expressible.
- One conformance suite, shared with mekik, instead of a parallel one.
- Backward compatibility for existing Converger API clients during the transition.

## Considered options

1. **Superset profile of mekik/1** - identical wherever mekik/1 defines something, additive where the hub needs more; the server advertises `protocol: "converger/1"` and `compat: ["mekik/1"]`.
2. **Independent Converger protocol** (the original [#21](https://github.com/AimTune/converger/issues/21) draft) plus a translation adapter for mekik and chativa.
3. **Adopt mekik/1 verbatim** with no extensions; hub features only over REST.
4. **Base v1 on Bot Framework Direct Line** (the Converger REST API is already Direct Line-inspired).

### Pros and cons of the options

**Option 1: superset of mekik/1**

- Good: chativa and mekik interoperate on day one; mekik's golden fixtures become Converger's conformance tests.
- Good: a mekik client that never sends hub-only fields simply never receives hub-only frames.
- Bad: Converger inherits mekik/1's design choices and must coordinate future changes with mekik.
- Bad: requires plain JSON frames, not Phoenix Channel framing, for compatible clients, so a raw WebSocket endpoint is needed ([#26](https://github.com/AimTune/converger/issues/26)).

**Option 2: independent protocol plus translation**

- Good: full design freedom.
- Bad: two specs and a translation layer that must stay in sync with both; the third-connector problem for chativa.

**Option 3: mekik/1 verbatim**

- Good: zero divergence.
- Bad: no acks for client-stamped sends ([#24](https://github.com/AimTune/converger/issues/24)), no delivery status ([#25](https://github.com/AimTune/converger/issues/25)) and no channel-scoped sockets, which are the hub's reason to exist.

**Option 4: Direct Line**

- Good: familiar to Bot Framework users.
- Bad: no mekik or chativa client speaks it; its activity-stream model does not cover the rich and transient frames chativa renders.

## Decision

Chosen option: **"Superset profile of mekik/1"** (option 1), because it gives Converger a working client and bot ecosystem immediately and keeps one protocol family, while the additive rule leaves room for everything the hub needs.

**Adopted unchanged from mekik/1**

| Area | What |
| --- | --- |
| Handshake | `hello` / `welcome` and their fields; `welcome.data.protocol` is `"converger/1"` with `compat: ["mekik/1"]` |
| Persistent envelope | `{type, id, seq, from, data, timestamp}`; `seq` per conversation, strictly monotonic, no gaps; replay of `seq > watermark` after `welcome` |
| Persistent types | `text`, `tool_call`, `genui`, `interrupt`, `interrupt_resolved`, `skill`, and the open rich-message rule: a frame whose `type` is a renderer name is stored as an activity with `activity.type = frame.type` and `activity.data = frame.data`, relayed without interpretation |
| Transient (bot to client) | `run`, `error`, `typing`, `genui_components`, `skills`: relayed, never persisted |
| Client to server | `text`, `resume`, `genui_event`, `client_tools`, `client_skills`, `abort`, `survey`, `regenerate`, `edit`: accepted and forwarded to the conversation's bot channel |
| Rules | unknown-frame rule, `busy` and `interrupted` error codes, query-string identity for L7 affinity, close code `4401` on auth failure |

**Added by Converger (all additive)**

| Addition | Purpose |
| --- | --- |
| `ack {clientId, id, seq, timestamp}` | acknowledges client-stamped sends ([#24](https://github.com/AimTune/converger/issues/24)); a mekik client never sends `clientId` and gets no ack |
| `deliveryStatus {activityId, channelId, status, ...}`, `presence`, `heartbeat` | receipts and presence ([#25](https://github.com/AimTune/converger/issues/25)) |
| `conversationUpdate` | lifecycle events from [ADR-0017](0017-conversation-lifecycle-enforced-under-the-seq-lock.md) |
| Channel-scoped (agent) sockets | a token with `scope: channel` subscribes to every conversation of a channel, frames wrapped as `{conversationId, frame}`; needed for agent consoles and the mekik transport ([#64](https://github.com/AimTune/converger/issues/64), [#67](https://github.com/AimTune/converger/issues/67)) |
| Error codes | rate limited, payload too large, `conversation_closed` |

**Not adopted**: mekik's turn lock and the *semantics* of `busy` belong to the bot. Converger relays `error{busy}` from the bot channel but does not serialize turns itself.

### Relation to ADR-0006: integer seq watermark

[ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md) introduced the per-conversation `seq` and an **opaque** watermark: today `Converger.ConvergerAPI.Watermark` encodes it as `Base.url_encode64("seq:" <> seq)` without padding and still accepts legacy base64 activity-id watermarks. mekik/1 uses the **integer** `seq` as the watermark. Because the opaque watermark already carries nothing but the `seq`, the underlying model is identical and only the encoding changes. This ADR supersedes the opaque encoding for Converger Protocol v1:

- Planned ([#63](https://github.com/AimTune/converger/issues/63)): v1 frames and `hello.watermark` use the integer `seq`.
- Planned ([#63](https://github.com/AimTune/converger/issues/63)): the Converger API keeps accepting opaque `seq:` watermarks (and legacy activity-id ones, while they are supported) for one release after integer watermarks ship, so existing clients can migrate.
- `seq` allocation, gap-freedom and ordering stay exactly as decided in ADR-0006; ADR-0006 remains in force for everything but the wire encoding.

## Consequences

### Positive

- `@chativa/connector-mekik` should connect, resume and render `text`, `tool_call`, `genui` and `interrupt` from a mekik bot behind Converger without modification (acceptance criterion of [#63](https://github.com/AimTune/converger/issues/63)).
- Converger can be the single transcript, `seq` and auth authority for mekik bots ([#64](https://github.com/AimTune/converger/issues/64), mode B).
- mekik's `conformance/fixtures/*.json` become Converger's conformance tests: persistent frames must round-trip through Converger storage byte-identically (canonical JSON compare).
- Rich frames are stored opaquely, so new renderer types need no server change ([#68](https://github.com/AimTune/converger/issues/68)).

### Negative and trade-offs

- Converger's protocol evolution is coupled to mekik's; incompatible changes need coordination across repositories.
- The current Phoenix Channel framing and the `activitySet` frame are not mekik/1; existing Converger API clients face a migration, and the legacy `conversation:*` topics need a deprecation window ([#23](https://github.com/AimTune/converger/issues/23)).
- The WebSocket replay cap with REST continuation from [ADR-0018](0018-keyset-pagination.md) has to be reconciled with mekik/1's replay-after-`welcome` rule in the spec.
- Storing rich frames without interpretation means Converger cannot validate them; per-channel downgrade (for example `interrupt` to WhatsApp buttons) is extra adapter work ([#68](https://github.com/AimTune/converger/issues/68)).
- Two watermark encodings coexist during the transition.

### Follow-ups

- Write the specification with a "mekik/1 compatibility" section listing each frame as adopted, extended or not applicable: [#21](https://github.com/AimTune/converger/issues/21).
- Raw WebSocket endpoint without Phoenix framing: [#26](https://github.com/AimTune/converger/issues/26).
- Unify the two socket implementations on the v1 protocol: [#23](https://github.com/AimTune/converger/issues/23); first-class `websocket` channel adapter: [#22](https://github.com/AimTune/converger/issues/22).
- Acks and client message ids: [#24](https://github.com/AimTune/converger/issues/24); receipts, typing and presence: [#25](https://github.com/AimTune/converger/issues/25).
- mekik integration (agent-side multiplexed socket, `mekik` adapter, `seq` authority): [#64](https://github.com/AimTune/converger/issues/64); chativa as reference client: [#65](https://github.com/AimTune/converger/issues/65); agent SDKs: [#67](https://github.com/AimTune/converger/issues/67); TypeScript SDK: [#46](https://github.com/AimTune/converger/issues/46).
- Epic: [#58](https://github.com/AimTune/converger/issues/58) (v3.0 WebSocket-first and Converger Protocol v1).

## Implementation

Not implemented yet. The current state that v1 builds on:

- [`Converger.ConvergerAPI.Watermark`](https://github.com/AimTune/converger/blob/main/lib/converger/converger_api/watermark.ex): opaque `seq:` watermark and legacy activity-id decoding.
- [`ConvergerWeb.ConvergerSocket`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/converger_socket.ex) and [`ConvergerWeb.ConvergerChannel`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/converger_channel.ex): Phoenix Channel framing, `activitySet` frames with `has_more`.
- [`Converger.Activities`](https://github.com/AimTune/converger/blob/main/lib/converger/activities.ex): gap-free `seq` allocation, the property mekik/1's envelope relies on.
- [`ConvergerWeb.Sockets`](https://github.com/AimTune/converger/blob/main/lib/converger_web/sockets.ex): per-subject socket ids and presence ([ADR-0020](0020-per-subject-socket-ids-and-presence.md)), the basis for `presence` frames.

## Links

- Issue [#63](https://github.com/AimTune/converger/issues/63), protocol specification issue [#21](https://github.com/AimTune/converger/issues/21)
- [mekik](https://github.com/AimTune/mekik) and [chativa](https://github.com/AimTune/chativa); client-side work in AimTune/chativa#86
- [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md): the `seq` model this protocol exposes
