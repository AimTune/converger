"""Protocol v1 WebSocket client (``/socket/converger/v1``) with resume.

::

    async with AsyncConverger(base_url) as cvg:
        async with cvg.socket(conversation_token) as sock:
            ack = await sock.send_text("Where is my order?")
            async for frame in sock:
                print(frame["type"], frame.get("data"))

The socket reconnects with jittered exponential backoff, resumes from the
watermark (nothing persistent is lost or delivered twice) and re-sends
unacknowledged sends with their original ``clientId`` (exactly-once
persistence on the server).
"""

from __future__ import annotations

import asyncio
import inspect
import json
import random
import uuid
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import suppress
from typing import Any, Union
from urllib.parse import urlsplit, urlunsplit

from websockets.asyncio.client import ClientConnection, connect
from websockets.exceptions import ConnectionClosed as WsConnectionClosed
from websockets.exceptions import InvalidHandshake

from .._version import __version__
from ..errors import ConnectionClosed, ConvergerError, ProtocolError
from ..models import Ack
from .session import Frame, Session

SUBPROTOCOL = "converger.v1"
PATH = "/socket/converger/v1"

# Close codes after which reconnecting cannot help (docs/protocol/v1.md 12.3).
TERMINAL_CLOSE_CODES = frozenset({1008, 4400, 4401, 4403})

TokenSource = Union[str, Callable[[], Union[str, Awaitable[str]]]]

_CLOSED = object()


def ws_url(base_url: str) -> str:
    """The native endpoint URL for a REST base URL (``https://h`` -> ``wss://h/socket/converger/v1``)."""
    parts = urlsplit(base_url.rstrip("/"))
    scheme = {"http": "ws", "https": "wss"}.get(parts.scheme, parts.scheme)
    return urlunsplit((scheme, parts.netloc, parts.path + PATH, "", ""))


