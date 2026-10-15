"""The agent against the in-process fake server (tests/conftest.py)."""

from __future__ import annotations

import asyncio
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from converger_agent import Agent, ConnectionClosed, ConvergerError, channel_token_source, http_base, ws_url
from conftest import CONV, CONV2, genui_text


def make_agent(server, **kw) -> Agent:
    kw.setdefault("token", "tok-1")
    kw.setdefault("backoff_initial", 0.01)
    kw.setdefault("backoff_max", 0.05)
    return Agent(server.url, **kw)


# --- URLs ---------------------------------------------------------------------


def test_urls():
    assert ws_url("https://chat.example.com") == "wss://chat.example.com/socket/converger/v1"
    assert ws_url("http://localhost:4000/") == "ws://localhost:4000/socket/converger/v1"
    assert ws_url("wss://h/socket/converger/v1") == "wss://h/socket/converger/v1"
    assert http_base("wss://h/socket/converger/v1") == "https://h"
    assert http_base("ws://localhost:4000") == "http://localhost:4000"


def test_exactly_one_credential():
    with pytest.raises(ValueError):
        Agent("ws://x")
    with pytest.raises(ValueError):
        Agent("ws://x", "t", channel_secret="s")


# --- handshake ----------------------------------------------------------------


async def test_hello_and_welcome(server, run_agent):
    agent = make_agent(server, group="faq-bot", user_id="agent-7")
    run_agent(agent)
    await agent.wait_connected(5)
    assert server.tokens == ["tok-1"]
    assert server.subprotocols == ["converger.v1"]
    assert server.hellos == [{"type": "hello", "protocol": "converger/1", "group": "faq-bot", "userId": "agent-7"}]
    assert agent.welcome["scope"] == "channel"


# --- turns --------------------------------------------------------------------


async def test_turn_dispatch_and_text_reply(server, run_agent):
    agent = make_agent(server)
    turns = []

    @agent.on_turn
    async def handle(turn, reply):
        turns.append(turn)
        ack = await reply.text(f"echo: {turn.text}", actions=["Track", {"label": "Refund", "value": "/refund"}])
        assert ack["type"] == "ack" and isinstance(ack["seq"], int)

    run_agent(agent)
    await server.wait_connected()
    sent = await server.user_text(CONV, "hello", meta={"locale": "tr-TR", "channel": {"type": "whatsapp"}}, metadata={"action": {"label": "Hi", "value": "hi"}}, replyTo={"id": "m-1"})

    finished = await server.wait_frame("run", CONV, data__status="finished")
    assert finished == {"type": "run", "data": {"status": "finished"}}
    turn = turns[0]
    assert (turn.conversation_id, turn.text, turn.id, turn.seq) == (CONV, "hello", sent["id"], 1)
    assert turn.message.type == "text" and turn.message.raw == sent
    assert turn.meta["locale"] == "tr-TR" and turn.channel == {"type": "whatsapp"}
    assert turn.participant == {"id": "alice", "role": "user"}
    assert turn.action == {"label": "Hi", "value": "hi"} and turn.reply_to == {"id": "m-1"}

    types = [f["type"] for f in server.frames(CONV)]
    assert types == ["read", "run", "text", "run"]
    assert server.frames(CONV, "read") == [{"type": "read", "watermark": 1}]
    text = server.frames(CONV, "text")[0]
    assert text["data"] == {"text": "echo: hello"}
    assert text["actions"] == [{"label": "Track", "value": "Track"}, {"label": "Refund", "value": "/refund"}]
    assert text["clientId"].endswith(".m1") and sent["id"] in text["clientId"]
    assert agent.watermarks == {CONV: 1}


async def test_bot_frames_and_own_echoes_are_not_turns(server, run_agent):
    agent = make_agent(server)
    turns = []
    others = []

    @agent.on_turn
    async def handle(turn, reply):
        turns.append(turn.text)

    agent.on_frame(lambda cid, frame: others.append(frame["type"]))
    run_agent(agent)
    await server.wait_connected()
    await server.push(CONV, {"type": "text", "id": "b1", "seq": server.next_seq(CONV), "from": "bot", "data": {"text": "from another bot"}})
    await server.push(CONV, {"type": "tool_call", "seq": server.next_seq(CONV), "data": {"id": "t", "name": "x", "status": "running"}})
    await server.push(CONV, {"type": "deliveryStatus", "data": {"activityId": "a", "seq": 1, "channelId": "wa", "status": "delivered"}})
    await server.user_text(CONV, "real")
    await server.wait_frame("run", CONV, data__status="finished")
    assert turns == ["real"]
    assert others == ["text", "tool_call", "deliveryStatus"]
    assert agent.watermarks[CONV] == 3


