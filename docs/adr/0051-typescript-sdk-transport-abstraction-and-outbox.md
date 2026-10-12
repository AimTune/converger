---
title: "ADR-0051: TypeScript SDK with one session core over swappable transports, a persistent clientId outbox resent after the replay, and hand-written types until the OpenAPI document exists"
sidebar_label: "0051 TypeScript SDK"
description: "@converger/client is a dependency-free pnpm workspace package. One conversation-session core (reconnect, watermark, outbox, token refresh) runs over transports that normalise the native endpoint, the Phoenix binding and SSE to v1 frames. Unacked sends are persisted and resent once per connection after the replay, relying on the server's clientId de-duplication. Protocol and REST types are hand-written in a generator-compatible shape."
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-12 |
| **Issue** | [#46](https://github.com/AimTune/converger/issues/46) |
| **Pull request** | [#142](https://github.com/AimTune/converger/pull/142) |
| **Related** | [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md), [ADR-0027](0027-websocket-limits-backpressure-and-draining.md), [ADR-0029](0029-websocket-sends-acked-on-the-phoenix-binding.md), [ADR-0030](0030-native-websocket-endpoint-and-fallback-transports.md) |

## Context and problem statement

`converger_js/` was a 50-line wrapper around the Phoenix `Socket` for the pre-v1 topic. It had no reconnect handling
of its own, no watermark, no acks, no token refresh, no types, no tests and no build, and it called `console.log`.
Protocol v1 ([spec](../protocol/v1.md)) gives clients what they need for zero data loss: per-conversation `seq`,
replay from a watermark, `clientId` de-duplication with `ack`, `retryAfterMs` on closes and errors, and mid-session
`auth`. The server ships three transports: the native endpoint, the Phoenix binding (activities still in the pre-v1
`activitySet` shape) and Server-Sent Events. Issue #46 asks for a headless TypeScript client that uses all of this. The
scope note on the issue keeps the widget in chativa and the bot side in `@converger/agent` (#67). The OpenAPI document
(#45) was being written at the same time and was not on `main`.

## Decision drivers

- No message lost or stored twice across crashes, reconnects and reloads.
- One implementation of the session rules, whichever transport carries it.
- Runs in browsers, Node and React Native with no runtime dependencies (no `phoenix`, no `ws`).
- Matches what the server really does today, not the planned parts of the spec.
- Types can move to generated ones (OpenAPI #45, JSON Schemas) without breaking the public API.

## Considered options

1. **A session core plus transport adapters that normalise to v1 frames**, with our own Phoenix V2 serializer
2. **Wrap the `phoenix` npm client**, as `converger_js` did, and add the protocol on top
3. **The native endpoint only**, with no Phoenix or SSE support

For the outbox:

- A. **Persist, then resend every unacked send after `welcome`**
- B. **Persist, wait for the replay to reach the welcome head, settle sends whose turn shows up with their clientId, then resend the rest once**
- C. In-memory only

### Pros and cons of the options

#### Option 1

- Good, because reconnect, watermark, gap fill, outbox and token refresh exist once and are tested once against a mock
  server. A transport is a small adapter.
- Good, because without a `phoenix` dependency the package has no runtime dependencies. Phoenix's V2 framing
  (`[join_ref, ref, topic, event, payload]`, heartbeat on `phoenix`) is small.
- Bad, because the Phoenix adapter has to translate `activitySet` into v1 frames and derive `seq` from the set's
  watermark, since activities on that binding carry none. That is exact for owned conversations and best-effort for
  routed sockets whose middleware halts activities.

#### Option 2

- Good, because long-polling comes for free.
- Bad, because the `phoenix` client's own reconnect loop has no jitter by default and runs `onClose` after it has
  already scheduled the reconnect. It would fight the session's backoff and `retryAfterMs` handling.
- Bad, because the native endpoint, the transport #26 made the primary one, would still need its own code.

#### Option 3

- Good, because it is the simplest.
- Bad, because it gives nothing to networks that block WebSockets, although the server has an SSE fallback.

#### Outbox A / B / C

- A is simple. A send stored just before the crash is resent; the server answers `duplicate: true` and nothing is
  stored twice, but the turn is sent twice.
- B uses the replay that the reconnect causes anyway. The server includes the sender's `clientId` on its own replayed
  turns, so a send that was committed but never acked is settled from the replay and not resent. Each unacked send goes
  on the wire at most once per connection. It costs a short wait (until the head seq arrives, at most 5 s) before the
  resend.
- C loses messages on reload, which the issue rules out.

## Decision

Chosen: **Option 1 with outbox B**.

- `packages/client-ts` (`@converger/client`) is a pnpm workspace package at the repository root (`pnpm-workspace.yaml`).
  It builds ESM and CJS with tsup, uses strict TypeScript, and has no runtime dependencies.
- `Conversation` is the session core. It tracks the watermark (the highest contiguous seq, own acks included), drops
  duplicates by seq, and fills gaps with `sync` after 1.5 s or when a `heartbeat`'s `headSeq` is ahead. It handles
  `replayTruncated`, `replay_unavailable` and `invalid_watermark`, and reconnects with equal-jitter exponential backoff
  floored by `retryAfterMs`. It stops on 4400, 4403 and 1008, and refreshes the token first after 4401. The reconnect
  `hello` carries the user id from the first `welcome`, so the `ws:<user>:<clientId>` namespace stays stable for tokens
  without a `user_id` claim.
- Sends get a UUID `clientId` and are written to a `KeyValueStorage` outbox (`localStorage` in browsers, memory
  elsewhere, pluggable and sync or async) together with the resume state, before they go on the wire. Retryable errors
  are retried with the same `clientId` after `retryAfterMs`; other errors drop the send.
- Transports implement `connect` / `send` / `close` and emit v1 frames:
  - `native`, the default: the token in `hello`, `ping` after `idleTimeoutMs / 2` of silence, a liveness timeout.
  - `phoenix`: own V2 framing, `activitySet` mapped to frames, a synthesised `welcome` with an unknown head, so the
    resend happens right away.
  - `sse`: a `fetch` stream with the token in a header. Sends are REST `POST` with `X-Idempotency-Key:
    ws:<user>:<clientId>`, so a resend across transports is stored once; the `ack` is synthesised when the turn arrives
    on the stream.

  The default order is `["native", "sse"]`, and the client falls back after two connects that never open.
- Types: protocol frames are hand-written from the spec and schemas. REST types live in `src/rest/openapi.ts` in the
  `openapi-typescript` shape, re-exported under stable names from `src/rest/types.ts`. `pnpm generate:types`
  regenerates the file once `priv/static/openapi.json` exists. `ConvergerApiError` reads both the planned error
  envelope and today's shapes.

## Consequences

### Positive

- The acceptance test runs against the real server: kill it mid-session, and the client reconnects, receives what it
  missed through the watermark, and puts the unacked message on the wire exactly once. It also runs on the Phoenix and
  SSE transports.
- No runtime dependencies, one code path for all transports, typed events and typedoc output.

### Negative and trade-offs

- On the Phoenix binding, seqs are derived until #22 sends v1 frames there. Routed sockets with halting middleware can
  get wrong seqs; the native endpoint is the recommended transport.
- The resend after a reconnect waits for the replay, up to 5 s on a conversation with a large backlog.
- An own turn that is replayed **without** a clientId (sent with a token whose `user_id` differs from the session's)
  cannot be told apart from someone else's and is reported as an `activity`.
- No MessagePack and no channel-scoped sockets in this package.
- The package `license` is `UNLICENSED` until the project settles the npm license.

### Follow-ups

- [#45](https://github.com/AimTune/converger/issues/45): run `generate:types` against the OpenAPI document and check
  the aliases in `src/rest/types.ts`.
- [#67](https://github.com/AimTune/converger/issues/67): `@converger/agent` and the shared `@converger/protocol` package
  (frame codec, reconnect, outbox). Generating protocol types from `priv/protocol/v1/` belongs there.
- [#22](https://github.com/AimTune/converger/issues/22): v1 framing on the Phoenix binding removes the seq derivation.

## Implementation

- `packages/client-ts/src/conversation.ts` (session core), `src/client.ts`, `src/transport/{native,phoenix,sse}.ts`,
  `src/storage/{storage,outbox}.ts`, `src/token.ts`, `src/rest/*`, `src/errors.ts`, `src/protocol/*`.
- Tests: `test/unit` (vitest against `test/support/mock-server.ts`, a mock of the native endpoint, plus transport and
  REST tests) and `test/e2e` (`mix phx.server` started, killed and restarted by `test/e2e/server.ts`).
- CI: `.github/workflows/client-ts.yml` (typecheck, unit, build, typedoc, e2e with PostgreSQL) and
  `client-ts-publish.yml` (npm publish with provenance on a `client-ts-v*` tag).
- Examples: `examples/typescript/react-widget`, `examples/typescript/node-bot`. `converger_js/` was removed.

## Links

- [TypeScript SDK](../sdk/typescript.md)
- [Converger Protocol v1](../protocol/v1.md), sections 3, 6, 7 and 12
- [WebSocket limits and draining](../operations/websocket-limits.md)
