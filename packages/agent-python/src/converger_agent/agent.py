"""The agent: one channel-scoped Protocol v1 socket serving every conversation of a channel.

::

    from converger_agent import Agent

    agent = Agent("wss://chat.example.com", channel_secret="...")

    @agent.on_turn
    async def handle(turn, reply):
        await reply.text(f"You said: {turn.text}")

    asyncio.run(agent.run())

See docs/sdk/agent-python.md and docs/protocol/v1.md, sections 9 and 10.
"""

from __future__ import annotations

import asyncio
import inspect
import json
import logging
import random
import time
import urllib.error
import urllib.request
import uuid
from collections.abc import Awaitable, Callable, Mapping
from contextlib import suppress
from typing import Any, Union
from urllib.parse import urlsplit, urlunsplit

from websockets.asyncio.client import ClientConnection, connect
from websockets.exceptions import ConnectionClosed as WsConnectionClosed
from websockets.exceptions import InvalidHandshake

from ._version import __version__
from .errors import ConnectionClosed, ConvergerError
from .turn import NATIVE_TYPES, Frame, Reply, Turn

SUBPROTOCOL = "converger.v1"
PROTOCOL = "converger/1"
PATH = "/socket/converger/v1"

# Close codes after which reconnecting cannot help (docs/protocol/v1.md 12.3);
# 4401 gets one retry when a token source can mint a fresh token.
TERMINAL_CLOSE_CODES = frozenset({4400, 4401, 4403})

# Agent frames that are never stored: sent when connected, dropped otherwise.
TRANSIENT_TYPES = frozenset({"run", "typing", "read", "sync", "genui_components", "skills", "error"})

# Persistent frames with `from` that are not conversation messages.
NON_MESSAGE_TYPES = frozenset({"typing", "event", "conversationUpdate"})

# Errors after which a message send is retried with the same clientId.
RETRYABLE_SEND_CODES = frozenset({"rate_limited", "too_many_in_flight", "unavailable"})

TokenSource = Union[str, Callable[[], Union[str, Awaitable[str]]]]
TurnHandler = Callable[[Turn, Reply], Awaitable[None]]
FrameHandler = Callable[[str, Frame], Union[None, Awaitable[None]]]

log = logging.getLogger("converger_agent")


def ws_url(url: str) -> str:
    """The native endpoint URL: ``https://h`` -> ``wss://h/socket/converger/v1``; a ``ws(s)://`` URL with a path is kept."""
    parts = urlsplit(url.rstrip("/"))
    scheme = {"http": "ws", "https": "wss"}.get(parts.scheme, parts.scheme)
    path = parts.path
    if not path.endswith(PATH):
        path = path + PATH
    return urlunsplit((scheme, parts.netloc, path, parts.query, ""))


def http_base(url: str) -> str:
    """The REST base URL of a server URL (``wss://h/socket/converger/v1`` -> ``https://h``)."""
    parts = urlsplit(url.rstrip("/"))
    scheme = {"ws": "http", "wss": "https"}.get(parts.scheme, parts.scheme)
    path = parts.path[: -len(PATH)] if parts.path.endswith(PATH) else parts.path
    return urlunsplit((scheme, parts.netloc, path, "", ""))