async def test_reply_helpers_produce_valid_frames(server, run_agent):
    agent = make_agent(server)

    @agent.on_turn
    async def handle(turn, reply):
        await reply.typing(True)
        async with reply.stream() as s:
            await s.write("Hel")
            await s.write("lo")
            await s.ui("order-card", {"id": "ORD-42"})
        await reply.tool_call("t1", "running", name="get_order", params={"id": "ORD-42"})
        await reply.tool_call("t1", "completed", result={"total": 249.9})
        await reply.tool_call("t2", "error", name="refund", error="declined")
        await reply.ui("approval-form", {"amount": 1})
        await reply.message("buttons", {"text": "Pick", "buttons": [{"label": "A", "value": "a"}]})
        await reply.message("card", {"title": "Order", "subtitle": "ORD-42"}, metadata={"k": "v"})
        with pytest.raises(ValueError):
            await reply.message("tool_call", {})

    run_agent(agent)
    await server.wait_connected()
    await server.user_text(CONV, "hi")
    await server.wait_frame("run", CONV, data__status="finished")
    frames = server.frames(CONV)
    genui = [f for f in frames if f["type"] == "genui"]
    streams = {f["streamId"] for f in genui}
    assert len(streams) == 2  # the stream and the standalone ui
    first = genui[0]["streamId"]
    assert genui_text(frames, first) == "Hello"
    assert [f["done"] for f in genui if f["streamId"] == first] == [False, False, True]
    # The deltas are one text run (coalesced into one chunk here: the ui chunk
    # flushes them), the ui chunk takes the next id and stream_done closes it.
    assert [f["chunk"] for f in genui if f["streamId"] == first] == [
        {"type": "text", "content": "Hello", "id": 1},
        {"type": "ui", "component": "order-card", "props": {"id": "ORD-42"}, "id": 2},
        {"type": "event", "name": "stream_done", "id": 3},
    ]
    tools = server.frames(CONV, "tool_call")
    assert [t["data"]["status"] for t in tools] == ["running", "completed", "error"]
    assert tools[1]["data"]["name"] == "get_order"  # remembered from the first call
    typing = server.frames(CONV, "typing")
    assert typing == [{"type": "typing", "isTyping": True}, {"type": "typing", "isTyping": False}]
    assert [f["type"] for f in frames if "clientId" in f] == ["buttons", "card"]


async def test_stream_deltas_are_one_text_run_coalesced_per_flush_interval(server, run_agent):
    agent = make_agent(server, stream_flush=0.05)
    unbuffered = make_agent(server, stream_flush=0)

    async def handle(turn, reply):
        async with reply.stream() as s:
            for delta in ("Orders", " ", "ship", " ", "today."):
                await s.write(delta)
            await asyncio.sleep(0.15)  # past the flush interval: a second chunk
            await s.write(" Bye")

    agent.on_turn(handle)
    run_agent(agent)
    await server.wait_connected()
    await server.user_text(CONV, "hi")
    await server.wait_frame("run", CONV, data__status="finished")
    chunks = [f["chunk"] for f in server.frames(CONV, "genui")]
    assert chunks == [
        {"type": "text", "content": "Orders ship today.", "id": 1},
        {"type": "text", "content": " Bye", "id": 1},
        {"type": "event", "name": "stream_done", "id": 2},
    ]
    await agent.stop()

    # stream_flush=0: one chunk per delta, still one text run.
    unbuffered.on_turn(handle)
    run_agent(unbuffered)
    await server.wait_connected(2)
    await server.user_text(CONV2, "hi")
    await server.wait_frame("run", CONV2, data__status="finished")
    chunks = [f["chunk"] for f in server.frames(CONV2, "genui")]
    assert [c.get("content") for c in chunks] == ["Orders", " ", "ship", " ", "today.", " Bye", None]
    assert {c["id"] for c in chunks[:-1]} == {1}


async def test_outbound_frames_are_paced_below_the_server_rate(server, run_agent):
    agent = make_agent(server, max_frames_per_second=20)
    elapsed = []

    @agent.on_turn
    async def handle(turn, reply):
        loop = asyncio.get_running_loop()
        start = loop.time()
        for i in range(16):
            await reply.tool_call(f"t{i}", "running", name="lookup")
        elapsed.append(loop.time() - start)

    run_agent(agent)
    await server.wait_connected()
    await server.user_text(CONV, "hi")
    await server.wait_frame("run", CONV, data__status="finished", timeout=10)
    assert len(server.frames(CONV, "tool_call")) == 16
    # A burst of 20 / 3 frames, then 20 per second: at least (16 - 6.7) / 20 s.
    assert elapsed[0] >= 0.4


