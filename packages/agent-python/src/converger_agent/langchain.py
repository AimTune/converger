"""First-party LangChain / LangGraph adapter (``pip install 'converger-agent[langchain]'``).

::

    from converger_agent.langchain import serve

    agent = serve(graph, url="wss://chat.example.com", channel_secret="...")
    asyncio.run(agent.run())

Each turn runs ``runnable.astream_events(input, config, version="v2")`` with
``thread_id = conversation_id`` and maps the events onto the turn's reply:

==============================================  ===============================================
LangChain / LangGraph                           Converger (Protocol v1)
==============================================  ===============================================
``on_chat_model_stream`` text deltas            ``genui`` text chunks, one ``streamId`` per model call
``on_tool_start`` / ``on_tool_end`` / error     ``tool_call`` running / completed / error (id = run id)
LangGraph ``interrupt(value)``                  ``interrupt`` with actions; the answer resumes the
                                                graph with ``Command(resume=answer)``
new AI messages that were not streamed          ``text`` messages
==============================================  ===============================================

``bridge_langserve(url)`` does the same for a runnable served by LangServe
(``POST {url}/stream_events``).
"""

from __future__ import annotations

import inspect
import json
from collections.abc import AsyncIterator, Awaitable, Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from .agent import Agent
from .turn import DEFAULT_ACTIONS, Reply, Stream, Turn

InputFn = Callable[[Turn], Any]
ConfigArg = Mapping[str, Any] | Callable[[Turn], Mapping[str, Any]] | None


@dataclass(frozen=True)
class PendingInterrupt:
    """A LangGraph interrupt (``Interrupt.id``, ``Interrupt.value``) waiting for an answer."""

    id: str
    value: Any


def content_text(content: Any) -> str:
    """The text of a message (chunk) content: a string, or a list of content blocks (Anthropic, OpenAI)."""
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, Mapping):
        if "content" in content:
            return content_text(content["content"])
        if content.get("type") in ("text", "text_delta", None) and isinstance(content.get("text"), str):
            return content["text"]
        return ""
    if isinstance(content, (list, tuple)):
        return "".join(content_text(block) if not isinstance(block, str) else block for block in content)
    inner = getattr(content, "content", None)
    if inner is not None:
        return content_text(inner)
    return ""


