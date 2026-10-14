"""A user turn and the helpers that answer it."""

from __future__ import annotations

import asyncio
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from .agent import Agent

Frame = dict[str, Any]

# Frame types an agent sends that are not message frames.
NATIVE_TYPES = frozenset({"tool_call", "skill", "genui", "interrupt", "interrupt_resolved"})

DEFAULT_ACTIONS: list[dict[str, Any]] = [
    {"label": "Approve", "value": {"approved": True}},
    {"label": "Reject", "value": {"approved": False}},
]

_CLIENT_ID_UNSAFE = re.compile(r"[^A-Za-z0-9._:~-]")


def safe_id(value: str, limit: int = 96) -> str:
    """``value`` reduced to the clientId alphabet (docs/protocol/v1.md, section 7)."""
    return _CLIENT_ID_UNSAFE.sub("-", value)[:limit] or "x"


def normalize_actions(actions: Sequence[Any] | None) -> list[dict[str, Any]] | None:
    """Actions as ``{label, value?, url?}`` objects; a plain string is both label and value."""
    if actions is None:
        return None
    out: list[dict[str, Any]] = []
    for action in actions:
        if isinstance(action, str):
            out.append({"label": action, "value": action})
        elif isinstance(action, Mapping):
            item = dict(action)
            if "label" not in item:
                item["label"] = str(item.get("value", ""))
            out.append(item)
        else:
            out.append({"label": str(action), "value": action})
    return out


@dataclass(frozen=True)
class Message:
    """The message frame of a turn: its ``type`` (``text``, ``image``, ``location``, ...), typed ``data`` and the raw frame."""

    type: str
    data: dict[str, Any]
    raw: Frame


@dataclass
class Turn:
    """One end-user turn of a conversation, from any channel routed to the agent's channel.

    ``resume`` is set instead of a message when the end user answered an
    interrupt this process does not wait for (for example one asked before a
    restart): ``{interrupt_id: answer}``. Adapters with durable state (a
    LangGraph checkpointer) resume from it; other handlers can ignore it.
    """

    conversation_id: str
    message: Message
    text: str
    id: str | None = None
    seq: int | None = None
    attachments: list[Any] = field(default_factory=list)
    participant: dict[str, Any] | None = None
    channel: Any = None
    meta: dict[str, Any] = field(default_factory=dict)
    metadata: dict[str, Any] = field(default_factory=dict)
    action: dict[str, Any] | None = None
    reply_to: dict[str, Any] | None = None
    resume: dict[str, Any] | None = None
    _agent: Agent | None = field(default=None, repr=False, compare=False)

    @classmethod
    def from_frame(cls, conversation_id: str, frame: Frame, agent: Agent | None = None) -> Turn:
        data = frame.get("data") if isinstance(frame.get("data"), dict) else {}
        meta = frame.get("meta") if isinstance(frame.get("meta"), dict) else {}
        metadata = frame.get("metadata") if isinstance(frame.get("metadata"), dict) else {}
        action = metadata.get("action") if isinstance(metadata.get("action"), dict) else None
        participant = meta.get("participant") if isinstance(meta.get("participant"), dict) else None
        if participant is None and isinstance(frame.get("sender"), dict):
            participant = frame["sender"]
        attachments = data.get("attachments") if isinstance(data.get("attachments"), list) else []
        reply_to = frame.get("replyTo") if isinstance(frame.get("replyTo"), dict) else None
        return cls(
            conversation_id=conversation_id,
            message=Message(str(frame.get("type") or "text"), data, frame),
            text=_text_of(data),
            id=frame.get("id") if isinstance(frame.get("id"), str) else None,
            seq=frame.get("seq") if isinstance(frame.get("seq"), int) else None,
            attachments=attachments,
            participant=participant,
            channel=meta.get("channel", metadata.get("channel")),
            meta=meta,
            metadata=metadata,
            action=action,
            reply_to=reply_to,
            _agent=agent,
        )

    @classmethod
    def resume_turn(cls, conversation_id: str, answers: dict[str, Any], agent: Agent | None = None) -> Turn:
        frame: Frame = {"type": "resume", "answers": answers}
        return cls(conversation_id, Message("resume", {}, frame), "", resume=dict(answers), _agent=agent)

    async def history(self, limit: int = 50) -> list[Frame]:
        """The conversation's message frames (end user's and bots'), oldest first, at most ``limit``.

        Frames this process saw are kept in memory; the first call also asks
        the server to replay the transcript (an enveloped ``sync`` from 0), so
        a fresh process sees the earlier turns too. Best effort: frames a
        routed channel's middleware drops are not there.
        """
        if self._agent is None:
            return []
        return await self._agent.history(self.conversation_id, limit=limit)


