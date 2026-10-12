---
title: TypeScript SDK (@converger/client)
description: The headless TypeScript client for Converger Protocol v1 - install, usage, events, reconnect and outbox semantics, token refresh, transports and REST helpers.
sidebar_position: 1
---

`@converger/client` is a headless TypeScript client for [Converger Protocol v1](../protocol/v1.md). It runs in
browsers, in Node 20+ and in React Native, and has no runtime dependencies. The source is in
[`packages/client-ts`](https://github.com/AimTune/converger/tree/main/packages/client-ts). The design is recorded in
[ADR-0051](../adr/0051-typescript-sdk-transport-abstraction-and-outbox.md).

Which client to use:

| you are building | use |
| --- | --- |
| a web chat widget | [chativa](https://github.com/AimTune/chativa) with `@chativa/connector-converger` |
| a bot or an agent console that serves a whole channel | `@converger/agent` (channel-scoped sockets, planned in [#67](https://github.com/AimTune/converger/issues/67)) |
| a Node service, a React Native app, a custom UI | **`@converger/client`** (this page) |

> **Status:** implemented in [#46](https://github.com/AimTune/converger/issues/46). The package is built and tested in
> CI. It is published to npm by the `client-ts-publish` workflow when a `client-ts-v*` tag is pushed; no version has
> been published yet.

## Install

```sh
npm install @converger/client
# pnpm add @converger/client
```

The package ships ESM and CommonJS builds with type declarations. It uses the platform's `WebSocket`, `fetch` and, in
browsers, `localStorage`. On Node 20 (which has no global `WebSocket`), pass one from the
[`ws`](https://www.npmjs.com/package/ws) package as the `WebSocket` option.

## Usage

```ts
import { ConvergerClient } from "@converger/client";

const client = await ConvergerClient.connect({
  baseUrl: "https://converger.example.com",
  // Your backend calls POST /api/v1/converger/tokens/generate with the
  // channel secret and returns the token. Never ship a channel secret.
  tokenProvider: async ({ reason }) => {
    const response = await fetch("/api/converger-token", { method: "POST" });
    const { token, expires_in } = await response.json();
    return { token, expiresIn: expires_in };
  },
});

const conversation = client.conversation();
conversation.on("activity", (frame) => render(frame));
conversation.on("connectionState", ({ state }) => showStatus(state));

await conversation.start();                        // resolves on `welcome`
const ack = await conversation.send("Where is my order?"); // resolves on `ack`: {clientId, id, seq, duplicate}

// Later, or after a reload:
const resumed = client.conversation(conversationId);
await resumed.resume();     // from the stored watermark (0 = the whole transcript)
await resumed.resume(17);   // or from an explicit one
```

`ConvergerClient.connect` fetches the first token, so a broken `tokenProvider` fails right away. It opens no socket yet.
Each conversation has its own connection: the native endpoint serves one conversation per connection.

`start()` opens a new conversation, or the conversation a token is restricted to. With a channel-level token that carries
`user.id`, the server creates the conversation in the handshake ([section 3.2](../protocol/v1.md#32-identity-resolution)).
`resume()` needs the conversation id.

### Events

| event | payload | when |
| --- | --- | --- |
| `activity` | `ActivityFrame`: `text`, `event`, `conversationUpdate`, rich and mekik frames | a persistent frame, live or replayed. Each seq is emitted once; own turns acknowledged in this session are not repeated |
| `deliveryStatus` | `DeliveryStatusFrame` | delivery progress or a read receipt ([section 8.1](../protocol/v1.md#81-deliverystatus-implemented-25)) |
| `typing` | `TypingFrame` | another participant typing |
| `presence` | `PresenceFrame` | a participant online or offline |
| `connectionState` | `{state, previous, attempt, delayMs?, transport, close?, error?}` | `connecting`, `open`, `reconnecting`, `closed` |
| `welcome` | `welcome.data` | every handshake, with limits, capabilities and `expiresAt` |
| `sent` | `{clientId, id, seq, duplicate}` | a send was acknowledged, including sends restored from storage |
| `sendFailed` | `{clientId, error}` | a send was rejected for good |
| `replayTruncated` | `{watermark, headSeq}` | more than `replayMax` frames were missing; the client keeps syncing |
| `error` | `ConvergerError` | non-fatal: protocol errors, storage failures, token refresh failures |

Other calls: `conversation.typing(true)`, `conversation.markRead(seq?)`, `conversation.history({limit})` (an async
iterator over REST pages), `conversation.upload(file, {activity})`, `conversation.closeConversation()` and
`reopenConversation()`, `conversation.disconnect()` and `client.close()`.

## Reconnect and resume

- On every close except `4400` (unsupported protocol), `4403` (channel inactive, forced disconnect) and `1008`
  (conversation not found), the client reconnects with jittered exponential backoff. The delay is
  `min(maxDelayMs, initialDelayMs * factor^(attempt-1))` with 50 % "equal jitter", by default 1 s, 2 s, 4 s and so on
  up to 30 s. A `retryAfterMs` from the close reason (`1012` draining, `4503` slow consumer) or from an `error` frame is a
  floor. After `4401` the client asks the `tokenProvider` for a new token (`reason: "rejected"`) before reconnecting; it
  gives up after three rejections in a row. `reconnect: false` turns reconnects off, and `maxAttempts` bounds them.
- The **watermark** is the highest seq up to which the client has seen every persistent frame. Own turns count through
  their `ack`. The reconnect `hello` carries the conversation id, the watermark and the user id the server assigned in
  the first `welcome`, so a session without a `user_id` claim keeps its identity and its clientId namespace. The server
  replays everything above the watermark ([section 6.2](../protocol/v1.md#62-replay)). Frames at or below it, or seen
  twice, are dropped.
- **Gaps** (a seq that never arrived, for example a PubSub message lost between nodes) are filled with `sync` after
  1.5 s, also when a `heartbeat`'s `headSeq` is ahead of the watermark. `replayTruncated` and `replay_unavailable` lead
  to a `sync` from the right position. `invalid_watermark` (the client is ahead of the server, for example after a
  database restore) resets the watermark to 0.
- The native transport sends `ping` after `idleTimeoutMs / 2` of its own silence and drops a connection that has been
  silent for `idleTimeoutMs` plus 15 s, so a half-open TCP connection is noticed.

## Outbox: exactly-once sends

Every send gets a `clientId` (a UUID unless you pass one). It is written to the outbox **before** it goes on the wire,
and removed when its `ack` arrives.

- After a reconnect the client first waits for the replay to reach `welcome.data.watermark` (the head), at most 5 s. A
  turn the server stored before the connection dropped shows up there with its `clientId`; the send is settled from it
  and **not** resent. Then each remaining send goes on the wire **once** per connection, in order, with its original
  `clientId`, and at most `maxInFlight` at a time.
- The server stores a `clientId` under `ws:<user>:<clientId>` at most once, and answers a resend with the original ack
  plus `duplicate: true` ([section 7](../protocol/v1.md#7-sending-acks-and-idempotency-implemented-native-endpoint-26-phoenix-binding-24)).
  Each message is therefore persisted exactly once, however often the connection drops.
- Retryable errors (`rate_limited`, `too_many_in_flight`, `unavailable`, `internal`) are retried with the same
  `clientId` after `retryAfterMs`. Any other error rejects the `send()` promise, removes the send from the outbox and
  emits `sendFailed`.
- **Storage** is pluggable (`KeyValueStorage`: `getItem`, `setItem`, `removeItem`, sync or async). The default is
  `localStorage` in browsers and memory in Node and React Native; for React Native, wrap AsyncStorage. The outbox and the
  resume state (conversation id, user id, watermark) are stored per conversation under `<storageKey>:conversation:<id>`.
  After a reload, `resume()` restores both, resends what is pending and reports the results as `sent` events (the old
  promises are gone). `disconnect()` keeps the outbox; `discardOutbox()` drops it.

## Tokens

The `tokenProvider` is called once at connect (`reason: "initial"`), before the token expires (`"refresh"`) and after
the server rejected one (`"rejected"`). It returns a token string or `{token, expiresAt?, expiresIn?}`. Without an
expiry, the client reads the JWT's `exp`. The refresh runs `refreshSkewMs` (default 60 s, at most half the lifetime)
before `welcome.data.expiresAt`. On the native endpoint the new token is sent as `auth` and the server confirms with
`tokenRefreshed`, so the connection stays open ([section 3.3](../protocol/v1.md#33-rejection-expiry-and-refresh)). On
the other transports it is used for the next connection.

`createRefreshingTokenProvider({baseUrl, token})` renews a token you already have with
`POST /api/v1/converger/tokens/refresh`. Renewal only works while that token is still valid. `generateToken({baseUrl,
secret, userId})` is for servers only.

## Transports

| transport | endpoint | notes |
| --- | --- | --- |
| `nativeTransport()` (default) | `wss://HOST/socket/converger/v1`, subprotocol `converger.v1` | the full protocol. The token goes in `hello.token`, not in the URL |
| `phoenixTransport()` | `/socket/converger/websocket`, topic `converger:conversation:ID` | activities arrive as pre-v1 `activitySet`s, are mapped to v1 frames, and get their seq from the set's watermark. Sends use the `frame` event (#24). No mid-session `auth` (#22). Needs a conversation: `start()` creates one over REST and joins with the conversation token |
| `sseTransport()` | `GET /api/v1/converger/conversations/ID/events` + `POST .../activities` | for networks without WebSockets. Read with `fetch`, so the token travels in the `Authorization` header. Sends carry `X-Idempotency-Key: ws:<user>:<clientId>`, so a resend across transports is still stored once. No `typing` or `read` |

The default is `["native", "sse"]`: if the WebSocket never connects `fallbackAfterAttempts` times in a row (default 2),
the client switches to SSE. Custom transports implement the `Transport` interface (`connect`, `send`, `close`, plus
`onOpen`, `onFrame` and `onClose` callbacks). The client does not offer MessagePack (`converger.v1+msgpack`).
Channel-scoped sockets belong to `@converger/agent` (#67).

## REST helpers and errors

`client.rest` (a `RestClient`) wraps the [client API](../api/client-api.md): `createConversation`,
`getConversation`, `closeConversation`, `reopenConversation`, `postActivity` (with an `idempotencyKey`),
`listActivities` and `history` (paged by `has_more`), `allActivities`, `upload` (multipart) and
`downloadAttachment`.

Failed requests throw `ConvergerApiError` with `status`, `code`, `message`, `details`, `requestId` and
`retryAfterMs` (from `Retry-After`). It understands the standard error envelope
`{"error": {"code", "message", "details", "request_id"}}` (planned in
[#45](https://github.com/AimTune/converger/issues/45)) and the shapes the API returns today: `{"error": "..."}`,
`{"error": "conversation_closed", "detail": "..."}`, `{"errors": {"detail": "..."}}` and changeset errors keyed by field.
Protocol errors are `ConvergerProtocolError` (`code`, `number`, `retryable`, `retryAfterMs`, `details`, `clientId`).

## Types

The protocol frame types are hand-written from this specification and the JSON Schemas in `priv/protocol/v1/`. The
REST types live in `src/rest/openapi.ts` in the shape `openapi-typescript` generates. When the OpenAPI document
`priv/static/openapi.json` exists (#45), `pnpm --filter @converger/client generate:types` regenerates that file, and the
public names in `src/rest/types.ts` stay the same. API reference: `pnpm --filter @converger/client run docs` (typedoc).

## Tests and CI

- Unit tests (vitest) drive the client against an in-process mock of the native endpoint: handshake, replay, acks and
  clientId de-duplication, crashes before and after commit, close codes, `retryAfterMs`, gap fill, token refresh,
  storage. The Phoenix and SSE transports and the REST client have their own tests.
- An end-to-end test (`test/e2e`) starts the real server with `mix phx.server`. It sends a message, kills the server
  process tree, sends while the server is down, restarts it, and posts two activities the client has not seen. It then
  checks that the client reconnects, receives both through its watermark, puts the unacknowledged message on the wire
  exactly once, and that the server stored every message once. It also runs a send and receive over the Phoenix and SSE
  transports.
- CI: the `client-ts` workflow (`.github/workflows/client-ts.yml`) runs typecheck, unit tests, the build, typedoc and
  the e2e test against PostgreSQL. `client-ts-publish.yml` publishes to npm with provenance when a `client-ts-v*` tag
  is pushed. It needs the `NPM_TOKEN` secret.

## Examples

- [`examples/typescript/react-widget`](https://github.com/AimTune/converger/tree/main/examples/typescript/react-widget):
  a React chat widget with resume, an offline outbox, typing and read receipts.
- [`examples/typescript/node-bot`](https://github.com/AimTune/converger/tree/main/examples/typescript/node-bot): a Node
  participant that answers every message and survives server restarts.
- [`examples/python/converger_ws.py`](https://github.com/AimTune/converger/blob/main/examples/python/converger_ws.py):
  the protocol with nothing but Python's `websockets`.
