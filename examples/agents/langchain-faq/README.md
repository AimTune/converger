# LangChain FAQ agent

A support FAQ agent built with LangGraph and Claude, served on a Converger channel with
[`converger-agent`](../../../packages/agent-python) (`converger_agent.langchain.serve`). One process answers the
conversations of every channel routed to its bot channel: here a WhatsApp number and the web widget.

```text
WhatsApp user ──> whatsapp_meta channel ──┐                         ┌── tool_call, genui, text, interrupt
                                          ├─ routing rules ─> websocket bot channel <══ faq_agent.py (one socket)
web widget    ──> websocket widget ───────┘                         └── turns, resume
```

The graph (`faq_agent.py`):

- **answer**: calls the `search_faq` tool (shown as a tool trace), then Claude answers from the FAQ entries; its
  tokens are streamed.
- **escalate**: when the user asks for a human (or a refund), the graph pauses on a LangGraph `interrupt()` with two
  actions, *Yes, connect me* and *No, thanks*, and continues with the user's answer.

The thread id of the graph is the Converger conversation id, so each conversation keeps its own LangGraph state.

## 1. Channels and routing rules

With a tenant API key (`x-api-key`, scope `manage`) on a running server (`http://localhost:4000` here):

```bash
# The bot channel the agent connects to. Keep its secret on the agent's side only.
curl -s -X POST http://localhost:4000/api/v1/manage/channels \
  -H "x-api-key: $API_KEY" -H "content-type: application/json" \
  -d '{"channel": {"name": "faq-bot", "type": "websocket", "mode": "duplex"}}'
# -> data.id = BOT_ID, data.secret = BOT_SECRET

# The web widget's channel (chativa or any Protocol v1 client gets its tokens from this secret).
curl -s -X POST http://localhost:4000/api/v1/manage/channels \
  -H "x-api-key: $API_KEY" -H "content-type: application/json" \
  -d '{"channel": {"name": "web-widget", "type": "websocket", "mode": "duplex"}}'
# -> WIDGET_ID
```

The WhatsApp channel is a `whatsapp_meta` (or `whatsapp_infobip`) channel configured as in
[WhatsApp](../../../docs/channels/whatsapp.md); call its id `WA_ID`. Then route both to the bot:

```bash
for SRC in $WA_ID $WIDGET_ID; do
  curl -s -X POST http://localhost:4000/api/v1/routing_rules \
    -H "x-api-key: $API_KEY" -H "content-type: application/json" \
    -d "{\"routing_rule\": {\"name\": \"faq-$SRC\", \"source_channel_id\": \"$SRC\", \"target_channel_ids\": [\"$BOT_ID\"]}}"
done
```

The admin panel (Channels, Routing rules) does the same. The agent's replies go back to the channel each
conversation came from (reply-back routing).

## 2. Run the agent

Python 3.11 or later (LangGraph interrupts under asyncio need it).

```bash
cd examples/agents/langchain-faq
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt

export CONVERGER_URL=http://localhost:4000
export CONVERGER_CHANNEL_SECRET=$BOT_SECRET   # the SDK issues channel-scoped tokens from it
export ANTHROPIC_API_KEY=...
python faq_agent.py
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `CONVERGER_URL` | `http://localhost:4000` | The server (http(s) or ws(s)) |
| `CONVERGER_CHANNEL_SECRET` | | The bot channel's secret, or set `CONVERGER_TOKEN` to a channel-scoped token instead |
| `CONVERGER_AGENT_GROUP` | `faq` | Agent group: run several processes with the same group and each conversation is served by one of them |
| `ANTHROPIC_API_KEY` | | For `ChatAnthropic(model="claude-sonnet-5-5")`; `FAQ_AGENT_MODEL` picks another model |
| `FAQ_AGENT_FAKE_MODEL` | | `1` uses a canned fake model instead of Claude (no key, no network) |
| `FAQ_AGENT_FAKE_DELAY` | `0.05` | Seconds between the fake model's streamed tokens |
| `CONVERGER_TEXT_FALLBACK` | | `1` also sends each streamed answer as one `text` message (only for clients that render neither GenUI nor the joined text) |

## 3. What each channel shows

Write "When does my order ship?" and then "I want to talk to a human" from both channels.

| | Web widget (chativa, Protocol v1) | WhatsApp |
| --- | --- | --- |
| `run` started / finished | relayed live (a client can show a busy state) | nothing (transient frames are not delivered to WhatsApp) |
| `search_faq` tool trace | a tool-call card (`tool_call` running, then completed) | nothing, unless the channel enables `show_tool_traces` (one line `search_faq: completed`) |
| Claude's answer | streamed token by token (`genui` text chunks of one `streamId`, one growing bubble) | one text message with the joined answer, when the stream is done |
| "talk to a human" | the interrupt as two chips, *Yes, connect me* / *No, thanks* | the title with the two actions as reply buttons |
| the user's answer | the tapped chip is sent as `resume` | the tapped button reaches the agent as `resume` (Protocol v1 section 9); a typed "yes" also answers it |

Notes:

- WhatsApp gets the streamed answer as one message and the interrupt as reply buttons because Converger renders
  typed messages per channel ([messages.md, section 5](../../../docs/protocol/messages.md)). A user who types
  "yes" instead of tapping also answers the open interrupt: the SDK takes the next user message of the conversation
  as the answer of an open question (`free_text_answers`).
- `InMemorySaver` keeps LangGraph state in the process. Use a persistent checkpointer (Postgres, SQLite) so a
  conversation paused on an interrupt survives a restart: the SDK passes an answer for an interrupt it is not
  waiting for to the graph as `Command(resume=...)`.

## Tests

```bash
pip install -r requirements-test.txt
python -m pytest
```

`tests/test_faq_agent.py` runs the graph with the fake model through the SDK against its in-process fake server
(`converger_agent.testing.FakeServer`): streamed answer with the tool trace, the interrupt answered by a tapped
button and by a typed answer.

### Live check against a real server

`test/acceptance/langchain_faq_live_test.exs` in the repository root runs this agent, unmodified, against a real
Converger endpoint (#67, first acceptance criterion). It needs Docker and the Elixir toolchain, not Python:

```bash
# from the repository root, with the test database up (docker compose up -d db)
mix test --only langchain_faq
```

The test starts the endpoint on a random port, creates the channels and routing rules of section 1 (a
`whatsapp_meta` channel whose Graph API calls go to a stub, a `websocket` widget channel, the `websocket` bot
channel) and runs `python faq_agent.py` in `python:3.12-slim` with `FAQ_AGENT_FAKE_MODEL=1`, connected to the bot
channel through `host.docker.internal`. Then, from a native Protocol v1 widget socket and from signed WhatsApp
webhooks, it checks section 3:

- the widget gets the `search_faq` trace and the answer as several `genui` text chunks of one stream and one text
  run, closed by `stream_done`; WhatsApp gets the same answer as one text message;
- "I want to talk to a human" pauses the graph: the widget gets the interrupt with its two actions, WhatsApp gets
  two reply buttons;
- the widget's `resume` and the WhatsApp button tap both resume the graph, and each channel gets the final reply.

The dependencies are installed once into the Docker volume `converger-langchain-faq-venv` (`LANGCHAIN_FAQ_VENV`);
`docker volume rm converger-langchain-faq-venv` removes it. `LANGCHAIN_FAQ_IMAGE` picks another Python image.
