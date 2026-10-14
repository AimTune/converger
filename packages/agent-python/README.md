# converger-agent

Agent SDK for [Converger](https://converger.aimtune.dev): one Python process serves every conversation routed to a
`websocket` bot channel (WhatsApp, Telegram, the web widget, ...) over a single channel-scoped
[Protocol v1](https://converger.aimtune.dev/protocol/v1) socket. Turns come in; text, rich messages, token streams,
tool traces, GenUI and interrupts go out. A first-party LangChain / LangGraph adapter is included.

Documentation: <https://converger.aimtune.dev/sdk/agent-python>.

```bash
pip install converger-agent                # core: websockets only
pip install 'converger-agent[langchain]'   # + the LangChain / LangGraph adapter
```

Python 3.10 or later (LangGraph interrupts need 3.11 or later).

## Quick start

```python
import asyncio
from converger_agent import Agent

agent = Agent("https://chat.example.com", channel_secret="...")  # the bot channel's secret, server side only

@agent.on_turn
async def handle(turn, reply):
    if turn.text.lower() == "refund":
        answer = await reply.ask({"title": "Refund 249.90 TRY?"}, ["Yes", "No"])
        await reply.text(f"You said {answer}.")
        return
    async with reply.stream() as s:          # streamed as GenUI text chunks
        for word in ["Hello", " from", " Python"]:
            await s.write(word)

asyncio.run(agent.run())                      # reconnects forever; agent.stop() ends it
```

## LangChain / LangGraph

```python
from converger_agent.langchain import serve

agent = serve(graph, url="https://chat.example.com", channel_secret="...")
asyncio.run(agent.run())
```

Token deltas become a stream, tool runs become `tool_call` traces, LangGraph `interrupt()` becomes an `interrupt`
whose answer resumes the graph (`Command(resume=...)`), and the thread id is the conversation id.
`bridge_langserve("https://my-langserve/app")` serves a runnable that LangServe already exposes.

## Testing your agent

`converger_agent.testing.FakeServer` is an in-process fake of the channel-scoped endpoint:

```python
from converger_agent.testing import FakeServer

server = await FakeServer().start()
agent = Agent(server.url, token="test")
...
await server.user_text("conv-1", "hi")
await server.wait_frame("run", "conv-1", data__status="finished")
```

## Development

```bash
pip install -e '.[test,langchain]'
python -m pytest
```

The tests validate every frame the agent sends against the protocol JSON Schemas in `priv/protocol/v1`. The
end-to-end test against a real server runs with `packages/conformance/integration/run.sh agent-python`.
