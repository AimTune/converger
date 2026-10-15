# @converger/agent

Agent SDK for [Converger](https://converger.aimtune.dev): one WebSocket serves every conversation of a channel, and
one handler answers them, whatever channel the end user is on (web widget, WhatsApp, Telegram, ...).

```ts
import { channelTokenProvider, createAgent } from "@converger/agent";

const url = "https://converger.example.com";
const agent = createAgent({
  url,
  getToken: channelTokenProvider({ url, secret: process.env.CONVERGER_CHANNEL_SECRET! }),
  group: "faq-bot", // optional: processes of a group share the conversations
});

agent.onTurn(async (turn, reply) => {
  const stream = reply.stream();
  for await (const delta of myModel(turn.text)) stream.write(delta);
  await stream.end();

  const ok = await reply.ask<boolean>("Refund 249.90 TRY?", {
    actions: [{ label: "Approve", value: true }, { label: "Reject", value: false }],
  });
  await reply.text(ok ? "Refunded." : "Cancelled.");
});

await agent.start();
```

- Node 20+ with no runtime dependencies. Node 22+ and browsers have a global `WebSocket`; on Node 20 pass
  `WebSocket` from the [`ws`](https://www.npmjs.com/package/ws) package: `createAgent({ ..., WebSocket })`.
- The token must be channel-scoped (`POST /api/v1/converger/tokens/generate` with `{"scope": "channel"}`, which
  `channelTokenProvider` does) and its channel a `websocket` channel that routing rules target.

## API

| call | what it does | wire |
| --- | --- | --- |
| `createAgent({url, token \| getToken, group?, logger?, ...})` | create an agent | `hello {protocol, token, group, watermarks}` |
| `agent.onTurn(handler)` | handle user turns; one conversation at a time, conversations in parallel | message frames with `from: "user"` |
| `agent.onFrame(handler)` | every raw frame (bare and enveloped) | |
| `agent.start()` / `agent.stop()` | connect (resolves at `welcome`) / disconnect | |
| `agent.on("connected" \| "disconnected" \| "error" \| "resume", ...)` | events | |
| `agent.reply(conversationId)` | a reply outside a turn (proactive messages, no run frames) | |
| `agent.watermarks()` | resume positions, to persist across restarts (`watermarks` option) | `hello.watermarks` |
| `turn.text`, `.message`, `.type`, `.data`, `.attachments`, `.participant`, `.channel`, `.meta`, `.metadata`, `.action`, `.replyTo`, `.signal`, `.raw` | the user turn | |
| `turn.history({since?, limit?})` | the conversation's frames | enveloped `sync` |
| `reply.text(text, {actions?})` | text with chips; resolves with the ack | `text` + `clientId` -> `ack` |
| `reply.message(type, data)` | `buttons`, `card`, `carousel`, `image`, `file`, `location`, ... | message frame |
| `reply.stream()` -> `write(delta)`, `end()` | token streaming | `genui` text chunks, one chunk id per stream |
| `reply.toolCall(id, status, {name, params, result, error})` | tool trace | `tool_call` |
| `reply.ui(component, props)` | GenUI component | `genui` ui chunk |
| `reply.ask(payload, {actions?, ui?, id?, timeoutMs?})` | ask the user, resolve with the answer | `interrupt` ... `resume` -> `interrupt_resolved` |
| `reply.typing(on = true)` | typing indicator (refreshed while on) | `typing` |
| `reply.end()` | finish the turn (automatic when the handler returns; idempotent) | `genui` `stream_done`, `run finished` |

Errors are `AgentError` with `code` (protocol codes such as `invalid_message`, `rate_limited`, and SDK codes such as
`closed`, `aborted`, `timeout`, `handler_error`), `retryable`, `retryAfterMs` and `conversationId`.

## Testing your agent

```ts
import { FakeConvergerServer } from "@converger/agent/testing"; // needs the `ws` package

const server = await FakeConvergerServer.start();
const agent = createAgent({ url: server.url, token: "test" });
agent.onTurn(handler);
await agent.start();
const result = await server.turn("conversation-1", "hello"); // {texts, messages, toolCalls, streamed, interrupts, status}
```

`npx create-converger-agent my-agent` scaffolds a project with this wired up
([`create-converger-agent`](../create-converger-agent)).

## Development

```sh
pnpm --filter @converger/agent typecheck
pnpm --filter @converger/agent test        # unit tests against the fake server, frames validated against priv/protocol/v1
pnpm --filter @converger/agent test:e2e    # against a real server, see test/e2e/README.md
pnpm --filter @converger/agent build
```

Docs: [Agent SDK](https://converger.aimtune.dev/sdk/agent) ·
[ADR-0067](https://converger.aimtune.dev/adr/0067-agent-sdk-api-and-wire-mapping) ·
[Protocol v1, section 10](https://converger.aimtune.dev/protocol/v1).