def _text_of(data: Mapping[str, Any]) -> str:
    for key in ("text", "caption", "title", "name"):
        value = data.get(key)
        if isinstance(value, str):
            return value
    return ""


class Stream:
    """Token streaming as GenUI text chunks of one ``streamId``.

    ``write`` sends ``genui {streamId, done: false, chunk: {type: "text", content}}``;
    ``end`` sends the closing ``done: true`` chunk. Usable as an async context manager.
    """

    def __init__(self, reply: Reply, stream_id: str, text_fallback: bool) -> None:
        self._reply = reply
        self.stream_id = stream_id
        self.text_fallback = text_fallback
        self.parts: list[str] = []
        self._n = 0
        self.done = False

    @property
    def text(self) -> str:
        return "".join(self.parts)

    async def write(self, delta: str) -> None:
        if self.done:
            raise RuntimeError("stream already ended")
        if not delta:
            return
        self.parts.append(delta)
        self._n += 1
        await self._reply._native(
            {"type": "genui", "streamId": self.stream_id, "done": False, "chunk": {"type": "text", "content": delta, "id": self._n}}
        )

    async def ui(self, component: str, props: Mapping[str, Any] | None = None) -> None:
        """A GenUI component chunk inside this stream."""
        self._n += 1
        chunk: dict[str, Any] = {"type": "ui", "component": component, "id": self._n}
        if props is not None:
            chunk["props"] = dict(props)
        await self._reply._native({"type": "genui", "streamId": self.stream_id, "done": False, "chunk": chunk})

    async def end(self) -> None:
        if self.done:
            return
        self.done = True
        self._reply._streams.discard(self)
        await self._reply._native(
            {"type": "genui", "streamId": self.stream_id, "done": True, "chunk": {"type": "text", "content": "", "id": self._n + 1}}
        )
        if self.text_fallback and self.text:
            # Channels that do not render GenUI yet (messages.md section 5)
            # get the joined text as one message.
            await self._reply.message("text", {"text": self.text}, metadata={"genuiStreamId": self.stream_id})

    async def __aenter__(self) -> Stream:
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.end()


