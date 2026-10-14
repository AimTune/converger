---
title: "ADR-0067: Agent SDK API and wire mapping"
sidebar_label: "0067 Agent SDK API and wire mapping"
description: Every agent SDK exposes one onTurn(turn, reply) API over a channel-scoped socket; reply.stream maps to genui text chunks, reply.ask to interrupt/resume, handlers are wrapped in run frames, and agent groups share a channel.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-14 |
| **Issue** | [#67](https://github.com/AimTune/converger/issues/67) |
| **Pull request** | (this PR) |
| **Related** | [ADR-0063](0063-channel-scoped-agent-sockets-and-the-bot-relay.md), [ADR-0062](0062-typed-message-payloads-on-message-activities.md), [ADR-0051](0051-typescript-sdk-transport-abstraction-and-outbox.md), [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md) |

## Context and problem statement

[ADR-0063](0063-channel-scoped-agent-sockets-and-the-bot-relay.md) gave agents a channel-scoped socket: one
connection, every conversation of the channel in `{conversationId, frame}` envelopes, user turns from any channel,
mekik-native frames (`tool_call`, `genui`, `interrupt`) stored and routed back. Using it directly means writing the
handshake, envelopes, acks, resume, reconnects, the interrupt/resume pairing and the frame shapes by hand, in every
language. Issue #67 asks for agent SDKs in TypeScript, Python, Go, .NET and Elixir that make a bot a few lines, as
mekik does for ilmek graphs, and that behave the same so docs, examples and the conformance suite are shared.

The questions: what API every SDK exposes, how each call maps to frames (in particular token streaming, which has no
plain-message equivalent, and human-in-the-loop questions), what happens around a handler, and how several agent
processes share a channel.

## Decision drivers

- One mental model and one set of names across languages; docs and examples written once.
- Faithful to the wire: every SDK call is one or a few frames that `agent-frame.schema.json` accepts, so mekik
  clients (chativa) render agent output exactly as they render a mekik bot's.
- Works on every end-user channel, not only the web widget.
- No message lost or duplicated across reconnects, restarts and several processes.
- No framework dependency in the core SDKs.

## Considered options

1. **`onTurn(turn, reply)` with semantic reply helpers, mapped to mekik-native frames** (stream to `genui` text
   chunks, ask to `interrupt`/`resume`, `run` frames around handlers).
2. **A raw frame API** (`onFrame`, `send(frame)`) with no turn abstraction.
3. **`onTurn` returning one reply value** (request/response, like the `webhook` adapter), streaming as plain `text`
   messages per chunk.

### Pros and cons of the options

#### Option 1

- Good, because a handler reads like the conversation: stream, show a tool, ask, answer.
- Good, because the frames are exactly mekik's, so chativa and other mekik/1 clients render streams, tool traces,
  GenUI and interrupts with no Converger-specific code.
- Bad, because `genui` text chunks reach only clients that render genui until the hub joins them for other channels
  (planned, #68); the SDKs need a `text` stream mode until then.

#### Option 2

- Good, because it is complete and simple to implement.
- Bad, because every bot re-implements turns, acks and interrupt bookkeeping; nothing is shared across languages.

#### Option 3

- Good, because it fits request/response backends.
- Bad, because there is no streaming, no tool trace, no interrupt; one stored message per chunk floods channels.

## Decision

Chosen option: **"Option 1"**, kept as the raw escape hatch of option 2 (`onFrame`, `send`).

- **API, the same in every SDK** (language casing aside): `createAgent({url, token | getToken, group?, logger?})`,
  `agent.onTurn(handler)`, `agent.onFrame(handler)`, `agent.start()`, `agent.stop()`, events `connected`,
  `disconnected`, `error`. `turn` has `conversationId`, `text`, `message`, `attachments`, `participant`, `channel`,
  `meta`, `action` (`metadata.action`), `replyTo`, `history()`. `reply` has `text(text, {actions})`, `stream()`,
  `message(type, data)`, `toolCall(id, status, {...})`, `ui(component, props)`, `ask(payload, {actions, ui, id})`,
  `typing(on)`, `end()`.
- **Wire mapping.** `text`/`message` send message frames with a `clientId` and resolve with the `ack`.
  `stream()` sends `genui` text chunks of the turn's stream, with one chunk id per stream (mekik `emitToken`);
  `ui()` a `genui` ui chunk; `end()` closes the turn's stream with a `done` `stream_done` event chunk. `toolCall` sends
  `tool_call`. `ask` sends `interrupt {id, data: {payload, actions?, ui?}}`, resolves with the value of the `resume`
  that answers that id (from chativa, or converted by the hub from a tapped button on any channel), then sends
  `interrupt_resolved {id, data: {answer}}`. A `text` stream mode (one message at the end) and `genui+text` exist for
  channels that do not render genui yet.
- **Run frames.** The SDK sends `run started` before a handler and `run finished` (or `error`, `aborted`) after it,
  and `run interrupted` / `run started` around an `ask`, as a mekik bot does; clients show progress without the agent
  doing anything.
- **Turns.** Message frames with `from: "user"` are turns; `from: "bot"` (the agent itself, other agents) is ignored
  by default. Turns of one conversation run one after another; conversations run concurrently. An end user's `abort`
  aborts the running turn.
- **Groups.** `group` is `hello.group`: the processes of a group share the channel's conversations, one member per
  conversation (ADR-0063), so scaling out never answers a turn twice.
- **Delivery.** Per-conversation watermarks (highest seq seen, capped list) in `hello.watermarks` on reconnect;
  jittered exponential backoff with `retryAfterMs` as a floor; `clientId` resends after reconnects and ack timeouts;
  bounded in-flight sends and outbound pacing below the server's per-connection rate; typed errors with `code` and
  `retryable`.
- **History** is read with an enveloped `sync` on the agent's socket, not over REST: the REST history endpoint accepts
  only tokens of the conversation's own channel, and served conversations are usually routed from another one.
- **Testing.** Each SDK ships a fake channel-scoped server for unit-testing agents (`@converger/agent/testing` in
  TypeScript), used by the `create-converger-agent` template.

## Consequences

### Positive

- An LLM tool loop, a LangChain graph or a rules bot becomes a `onTurn` handler and works on every routed channel.
- Agent output is indistinguishable from a mekik bot's for chativa, so the web experience (streaming, traces, GenUI,
  approvals) comes for free.
- The SDKs share docs, examples and a conformance surface.

### Negative and trade-offs

- Until the hub joins genui text chunks (#68), `stream()` in the default mode shows nothing on WhatsApp or Telegram;
  agents serving those channels choose the `text` stream mode.
- Every streamed chunk is a stored activity; deltas are coalesced, but streams still cost more storage than one
  message.
- Pending asks live in the agent's memory: an answer that arrives after the agent restarted cannot resume the handler
  and is surfaced as an unmatched `resume` event.
- mekik-native frames have no ack and are sent at most once.

### Follow-ups

- [#68](https://github.com/AimTune/converger/issues/68): join genui text chunks into one message for channels that do
  not render genui.
- [#67](https://github.com/AimTune/converger/issues/67): the Python, Go, .NET and Elixir SDKs with the same API; the
  LangChain adapter; publishing.

## Implementation

- `packages/agent-ts` (`@converger/agent`): `src/agent.ts` (connection, dispatch, outbox), `src/reply.ts` (wire
  mapping), `src/turn.ts`, `src/watermarks.ts`, `src/socket.ts`, `src/token.ts` (`channelTokenProvider`),
  `src/testing` (`FakeConvergerServer`).
- Tests: unit tests against the fake server with every agent frame validated against `priv/protocol/v1` (ajv); an e2e
  test against a real server (`test/e2e`).
- `packages/create-converger-agent` (template and CLI), `examples/agents/llm-tool-loop-ts` (Claude tool loop).
- CI: `.github/workflows/agent-ts.yml`.

## Links

- [Agent SDK](../sdk/agent.md)
- [Protocol v1](../protocol/v1.md), sections 9 and 10; [message types](../protocol/messages.md)
- [WebSocket channel type](../channels/websocket.md)