def channel_token_source(base_url: str, channel_secret: str, *, user_id: str | None = None, timeout: float = 10.0) -> Callable[[], Awaitable[str]]:
    """A token source that exchanges the channel secret for a channel-scoped token.

    Calls ``POST /api/v1/converger/tokens/generate`` with ``{"scope": "channel"}`` on every
    (re)connect and mid-session refresh. The secret is a server-side credential.
    """
    endpoint = http_base(base_url) + "/api/v1/converger/tokens/generate"
    body: dict[str, Any] = {"scope": "channel"}
    if user_id:
        body["user"] = {"id": user_id}
    payload = json.dumps(body).encode()

    def generate() -> str:
        request = urllib.request.Request(
            endpoint,
            data=payload,
            method="POST",
            headers={
                "Authorization": f"Bearer {channel_secret}",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": f"converger-agent-python/{__version__}",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 - configured server URL
                data = json.loads(response.read())
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            try:
                error = json.loads(raw).get("error")
            except ValueError:
                error = None
            code = error.get("code") if isinstance(error, dict) else None
            message = error.get("message") if isinstance(error, dict) else (error if isinstance(error, str) else raw.decode(errors="replace"))
            raise ConvergerError(f"token request failed ({exc.code}): {message}", code=code or "unauthorized", retryable=exc.code >= 500) from None
        except (urllib.error.URLError, OSError) as exc:
            raise ConvergerError(f"token request failed: {exc}", code="unavailable", retryable=True) from None
        token = data.get("token") if isinstance(data, dict) else None
        if not isinstance(token, str):
            raise ConvergerError("token response has no token", code="bad_response")
        return token

    async def source() -> str:
        return await asyncio.to_thread(generate)

    return source


class _Conversation:
    """Per-conversation state: the turn queue (turns run one at a time), open asks and the transcript cache."""

    def __init__(self, conversation_id: str) -> None:
        self.id = conversation_id
        self.queue: asyncio.Queue[Turn] = asyncio.Queue()
        self.worker: asyncio.Task[None] | None = None
        self.current: asyncio.Task[Any] | None = None
        self.aborted = False
        self.asks: dict[str, asyncio.Future[Any]] = {}
        self.transcript: dict[int, Frame] = {}
        self.backfilled = False
        self.replayed = asyncio.Event()
        self.tool_names: dict[str, str] = {}


class Agent:
    """Serves every conversation routed to a ``websocket`` channel over one channel-scoped socket.

    Exactly one credential: ``token`` (a channel-scoped converger token),
    ``get_token`` (a sync or async callable returning one, called on every
    connect and before expiry) or ``channel_secret`` (the SDK then generates
    channel-scoped tokens itself, server-side only).
    """

    def __init__(
        self,
        url: str,
        token: str | None = None,
        *,
        get_token: Callable[[], str | Awaitable[str]] | None = None,
        channel_secret: str | None = None,
        group: str | None = None,
        user_id: str | None = None,
        watermarks: Mapping[str, int] | None = None,
        reconnect: bool = True,
        max_retries: int | None = None,
        backoff_initial: float = 0.5,
        backoff_max: float = 30.0,
        open_timeout: float = 10.0,
        ack_timeout: float = 30.0,
        send_retries: int = 3,
        free_text_answers: bool = True,
        auto_read: bool = True,
        text_fallback: bool = False,
        stream_flush: float = 0.15,
        max_frames_per_second: float = 12.0,
        history_size: int = 200,
        history_timeout: float = 3.0,
        refresh_margin: float = 60.0,
        client_prefix: str | None = None,
        headers: Mapping[str, str] | None = None,
        logger: logging.Logger | None = None,
    ) -> None:
        if sum(x is not None for x in (token, get_token, channel_secret)) != 1:
            raise ValueError("pass exactly one of token, get_token or channel_secret")
        self.url = ws_url(url)
        if channel_secret is not None:
            get_token = channel_token_source(url, channel_secret, user_id=user_id)
        self._token: TokenSource = token if token is not None else get_token  # type: ignore[assignment]
        self.group = group
        self.user_id = user_id
        self.watermarks: dict[str, int] = dict(watermarks or {})
        self.reconnect = reconnect
        self.max_retries = max_retries
        self.backoff_initial = backoff_initial
        self.backoff_max = backoff_max
        self.open_timeout = open_timeout
        self.ack_timeout = ack_timeout
        self.send_retries = send_retries
        self.free_text_answers = free_text_answers
        self.auto_read = auto_read
        self.text_fallback = text_fallback
        self.stream_flush = stream_flush
        self.max_frames_per_second = max_frames_per_second
        # Outbound pacing (a token bucket): the server accepts 20 inbound
        # frames per second per connection (docs/protocol/v1.md, section 11)
        # and refuses the rest with rate_limited, which would lose native
        # frames. A burst of a third of the rate keeps any 1 s window below
        # burst + rate frames.
        self._pace_burst = max(1.0, (max_frames_per_second or 0) / 3)
        self._pace_tokens = self._pace_burst
        self._pace_at = 0.0
        self._pace_lock: asyncio.Lock | None = None
        self.history_size = history_size
        self.history_timeout = history_timeout
        self.refresh_margin = refresh_margin
        self.client_prefix = client_prefix or f"py{uuid.uuid4().hex[:8]}"
        self.headers = dict(headers or {})
        self.log = logger or log
        self.welcome: dict[str, Any] | None = None

        self._handler: TurnHandler | None = None
        self._frame_handlers: list[FrameHandler] = []
        self._error_handlers: list[Callable[[ConvergerError], Any]] = []
        self._conversations: dict[str, _Conversation] = {}
        self._pending: dict[tuple[str, str], tuple[dict[str, Any], asyncio.Future[Frame]]] = {}
        self._ws: ClientConnection | None = None
        self._ready = asyncio.Event()
        self._stop = asyncio.Event()
        self._timers: list[asyncio.Task[Any]] = []
        self._background: set[asyncio.Task[Any]] = set()
        self._running = False

    # --- registration ----------------------------------------------------------

    def on_turn(self, handler: TurnHandler) -> TurnHandler:
        """Register the turn handler (decorator). Turns of one conversation run one at a time."""
        self._handler = handler
        return handler

    def on_frame(self, handler: FrameHandler) -> FrameHandler:
        """Register a handler for every other conversation frame (``genui_event``, ``abort``, ``deliveryStatus``, ...)."""
        self._frame_handlers.append(handler)
        return handler

    def on_error(self, handler: Callable[[ConvergerError], Any]) -> Callable[[ConvergerError], Any]:
        """Register a handler for ``error`` frames that answer no pending send."""
        self._error_handlers.append(handler)
        return handler

    # --- lifecycle ---------------------------------------------------------------

    @property
    def connected(self) -> bool:
        return self._ready.is_set()

    async def wait_connected(self, timeout: float | None = None) -> None:
        await asyncio.wait_for(self._ready.wait(), timeout)

    async def run(self) -> None:
        """Connect and serve until :meth:`stop`, reconnecting with jittered backoff.

        Raises :class:`ConnectionClosed` on a terminal close (4400, 4401
        without a token source, 4403) or when ``max_retries`` is exhausted.
        """
        if self._running:
            raise RuntimeError("agent is already running")
        self._running = True
        self._stop.clear()
        attempt = 0
        auth_retry = False
        try:
            while not self._stop.is_set():
                code: int | None = None
                reason = ""
                welcomed = False
                try:
                    token = await self._resolve_token()
                    async with connect(
                        self.url,
                        subprotocols=[SUBPROTOCOL],  # type: ignore[list-item]
                        additional_headers={
                            "Authorization": f"Bearer {token}",
                            "User-Agent": f"converger-agent-python/{__version__}",
                            **self.headers,
                        },
                        open_timeout=self.open_timeout,
                        user_agent_header=None,
                    ) as ws:
                        self._ws = ws
                        await ws.send(json.dumps(self._hello()))
                        try:
                            async for raw in ws:
                                try:
                                    frame = json.loads(raw)
                                except ValueError:
                                    continue
                                if isinstance(frame, dict) and frame.get("type") == "welcome":
                                    welcomed = True
                                    attempt = 0
                                    auth_retry = False
                                await self._on_frame(frame)
                        except WsConnectionClosed:
                            pass
                        code, reason = ws.close_code, ws.close_reason or ""
                except ConvergerError as exc:
                    # The token source failed (for example the secret is wrong).
                    if not exc.retryable:
                        raise
                    reason = str(exc)
                except (OSError, InvalidHandshake, asyncio.TimeoutError, WsConnectionClosed) as exc:
                    reason = str(exc)
                finally:
                    self._disconnected()

                if self._stop.is_set():
                    break
                if code == 4401 and callable(self._token) and not auth_retry:
                    auth_retry = True
                    continue
                if not self.reconnect or code in TERMINAL_CLOSE_CODES:
                    raise ConnectionClosed(code, reason)
                if not welcomed:
                    attempt += 1
                if self.max_retries is not None and attempt > self.max_retries:
                    raise ConnectionClosed(code, reason or "too many reconnect attempts")
                delay = _retry_after(reason) or self._backoff(attempt)
                self.log.info("converger agent reconnecting in %.2fs (close %s %s)", delay, code, reason)
                with suppress(asyncio.TimeoutError):
                    await asyncio.wait_for(self._stop.wait(), delay)
        finally:
            self._running = False
            await self._shutdown()

    async def stop(self) -> None:
        """Close the socket and stop :meth:`run` (running turns are cancelled)."""
        self._stop.set()
        ws = self._ws
        if ws is not None:
            with suppress(Exception):
                await ws.close()

    # --- sending -----------------------------------------------------------------

    async def send(self, conversation_id: str, frame: Frame) -> Frame | None:
        """Send one agent frame (``frames/channel/agent-frame``) to a conversation.

        A message frame with a ``clientId`` waits for its ``ack`` and returns it;
        retryable refusals are retried with the same ``clientId``, others raise
        :class:`ConvergerError`. Transient frames are dropped while
        disconnected; other frames wait for the connection.
        """
        envelope = {"conversationId": conversation_id, "frame": frame}
        ftype = frame.get("type")
        if ftype in TRANSIENT_TYPES:
            if self._ready.is_set():
                await self._send_raw(envelope)
            return None
        client_id = frame.get("clientId")
        if ftype in NATIVE_TYPES or not isinstance(client_id, str):
            await self._wait_ready()
            await self._send_raw(envelope)
            return None

        attempts = 0
        while True:
            key = (conversation_id, client_id)
            future: asyncio.Future[Frame] = asyncio.get_running_loop().create_future()
            self._pending[key] = (envelope, future)
            try:
                if self._ready.is_set():
                    await self._send_raw(envelope)
                try:
                    return await asyncio.wait_for(asyncio.shield(future), self.ack_timeout)
                except asyncio.TimeoutError:
                    raise ConvergerError(
                        f"no ack for {client_id} within {self.ack_timeout}s",
                        code="ack_timeout",
                        retryable=True,
                        conversation_id=conversation_id,
                        client_id=client_id,
                    ) from None
            except ConvergerError as exc:
                if exc.code in RETRYABLE_SEND_CODES and attempts < self.send_retries:
                    attempts += 1
                    await asyncio.sleep((exc.retry_after_ms or 500 * attempts) / 1000)
                    continue
                raise
            finally:
                if self._pending.get(key, (None, None))[1] is future:
                    del self._pending[key]

    async def run_status(self, conversation_id: str, status: str) -> None:
        """A transient ``run {status}`` frame (``started``, ``finished``, ``interrupted``, ``error``, ``aborted``)."""
        with suppress(Exception):
            await self.send(conversation_id, {"type": "run", "data": {"status": status}})

    async def history(self, conversation_id: str, limit: int = 50) -> list[Frame]:
        """See :meth:`Turn.history`."""
        conv = self._conv(conversation_id)
        if not conv.backfilled and self._ready.is_set():
            conv.backfilled = True
            conv.replayed.clear()
            await self.send(conversation_id, {"type": "sync", "watermark": 0})
            loop = asyncio.get_running_loop()
            deadline = loop.time() + self.history_timeout
            wait = min(1.0, self.history_timeout)
            while loop.time() < deadline:
                try:
                    await asyncio.wait_for(conv.replayed.wait(), wait)
                except asyncio.TimeoutError:
                    break
                conv.replayed.clear()
                wait = 0.3
        frames = [conv.transcript[seq] for seq in sorted(conv.transcript)]
        return frames[-limit:] if limit else frames

    # --- internals: connection ---------------------------------------------------

    def _hello(self) -> Frame:
        hello: Frame = {"type": "hello", "protocol": PROTOCOL}
        if self.group:
            hello["group"] = self.group
        if self.user_id:
            hello["userId"] = self.user_id
        watermarks = {cid: seq for cid, seq in self.watermarks.items() if isinstance(seq, int) and seq > 0}
        if watermarks:
            hello["watermarks"] = watermarks
        return hello

    async def _resolve_token(self) -> str:
        token = self._token() if callable(self._token) else self._token
        if inspect.isawaitable(token):
            token = await token
        return str(token)

    async def _wait_ready(self) -> None:
        if self._ready.is_set():
            return
        if not self._running:
            raise ConnectionClosed(None, "agent is not running")
        await self._ready.wait()

    async def _pace(self) -> None:
        rate = self.max_frames_per_second
        if not rate or rate <= 0:
            return
        if self._pace_lock is None:
            self._pace_lock = asyncio.Lock()
        async with self._pace_lock:
            loop = asyncio.get_running_loop()
            now = loop.time()
            self._pace_tokens = min(self._pace_burst, self._pace_tokens + (now - self._pace_at) * rate)
            self._pace_at = now
            if self._pace_tokens < 1:
                await asyncio.sleep((1 - self._pace_tokens) / rate)
                self._pace_tokens, self._pace_at = 1.0, loop.time()
            self._pace_tokens -= 1

    async def _send_raw(self, frame: Mapping[str, Any]) -> None:
        ws = self._ws
        if ws is None:
            return
        await self._pace()
        ws = self._ws
        if ws is None:
            return
        with suppress(WsConnectionClosed):
            await ws.send(json.dumps(frame))

    def _backoff(self, attempt: int) -> float:
        base = min(self.backoff_max, self.backoff_initial * (2 ** max(attempt - 1, 0)))
        return random.uniform(base / 2, base)

    def _disconnected(self) -> None:
        self._ws = None
        self._ready.clear()
        for timer in self._timers:
            timer.cancel()
        self._timers.clear()

    async def _shutdown(self) -> None:
        closed = ConnectionClosed(1000, "agent stopped")
        for _, future in self._pending.values():
            if not future.done():
                future.set_exception(closed)
        self._pending.clear()
        tasks = []
        for conv in self._conversations.values():
            for future in conv.asks.values():
                if not future.done():
                    future.cancel()
            if conv.worker is not None:
                conv.worker.cancel()
                tasks.append(conv.worker)
        tasks.extend(self._background)
        for task in self._background:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    def _spawn(self, coro: Awaitable[Any]) -> asyncio.Task[Any]:
        task = asyncio.ensure_future(coro)
        self._background.add(task)
        task.add_done_callback(self._background.discard)
        return task

    async def _on_frame(self, frame: Any) -> None:
        if not isinstance(frame, dict):
            return
        if "type" not in frame and isinstance(frame.get("conversationId"), str) and isinstance(frame.get("frame"), dict):
            await self._on_conversation_frame(frame["conversationId"], frame["frame"])
            return
        ftype = frame.get("type")
        data = frame.get("data") if isinstance(frame.get("data"), dict) else {}
        if ftype == "welcome":
            self.welcome = data
            self._ready.set()
            self._start_timers(data)
            for envelope, future in list(self._pending.values()):
                if not future.done():
                    await self._send_raw(envelope)
        elif ftype == "tokenRefreshed":
            self._schedule_refresh(data.get("expiresAt"))
        elif ftype == "error":
            error = ConvergerError.from_frame(data)
            self.log.warning("converger agent: %s (%s)", error.message, error.code)
            await self._emit_error(error)

    def _start_timers(self, welcome: Mapping[str, Any]) -> None:
        limits = welcome.get("limits") if isinstance(welcome.get("limits"), dict) else {}
        idle = limits.get("idleTimeoutMs") if isinstance(limits.get("idleTimeoutMs"), int) else 60_000
        interval = max(idle / 2000, 1.0)
        ws = self._ws

        async def ping() -> None:
            while self._ws is ws:
                await asyncio.sleep(interval)
                await self._send_raw({"type": "ping"})

        self._timers.append(asyncio.ensure_future(ping()))
        self._schedule_refresh(welcome.get("expiresAt"))

    def _schedule_refresh(self, expires_at: Any) -> None:
        if not isinstance(expires_at, (int, float)) or not callable(self._token):
            return
        delay = max(expires_at / 1000 - time.time() - self.refresh_margin, 1)
        ws = self._ws

        async def refresh() -> None:
            await asyncio.sleep(delay)
            if self._ws is not ws:
                return
            try:
                token = await self._resolve_token()
            except Exception as exc:  # noqa: BLE001 - the reconnect after expiry retries
                self.log.warning("converger agent: token refresh failed: %s", exc)
                return
            await self._send_raw({"type": "auth", "token": token})

        self._timers.append(asyncio.ensure_future(refresh()))

    async def _emit_error(self, error: ConvergerError) -> None:
        for handler in self._error_handlers:
            with suppress(Exception):
                result = handler(error)
                if inspect.isawaitable(result):
                    await result

    # --- internals: conversations ------------------------------------------------

    def _conv(self, conversation_id: str) -> _Conversation:
        conv = self._conversations.get(conversation_id)
        if conv is None:
            conv = self._conversations[conversation_id] = _Conversation(conversation_id)
        return conv

    def _tool_names(self, conversation_id: str) -> dict[str, str]:
        return self._conv(conversation_id).tool_names

    def _register_ask(self, conversation_id: str, interrupt_id: str) -> asyncio.Future[Any]:
        future: asyncio.Future[Any] = asyncio.get_running_loop().create_future()
        self._conv(conversation_id).asks[interrupt_id] = future
        return future

    def _unregister_ask(self, conversation_id: str, interrupt_id: str) -> None:
        self._conv(conversation_id).asks.pop(interrupt_id, None)

    def _remember(self, conv: _Conversation, frame: Frame) -> None:
        seq = frame.get("seq")
        if not isinstance(seq, int) or frame.get("type") in NATIVE_TYPES or frame.get("type") in NON_MESSAGE_TYPES:
            return
        if "data" not in frame:
            return
        conv.transcript[seq] = frame
        while len(conv.transcript) > self.history_size:
            del conv.transcript[min(conv.transcript)]

    async def _on_conversation_frame(self, conversation_id: str, frame: Frame) -> None:
        conv = self._conv(conversation_id)
        ftype = frame.get("type")
        seq = frame.get("seq")

        if ftype == "ack":
            # The watermark follows delivered frames only: an ack can overtake
            # an earlier user turn that is still on its way (the server's
            # echo rule never delivers our own frames back).
            entry = self._pending.get((conversation_id, str(frame.get("clientId"))))
            if entry is not None:
                sent = dict(entry[0]["frame"])
                sent.update({"seq": seq, "id": frame.get("id"), "from": "bot", "timestamp": frame.get("timestamp")})
                self._remember(conv, sent)
                if not entry[1].done():
                    entry[1].set_result(frame)
            return

        if ftype == "error":
            data = frame.get("data") if isinstance(frame.get("data"), dict) else {}
            error = ConvergerError.from_frame(data, conversation_id)
            entry = self._pending.get((conversation_id, error.client_id)) if error.client_id else None
            if entry is not None and not entry[1].done():
                entry[1].set_exception(error)
            else:
                self.log.warning("converger agent: %s in %s (%s)", error.message, conversation_id, error.code)
                await self._emit_error(error)
            return

        if ftype == "resume":
            answers = frame.get("answers") if isinstance(frame.get("answers"), dict) else {}
            unknown = {}
            for interrupt_id, answer in answers.items():
                future = conv.asks.get(interrupt_id)
                if future is not None and not future.done():
                    future.set_result(answer)
                else:
                    unknown[interrupt_id] = answer
            if unknown and self._handler is not None:
                self._dispatch(conv, Turn.resume_turn(conversation_id, unknown, self))
            return

        if ftype == "abort":
            if conv.current is not None and not conv.current.done():
                conv.aborted = True
                conv.current.cancel()
            await self._emit_frame(conversation_id, frame)
            return

        if isinstance(seq, int):
            if seq <= self.watermarks.get(conversation_id, 0):
                # Already seen: a replay (history backfill or a sync).
                self._remember(conv, frame)
                conv.replayed.set()
                return
            self.watermarks[conversation_id] = seq
            self._remember(conv, frame)

        if frame.get("from") == "user" and "data" in frame and ftype not in NATIVE_TYPES and ftype not in NON_MESSAGE_TYPES:
            turn = Turn.from_frame(conversation_id, frame, self)
            if conv.asks and self.free_text_answers:
                # A typed answer to an open question (a channel without buttons).
                answer = turn.action["value"] if turn.action and "value" in turn.action else turn.text
                interrupt_id = list(conv.asks)[-1]
                future = conv.asks[interrupt_id]
                if not future.done():
                    future.set_result(answer)
                return
            if self._handler is not None:
                self._dispatch(conv, turn)
            return

        await self._emit_frame(conversation_id, frame)

    async def _emit_frame(self, conversation_id: str, frame: Frame) -> None:
        for handler in self._frame_handlers:
            try:
                result = handler(conversation_id, frame)
                if inspect.isawaitable(result):
                    await result
            except Exception:  # noqa: BLE001
                self.log.exception("converger agent: frame handler failed")

    def _dispatch(self, conv: _Conversation, turn: Turn) -> None:
        conv.queue.put_nowait(turn)
        if conv.worker is None or conv.worker.done():
            conv.worker = asyncio.ensure_future(self._worker(conv))

    async def _worker(self, conv: _Conversation) -> None:
        while not conv.queue.empty():
            turn = conv.queue.get_nowait()
            await self._run_turn(conv, turn)

    async def _run_turn(self, conv: _Conversation, turn: Turn) -> None:
        assert self._handler is not None
        cid = conv.id
        reply = Reply(self, cid, turn)
        if self.auto_read and turn.seq:
            with suppress(Exception):
                await self.send(cid, {"type": "read", "watermark": turn.seq})
        await self.run_status(cid, "started")
        conv.aborted = False
        task = asyncio.ensure_future(self._handler(turn, reply))
        conv.current = task
        status = "finished"
        try:
            await task
            await reply.end()
        except asyncio.CancelledError:
            if not conv.aborted:
                task.cancel()
                raise
            status = "aborted"
        except Exception as exc:  # noqa: BLE001 - one failed turn must not stop the agent
            status = "error"
            self.log.exception("converger agent: turn handler failed in %s", cid)
            with suppress(Exception):
                await reply.end()
            code = exc.code if isinstance(exc, ConvergerError) else "agent_error"
            with suppress(Exception):
                await self.send(
                    cid,
                    {"type": "error", "data": {"code": code if _code_ok(code) else "agent_error", "message": "the agent could not answer this turn", "retryable": False}},
                )
        finally:
            conv.current = None
        await self.run_status(cid, status)


def _code_ok(code: str) -> bool:
    return bool(code) and code[0].isalpha() and code.islower() and all(c.isalnum() or c == "_" for c in code) and len(code) <= 64


def _retry_after(reason: str) -> float | None:
    """Close reasons of 1012 and 4503 carry ``{"retryAfterMs": N}``."""
    try:
        data = json.loads(reason)
    except (ValueError, TypeError):
        return None
    if isinstance(data, dict) and isinstance(data.get("retryAfterMs"), int):
        return data["retryAfterMs"] / 1000
    return None
