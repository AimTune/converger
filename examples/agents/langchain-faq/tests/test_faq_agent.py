"""The FAQ graph with a fake model, served through converger-agent against the SDK's fake server."""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from faq_agent import build_graph, fake_model, make_agent, search_faq  # noqa: E402

from converger_agent.testing import FakeServer, genui_text  # noqa: E402

needs_311 = pytest.mark.skipif(sys.version_info < (3, 11), reason="LangGraph interrupt() under asyncio needs Python 3.11+")

WIDGET = "c0a8012e-7d3b-4c5e-9f1a-2b3c4d5e6f70"
WHATSAPP = "5d1e0a77-2a4b-4c4d-9e8f-0a1b2c3d4e5f"


@pytest.fixture
async def setup():
    server = await FakeServer().start()
    agent = make_agent(build_graph(fake_model(["Orders ship within 1 business day."])), url=server.url, token="test", backoff_initial=0.01)
    task = asyncio.ensure_future(agent.run())
    await server.wait_connected()
    yield server
    await agent.stop()
    await asyncio.wait_for(task, 5)
    await server.stop()


def test_search_faq_tool():
    assert search_faq.invoke({"question": "When will my order ship?"})[0]["topic"] == "shipping"
    assert len(search_faq.invoke({"question": "zzz"})) == 5


async def test_answers_and_streams_with_a_tool_trace(setup):
    server = setup
    await server.user_text(WIDGET, "When does my order ship?")
    await server.wait_frame("run", WIDGET, data__status="finished")
    assert genui_text(server.frames(WIDGET)) == "Orders ship within 1 business day."
    tools = server.frames(WIDGET, "tool_call")
    assert [(t["data"]["name"], t["data"]["status"]) for t in tools] == [("search_faq", "running"), ("search_faq", "completed")]
    assert tools[1]["data"]["result"][0]["topic"] == "shipping"


@needs_311
async def test_talk_to_a_human_pauses_on_an_interrupt(setup):
    server = setup
    await server.user_text(WHATSAPP, "I want to talk to a human")
    interrupt = await server.wait_frame("interrupt", WHATSAPP)
    assert interrupt["data"]["payload"]["title"] == "Shall I connect you with a human agent?"
    assert [a["label"] for a in interrupt["data"]["actions"]] == ["Yes, connect me", "No, thanks"]

    # A tapped button (widget chip or WhatsApp reply button) reaches the agent as resume.
    await server.push(WHATSAPP, {"type": "resume", "answers": {interrupt["id"]: "yes"}})
    await server.wait_frame("run", WHATSAPP, data__status="finished")
    assert server.frames(WHATSAPP, "text")[-1]["data"]["text"].startswith("Done: a human agent")


@needs_311
async def test_a_typed_answer_also_resumes(setup):
    server = setup
    await server.user_text(WHATSAPP, "connect me to an agent please")
    await server.wait_frame("interrupt", WHATSAPP)
    await server.user_text(WHATSAPP, "no")
    await server.wait_frame("run", WHATSAPP, data__status="finished")
    assert server.frames(WHATSAPP, "text")[-1]["data"]["text"].startswith("No problem")
