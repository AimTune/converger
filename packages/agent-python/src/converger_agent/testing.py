"""An in-process fake Converger server for testing agents without a real server.

::

    from converger_agent.testing import FakeServer

    async def test_my_agent():
        server = await FakeServer().start()
        agent = Agent(server.url, token="test")
        ...                                   # register on_turn, start agent.run()
        await server.wait_connected()
        await server.user_text("conv-1", "hi")
        await server.wait_frame("run", "conv-1", data__status="finished")
        print(server.frames("conv-1", "text"))
        await server.stop()

It speaks the channel-scoped wire exchange of docs/protocol/v1.md, section 10:
a bare ``hello`` / ``welcome``, then ``{conversationId, frame}`` envelopes both
ways, and an enveloped ``ack`` for every message frame with a ``clientId``
(``duplicate: true`` for a resend). ``validate`` (optional) is called with
every frame the agent sends; exceptions it raises are collected in
``server.invalid``.
"""

from __future__ import annotations

import asyncio
import json
import re
import time
from collections.abc import Callable
from typing import Any

from websockets.asyncio.server import ServerConnection, serve

_CLIENT_ID = re.compile(r"[A-Za-z0-9._:~-]{1,128}")
_TRANSIENT = frozenset({"run", "typing", "read", "sync", "genui_components", "skills", "error"})


