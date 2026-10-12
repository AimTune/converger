"""ConvergerSocket against an in-process fake of the native endpoint."""

import asyncio
import json

import pytest
from websockets.asyncio.server import serve

from converger import ConnectionClosed, ConvergerSocket


class FakeServer:
    def __init__(self, frames=0):
        self.frames = [self._text(i + 1, "bot", f"m{i + 1}") for i in range(frames)]
        self.hellos = []
        self.received = []
        self.subprotocols = []
        self.conns = []
        self.close_after_replay = []  # close codes for the next connections
        self.drop_first_text = False
        self.acked = {}

    @staticmethod
    def _text(seq, frm, text, client_id=None):
        f = {"type": "text", "id": f"a-{seq}", "seq": seq, "from": frm, "data": {"text": text}, "timestamp": 1750000000000 + seq}
        if client_id:
            f["clientId"] = client_id
        return f

    async def push(self, frm, text):
        frame = self._text(len(self.frames) + 1, frm, text)
        self.frames.append(frame)
        for ws in list(self.conns):
            await ws.send(json.dumps(frame))

    async def handler(self, ws):
        self.subprotocols.append(ws.subprotocol)
        hello = json.loads(await ws.recv())
        self.hellos.append(hello)
        if ws.request.headers.get("Authorization") != "Bearer good":
            await ws.send(json.dumps({"type": "error", "data": {"code": "unauthorized"}}))
            await ws.close(4401, "unauthorized")
            return
        wm = hello.get("watermark", 0)
        await ws.send(json.dumps({"type": "welcome", "data": {"protocol": "converger/1", "conversationId": "c-1", "watermark": len(self.frames), "limits": {"idleTimeoutMs": 60000}}}))
        for f in self.frames:
            if f["seq"] > wm:
                await ws.send(json.dumps(f))
        if self.close_after_replay:
            await ws.close(self.close_after_replay.pop(0), json.dumps({"reason": "unavailable", "retryAfterMs": 10}))
            return
        self.conns.append(ws)
        try:
            async for raw in ws:
                frame = json.loads(raw)
                self.received.append(frame)
                if frame["type"] == "text":
                    if self.drop_first_text:
                        self.drop_first_text = False
                        await ws.close(1011, "boom")
                        return
                    cid = frame["clientId"]
                    if cid in self.acked:
                        await ws.send(json.dumps({**self.acked[cid], "duplicate": True}))
                        continue
                    seq = len(self.frames) + 1
                    self.frames.append(self._text(seq, "user", frame["data"]["text"], cid))
                    ack = {"type": "ack", "clientId": cid, "id": f"a-{seq}", "seq": seq, "timestamp": 1}
                    self.acked[cid] = ack
                    await ws.send(json.dumps(ack))
                elif frame["type"] == "sync":
                    for f in self.frames:
                        if f["seq"] > frame["watermark"]:
                            await ws.send(json.dumps(f))
        finally:
            if ws in self.conns:
                self.conns.remove(ws)


@pytest.fixture
async def server():
    fake = FakeServer()
    async with serve(fake.handler, "127.0.0.1", 0, subprotocols=["converger.v1"]) as srv:
        port = srv.sockets[0].getsockname()[1]
        fake.url = f"ws://127.0.0.1:{port}/socket/converger/v1"
        yield fake


async def recv_types(sock, n):
    out = []
    for _ in range(n):
        f = await asyncio.wait_for(sock.recv(), 5)
        out.append(f"{f['type']}:{f['seq']}" if "seq" in f else f["type"])
    return out


async def test_handshake_replay_send_and_live(server):
    server.frames = [FakeServer._text(i, "bot", f"m{i}") for i in (1, 2)]
    async with ConvergerSocket(server.url, "good") as sock:
        assert await recv_types(sock, 3) == ["welcome", "text:1", "text:2"]
        ack = await sock.send_text("hello")
        assert ack.seq == 3 and ack.client_id.startswith("py-")
        await server.push("bot", "live")
        assert await recv_types(sock, 1) == ["text:4"]
        assert sock.watermark == 4
        assert sock.conversation_id == "c-1"
    assert server.subprotocols == ["converger.v1"]
    assert server.hellos[0] == {"type": "hello", "protocol": "converger/1", "watermark": 0}


async def test_reconnect_resumes_from_the_watermark(server):
    server.frames = [FakeServer._text(i, "bot", f"m{i}") for i in (1, 2)]
    server.close_after_replay = [1012]
    async with ConvergerSocket(server.url, "good", backoff_initial=0.01) as sock:
        assert await recv_types(sock, 3) == ["welcome", "text:1", "text:2"]
        assert await recv_types(sock, 1) == ["welcome"]
        await server.push("bot", "after reconnect")
        assert await recv_types(sock, 1) == ["text:3"]
    assert server.hellos[1] == {"type": "hello", "protocol": "converger/1", "watermark": 2, "conversationId": "c-1"}


async def test_unacked_send_is_resent_with_the_same_client_id(server):
    server.drop_first_text = True
    async with ConvergerSocket(server.url, "good", backoff_initial=0.01) as sock:
        ack = await sock.send_text("exactly once", client_id="cid-1")
        assert ack.seq == 1
    texts = [f for f in server.received if f["type"] == "text"]
    assert [f["clientId"] for f in texts] == ["cid-1", "cid-1"]  # sent, dropped, re-sent
    assert len(server.frames) == 1


async def test_unauthorized_is_terminal(server):
    with pytest.raises(ConnectionClosed) as exc:
        await ConvergerSocket(server.url, "bad", backoff_initial=0.01).connect()
    assert exc.value.code == 4401


async def test_token_provider_is_asked_again_after_4401(server):
    tokens = iter(["bad", "good"])

    async def provider():
        return next(tokens)

    async with ConvergerSocket(server.url, provider, backoff_initial=0.01) as sock:
        assert await recv_types(sock, 2) == ["error", "welcome"]  # the refusal is surfaced, then the retry succeeds
    assert len(server.hellos) == 2
