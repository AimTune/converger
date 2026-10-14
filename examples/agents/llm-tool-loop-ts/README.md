# LLM tool loop agent (TypeScript)

A generic Claude tool-loop agent on [`@converger/agent`](../../../packages/agent-ts). One process serves every
conversation of a Converger `websocket` channel: web widget, WhatsApp, Telegram, ... users routed to it by a routing
rule all talk to the same loop.

| what the model does | what the end user sees | SDK call |
| --- | --- | --- |
| streams text | tokens appear live in the web widget (genui text chunks) | `reply.stream()` |
| calls `lookup_order` | a tool trace (web; other channels with `show_tool_traces`) | `reply.toolCall(id, "running" / "completed")` |
| calls `refund_order` | an approval with Approve / Reject buttons, on any channel | `reply.ask(payload, {actions})` |

The loop is a manual streaming loop over the Anthropic Messages API (`claude-sonnet-5-5`, `client.beta.messages.stream`
with server-side fallback on refusals). The tools are fakes in `src/tools.ts`; replace them with yours.

## Run

Node 22.6+ (the entry point is TypeScript run with `--experimental-strip-types`).

```sh
cp .env.example .env    # fill in the values, then export them
export CONVERGER_URL=http://localhost:4000
export CONVERGER_CHANNEL_SECRET=...    # secret of the websocket channel the agent serves
export ANTHROPIC_API_KEY=...
pnpm install
pnpm --filter @converger/agent build
pnpm --filter @converger/example-llm-tool-loop-ts start
```

Route a widget or WhatsApp channel to the agent's channel with a routing rule
([Agents and bots on the native endpoint](https://converger.aimtune.dev/channels/websocket)).

## Test

`pnpm test` runs the loop against the SDK's fake server (`@converger/agent/testing`) and a scripted fake of the
Anthropic stream. It never calls the API.

## Notes

- The conversation history is kept in memory per conversation, so a restart forgets it. Read it back with
  `turn.history()` if you need it to survive restarts.
- `reply.stream()` uses genui text chunks; end-user channels that do not render genui receive the text only once the
  hub joins the chunks (#68). Pass `streamMode: "text"` to `createAgent` to send one text message per answer instead.