class FakeServer:
    """A fake channel-scoped Protocol v1 endpoint; one agent connection at a time."""

    def __init__(self, validate: Callable[[dict[str, Any]], Any] | None = None) -> None:
        self.validate = validate
        self.invalid: list[tuple[dict[str, Any], Exception]] = []
        self.received: list[dict[str, Any]] = []
        self.duplicates: list[dict[str, Any]] = []
        self.hellos: list[dict[str, Any]] = []
        self.tokens: list[str] = []
        self.subprotocols: list[str | None] = []
        self.ws: ServerConnection | None = None
        self.auto_ack = True
        self.seq: dict[str, int] = {}
        self.acked: dict[tuple[str, str], dict[str, Any]] = {}
        self.welcome_data: dict[str, Any] = {}
        self.on_frame: Callable[[dict[str, Any]], Any] | None = None
        self._connected = asyncio.Event()
        self._new = asyncio.Event()
        self.port = 0
        self._server: Any = None

    def _check(self, frame: dict[str, Any]) -> None:
        if self.validate is None:
            return
        try:
            self.validate(frame)
        except Exception as exc:  # noqa: BLE001 - reported through self.invalid
            self.invalid.append((frame, exc))

    @property
    def url(self) -> str:
        return f"ws://127.0.0.1:{self.port}"

    async def start(self) -> FakeServer:
        self._server = await serve(self._handle, "127.0.0.1", 0, subprotocols=["converger.v1"])  # type: ignore[list-item]
        self.port = self._server.sockets[0].getsockname()[1]
        return self

    async def stop(self) -> None:
        self._server.close()
        await self._server.wait_closed()

    async def _handle(self, ws: ServerConnection) -> None:
        self.subprotocols.append(ws.subprotocol)
        auth = ws.request.headers.get("Authorization", "") if ws.request else ""
        self.tokens.append(auth.removeprefix("Bearer "))
        hello = json.loads(await ws.recv())
        self._check(hello)
        self.hellos.append(hello)
        data = {
            "protocol": "converger/1",
            "compat": ["mekik/1"],
            "connectionId": f"conn-{len(self.hellos)}",
            "scope": "channel",
            "channelId": "bot-channel",
            "limits": {"maxConversations": 5000},
            **self.welcome_data,
        }
        await ws.send(json.dumps({"type": "welcome", "data": data}))
        self.ws = ws
        self._connected.set()
        try:
            async for raw in ws:
                frame = json.loads(raw)
                self._check(frame)
                self.received.append(frame)
                self._new.set()
                if self.on_frame is not None:
                    result = self.on_frame(frame)
                    if asyncio.iscoroutine(result):
                        result = await result
                    if result is False:
                        continue
                await self._auto_ack(frame)
        except Exception:  # noqa: BLE001 - connection closed
            pass
        finally:
            if self.ws is ws:
                self.ws = None
                self._connected.clear()

    async def _auto_ack(self, envelope: dict[str, Any]) -> None:
        """Persist like the server: the idempotency key is ``clientId``, else an ``id`` in the clientId
        alphabet (also on native frames, docs/protocol/v1.md section 7). A repeated key is not stored
        again (recorded in ``self.duplicates``) and is answered with the original ack."""
        frame = envelope.get("frame")
        if not isinstance(frame, dict) or frame.get("type") in _TRANSIENT:
            return
        cid = envelope["conversationId"]
        client_id = frame.get("clientId")
        if client_id is None and isinstance(frame.get("id"), str) and _CLIENT_ID.fullmatch(frame["id"]):
            client_id = frame["id"]
        if client_id is None:
            self.next_seq(cid)
            return
        key = (cid, client_id)
        if key in self.acked:
            self.duplicates.append(frame)
            ack = {**self.acked[key], "duplicate": True}
        else:
            seq = self.next_seq(cid)
            ack = {"type": "ack", "clientId": client_id, "id": f"act-{cid[:4]}-{seq}", "seq": seq, "timestamp": int(time.time() * 1000)}
            self.acked[key] = ack
        if self.auto_ack:
            await self.push(cid, ack)

    def next_seq(self, cid: str) -> int:
        self.seq[cid] = self.seq.get(cid, 0) + 1
        return self.seq[cid]

    async def wait_connected(self, count: int = 1, timeout: float = 5.0) -> None:
        async def wait() -> None:
            while len(self.hellos) < count or self.ws is None:
                await asyncio.sleep(0.01)

        await asyncio.wait_for(wait(), timeout)

    async def push(self, cid: str, frame: dict[str, Any]) -> None:
        assert self.ws is not None, "agent not connected"
        await self.ws.send(json.dumps({"conversationId": cid, "frame": frame}))

    async def push_bare(self, frame: dict[str, Any]) -> None:
        assert self.ws is not None
        await self.ws.send(json.dumps(frame))

    async def user_text(self, cid: str, text: str, **extra: Any) -> dict[str, Any]:
        seq = self.next_seq(cid)
        frame = {"type": "text", "id": f"u-{cid[:4]}-{seq}", "seq": seq, "from": "user", "sender": {"id": "alice", "role": "user"}, "data": {"text": text}, "timestamp": int(time.time() * 1000), **extra}
        await self.push(cid, frame)
        return frame

    def frames(self, cid: str | None = None, type: str | None = None) -> list[dict[str, Any]]:
        out = []
        for envelope in self.received:
            if "frame" not in envelope:
                continue
            if cid is not None and envelope["conversationId"] != cid:
                continue
            if type is not None and envelope["frame"].get("type") != type:
                continue
            out.append(envelope["frame"])
        return out

    async def wait_for(self, predicate: Callable[[dict[str, Any]], bool], timeout: float = 5.0) -> dict[str, Any]:
        deadline = asyncio.get_running_loop().time() + timeout
        seen = 0
        while True:
            while seen < len(self.received):
                envelope = self.received[seen]
                seen += 1
                if predicate(envelope):
                    return envelope
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise AssertionError(f"timed out; received {self.received}")
            self._new.clear()
            try:
                await asyncio.wait_for(self._new.wait(), remaining)
            except asyncio.TimeoutError:
                pass

    async def wait_frame(self, type: str, cid: str | None = None, timeout: float = 5.0, **match: Any) -> dict[str, Any]:
        def pred(envelope: dict[str, Any]) -> bool:
            frame = envelope.get("frame")
            if not isinstance(frame, dict) or frame.get("type") != type:
                return False
            if cid is not None and envelope.get("conversationId") != cid:
                return False
            return all(_dig(frame, k) == v for k, v in match.items())

        return (await self.wait_for(pred, timeout))["frame"]

    async def close(self, code: int = 1012, reason: str = "") -> None:
        if self.ws is not None:
            await self.ws.close(code, reason)


def _dig(frame: dict[str, Any], path: str) -> Any:
    value: Any = frame
    for part in path.split("__"):
        value = value.get(part) if isinstance(value, dict) else None
    return value


def genui_text(frames: list[dict[str, Any]], stream_id: str | None = None) -> str:
    return "".join(
        f["chunk"].get("content", "")
        for f in frames
        if f.get("type") == "genui" and (stream_id is None or f["streamId"] == stream_id) and f["chunk"].get("type") == "text"
    )