def jsonable(value: Any) -> Any:
    """``value`` as JSON-compatible data (messages become their content; models dump; the rest is ``str``)."""
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, Mapping):
        return {str(k): jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [jsonable(v) for v in value]
    if hasattr(value, "content") and hasattr(value, "type"):  # a LangChain message
        return jsonable(value.content)
    for attr in ("model_dump", "dict"):
        dump = getattr(value, attr, None)
        if callable(dump):
            try:
                return jsonable(dump())
            except Exception:  # noqa: BLE001
                break
    try:
        json.dumps(value)
        return value
    except (TypeError, ValueError):
        return str(value)


def _get(obj: Any, key: str, default: Any = None) -> Any:
    if isinstance(obj, Mapping):
        return obj.get(key, default)
    return getattr(obj, key, default)


def interrupt_request(value: Any, default_actions: Sequence[Any] | None = DEFAULT_ACTIONS) -> tuple[Any, list[Any] | None, dict[str, Any] | None]:
    """Map an ``interrupt(value)`` to ``(payload, actions, ui)`` for :meth:`Reply.ask`.

    A mapping value may carry ``actions`` (``[{label, value}]`` or strings),
    ``options`` (strings: label and answer) and ``ui`` (``{component, props}``);
    the rest is the payload, whose ``title`` (else ``question``, ``message``,
    ``text``) is the prompt channels show. Without actions or ui the default
    Approve / Reject actions are offered.
    """
    if isinstance(value, Mapping):
        payload = {k: v for k, v in value.items() if k not in ("actions", "options", "ui")}
        if "title" not in payload:
            for key in ("question", "message", "text", "prompt"):
                if isinstance(payload.get(key), str):
                    payload["title"] = payload[key]
                    break
        actions = value.get("actions") or value.get("options")
        ui = value.get("ui") if isinstance(value.get("ui"), Mapping) else None
    elif isinstance(value, str):
        payload, actions, ui = {"title": value}, None, None
    else:
        payload, actions, ui = {"title": str(value), "value": jsonable(value)}, None, None
    if not actions and ui is None and default_actions:
        actions = list(default_actions)
    return jsonable(payload), (list(actions) if actions else None), (dict(ui) if ui else None)


def _is_graph(runnable: Any) -> bool:
    return callable(getattr(runnable, "aget_state", None))


def default_input(runnable: Any) -> InputFn:
    """LangGraph graphs get ``{"messages": [HumanMessage(text)]}`` (``MessagesState``); other runnables the text."""
    if _is_graph(runnable):
        from langchain_core.messages import HumanMessage

        return lambda turn: {"messages": [HumanMessage(content=turn.text)]}
    return lambda turn: turn.text


def _config_for(turn: Turn, config: ConfigArg, thread: bool) -> dict[str, Any]:
    extra = dict(config(turn) if callable(config) else (config or {}))
    configurable = dict(extra.get("configurable") or {})
    if thread:
        configurable.setdefault("thread_id", turn.conversation_id)
    metadata = dict(extra.get("metadata") or {})
    metadata.setdefault("converger_conversation_id", turn.conversation_id)
    out = {**extra, "metadata": metadata}
    if configurable:
        out["configurable"] = configurable
    return out


class _Run:
    """Maps one ``astream_events`` run onto a reply."""

    def __init__(self, reply: Reply, *, stream: bool, tool_traces: bool) -> None:
        self.reply = reply
        self.stream = stream
        self.tool_traces = tool_traces
        self.streams: dict[str, Stream] = {}
        self.streamed_runs: set[str] = set()
        self.streamed_texts: set[str] = set()
        self.interrupts: dict[str, PendingInterrupt] = {}
        self.output: Any = None
        self.has_output = False

    async def event(self, ev: Mapping[str, Any]) -> None:
        kind = ev.get("event")
        data = ev.get("data") or {}
        run_id = str(ev.get("run_id") or "")
        if kind == "on_chat_model_stream":
            if not self.stream:
                return
            text = content_text(data.get("chunk"))
            if text:
                s = self.streams.get(run_id)
                if s is None:
                    s = self.streams[run_id] = self.reply.stream()
                await s.write(text)
        elif kind == "on_chat_model_end":
            await self._end_stream(run_id)
        elif kind == "on_tool_start" and self.tool_traces:
            params = jsonable(data.get("input"))
            await self.reply.tool_call(run_id, "running", name=str(ev.get("name") or "tool"), params=params if isinstance(params, dict) else {"input": params})
        elif kind == "on_tool_end" and self.tool_traces:
            await self.reply.tool_call(run_id, "completed", name=str(ev.get("name") or "tool"), result=jsonable(data.get("output")))
        elif kind == "on_tool_error" and self.tool_traces:
            await self.reply.tool_call(run_id, "error", name=str(ev.get("name") or "tool"), error=str(data.get("error") or "tool failed"))
        elif kind == "on_chain_stream":
            chunk = data.get("chunk")
            if isinstance(chunk, Mapping) and "__interrupt__" in chunk:
                for item in chunk["__interrupt__"] or ():
                    self._interrupt(item)
        if kind and kind.endswith("_end") and not ev.get("parent_ids"):
            self.output = data.get("output")
            self.has_output = True

    def _interrupt(self, item: Any) -> None:
        interrupt_id = _get(item, "id") or _get(item, "interrupt_id") or f"interrupt-{len(self.interrupts)}"
        self.interrupts[str(interrupt_id)] = PendingInterrupt(str(interrupt_id), _get(item, "value"))

    async def _end_stream(self, run_id: str) -> None:
        s = self.streams.pop(run_id, None)
        if s is not None:
            self.streamed_runs.add(run_id)
            self.streamed_texts.add(s.text.strip())
            await s.end()

    async def close(self) -> None:
        for run_id in list(self.streams):
            await self._end_stream(run_id)

    def unstreamed_replies(self, before: set[str]) -> list[str]:
        """Texts of the run's new AI messages that were not streamed."""
        out = self.output
        messages = _get(out, "messages") if isinstance(out, Mapping) or hasattr(out, "messages") else None
        if isinstance(messages, (list, tuple)):
            texts = []
            for message in messages:
                if _get(message, "type") not in ("ai", "AIMessage", "AIMessageChunk"):
                    continue
                message_id = str(_get(message, "id") or "")
                if message_id and message_id in before:
                    continue
                if message_id.startswith("lc_run--") and message_id[len("lc_run--") :] in self.streamed_runs:
                    continue
                if _get(message, "tool_calls"):
                    continue
                text = content_text(_get(message, "content"))
                if text.strip() and text.strip() not in self.streamed_texts:
                    texts.append(text)
            return texts
        if self.streamed_runs or not self.has_output:
            return []
        text = content_text(out) if not isinstance(out, str) else out
        return [text] if text and text.strip() else []


async def _state_ids(runnable: Any, config: Mapping[str, Any]) -> tuple[set[str], list[PendingInterrupt]]:
    """Message ids already in the graph state, and its open interrupts."""
    if not _is_graph(runnable):
        return set(), []
    try:
        state = await runnable.aget_state(config)
    except Exception:  # noqa: BLE001 - no checkpointer: nothing to compare against
        return set(), []
    values = getattr(state, "values", None)
    messages = values.get("messages") if isinstance(values, Mapping) else None
    ids = {str(_get(m, "id")) for m in messages or () if _get(m, "id")}
    interrupts = list(getattr(state, "interrupts", ()) or ())
    if not interrupts:
        for task in getattr(state, "tasks", ()) or ():
            interrupts.extend(getattr(task, "interrupts", ()) or ())
    pending = [PendingInterrupt(str(_get(i, "id")), _get(i, "value")) for i in interrupts if _get(i, "id")]
    return ids, pending


LG_PREFIX = "lg/"


def protocol_interrupt_id(langgraph_id: str) -> str:
    """The wire id of a LangGraph interrupt. The "/" keeps it out of the clientId
    alphabet, so the server does not treat `interrupt_resolved` (same id) as a
    duplicate of the `interrupt`."""
    return LG_PREFIX + langgraph_id


def _command(answers: Mapping[str, Any]) -> Any:
    from langgraph.types import Command

    answers = {k[len(LG_PREFIX) :] if k.startswith(LG_PREFIX) else k: v for k, v in answers.items()}

    if len(answers) == 1:
        return Command(resume=next(iter(answers.values())))
    return Command(resume=dict(answers))


def turn_handler(
    runnable: Any,
    *,
    input: InputFn | None = None,
    config: ConfigArg = None,
    stream: bool = True,
    tool_traces: bool = True,
    typing: bool = True,
    default_actions: Sequence[Any] | None = DEFAULT_ACTIONS,
    ask_timeout: float | None = None,
    thread: bool = True,
) -> Callable[[Turn, Reply], Awaitable[None]]:
    """The ``on_turn`` handler :func:`serve` registers; use it to compose your own agent.

    ``input(turn)`` builds the runnable's input (see :func:`default_input`),
    ``config`` (a mapping or ``config(turn)``) is merged into the run config,
    which always carries ``configurable.thread_id = conversation_id`` unless
    ``thread=False``.
    """
    make_input = input or default_input(runnable)

    async def handle(turn: Turn, reply: Reply) -> None:
        cfg = _config_for(turn, config, thread)
        if turn.resume is not None:
            # An answer to an interrupt asked before this process started.
            payload: Any = _command(turn.resume)
        else:
            payload = make_input(turn)
            if inspect.isawaitable(payload):
                payload = await payload
        if typing:
            await reply.typing(True)
        while True:
            before, _ = await _state_ids(runnable, cfg)
            run = _Run(reply, stream=stream, tool_traces=tool_traces)
            try:
                async for ev in runnable.astream_events(payload, config=cfg, version="v2"):
                    await run.event(ev)
            finally:
                await run.close()
            for text in run.unstreamed_replies(before):
                await reply.text(text)
            _, pending = await _state_ids(runnable, cfg)
            interrupts = pending or list(run.interrupts.values())
            if not interrupts:
                return
            answers: dict[str, Any] = {}
            for item in interrupts:
                body, actions, ui = interrupt_request(item.value, default_actions)
                answers[item.id] = await reply.ask(body, actions, ui=ui, id=protocol_interrupt_id(item.id), timeout=ask_timeout)
            payload = _command(answers)

    return handle


def serve(runnable: Any, agent: Agent | None = None, *, input: InputFn | None = None, config: ConfigArg = None, stream: bool = True, tool_traces: bool = True, typing: bool = True, default_actions: Sequence[Any] | None = DEFAULT_ACTIONS, ask_timeout: float | None = None, thread: bool = True, **agent_kwargs: Any) -> Agent:
    """Serve a LangChain runnable or a LangGraph graph on a Converger channel.

    Pass an existing ``agent`` or the :class:`~converger_agent.Agent` arguments
    (``url``, ``token`` / ``get_token`` / ``channel_secret``, ``group``, ...).
    Returns the agent; ``await agent.run()`` serves until stopped. LangGraph
    interrupts need a checkpointer (``graph.compile(checkpointer=...)``).
    """
    if agent is None:
        agent = Agent(**agent_kwargs)
    elif agent_kwargs:
        raise TypeError("pass either agent or Agent arguments, not both")
    agent.on_turn(
        turn_handler(runnable, input=input, config=config, stream=stream, tool_traces=tool_traces, typing=typing, default_actions=default_actions, ask_timeout=ask_timeout, thread=thread)
    )
    return agent


class RemoteRunnable:
    """A runnable served by LangServe, seen through its ``/stream_events`` endpoint.

    Only ``astream_events`` is implemented (the events are the serialised
    v2 events; message chunks arrive as dicts). ``http_client`` is an
    ``httpx.AsyncClient`` to reuse (tests pass one with a mock transport).
    """

    def __init__(self, url: str, *, headers: Mapping[str, str] | None = None, timeout: float = 120.0, http_client: Any = None, send_config: bool = False) -> None:
        self.url = url.rstrip("/")
        self.headers = dict(headers or {})
        self.timeout = timeout
        self.http_client = http_client
        self.send_config = send_config

    async def astream_events(self, input: Any, config: Mapping[str, Any] | None = None, *, version: str = "v2", **_: Any) -> AsyncIterator[dict[str, Any]]:
        import httpx

        body: dict[str, Any] = {"input": jsonable(input), "kwargs": {}}
        if self.send_config and config:
            body["config"] = {k: jsonable(v) for k, v in config.items() if k in ("configurable", "metadata", "tags")}
        client = self.http_client or httpx.AsyncClient(timeout=self.timeout)
        try:
            async with client.stream("POST", f"{self.url}/stream_events", json=body, headers={"Accept": "text/event-stream", **self.headers}) as response:
                if response.status_code >= 400:
                    text = (await response.aread()).decode(errors="replace")
                    raise RuntimeError(f"LangServe stream_events failed ({response.status_code}): {text[:500]}")
                event = "message"
                data_lines: list[str] = []
                async for line in response.aiter_lines():
                    if line == "":
                        if data_lines:
                            done = await _sse_event(event, "\n".join(data_lines))
                            if done is _END:
                                return
                            if done is not None:
                                yield done
                        event, data_lines = "message", []
                    elif line.startswith("event:"):
                        event = line[6:].strip()
                    elif line.startswith("data:"):
                        data_lines.append(line[5:].lstrip())
                if data_lines:
                    done = await _sse_event(event, "\n".join(data_lines))
                    if done is not None and done is not _END:
                        yield done
        finally:
            if self.http_client is None:
                await client.aclose()


_END = object()


async def _sse_event(event: str, data: str) -> Any:
    if event == "end":
        return _END
    try:
        payload = json.loads(data) if data else None
    except ValueError:
        return None
    if event == "error":
        raise RuntimeError(f"LangServe error: {payload}")
    return payload if isinstance(payload, dict) else None


def bridge_langserve(url: str, agent: Agent | None = None, *, headers: Mapping[str, str] | None = None, http_client: Any = None, send_config: bool = False, input: InputFn | None = None, config: ConfigArg = None, stream: bool = True, tool_traces: bool = True, typing: bool = True, **agent_kwargs: Any) -> Agent:
    """Serve a runnable that LangServe already exposes (``{url}/stream_events``) on a Converger channel.

    The input defaults to the turn text; pass ``input`` for chains that take
    a dict (``input=lambda turn: {"question": turn.text}``). LangServe has no
    interrupts, so ``ask`` is not used; streaming and tool traces map as in
    :func:`serve`. ``send_config=True`` also sends ``configurable.thread_id``
    (the runnable must accept it).
    """
    remote = RemoteRunnable(url, headers=headers, http_client=http_client, send_config=send_config)
    return serve(remote, agent, input=input or (lambda turn: turn.text), config=config, stream=stream, tool_traces=tool_traces, typing=typing, thread=send_config, **agent_kwargs)


__all__ = [
    "PendingInterrupt",
    "RemoteRunnable",
    "bridge_langserve",
    "content_text",
    "default_input",
    "interrupt_request",
    "jsonable",
    "serve",
    "turn_handler",
]