async def test_text_fallback_sends_the_joined_text(server, run_agent):
    agent = make_agent(server, text_fallback=True)

    @agent.on_turn
    async def handle(turn, reply):
        s = reply.stream()
        await s.write("a")
        await s.write("b")
        # left open: the reply ends it after the handler

    run_agent(agent)
    await server.wait_connected()
    await server.user_text(CONV, "hi")
    await server.wait_frame("run", CONV, data__status="finished")
    text = server.frames(CONV, "text")[0]
    assert text["data"] == {"text": "ab"} and text["metadata"]["genuiStreamId"]


async def test_turns_of_a_conversation_are_serialised_and_conversations_concurrent(server, run_agent):
    agent = make_agent(server, auto_read=False)
    log = []
    gate = asyncio.Event()

    @agent.on_turn
    async def handle(turn, reply):
        log.append(("start", turn.conversation_id, turn.text))
        if turn.text == "slow":
            await gate.wait()
        log.append(("end", turn.conversation_id, turn.text))

    run_agent(agent)
    await server.wait_connected()
    await server.user_text(CONV, "slow")
    await server.user_text(CONV, "second")
    await server.user_text(CONV2, "other")
    await server.wait_frame("run", CONV2, data__status="finished")
    assert ("end", CONV2, "other") in log
    assert ("start", CONV, "second") not in log
    gate.set()
    await server.wait_for(lambda e: len([f for f in server.frames(CONV, "run") if f["data"]["status"] == "finished"]) == 2)
    conv_log = [entry for entry in log if entry[1] == CONV]
    assert conv_log == [("start", CONV, "slow"), ("end", CONV, "slow"), ("start", CONV, "second"), ("end", CONV, "second")]


# --- ask / resume -------------------------------------------------------------


async def test_ask_waits_for_resume(server, run_agent):
    agent = make_agent(server)
    answers = []

    @agent.on_turn
    async def handle(turn, reply):
        answer = await reply.ask({"title": "Refund 249.90?"}, [{"label": "Yes", "value": {"ok": True}}, "No"], ui={"component": "approval-form", "props": {"amount": 249.9}})
        answers.append(answer)
        await reply.text("done")

    run_agent(agent)
    await server.wait_connected()
    await server.user_text(CONV, "refund please")
    interrupt = await server.wait_frame("interrupt", CONV)
    assert interrupt["data"] == {
        "payload": {"title": "Refund 249.90?"},
        "actions": [{"label": "Yes", "value": {"ok": True}}, {"label": "No", "value": "No"}],
        "ui": {"component": "approval-form", "props": {"amount": 249.9}},
    }
    await server.wait_frame("run", CONV, data__status="interrupted")
    await server.push(CONV, {"type": "resume", "answers": {interrupt["id"]: {"ok": True}}})
    resolved = await server.wait_frame("interrupt_resolved", CONV)
    assert resolved == {"type": "interrupt_resolved", "id": interrupt["id"], "data": {"answer": {"ok": True}}}
    await server.wait_frame("run", CONV, data__status="finished")
    assert answers == [{"ok": True}]
    statuses = [f["data"]["status"] for f in server.frames(CONV, "run")]
    assert statuses == ["started", "interrupted", "started", "finished"]


async def test_typed_answer_resolves_an_open_ask(server, run_agent):
    agent = make_agent(server)
    answers = []

    @agent.on_turn
    async def handle(turn, reply):
        answers.append(await reply.ask("Are you sure?", id="sure#0"))

    run_agent(agent)
    await server.wait_connected()
    await server.user_text(CONV, "cancel my order")
    await server.wait_frame("interrupt", CONV)
    await server.user_text(CONV, "yes")
    await server.wait_frame("run", CONV, data__status="finished")
    assert answers == ["yes"]
    assert len([f for f in server.frames(CONV, "run") if f["data"]["status"] == "finished"]) == 1


async def test_resume_without_a_waiting_ask_becomes_a_resume_turn(server, run_agent):
    agent = make_agent(server)
    seen = []

    @agent.on_turn
    async def handle(turn, reply):
        seen.append((turn.message.type, turn.resume))

    run_agent(agent)
    await server.wait_connected()
    await server.push(CONV, {"type": "resume", "answers": {"old#0": True}})
    await server.wait_frame("run", CONV, data__status="finished")
    assert seen == [("resume", {"old#0": True})]


