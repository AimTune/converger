"""End-to-end test against a real server (packages/conformance/integration).

Skipped unless CONVERGER_FIXTURES points at the fixtures file written by
packages/conformance/integration/server.exs (its "agent-python" entry: a
widget channel routed to a bot channel). Run with
``packages/conformance/integration/run.sh agent-python``.
"""

from __future__ import annotations

import asyncio
import json
import os
import urllib.request
import uuid

import pytest
from websockets.asyncio.client import connect

from converger_agent import Agent, http_base, ws_url

FIXTURES = os.environ.get("CONVERGER_FIXTURES")
pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(not FIXTURES, reason="set CONVERGER_FIXTURES to run against a real server"),
]


def fixtures() -> dict:
    with open(FIXTURES, encoding="utf-8") as f:
        doc = json.load(f)
    fx = doc["agent-python"]
    fx["base_url"] = os.environ.get("CONVERGER_BASE_URL", doc["base_url"])
    return fx


def post(url: str, bearer: str, body: dict) -> dict:
    request = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST", headers={"Authorization": f"Bearer {bearer}", "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=10) as response:  # noqa: S310
        return json.loads(response.read())


async def end_user(base: str, widget_secret: str) -> tuple[str, str]:
    """A widget end user: a token from the channel secret, then a conversation-bound token."""
    api = http_base(base) + "/api/v1/converger"
    token = (await asyncio.to_thread(post, api + "/tokens/generate", widget_secret, {"user": {"id": f"user-{uuid.uuid4().hex[:6]}"}}))["token"]
    conv = await asyncio.to_thread(post, api + "/conversations", token, {})
    return conv["conversationId"], conv["token"]


async def recv_until(ws, predicate, timeout: float = 15.0) -> tuple[dict, list[dict]]:
    seen: list[dict] = []

    async def loop() -> dict:
        while True:
            frame = json.loads(await ws.recv())
            seen.append(frame)
            if predicate(frame):
                return frame

    return await asyncio.wait_for(loop(), timeout), seen


async def test_an_agent_answers_a_widget_user_through_the_server():
    fx = fixtures()
    agent = Agent(fx["base_url"], channel_secret=fx["bot_secret"], user_id="agent-it", group="it", backoff_initial=0.1)
    turns = []
    errors = []
    agent.on_error(errors.append)

    @agent.on_turn
    async def handle(turn, reply):
        turns.append(turn)
        if turn.text == "refund":
            answer = await reply.ask({"title": "Refund 249.90?"}, ["Yes", "No"])
            await reply.text(f"answer: {answer}")
            return
        await reply.tool_call("t1", "running", name="lookup", params={"q": turn.text})
        await reply.tool_call("t1", "completed", result={"ok": True})
        async with reply.stream() as s:
            await s.write("echo: ")
            await s.write(turn.text)
        await reply.text(f"done: {turn.text}")

    runner = asyncio.ensure_future(agent.run())
    try:
        await agent.wait_connected(15)
        conversation_id, token = await end_user(fx["base_url"], fx["widget_secret"])
        async with connect(ws_url(fx["base_url"]), subprotocols=["converger.v1"], additional_headers={"Authorization": f"Bearer {token}"}) as ws:  # type: ignore[list-item]
            await ws.send(json.dumps({"type": "hello", "protocol": "converger/1"}))
            welcome, _ = await recv_until(ws, lambda f: f.get("type") == "welcome")
            assert welcome["data"]["conversationId"] == conversation_id

            await ws.send(json.dumps({"type": "text", "clientId": "u-1", "data": {"text": "hello"}}))
            done, seen = await recv_until(ws, lambda f: f.get("type") == "text" and f.get("from") == "bot" and f["data"]["text"] == "done: hello")
            types = [f["type"] for f in seen]
            assert "ack" in types and "run" in types and "tool_call" in types
            assert "".join(f["chunk"].get("content", "") for f in seen if f["type"] == "genui") == "echo: hello"
            assert turns[0].conversation_id == conversation_id and turns[0].text == "hello"

            await ws.send(json.dumps({"type": "text", "clientId": "u-2", "data": {"text": "refund"}}))
            interrupt, _ = await recv_until(ws, lambda f: f.get("type") == "interrupt")
            assert interrupt["data"]["actions"] == [{"label": "Yes", "value": "Yes"}, {"label": "No", "value": "No"}]
            await ws.send(json.dumps({"type": "resume", "answers": {interrupt["id"]: "Yes"}}))
            _, seen = await recv_until(ws, lambda f: f.get("type") == "text" and f.get("from") == "bot" and f["data"]["text"] == "answer: Yes")
            assert any(f["type"] == "interrupt_resolved" and f["id"] == interrupt["id"] for f in seen), (seen, errors)
        assert agent.watermarks[conversation_id] >= 1
    finally:
        await agent.stop()
        await asyncio.wait_for(runner, 10)