class ConvergerSocket:
    """One conversation over the native Protocol v1 endpoint.

    ``token`` is a conversation-bound converger token, or a (sync or async)
    callable returning one; a callable is called on every connect, so a
    token that expired (close 4401) is replaced instead of ending the socket.
    """

    def __init__(
        self,
        url: str,
        token: TokenSource,
        *,
        conversation_id: str | None = None,
        watermark: int = 0,
        reconnect: bool = True,
        max_retries: int | None = None,
        backoff_initial: float = 0.5,
        backoff_max: float = 30.0,
        open_timeout: float = 10.0,
        ack_timeout: float = 30.0,
        headers: dict[str, str] | None = None,
    ) -> None:
        self.url = url
        self.session = Session(watermark, conversation_id)
        self.welcome: dict[str, Any] | None = None
        self._token = token
        self._reconnect = reconnect
        self._max_retries = max_retries
        self._backoff_initial = backoff_initial
        self._backoff_max = backoff_max
        self._open_timeout = open_timeout
        self._ack_timeout = ack_timeout
        self._headers = headers or {}
        self._queue: asyncio.Queue[Any] = asyncio.Queue()
        self._pending: dict[str, tuple[Frame, asyncio.Future[Ack]]] = {}
        self._ws: ClientConnection | None = None
        self._ready = asyncio.Event()
        self._welcomed = asyncio.Event()
        self._runner: asyncio.Task[None] | None = None
        self._ping: asyncio.Task[None] | None = None
        self._closing = False
        self._closed_error: ConnectionClosed | None = None

    # --- public API ----------------------------------------------------------

    @property
    def watermark(self) -> int:
        return self.session.watermark

    @property
    def conversation_id(self) -> str | None:
        return self.session.conversation_id

    async def connect(self) -> ConvergerSocket:
        """Connect and wait for the first ``welcome``."""
        if self._runner is None:
            self._runner = asyncio.create_task(self._run())
        waiter = asyncio.create_task(self._welcomed.wait())
        await asyncio.wait({waiter, self._runner}, return_when=asyncio.FIRST_COMPLETED)
        if not self._welcomed.is_set():
            waiter.cancel()
            raise self._closed_error or ConnectionClosed(None, "closed before welcome")
        return self

    async def __aenter__(self) -> ConvergerSocket:
        return await self.connect()

    async def __aexit__(self, *exc: object) -> None:
        await self.close()

    def __aiter__(self) -> AsyncIterator[Frame]:
        return self

    async def __anext__(self) -> Frame:
        try:
            return await self.recv()
        except ConnectionClosed:
            raise StopAsyncIteration from None

    async def recv(self) -> Frame:
        """The next frame for the application (persistent frames in seq order, exactly once)."""
        item = await self._queue.get()
        if item is _CLOSED:
            self._queue.put_nowait(_CLOSED)
            raise self._closed_error or ConnectionClosed(1000)
        return item

    async def send_text(
        self,
        text: str,
        *,
        client_id: str | None = None,
        metadata: dict[str, Any] | None = None,
        reply_to: str | None = None,
        timeout: float | None = None,
    ) -> Ack:
        """Send a ``text`` turn and wait for its ``ack``."""
        return await self.send_message("text", {"text": text}, client_id=client_id, metadata=metadata, reply_to=reply_to, timeout=timeout)

    async def send_message(
        self,
        type: str,
        data: dict[str, Any],
        *,
        client_id: str | None = None,
        metadata: dict[str, Any] | None = None,
        reply_to: str | None = None,
        timeout: float | None = None,
    ) -> Ack:
        """Send a message frame of any type; raises :class:`ProtocolError` when refused."""
        if self._closed_error is not None:
            raise self._closed_error
        cid = client_id or f"py-{uuid.uuid4()}"
        frame: Frame = {"type": type, "clientId": cid, "data": data}
        if metadata is not None:
            frame["metadata"] = metadata
        if reply_to is not None:
            frame["replyTo"] = {"id": reply_to}
        future: asyncio.Future[Ack] = asyncio.get_running_loop().create_future()
        self._pending[cid] = (frame, future)
        if self._ready.is_set():
            await self._send_raw(frame)
        try:
            return await asyncio.wait_for(asyncio.shield(future), timeout or self._ack_timeout)
        finally:
            if future.done():
                self._pending.pop(cid, None)

    async def typing(self, is_typing: bool) -> None:
        await self._send_raw({"type": "typing", "isTyping": is_typing})

    async def read(self, watermark: int | None = None) -> None:
        """Mark everything up to ``watermark`` (default: the current one) as read."""
        await self._send_raw({"type": "read", "watermark": self.watermark if watermark is None else watermark})

    async def refresh(self, token: str) -> None:
        """Mid-session token refresh (``auth`` frame)."""
        await self._send_raw({"type": "auth", "token": token})

    async def close(self) -> None:
        self._closing = True
        if self._ws is not None:
            with suppress(Exception):
                await self._ws.close()
        if self._runner is not None:
            with suppress(asyncio.CancelledError, Exception):
                await self._runner
        self._finish(ConnectionClosed(1000, "closed by client"))

    # --- internals -------------------------------------------------------------

    async def _resolve_token(self) -> str:
        token = self._token() if callable(self._token) else self._token
        if inspect.isawaitable(token):
            token = await token
        return token

    async def _send_raw(self, frame: Frame) -> None:
        ws = self._ws
        if ws is None:
            raise ConvergerError("socket is not connected")
        with suppress(WsConnectionClosed):
            await ws.send(json.dumps(frame))

    def _backoff(self, attempt: int) -> float:
        base = min(self._backoff_max, self._backoff_initial * (2**attempt))
        return random.uniform(base / 2, base)

    async def _run(self) -> None:
        attempt = 0
        auth_failures = 0
        while not self._closing:
            code: int | None = None
            reason = ""
            welcomed = False
            try:
                token = await self._resolve_token()
                headers = {
                    "Authorization": f"Bearer {token}",
                    "User-Agent": f"converger-python/{__version__}",
                    **self._headers,
                }
                async with connect(
                    self.url,
                    subprotocols=[SUBPROTOCOL],  # type: ignore[list-item]
                    additional_headers=headers,
                    open_timeout=self._open_timeout,
                    user_agent_header=None,
                ) as ws:
                    self._ws = ws
                    await ws.send(json.dumps(self.session.hello()))
                    try:
                        async for raw in ws:
                            frame = json.loads(raw)
                            if isinstance(frame, dict) and frame.get("type") == "welcome":
                                welcomed = True
                                attempt = 0
                                auth_failures = 0
                            await self._handle(ws, frame)
                    except WsConnectionClosed:
                        pass
                    code, reason = ws.close_code, ws.close_reason or ""
            except (OSError, InvalidHandshake, asyncio.TimeoutError, WsConnectionClosed) as exc:
                reason = str(exc)
            finally:
                self._ws = None
                self._ready.clear()
                if self._ping is not None:
                    self._ping.cancel()
                    self._ping = None

            if self._closing:
                break
            if code == 4401 and callable(self._token) and auth_failures == 0:
                auth_failures += 1
                continue
            if not self._reconnect or code in TERMINAL_CLOSE_CODES:
                self._finish(ConnectionClosed(code, reason))
                return
            if not welcomed:
                attempt += 1
            if self._max_retries is not None and attempt > self._max_retries:
                self._finish(ConnectionClosed(code, reason or "too many reconnect attempts"))
                return
            await asyncio.sleep(_retry_after(reason) or self._backoff(attempt))

    async def _handle(self, ws: ClientConnection, frame: Any) -> None:
        if not isinstance(frame, dict):
            return
        ftype = frame.get("type")
        resolved_send = False

        if ftype == "ack":
            entry = self._pending.pop(str(frame.get("clientId")), None)
            if entry and not entry[1].done():
                entry[1].set_result(Ack.model_validate(frame))
        elif ftype == "error":
            data = frame.get("data") or {}
            entry = self._pending.pop(str(data.get("clientId")), None) if "clientId" in data else None
            if entry and not entry[1].done():
                entry[1].set_exception(ProtocolError(data))
                resolved_send = True

        step = self.session.on_frame(frame)

        if ftype == "welcome":
            self.welcome = frame.get("data") or {}
            self._ready.set()
            self._welcomed.set()
            self._start_ping(ws)
            for pending_frame, future in list(self._pending.values()):
                if not future.done():
                    await self._send_raw(pending_frame)

        for out in step.send:
            await self._send_raw(out)
        for item in step.schedule:
            asyncio.get_running_loop().call_later(item.after_ms / 1000, self._scheduled_sync, ws)
        for delivered in step.deliver:
            if not (resolved_send and delivered is frame):
                self._queue.put_nowait(delivered)

    def _scheduled_sync(self, ws: ClientConnection) -> None:
        if self._ws is ws:
            asyncio.ensure_future(self._send_raw(self.session.sync_frame()))

    def _start_ping(self, ws: ClientConnection) -> None:
        limits = (self.welcome or {}).get("limits") or {}
        idle = limits.get("idleTimeoutMs") if isinstance(limits.get("idleTimeoutMs"), int) else 60_000
        interval = max(idle / 2000, 1.0)

        async def ping() -> None:
            while self._ws is ws:
                await asyncio.sleep(interval)
                await self._send_raw({"type": "ping"})

        if self._ping is not None:
            self._ping.cancel()
        self._ping = asyncio.create_task(ping())

    def _finish(self, error: ConnectionClosed) -> None:
        if self._closed_error is not None:
            return
        self._closed_error = error
        for _, future in self._pending.values():
            if not future.done():
                future.set_exception(error)
        self._pending.clear()
        self._queue.put_nowait(_CLOSED)


def _retry_after(reason: str) -> float | None:
    """Close reasons of 1012 and 4503 carry ``{"retryAfterMs": N}``."""
    try:
        data = json.loads(reason)
    except (ValueError, TypeError):
        return None
    if isinstance(data, dict) and isinstance(data.get("retryAfterMs"), int):
        return data["retryAfterMs"] / 1000
    return None