async def test_abort_cancels_the_running_turn(server, run_agent):
    agent = make_agent(server)
    cancelled = asyncio.Event()

    @agent.on_turn
    async def handle(turn, reply):
        try:
            await asyncio.sleep(30)
        except asyncio.CancelledError:
            cancelled.set()
            raise

    run_agent(agent)
    await server.wait_connected()
    await server.user_text(CONV, "long")
    await server.wait_frame("run", CONV, data__status="started")
    await server.push(CONV, {"type": "abort"})
    await server.wait_frame("run", CONV, data__status="aborted")
    assert cancelled.is_set()


# --- errors -------------------------------------------------------------------


async def test_a_refused_send_raises_and_the_turn_reports_an_error(server, run_agent):
    agent = make_agent(server)
    errors = []

    async def refuse(envelope):
        frame = envelope.get("frame", {})
        if frame.get("type") == "text":
            await server.push(envelope["conversationId"], {"type": "error", "data": {"code": "conversation_closed", "message": "closed", "number": 4000, "retryable": False, "clientId": frame["clientId"]}})
            return False
        return None

    server.on_frame = refuse

    @agent.on_turn
    async def handle(turn, reply):
        try:
            await reply.text("hi")
        except ConvergerError as exc:
            errors.append(exc)
            raise

    run_agent(agent)
    await server.wait_connected()
    await server.user_text(CONV, "x")
    await server.wait_frame("run", CONV, data__status="error")
    assert errors[0].code == "conversation_closed" and not errors[0].retryable and errors[0].conversation_id == CONV
    error = server.frames(CONV, "error")[0]
    assert error["data"]["code"] == "conversation_closed"


async def test_retryable_refusals_are_retried_with_the_same_client_id(server, run_agent):
    agent = make_agent(server)
    attempts = []

    async def limit(envelope):
        frame = envelope.get("frame", {})
        if frame.get("type") == "text":
            attempts.append(frame["clientId"])
            if len(attempts) == 1:
                await server.push(envelope["conversationId"], {"type": "error", "data": {"code": "rate_limited", "message": "slow down", "retryable": True, "retryAfterMs": 10, "clientId": frame["clientId"]}})
                return False
        return None

    server.on_frame = limit

    @agent.on_turn
    async def handle(turn, reply):
        await reply.text("hi")

    run_agent(agent)
    await server.wait_connected()
    await server.user_text(CONV, "x")
    await server.wait_frame("run", CONV, data__status="finished")
    assert len(attempts) == 2 and attempts[0] == attempts[1]


async def test_connection_errors_go_to_on_error(server, run_agent):
    agent = make_agent(server)
    errors = []
    agent.on_error(errors.append)
    run_agent(agent)
    await server.wait_connected()
    await server.push_bare({"type": "error", "data": {"code": "bad_request", "message": "nope", "number": 1000, "retryable": False}})
    await server.push(CONV, {"type": "error", "data": {"code": "conversation_not_found", "message": "not found"}})
    for _ in range(100):
        if len(errors) == 2:
            break
        await asyncio.sleep(0.01)
    assert [(e.code, e.conversation_id) for e in errors] == [("bad_request", None), ("conversation_not_found", CONV)]


async def test_terminal_close_ends_run(server):
    agent = make_agent(server)
    task = asyncio.ensure_future(agent.run())
    await server.wait_connected()
    await server.close(4403, "forbidden")
    with pytest.raises(ConnectionClosed) as info:
        await asyncio.wait_for(task, 5)
    assert info.value.close_code == 4403 and info.value.code == "forbidden"


async def test_401_with_a_token_source_reconnects_with_a_fresh_token(server, run_agent):
    tokens = iter(["t1", "t2", "t3"])

    async def get_token():
        return next(tokens)

    agent = make_agent(server, token=None, get_token=get_token)
    run_agent(agent)
    await server.wait_connected()
    await server.close(4401, "token_expired")
    await server.wait_connected(2)
    assert server.tokens == ["t1", "t2"]


async def test_mid_session_refresh_before_expiry(server, run_agent):
    import time

    server.welcome_data = {"expiresAt": int((time.time() + 60) * 1000)}
    agent = make_agent(server, token=None, get_token=lambda: "fresh", refresh_margin=600)  # due now: after the 1 s minimum
    run_agent(agent)
    await server.wait_connected()
    auth = await server.wait_for(lambda e: e.get("type") == "auth", timeout=5)
    assert auth == {"type": "auth", "token": "fresh"}


# --- reconnect and resume -----------------------------------------------------


