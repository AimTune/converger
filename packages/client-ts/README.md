# @converger/client

Headless TypeScript client for [Converger](https://converger.aimtune.dev) Protocol v1 (`converger/1`).
It runs in browsers, Node 20+ and React Native, and has no runtime dependencies. It handles:

- **Reconnects** with jittered exponential backoff. A server's `retryAfterMs` is always honoured.
- **Watermark resume.** After any disconnect the client asks for everything after the highest seq it has seen, so
  nothing committed in the meantime is missed.
- **Acked sends.** `send()` returns a promise that resolves on the server's `ack`.
- **A persistent outbox.** Unacknowledged sends survive reconnects (and reloads, with `localStorage`). They are resent
  once per reconnect with their original `clientId`, and the server stores each `clientId` only once.
- **Token refresh** ahead of expiry, and a fresh token after the server rejects one.
- **Typed events**: `activity`, `deliveryStatus`, `typing`, `presence`, `connectionState`, and others.
- **REST helpers**: tokens, conversations, history paging, uploads.
- **Transports**: the native endpoint `/socket/converger/v1` (default), the Phoenix Channels binding, and a
  Server-Sent Events fallback.

The widget side is covered by [chativa](https://github.com/AimTune/chativa), and the bot/agent side by
`@converger/agent` ([#67](https://github.com/AimTune/converger/issues/67)). This package is for everything in
between: Node services, React Native apps, custom UIs.

## Install

```sh
npm install @converger/client
# or: pnpm add @converger/client
```

## Usage

```ts
import { ConvergerClient } from "@converger/client";

const client = await ConvergerClient.connect({
  baseUrl: "https://converger.example.com",
  // Your backend calls POST /api/v1/converger/tokens/generate with the channel
  // secret and returns the token. Never ship the channel secret to a client.
  tokenProvider: async () => {
    const response = await fetch("/api/converger-token", { method: "POST" });
    return response.json(); // { token, expiresIn? } or just the token string
  },
});

const conversation = client.conversation();
conversation.on("activity", (frame) => console.log(frame.seq, frame.type, frame.data));
conversation.on("connectionState", ({ state, delayMs }) => console.log(state, delayMs));

await conversation.start(); // resolves on `welcome`
const { id, seq } = await conversation.send("Where is my order?"); // resolves on `ack`

// Later, or after a reload: resume where you left off.
const again = client.conversation(conversation.conversationId!);
await again.resume(); // the stored watermark, or 0 for the whole transcript
```

### Events

| event | payload | when |
| --- | --- | --- |
| `activity` | `ActivityFrame` (`text`, `event`, `conversationUpdate`, rich frames) | a persistent frame from someone else, live or replayed, each seq once |
| `deliveryStatus` | `DeliveryStatusFrame` | delivery progress of an activity, or a read receipt (`upToSeq`) |
| `typing` | `TypingFrame` | another participant started or stopped typing |
| `presence` | `PresenceFrame` | a participant came online or went offline |
| `connectionState` | `{state, previous, attempt, delayMs?, close?, error?}` | `connecting`, `open`, `reconnecting`, `closed` |
| `welcome` | `welcome.data` | every completed handshake (limits, capabilities, expiry) |
| `sent` | `{clientId, id, seq, duplicate}` | a send was acknowledged (also restored sends, which have no promise) |
| `sendFailed` | `{clientId, error}` | a send was rejected for good and removed from the outbox |
| `error` | `ConvergerError` | non-fatal problems: protocol errors, storage or token refresh failures |

### Sending, typing, read receipts

```ts
await conversation.send({ text: "Here you go", metadata: { orderId: "ORD-42" }, replyTo: activityId });
conversation.typing(true);
conversation.markRead(); // everything up to the watermark
```

### REST helpers

```ts
for await (const page of conversation.history({ limit: 50 })) render(page.activities);
await conversation.upload(file, { activity: { text: "the invoice" } });
await client.rest.closeConversation(conversationId);

// Server side only:
import { generateToken } from "@converger/client";
const { token } = await generateToken({ baseUrl, secret: process.env.CHANNEL_SECRET!, userId: "user-42" });
```

`ConvergerApiError` carries `status`, `code`, `message`, `details`, `requestId` and `retryAfterMs`. It understands the
standard error envelope `{"error": {"code", "message", "details", "request_id"}}` and the older shapes.

## Reconnect and outbox semantics

- On every close except `4400` (unsupported protocol), `4403` (channel inactive or forced disconnect) and `1008`
  (conversation not found), the client reconnects. The delay is `min(maxDelayMs, initialDelayMs * factor^(n-1))` with
  50 % jitter, and never shorter than the server's `retryAfterMs`. After `4401` it first asks the `tokenProvider` for a
  new token (`reason: "rejected"`).
- The reconnect `hello` carries the conversation id, the user id the server assigned and the **watermark**, which is the
  highest seq up to which the client has seen everything. The server replays everything after it. Duplicates are dropped
  by seq. A gap (a seq that never arrived) is filled with `sync` after a short wait.
- Sends are written to the outbox before they hit the wire. After a reconnect the client waits for the replay to
  finish, settles any send whose turn shows up in it (stored before the crash, ack lost), and then puts each remaining
  send on the wire **once**. A resend of a `clientId` the server already stored is answered with the original ack plus
  `duplicate: true`, so every message is stored exactly once.
- Retryable send errors (`rate_limited`, `too_many_in_flight`, `unavailable`, `internal`) are retried with the same
  `clientId` after `retryAfterMs`. Other errors reject the promise and drop the send.
- `disconnect()` keeps the outbox. A later `resume()` of the same conversation with the same storage resends it, and
  the results arrive as `sent` events.

## Options

| option | default | |
| --- | --- | --- |
| `baseUrl` | (required) | `https://host[:port]` |
| `tokenProvider` | (required) | `({reason, previous}) => token \| {token, expiresAt?, expiresIn?}` |
| `transport` | `["native", "sse"]` | `"native"`, `"phoenix"`, `"sse"`, a `TransportFactory`, or a fallback list |
| `fallbackAfterAttempts` | `2` | failed connects (never opened) before the next transport |
| `reconnect` | `{initialDelayMs: 1000, maxDelayMs: 30000, factor: 2, jitter: 0.5}` | or `false` |
| `storage` | `localStorage` in browsers, memory elsewhere | any `KeyValueStorage` (sync or async, e.g. AsyncStorage) |
| `storageKey` | `"converger"` | key prefix |
| `refreshSkewMs` | `60000` | refresh this long before expiry (at most half the lifetime) |
| `WebSocket`, `fetch` | the globals | for Node < 22 pass `WebSocket` from the `ws` package |

## Transports

| transport | wire | notes |
| --- | --- | --- |
| `nativeTransport()` | `wss://HOST/socket/converger/v1`, raw v1 JSON frames | everything: handshake, replay, acks, `sync`, mid-session `auth`, receipts. The token goes in `hello`, not the URL |
| `phoenixTransport()` | `/socket/converger/websocket`, topic `converger:conversation:ID` | activities arrive as pre-v1 `activitySet`s and are mapped to v1 frames (seq derived from the set's watermark). No mid-session refresh. Needs a conversation, which `start()` creates over REST |
| `sseTransport()` | `GET .../conversations/ID/events` + `POST .../activities` | for networks that block WebSockets. Receive only; no `typing`/`read` |

MessagePack (`converger.v1+msgpack`) is not offered by this client. Channel-scoped sockets (`scope: "channel"`) are
`@converger/agent`'s job (#67).

## Types

Protocol frames are hand-written from `docs/protocol/v1.md` and the JSON Schemas in `priv/protocol/v1/`. REST types live
in `src/rest/openapi.ts` in the `openapi-typescript` shape. Once the server publishes `priv/static/openapi.json`
([#45](https://github.com/AimTune/converger/issues/45)), `pnpm generate:types` regenerates that file, and
`src/rest/types.ts` keeps the public names stable.

## Development

```sh
pnpm install
pnpm --filter @converger/client typecheck
pnpm --filter @converger/client test       # unit tests against a mocked server
pnpm --filter @converger/client build      # dist/ (ESM + CJS + .d.ts)
pnpm --filter @converger/client docs       # typedoc -> docs-api/
```

### Running the e2e test

`pnpm --filter @converger/client test:e2e` starts the real server with `mix phx.server` (`MIX_ENV=dev`, database
`converger_sdk_e2e`, port 4123; override with `E2E_MIX_ENV`, `E2E_DB_NAME`, `E2E_PORT`). It creates the database and a
channel, then kills the server mid-session. It needs Elixir and PostgreSQL (the `DB_*` variables of `config/dev.exs`)
and skips itself when `mix` is not installed. Set `E2E_SKIP=1` to skip it explicitly.

## License

Same terms as the Converger repository (see its README). The package license has to be settled before the first
publish (`license` in package.json is `UNLICENSED` until then).