class Reply:
    """Answers one turn. Every send goes to the turn's conversation.

    Message frames carry a ``clientId`` derived from the turn (so a replayed
    turn's resends are de-duplicated by the server) and wait for the ``ack``.
    """

    def __init__(self, agent: Agent, conversation_id: str, turn: Turn | None = None) -> None:
        self._agent = agent
        self.conversation_id = conversation_id
        self.turn = turn
        key = turn.id if turn is not None and turn.id else f"{id(self):x}"
        self._key = safe_id(f"{agent.client_prefix}.{key}")
        self._counter = 0
        self._streams: set[Stream] = set()
        self._typing = False
        self.ended = False

    def _bump(self) -> int:
        self._counter += 1
        return self._counter

    def _next(self, kind: str) -> str:
        return f"{self._key}.{kind}{self._bump()}"

    async def _native(self, frame: Frame) -> None:
        await self._agent.send(self.conversation_id, frame)

    async def text(
        self,
        text: str,
        actions: Sequence[Any] | None = None,
        *,
        metadata: Mapping[str, Any] | None = None,
        reply_to: str | None = None,
    ) -> dict[str, Any]:
        """A ``text`` message, with quick-reply ``actions`` (strings or ``{label, value}``). Returns the ``ack``."""
        frame: Frame = {"type": "text", "data": {"text": text}}
        if actions:
            frame["actions"] = normalize_actions(actions)
        return await self._message_frame(frame, metadata, reply_to)

    async def message(
        self,
        type: str,
        data: Mapping[str, Any],
        *,
        actions: Sequence[Any] | None = None,
        metadata: Mapping[str, Any] | None = None,
        reply_to: str | None = None,
    ) -> dict[str, Any]:
        """A message of any type (``buttons``, ``quick-reply``, ``card``, ``carousel``, ``image``, ``file``, ...). Returns the ``ack``."""
        if type in NATIVE_TYPES:
            raise ValueError(f"{type} is not a message type; use tool_call(), ui(), stream() or ask()")
        frame: Frame = {"type": type, "data": dict(data)}
        if actions:
            frame["actions"] = normalize_actions(actions)
        return await self._message_frame(frame, metadata, reply_to)

    async def _message_frame(self, frame: Frame, metadata: Mapping[str, Any] | None, reply_to: str | None) -> dict[str, Any]:
        frame["clientId"] = self._next("m")
        if metadata:
            frame["metadata"] = dict(metadata)
        if reply_to:
            frame["replyTo"] = {"id": reply_to}
        await self._stop_typing()
        return await self._agent.send(self.conversation_id, frame)

    def stream(self, *, text_fallback: bool | None = None) -> Stream:
        """A new token stream (one ``streamId``). ``text_fallback`` defaults to the agent's setting."""
        fallback = self._agent.text_fallback if text_fallback is None else text_fallback
        s = Stream(self, self._next("s"), fallback)
        self._streams.add(s)
        return s

    async def ui(self, component: str, props: Mapping[str, Any] | None = None) -> None:
        """A standalone GenUI component (a one-chunk stream)."""
        stream_id = self._next("ui")
        chunk: dict[str, Any] = {"type": "ui", "component": component, "id": 1}
        if props is not None:
            chunk["props"] = dict(props)
        await self._native({"type": "genui", "streamId": stream_id, "done": True, "chunk": chunk})

    async def tool_call(
        self,
        id: str,
        status: str,
        *,
        name: str | None = None,
        params: Mapping[str, Any] | None = None,
        result: Any = None,
        error: str | None = None,
        description: str | None = None,
    ) -> None:
        """A tool trace, upserted by ``id`` as it moves ``running`` -> ``completed`` / ``error``.

        ``name`` is remembered from the first call of an ``id``.
        """
        if status not in ("running", "completed", "error"):
            raise ValueError("status must be running, completed or error")
        names = self._agent._tool_names(self.conversation_id)
        name = name or names.get(id) or "tool"
        names[id] = name
        data: dict[str, Any] = {"id": str(id), "name": name, "status": status}
        if description:
            data["description"] = description
        if params is not None:
            data["params"] = dict(params)
        if result is not None:
            data["result"] = result
        if error is not None:
            data["error"] = str(error)
        await self._native({"type": "tool_call", "data": data})

    async def ask(
        self,
        payload: Any,
        actions: Sequence[Any] | None = None,
        *,
        ui: Mapping[str, Any] | None = None,
        id: str | None = None,
        timeout: float | None = None,
    ) -> Any:
        """Pause for the end user: send an ``interrupt`` and return its answer.

        The answer arrives as ``resume`` (a tapped chip or button, a submitted
        form) or, with ``free_text_answers``, as the end user's next typed
        message. ``interrupt_resolved`` is sent before returning.
        """
        # A "/" keeps the id outside the clientId alphabet: the server uses a
        # native frame's `id` as its idempotency key, and `interrupt_resolved`
        # shares the id of its `interrupt` (mekik ids look like "node/0:interrupt#0").
        interrupt_id = id or self._key + "/ask" + str(self._bump())
        data: dict[str, Any] = {"payload": payload if payload is not None else {}}
        if actions:
            data["actions"] = normalize_actions(actions)
        if ui:
            data["ui"] = dict(ui)
        future = self._agent._register_ask(self.conversation_id, interrupt_id)
        try:
            await self._stop_typing()
            for s in list(self._streams):
                await s.end()
            await self._native({"type": "interrupt", "id": interrupt_id, "data": data})
            await self._agent.run_status(self.conversation_id, "interrupted")
            answer = await asyncio.wait_for(future, timeout) if timeout else await future
        finally:
            self._agent._unregister_ask(self.conversation_id, interrupt_id)
        await self._native({"type": "interrupt_resolved", "id": interrupt_id, "data": {"answer": answer}})
        await self._agent.run_status(self.conversation_id, "started")
        return answer

    async def typing(self, is_typing: bool = True) -> None:
        self._typing = is_typing
        await self._agent.send(self.conversation_id, {"type": "typing", "isTyping": is_typing})

    async def _stop_typing(self) -> None:
        if self._typing:
            await self.typing(False)

    async def end(self) -> None:
        """Close open streams and the typing indicator. Called for you after the handler returns."""
        if self.ended:
            return
        self.ended = True
        for s in list(self._streams):
            await s.end()
        await self._stop_typing()
