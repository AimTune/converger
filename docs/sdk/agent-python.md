---
title: Python agent SDK (converger-agent)
description: Serve every conversation of a Converger channel from Python - the converger-agent SDK (turns, replies, streaming, tool traces, GenUI, interrupts, reconnect) and its LangChain / LangGraph adapter.
sidebar_position: 7
---

`converger-agent` connects an AI agent written in Python to Converger. One process opens **one** channel-scoped
[Protocol v1](../protocol/v1.md) socket on a `websocket` bot channel and serves every conversation routed to that
channel, whatever channel the end user writes from (WhatsApp, Telegram, the web widget, ...). The agent gets turns and
answers with text, rich messages, token streams, tool traces, GenUI and interrupts; Converger stores the frames and
routes them back to the end user's channel. Source:
[`packages/agent-python`](https://github.com/AimTune/converger/tree/main/packages/agent-python), issue
[#67](https://github.com/AimTune/converger/issues/67).

> **Status:** implemented in [#67](https://github.com/AimTune/converger/issues/67) on top of the channel-scoped
> sockets of [#64](https://github.com/AimTune/converger/issues/64)
> ([ADR-0063](../adr/0063-channel-scoped-agent-sockets-and-the-bot-relay.md)). Built and tested in this repository;
> not yet published to PyPI.

Which package to use:

| you are building | use |
| --- | --- |
| an AI agent or bot that answers a channel's conversations | **`converger-agent`** (this page) |
| a backend calling the REST API, one conversation's socket, webhooks | [`converger`](python.md) |

```bash
pip install converger-agent                # core: websockets is the only dependency
pip install 'converger-agent[langchain]'   # + converger_agent.langchain (langchain-core, langgraph, httpx)
```

Python 3.10 or later. LangGraph's `interrupt()` needs Python 3.11 or later under asyncio (a LangGraph limitation),
so agents that pause on interrupts need 3.11+.

## Setup on the server

1. Create a `websocket` channel for the agent (the **bot channel**) and keep its secret on the agent's side.
2. Add routing rules from the end users' channels (a WhatsApp channel, the web widget's channel, ...) to the bot
   channel ([routing rules](../concepts/routing-rules.md)). Replies go back to each conversation's origin channel.
3. Give the agent the bot channel's secret (the SDK exchanges it for channel-scoped tokens with
   `POST /api/v1/converger/tokens/generate` and `{"scope": "channel"}`), or channel-scoped tokens you issue.

The example [`examples/agents/langchain-faq`](https://github.com/AimTune/converger/tree/main/examples/agents/langchain-faq)
walks through all three with `curl`.

## Quick start

```python
import asyncio
from converger_agent import Agent

agent = Agent("https://chat.example.com", channel_secret="...")

@agent.on_turn
async def handle(turn, reply):
    if turn.text.lower() == "refund":
        answer = await reply.ask({"title": "Refund 249.90 TRY?"}, ["Yes", "No"])
        await reply.text(f"You said {answer}.")
        return
    async with reply.stream() as s:
        for word in ["Hello", " from", " Python"]:
            await s.write(word)

asyncio.run(agent.run())
```

## Agent

`Agent(url, token=None, *, get_token=None, channel_secret=None, group=None, ...)`. `url` is the server
(`https://...`, or the endpoint `wss://.../socket/converger/v1`). Exactly one credential:

| argument | meaning |
| --- | --- |
| `token` | a channel-scoped converger token. When it expires the socket closes with 4401 and `run()` raises |
| `get_token` | a sync or async callable returning a channel-scoped token; called on every connect, before `welcome.data.expiresAt` (a mid-session `auth` refresh, `refresh_margin` seconds early, default 60) and once more after a 4401 |
| `channel_secret` | the bot channel's secret; the SDK calls `tokens/generate` itself (server side only) |

Other options:

| option | default | meaning |
| --- | --- | --- |
| `group` | none | `hello.group`: processes with the same group share the channel's conversations, each served by one of them |
| `user_id` | none | `hello.userId`, the sender id of the agent's frames (also the token's `user` with `channel_secret`) |
| `watermarks` | `{}` | per-conversation watermarks to resume from on the first connect (`agent.watermarks` holds the current ones) |
| `reconnect`, `max_retries`, `backoff_initial`, `backoff_max` | `True`, unlimited, 0.5 s, 30 s | reconnect with jittered exponential backoff |
| `ack_timeout`, `send_retries` | 30 s, 3 | waiting for a message `ack`; retries of `rate_limited`, `too_many_in_flight`, `unavailable` |
| `free_text_answers` | `True` | a user message while an `ask` is open answers it (see [Interrupts](#interrupts)) |
| `auto_read` | `True` | send `read {watermark}` for each turn (acknowledges deliveries on a `require_ack` channel, shows the turn as read) |
| `text_fallback` | `False` | also send each stream's joined text as one `text` message (see [Streams](#streams)) |
| `history_size`, `history_timeout` | 200, 3 s | transcript cache per conversation and the wait of the first `history()` |

| method | does |
| --- | --- |
| `@agent.on_turn` | registers `async def handle(turn, reply)` |
| `@agent.on_frame` | `handler(conversation_id, frame)` for every other conversation frame (`genui_event`, `abort`, `deliveryStatus`, other bots' messages, ...) |
| `@agent.on_error` | `handler(ConvergerError)` for `error` frames that answer no pending send |
| `await agent.run()` | connects and serves until `stop()`; raises `ConnectionClosed` on 4400, 4401 (without a token source, or twice), 4403, or when `max_retries` is exhausted |
| `await agent.stop()` | closes the socket; running turns are cancelled |
| `await agent.send(conversation_id, frame)` | sends any agent frame (`frames/channel/agent-frame.schema.json`) |
| `agent.connected`, `await agent.wait_connected()`, `agent.welcome` | connection state |

## Turns

A turn is a message frame with `from: "user"` in a conversation envelope. Frames from bots (`from: "bot"`, including
the agent's own when they are replayed), tool traces, GenUI and lifecycle frames are not turns. `Turn` fields:

| field | from the frame |
| --- | --- |
| `conversation_id` | the envelope |
| `text` | `data.text` (else a caption, title or name) |
| `message` | `Message(type, data, raw)`: the message type (`text`, `image`, `location`, ...), its `data` and the raw frame |
| `id`, `seq` | the activity id and seq |
| `attachments` | `data.attachments` |
| `participant` | `meta.participant`, else the frame's `sender` |
| `channel` | `meta.channel` or `metadata.channel` when the client or channel provides it |
| `meta`, `metadata` | the turn's `meta` (relayed, not stored) and stored `metadata` |
| `action` | `metadata.action` (`{label, value, source}`) of a tapped button or chip ([messages.md, section 6](../protocol/messages.md)) |
| `reply_to` | `replyTo` |
| `resume` | `{interrupt_id: answer}` for a resume turn (see [Interrupts](#interrupts)), else `None` |
| `await history(limit=50)` | the conversation's message frames, oldest first: the ones this process saw, plus a one-time replay of the transcript (an enveloped `sync` from 0) |

Turns of one conversation run one at a time, in order; turns of different conversations run concurrently. Around
each turn the agent sends `run {status: "started"}` and `finished` (or `interrupted` while an `ask` waits, `aborted`,
`error`). When the handler raises, the agent logs it and sends a transient `error` (`agent_error`, or the
`ConvergerError` code) and `run {status: "error"}` to the conversation.

## Reply

| method | sends |
| --- | --- |
| `await text(text, actions=None, *, metadata=None, reply_to=None)` | a `text` message; `actions` are quick-reply chips (`"Yes"` or `{"label", "value"}`). Returns the `ack` |
| `await message(type, data, *, actions=None, metadata=None, reply_to=None)` | any message type: `buttons`, `quick-reply`, `card`, `carousel`, `image`, `file`, ... ([messages.md](../protocol/messages.md)). Returns the `ack` |
| `stream(text_fallback=None)` | a `Stream`: `await write(delta)`, `await ui(component, props)`, `await end()`; an async context manager |
| `await ui(component, props=None)` | a standalone GenUI component (a one-chunk `genui` stream) |
| `await tool_call(id, status, *, name=None, params=None, result=None, error=None)` | a `tool_call` trace, upserted by `id` (`running`, `completed`, `error`); the name is remembered per id |
| `await ask(payload, actions=None, *, ui=None, id=None, timeout=None)` | an `interrupt`; returns the answer after sending `interrupt_resolved` |
| `await typing(True)` | `typing {isTyping}`; turned off by the next message and at the end of the turn |
| `await end()` | closes open streams and the typing indicator (called for you after the handler) |

Message frames carry a `clientId` derived from the turn's activity id, so the server stores each at most once and
answers with an `ack` ([Protocol v1, section 7](../protocol/v1.md)).
A refused send raises `ConvergerError` (`code`, `message`, `retryable`, `retry_after_ms`, `details`); retryable
refusals are retried with the same `clientId` first.

### Streams

`write(delta)` sends `genui {streamId, done: false, chunk: {type: "text", content: delta}}`; `end()` sends the closing
`done: true` chunk. A web client renders the tokens as they arrive. A channel that does not render GenUI (WhatsApp,
Telegram, email, SMS) is meant to get the joined text as one message when the stream is done; that downgrade is
**planned** ([messages.md, section 5](../protocol/messages.md)). Until it ships, `text_fallback=True` (on the agent or
per stream) also sends the joined text as a `text` message with `metadata.genuiStreamId`; web clients then show both.

### Interrupts

`ask(payload, actions, ui=..., id=...)` sends `interrupt {id, data: {payload, actions?, ui?}}` (`payload.title` is the
prompt channels show), sends `run {status: "interrupted"}` and waits. The answer comes as:

- `resume {answers: {id: value}}`: a tapped chip or submitted form on the web, or a tapped button on WhatsApp or
  Telegram (the server turns a reply to an open interrupt into `resume`, [Protocol v1, section 9](../protocol/v1.md#9-the-bot-channel-and-mekik-relay-implemented-64));
- with `free_text_answers` (default), the next user message of the conversation: `metadata.action.value` if it has
  one, else its text. This covers channels where the interrupt arrives as plain text.

Then `ask` sends `interrupt_resolved {id, data: {answer}}` and `run {status: "started"}` and returns the answer. An
answer for an interrupt the process is not waiting for (asked before a restart) becomes a **resume turn**:
`turn.resume == {id: answer}`, `turn.text == ""`. The LangGraph adapter resumes the graph from it.

Interrupt ids the SDK generates contain a `/` (as mekik's `node/0:interrupt#0` ids do). The server uses a native
frame's `id` as its idempotency key when it has the `clientId` syntax, and `interrupt_resolved` shares the `id` of its
`interrupt`, so an id like `ask-1` would make the server drop `interrupt_resolved` as a duplicate. Pass your own `id`
only with a character outside `A-Z a-z 0-9 . _ : ~ -`.

An `abort` from the end user cancels the running turn (`run {status: "aborted"}`).

## Reconnect and resume

The agent tracks the highest `seq` delivered per conversation (`agent.watermarks`) and sends them in
`hello.watermarks` on every reconnect, so the server replays what it missed: turns that arrived while it was away
are handled, frames it has seen are not handled twice. Message sends that were not acked are sent again after
`welcome` with their original `clientId`; GenUI, tool traces and interrupts wait for the connection. Close codes
follow [Protocol v1, section 12.3](../protocol/v1.md): 4400 and 4403 end `run()`; 4401 ends it unless a
token source can mint a fresh token; 1012 and 4503 wait the close reason's `retryAfterMs`; everything else
reconnects with jittered exponential backoff. A protocol `ping` is sent every `idleTimeoutMs / 2`.

To survive a process restart, persist `agent.watermarks` and pass them back as `Agent(..., watermarks=...)`.

## Wire mapping

| SDK | frame inside `{conversationId, frame}` |
| --- | --- |
| a turn | `text` (or another message type) with `from: "user"` |
| around a turn | `run {data: {status}}` (transient) |
| `reply.text`, `reply.message` | message frame with `clientId` -> `ack` |
| `reply.stream()` | `genui {streamId, done, chunk: {type: "text", content}}` |
| `reply.ui` | `genui {streamId, done: true, chunk: {type: "ui", component, props}}` |
| `reply.tool_call` | `tool_call {data: {id, name, status, params?, result?, error?}}` |
| `reply.ask` | `interrupt {id, data: {payload, actions?, ui?}}`, then `interrupt_resolved {id, data: {answer}}` |
| `reply.typing` | `typing {isTyping}` |
| per turn | `read {watermark}` |
| `turn.history()` | `sync {watermark: 0}` once per conversation |

Every frame the SDK sends is validated against `priv/protocol/v1/frames/channel/client-envelope.schema.json` in the
SDK's tests.

## LangChain and LangGraph

```python
from converger_agent.langchain import serve

agent = serve(graph, url="https://chat.example.com", channel_secret="...", group="faq")
asyncio.run(agent.run())
```

`serve(runnable, agent=None, *, input=None, config=None, stream=True, tool_traces=True, typing=True,
default_actions=DEFAULT_ACTIONS, ask_timeout=None, **agent_kwargs)` registers a turn handler (also available as
`turn_handler(runnable, ...)`) that runs `runnable.astream_events(input, config, version="v2")` per turn:

| LangChain / LangGraph | Converger |
| --- | --- |
| `on_chat_model_stream` text deltas (string or content blocks) | one `reply.stream()` per model run: `genui` text chunks |
| `on_chat_model_end` | the stream's `done` chunk |
| `on_tool_start` / `on_tool_end` / `on_tool_error` | `tool_call` `running` / `completed` / `error`, id = the tool's run id, `params` = its input, `result` = its output |
| LangGraph `interrupt(value)` (`__interrupt__`, `state.interrupts`) | `reply.ask(...)`; the answer resumes with `Command(resume=answer)` (a mapping of ids when several are open) |
| new AI messages in the final state that were not streamed | `reply.text` |
| a non-streaming runnable's string output | `reply.text` |

- **Input:** a LangGraph graph gets `{"messages": [HumanMessage(turn.text)]}` (`MessagesState`); any other runnable
  gets `turn.text`. Pass `input=lambda turn: ...` for other shapes.
- **Config:** `{"configurable": {"thread_id": conversation_id}, "metadata": {"converger_conversation_id": ...}}`,
  merged with `config` (a mapping or `config(turn)`). Interrupts need a checkpointer; use a persistent one so a
  paused conversation survives restarts (its answer arrives as a resume turn and continues the graph).
- **Interrupt values:** a mapping may carry `actions` (`[{label, value}]` or strings), `options` (strings) and `ui`
  (`{component, props}`); the rest is the payload, whose `title` (else `question`, `message`, `text`) is the prompt.
  A string becomes `{"title": value}`. Without actions or ui, *Approve* (`{"approved": true}`) and *Reject*
  (`{"approved": false}`) are offered. The wire id is `lg/<LangGraph interrupt id>`.
- **Python 3.10:** pass `config` explicitly to models and tools inside async nodes
  (`await model.ainvoke(messages, config)`); asyncio propagates it only from 3.11 on, and `interrupt()` needs 3.11.

### LangServe bridge

```python
from converger_agent.langchain import bridge_langserve

agent = bridge_langserve("https://my-langserve.example.com/faq", url="https://chat.example.com", channel_secret="...",
                         input=lambda turn: {"question": turn.text})
```

`bridge_langserve(url, ...)` posts each turn to the runnable's `POST {url}/stream_events` (server-sent events) and maps
the events as above. LangServe has no interrupts. `send_config=True` also sends `configurable.thread_id` (the remote
runnable must accept it); `headers` adds HTTP headers (authentication).

## Testing an agent

`converger_agent.testing.FakeServer` is an in-process fake of the channel-scoped endpoint (bare `hello` / `welcome`,
envelopes, an `ack` per message frame with the server's idempotency rule):

```python
from converger_agent import Agent
from converger_agent.testing import FakeServer

async def test_agent():
    server = await FakeServer().start()
    agent = Agent(server.url, token="test")
    agent.on_turn(handle)
    task = asyncio.ensure_future(agent.run())
    await server.wait_connected()
    await server.user_text("conv-1", "hi")
    await server.wait_frame("run", "conv-1", data__status="finished")
    assert server.frames("conv-1", "text")[0]["data"]["text"] == "hello"
    await agent.stop(); await task; await server.stop()
```

`server.push(conversation_id, frame)` sends any frame (for example `resume`), `server.frames(conversation_id, type)`
lists what the agent sent, and `FakeServer(validate=...)` checks every frame (the SDK's own tests validate them
against the protocol JSON Schemas).

The SDK's tests run in CI (the `SDKs` workflow, `.github/workflows/sdks.yml`: Python 3.10 and 3.13, the example, and
the end-to-end job). The end-to-end test against a real server runs with
`packages/conformance/integration/run.sh agent-python`: an end user on
a widget channel talks to the agent on the bot channel through the server (turn, tool trace, stream, text, interrupt
and resume).

## Related

- [Protocol v1](../protocol/v1.md), sections 9 (bot relay) and 10 (channel-scoped sockets)
- [WebSocket channel type](../channels/websocket.md#agents-and-bots-on-the-native-endpoint-protocol-v1)
- [Message types](../protocol/messages.md)
- [ADR-0063](../adr/0063-channel-scoped-agent-sockets-and-the-bot-relay.md): channel-scoped agent sockets and the bot relay
- [Python SDK (`converger`)](python.md) for the REST API and single-conversation sockets