async def test_reconnect_sends_watermarks_and_resends_unacked(server, run_agent):
    agent = make_agent(server)
    server.auto_ack = False
    acks = []

    @agent.on_turn
    async def handle(turn, reply):
        acks.append(await reply.text("answer"))

    run_agent(agent)
    await server.wait_connected()
    await server.user_text(CONV, "q1")
    first = await server.wait_frame("text", CONV)
    server.auto_ack = True
    await server.close(1012, json.dumps({"reason": "unavailable", "retryAfterMs": 20}))
    await server.wait_connected(2)
    assert server.hellos[1]["watermarks"] == {CONV: 1}
    await server.wait_frame("run", CONV, data__status="finished")
    resent = server.frames(CONV, "text")
    assert len(resent) == 2 and resent[0]["clientId"] == resent[1]["clientId"] == first["clientId"]
    assert acks[0]["clientId"] == first["clientId"]


async def test_replayed_frames_at_or_below_the_watermark_are_not_dispatched(server, run_agent):
    agent = make_agent(server, watermarks={CONV: 5})
    turns = []

    @agent.on_turn
    async def handle(turn, reply):
        turns.append(turn.seq)

    run_agent(agent)
    await server.wait_connected()
    assert server.hellos[0]["watermarks"] == {CONV: 5}
    for seq in (4, 5, 6):
        await server.push(CONV, {"type": "text", "id": f"m{seq}", "seq": seq, "from": "user", "data": {"text": str(seq)}})
    await server.wait_frame("run", CONV, data__status="finished")
    assert turns == [6]


async def test_history_backfills_with_sync(server, run_agent):
    agent = make_agent(server, history_timeout=1.0)
    history = []

    async def replay(envelope):
        frame = envelope.get("frame", {})
        if frame.get("type") == "sync":
            cid = envelope["conversationId"]
            await server.push(cid, {"type": "text", "id": "m1", "seq": 1, "from": "user", "data": {"text": "earlier"}})
            await server.push(cid, {"type": "text", "id": "m2", "seq": 2, "from": "bot", "data": {"text": "earlier answer"}})
            await server.push(cid, {"type": "genui", "seq": 3, "streamId": "s", "done": True, "chunk": {"type": "text", "content": ""}})
            await server.push(cid, {"type": "text", "id": "m4", "seq": 4, "from": "user", "data": {"text": "now"}})
        return None

    server.on_frame = replay
    server.seq[CONV] = 3

    @agent.on_turn
    async def handle(turn, reply):
        await reply.text("ok")
        history.extend(await turn.history())

    run_agent(agent)
    await server.wait_connected()
    await server.user_text(CONV, "now")
    await server.wait_frame("run", CONV, data__status="finished")
    assert [f["data"]["text"] for f in history] == ["earlier", "earlier answer", "now", "ok"]
    assert server.frames(CONV, "sync") == [{"type": "sync", "watermark": 0}]


# --- channel secret -----------------------------------------------------------


async def test_channel_token_source_generates_a_channel_scoped_token():
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append((self.path, self.headers["Authorization"], body))
            status, payload = (200, {"token": "chan-tok", "expires_in": 1800}) if self.headers["Authorization"] == "Bearer good" else (401, {"error": {"code": "unauthorized", "message": "bad secret"}})
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    httpd = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        base = f"ws://127.0.0.1:{httpd.server_port}/socket/converger/v1"
        assert await channel_token_source(base, "good", user_id="agent-7")() == "chan-tok"
        assert requests[0] == ("/api/v1/converger/tokens/generate", "Bearer good", {"scope": "channel", "user": {"id": "agent-7"}})
        with pytest.raises(ConvergerError) as info:
            await channel_token_source(base, "bad")()
        assert info.value.code == "unauthorized" and not info.value.retryable
    finally:
        httpd.shutdown()


def test_the_schema_check_rejects_invalid_agent_frames():
    from conftest import assert_valid

    assert_valid({"conversationId": CONV, "frame": {"type": "tool_call", "data": {"id": "t", "name": "x", "status": "running"}}})
    for bad in (
        {"conversationId": CONV, "frame": {"type": "tool_call", "data": {"id": "t", "status": "running"}}},
        {"conversationId": CONV, "frame": {"type": "genui", "streamId": "s", "done": False, "chunk": {"type": "text"}}},
        {"conversationId": CONV, "frame": {"type": "run", "data": {"status": "thinking"}}},
        {"conversationId": CONV, "frame": {"type": "text", "clientId": "bad id!", "data": {"text": "x"}}},
    ):
        with pytest.raises(AssertionError):
            assert_valid(bad)
