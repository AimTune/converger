---
title: Agent SDK (@converger/agent)
description: Serve every conversation of a channel from one socket with onTurn(turn, reply) - the API shared by the agent SDKs, its mapping to Protocol v1 frames, groups, reconnect and resume, testing, and the create-converger-agent template.
sidebar_position: 6
---

An **agent** is the bot side of Converger: an AI backend (an LLM tool loop, a LangChain graph, a rules engine) that
answers the end users of every channel routed to it. The agent SDKs give it one API, `onTurn(turn, reply)`, on top of
a [channel-scoped socket](../protocol/v1.md#10-channel-scoped-sockets-implemented-64-on-the-native-endpoint): one
WebSocket that multiplexes every conversation of the agent's channel. The design is recorded in
[ADR-0067](../adr/0067-agent-sdk-api-and-wire-mapping.md); the server side in
[ADR-0063](../adr/0063-channel-scoped-agent-sockets-and-the-bot-relay.md).

| SDK | Package | Source |
| --- | --- | --- |
| TypeScript (Node 20+) | `@converger/agent` | [`packages/agent-ts`](https://github.com/AimTune/converger/tree/main/packages/agent-ts) |
| Project template | `create-converger-agent` | [`packages/create-converger-agent`](https://github.com/AimTune/converger/tree/main/packages/create-converger-agent) |
| Example | Claude tool loop | [`examples/agents/llm-tool-loop-ts`](https://github.com/AimTune/converger/tree/main/examples/agents/llm-tool-loop-ts) |

The Python, Go, .NET and Elixir agent SDKs of [#67](https://github.com/AimTune/converger/issues/67) expose the same
names (in each language's casing) and the same wire mapping.

> **Status:** `@converger/agent` and `create-converger-agent` are published on npm from 0.1.0
> ([#67](https://github.com/AimTune/converger/issues/67), [Releasing the SDKs](releasing.md)).

## Setup

1. Create a `websocket` channel for the agent and note its secret.
2. Add a routing rule from each end-user channel (web widget, WhatsApp, Telegram, ...) to the agent's channel
   ([routing rules](../concepts/routing-rules.md)). Replies are routed back to the end user's channel.
3. Run the agent with the channel secret. It issues itself channel-scoped tokens
   (`POST /api/v1/converger/tokens/generate` with `{"scope": "channel"}`, [Client API](../api/client-api.md#generate-a-token))
   and renews them before they expire.

```sh
npx create-converger-agent my-agent    # or: npm install @converger/agent
```

```ts
import { channelTokenProvider, createAgent } from "@converger/agent";

const url = "https://converger.example.com";
const agent = createAgent({
  url,
  getToken: channelTokenProvider({ url, secret: process.env.CONVERGER_CHANNEL_SECRET! }),
  group: "support-bot",
});

agent.onTurn(async (turn, reply) => {
  await reply.typing();
  const stream = reply.stream();
  for await (const delta of model.stream(turn.text)) stream.write(delta);
  await stream.end();
});

await agent.start();
```

The channel secret must stay on the agent's backend. On Node 20, which has no global `WebSocket`, pass the `ws`
package: `createAgent({ ..., WebSocket })`.

## API

### `createAgent(options)`

| option | default | |
| --- | --- | --- |
| `url` | required | Converger base URL, or the endpoint URL `wss://HOST/socket/converger/v1` |
| `token` or `getToken({reason})` | required | a channel-scoped token, or a function returning one; `getToken` is called on every connect (`reason: "connect"`), before expiry (`"refresh"`, sent as `auth`) and after a 4401 (`"rejected"`) |
| `group` | none | the agent group (`hello.group`), see [Groups](#groups) |
| `userId` | none | `hello.userId`: the sender of the replies when the token has no `user_id` (default sender `agent`) |
| `logger` | silent | `console` or anything with `debug`/`info`/`warn`/`error` |
| `WebSocket` | global | a WebSocket constructor, e.g. from `ws` |
| `reconnect` | 1 s doubling to 30 s, 50 % jitter | `false` disables; `retryAfterMs` from the server is a floor |
| `watermarks` | `{}` | resume positions to start from (see `agent.watermarks()`) |
| `maxTrackedConversations` | 1000 | conversations whose position is tracked and sent in `hello.watermarks` (least recently active dropped) |
| `maxInFlight` | 32 | unacknowledged message sends |
| `maxFramesPerSecond` | 15 | outbound pacing (the server allows 20 frames per second per connection) |
| `ackTimeoutMs` / `sendTimeoutMs` | 10 s / 120 s | resend an unacknowledged message with the same `clientId` / give up |
| `maxConcurrentTurns` | 64 | handlers running at once across conversations |
| `includeBotTurns` | `false` | also dispatch message frames with `from: "bot"` (other agents, human agents) |
| `streamMode` | `"genui"` | how `reply.stream()` is delivered, see [Streaming](#streaming) |
| `streamFlushMs` | 150 | stream deltas are coalesced into one frame per interval |
| `runFrames` | `true` | send `run` frames around handlers |

### `Agent`

| member | |
| --- | --- |
| `onTurn(handler)` | the turn handler, `(turn, reply) => Promise<void>` |
| `onFrame(handler)` | every inbound frame, bare (`conversationId` undefined) or enveloped; returns an unsubscribe function |
| `start()` | connect; resolves at the first `welcome`, rejects when the first connection is refused for good (4400, 4401 without `getToken`, 4403) |
| `stop({timeoutMs?})` | abort running turns, let them finish their sends, close |
| `on(event, listener)` | `connected` (the `welcome`), `disconnected` `{code, reason, willReconnect, retryInMs}`, `error` (`AgentError`), `resume` `{conversationId, answers, matched}` |
| `reply(conversationId)` | a `reply` outside a turn, for proactive messages (no `run` frames) |
| `send(conversationId, frame)` | a raw agent frame |
| `watermarks()` | `{conversationId: seq}`; persist it and pass it back as `watermarks` to resume after a restart |
| `connected`, `channelId`, `welcome` | connection state |

### `turn`

| field | |
| --- | --- |
| `conversationId` | the conversation, on whichever channel the user is |
| `text` | `data.text`, else a caption or title, else the tapped action's label, else `""` |
| `message`, `type`, `data` | the message frame, its type (`text`, `image`, `location`, ...) and payload |
| `attachments` | legacy `data.attachments`, or the data of an `image` / `file` / `video` / `audio` message |
| `participant` | `message.sender` (`{id, role}`) |
| `channel` | `meta.channel` or `metadata.channel` when the frame carries one |
| `meta` | the user turn's per-turn context (`meta`, relayed and never stored) |
| `metadata`, `action` | stored metadata, and `metadata.action` of a tapped button or numeric reply ([messages, section 6](../protocol/messages.md#6-answers-come-back-as-one-shape-implemented-68-64)) |
| `replyTo`, `id`, `seq` | the activity the turn answers, and the turn's own id and seq |
| `signal` | an `AbortSignal`, aborted when the user sends `abort` or the agent stops |
| `raw` | the `{conversationId, frame}` envelope |
| `history({since?, limit?, timeoutMs?})` | the conversation's persistent frames, oldest first |

`history()` sends an enveloped `sync {watermark: since}` and collects the replay (at most `replayMax`, 10 000 frames);
replayed frames are never dispatched as turns. It does not use `GET /api/v1/converger/conversations/:id/activities`,
because that endpoint only accepts a token of the conversation's own channel, and the conversations an agent serves are
usually routed from another channel.

### `reply`

| method | resolves with |
| --- | --- |
| `text(text, {actions?, metadata?, replyTo?, id?})` | the `ack` |
| `message(type, data, options?)` | the `ack` |
| `stream({mode?})` | a stream: `write(delta)`, `end()`, `text`, `streamId` |
| `toolCall(id, status, {name, params?, result?, error?, description?})` | written (`name` is remembered after the first call for an id) |
| `ui(component, props?, {id?})` | the chunk id (send again with it to update the component in place) |
| `ask(payload, {actions?, ui?, id?, timeoutMs?, signal?})` | the answer; a string payload becomes `{title: payload}` |
| `typing(on = true)` | written; refreshed every 4 s while on |
| `send(frame)` | a raw frame in this conversation |
| `end()` | idempotent; called automatically when the handler returns |

In TypeScript, `message(type, data)` checks `data` against the message type's schema for the vocabulary's types
(`buttons`, `card`, `carousel`, `quick-reply`, `image`, `file`, `video`, `audio`, `location`, `contact`, `text`;
see `MessageDataMap`); any other type name takes an object.

### Types generated from the schemas

The TypeScript SDK's protocol types are generated from the Protocol v1 JSON Schemas (`priv/protocol/v1/`, published
under `https://converger.aimtune.dev/schemas/protocol/v1/`, the single source of truth of [messages.md](../protocol/messages.md)
and [Protocol v1](../protocol/v1.md)):

- `packages/agent-ts/scripts/generate-types.mjs` compiles the message data schemas (`messages/*.schema.json`), the
  server frames (`frames/server/*`), the client and agent frames (`frames/client/*`, `frames/channel/*`) and the
  shared definitions (`common.schema.json`) with `json-schema-to-typescript` into `src/generated/protocol.ts`. `$ref`s
  are resolved from `priv/protocol/v1`, never fetched.
- `src/frames.ts` gives them the SDK's public names (`WelcomeFrame`, `AckFrame`, `ErrorData`, `HelloFrame`,
  `ToolCallData`, `InterruptData`, `AIChunk`, ...), exports the message data types (`ButtonsMessageData`,
  `CardMessageData`, ...) and `MessageDataMap`, and every generated type under the `protocol` namespace
  (`protocol.ServerPresenceFrame`). `MessageFrame` and `InboundFrame` stay hand-written and open, because a receiver
  ignores unknown fields and frame types (section 5.5).
- The generated file is committed. After changing a schema run `pnpm --filter @converger/agent run generate:types`
  (`run check:types` only checks); the `agent-ts` workflow regenerates it and fails when it differs from the commit.

## Wire mapping

Every frame below travels in a `{conversationId, frame}` envelope and is valid against
`priv/protocol/v1/frames/channel/agent-frame.schema.json` (the SDK's unit tests check every helper against it).

| SDK | frames |
| --- | --- |
| `start()` | `hello {protocol: "converger/1", token, group?, userId?, watermarks?}`, answered by a channel `welcome` |
| a user turn | a message frame with `from: "user"` (`text` or a typed message; `meta` and `metadata.action` when present) |
| handler starts / returns | `run {status: "started"}` / `run {status: "finished" \| "error" \| "aborted"}` |
| `reply.text` / `reply.message` | `{type, clientId, data, actions?}`, answered by `ack {clientId, id, seq}` |
| `reply.stream()` | `genui {streamId, done: false, chunk: {type: "text", content, id}}`; all deltas of one stream share one chunk id (one growing bubble, as mekik's `emitToken`), each stream a new one |
| `reply.ui` | `genui {streamId, done: false, chunk: {type: "ui", component, props, id}}` |
| `reply.end()` after genui | `genui {streamId, done: true, chunk: {type: "event", name: "stream_done"}}` |
| `reply.toolCall` | `tool_call {data: {id, name, status, params?, result?, error?, startedAt, endedAt?}}` |
| `reply.ask` | `interrupt {id, data: {payload, actions?, ui?}}` and `run {status: "interrupted"}`; on `resume {answers: {id: value}}`: `interrupt_resolved {id, data: {answer}}` and `run {status: "started"}` |
| `reply.typing` | `typing {isTyping}` |
| `turn.history` | `sync {watermark}` |
| end user's `abort` | aborts `turn.signal` |

A turn's genui frames share one `streamId` per turn. `ask` works on every channel: chativa sends `resume` itself, and
the hub turns a tapped WhatsApp or Telegram button (or a numeric reply) that answers an open interrupt into `resume`
([Protocol v1, section 9](../protocol/v1.md#9-the-bot-channel-and-mekik-relay-implemented-64)). Asks live in the
agent's memory: an answer that arrives after a restart is emitted as a `resume` event with `matched: []`.

### Streaming

| `streamMode` | web (chativa, mekik clients) | WhatsApp, Telegram, email, SMS |
| --- | --- | --- |
| `genui` (default) | tokens appear live | nothing until the hub joins genui text chunks into one message when the stream is done (Planned, [#68](https://github.com/AimTune/converger/issues/68)); today genui has no text fallback |
| `text` | one message at the end | one message at the end |
| `genui+text` | live tokens, then the same text again as a message | one message at the end |

Deltas are coalesced (`streamFlushMs`), because every chunk is a stored activity and the server accepts 20 inbound
frames per second per connection.

## Groups

Processes started with the same `group` share the channel's conversations: the server delivers each user turn to one
member (rendezvous hashing), so a turn is answered once, and every turn of a conversation goes to the same member
while the membership is stable. Without a group, every connection sees every conversation. Groups are how an agent
scales horizontally and how a second process takes over without duplicate replies
([Protocol v1, section 10](../protocol/v1.md#10-channel-scoped-sockets-implemented-64-on-the-native-endpoint),
[ADR-0069](../adr/0069-agent-group-eligibility-and-takeover.md)):

- A process that joins serves turns committed about a second (the server's `group_settle_ms`) after it connected, and
  takes over only some conversations; a turn already handed to another member is never delivered to it.
- When a process stops or crashes, the remaining members take its conversations over and receive their unanswered
  user turns (no bot or agent frame after them) once, then every later turn.
- Converger does not serialise turns: a conversation's next turn can arrive while the handler of the previous one is
  running. The SDK queues turns per conversation; an agent that rejects concurrent turns instead sends
  `error {code: "busy"}` (`reply.send`), which reaches the end user.

## Reconnect, resume and delivery

- **Resume.** The SDK tracks, per conversation, the highest `seq` it has seen (delivered frames and the acks of its
  own sends) and sends them in `hello.watermarks` on reconnect, so the server replays exactly what was missed. A frame
  already seen is not dispatched again; a frame below the highest seq that was not seen yet (a user turn delivered
  after the agent's own ack) still is.
- **Reconnect.** Jittered exponential backoff, never earlier than `retryAfterMs` (from an `error` frame or the JSON
  close reason of 1012 and 4503). 4400 stops; 4401 reconnects only with `getToken` (asked with `reason: "rejected"`);
  4403 before the first `welcome` fails `start()`. See [close codes](../protocol/v1.md#123-close-codes).
- **Sends.** Message frames carry a `clientId` (a random per-process prefix plus a counter, since the server keeps
  idempotency keys for the lifetime of the activity). A send resolves with its `ack`; unacknowledged sends are re-sent
  with the same `clientId` after a reconnect or `ackTimeoutMs` (the server answers duplicates with the original ack).
  Retryable errors (`rate_limited`, `too_many_in_flight`, `unavailable`, `internal`) are retried after `retryAfterMs`;
  others reject the send with an `AgentError`. mekik-native frames (`tool_call`, `genui`, `interrupt`) have no ack and
  are sent at most once.
- **Back-pressure.** At most `maxInFlight` sends are unacknowledged, and frames are paced at `maxFramesPerSecond`.
  A bare `rate_limited` pauses the outbox for `retryAfterMs`.
- **Errors.** `AgentError` has `code`, `retryable`, `retryAfterMs`, `conversationId`, `number`, `clientId`,
  `frameType` and `details`. Error frames nobody awaits, and handlers that throw (`handler_error`), are emitted as
  `error` events.

## Testing

`@converger/agent/testing` exports `FakeConvergerServer`, an in-process fake of the native endpoint for
channel-scoped agents (needs the `ws` package):

```ts
import { FakeConvergerServer } from "@converger/agent/testing";

const server = await FakeConvergerServer.start();
const agent = createAgent({ url: server.url, token: "test" });
agent.onTurn(handler);
await agent.start();

const result = await server.turn("conversation-1", "refund ORD-42");
// result.texts, result.messages, result.toolCalls, result.streamed, result.interrupts, result.status
server.resume("conversation-1", { [String(result.interrupts[0]!["id"])]: { approved: true } });
```

The SDK's own suite runs against it (handshake, envelopes, turn dispatch, every reply helper validated against the
schemas, ask/resume, reconnect with watermarks, acks and resends, error mapping), and an e2e test runs against a real
server: `packages/agent-ts/test/e2e/README.md`.

## Related

- [Protocol v1](../protocol/v1.md), sections 9 (bot relay) and 10 (channel-scoped sockets)
- [WebSocket channel type](../channels/websocket.md#agents-and-bots-on-the-native-endpoint-protocol-v1)
- [Message types](../protocol/messages.md)
- [TypeScript client SDK](typescript.md), for end-user apps rather than agents
