"""converger_agent.langchain with fake chat models and a tiny LangGraph graph (no network LLM calls)."""

from __future__ import annotations

import sys

import pytest

pytest.importorskip("langgraph")
httpx = pytest.importorskip("httpx")

from langchain_core.language_models.fake_chat_models import GenericFakeChatModel  # noqa: E402
from langchain_core.messages import AIMessage  # noqa: E402
from langchain_core.runnables import RunnableConfig, RunnableLambda  # noqa: E402
from langchain_core.tools import tool  # noqa: E402
from langgraph.checkpoint.memory import InMemorySaver  # noqa: E402
from langgraph.graph import END, START, MessagesState, StateGraph  # noqa: E402
from langgraph.types import interrupt  # noqa: E402

from converger_agent import Agent  # noqa: E402
from converger_agent.langchain import bridge_langserve, content_text, interrupt_request, jsonable, serve  # noqa: E402
from conftest import CONV, genui_text  # noqa: E402

pytestmark = pytest.mark.langchain

# LangGraph's interrupt() reads its config from a context variable that asyncio
# only propagates from Python 3.11 on.
needs_311 = pytest.mark.skipif(sys.version_info < (3, 11), reason="LangGraph interrupt() under asyncio needs Python 3.11+")


@tool
def lookup_order(order_id: str) -> dict:
    """Look up an order."""
    return {"id": order_id, "status": "shipped"}


def build_graph(replies: list[str], checkpointer=None):
    model = GenericFakeChatModel(messages=iter([AIMessage(content=r) for r in replies]))

    # Nodes take `config` and pass it on: before Python 3.11 asyncio does not
    # propagate it (streaming events, interrupt()) by itself.
    async def lookup(state: MessagesState, config: RunnableConfig):
        result = await lookup_order.ainvoke({"order_id": "ORD-42"}, config)
        return {"messages": [AIMessage(content=f"Order {result['id']} is {result['status']}.")]}

    async def answer(state: MessagesState, config: RunnableConfig):
        return {"messages": [await model.ainvoke(state["messages"], config)]}

    def approve(state: MessagesState):
        decision = interrupt({"title": "Refund 249.90 TRY?", "options": ["Yes", "No"]})
        return {"messages": [AIMessage(content=f"Refund {'approved' if decision == 'Yes' else 'cancelled'}.")]}

    g = StateGraph(MessagesState)
    g.add_node("lookup", lookup)
    g.add_node("answer", answer)
    g.add_node("approve", approve)
    g.add_edge(START, "lookup")
    g.add_edge("lookup", "answer")
    g.add_edge("answer", "approve")
    g.add_edge("approve", END)
    return g.compile(checkpointer=checkpointer or InMemorySaver())


def make_agent(server, **kw):
    return Agent(server.url, token="tok", backoff_initial=0.01, **kw)


# --- mapping helpers ----------------------------------------------------------


def test_content_text():
    assert content_text("hi") == "hi"
    assert content_text([{"type": "text", "text": "a"}, {"type": "tool_use", "id": "x"}, "b"]) == "ab"
    assert content_text({"content": "x", "type": "AIMessageChunk"}) == "x"
    assert content_text(AIMessage(content=[{"type": "text", "text": "z"}])) == "z"
    assert content_text(None) == ""


def test_interrupt_request():
    assert interrupt_request("Proceed?") == ({"title": "Proceed?"}, [{"label": "Approve", "value": {"approved": True}}, {"label": "Reject", "value": {"approved": False}}], None)
    payload, actions, ui = interrupt_request({"question": "Pick", "options": ["A", "B"], "order": 1})
    assert payload == {"question": "Pick", "order": 1, "title": "Pick"} and actions == ["A", "B"] and ui is None
    payload, actions, ui = interrupt_request({"title": "Form", "ui": {"component": "refund-form", "props": {"max": 10}}})
    assert actions is None and ui == {"component": "refund-form", "props": {"max": 10}}
    payload, actions, _ = interrupt_request({"title": "T", "actions": [{"label": "Go", "value": 1}]})
    assert actions == [{"label": "Go", "value": 1}]


def test_jsonable():
    assert jsonable({"m": AIMessage(content="x"), "t": (1, 2), "o": object}) == {"m": "x", "t": [1, 2], "o": str(object)}


# --- serve() end to end -------------------------------------------------------


@needs_311
async def test_graph_streams_traces_tools_and_interrupts(server, run_agent):
    graph = build_graph(["Your order ships today"])
    agent = serve(graph, make_agent(server))
    run_agent(agent)
    await server.wait_connected()
    await server.user_text(CONV, "where is my order?")

    interrupt_frame = await server.wait_frame("interrupt", CONV)
    assert interrupt_frame["data"]["payload"]["title"] == "Refund 249.90 TRY?"
    assert interrupt_frame["data"]["actions"] == [{"label": "Yes", "value": "Yes"}, {"label": "No", "value": "No"}]

    frames = server.frames(CONV)
    assert genui_text(frames) == "Your order ships today"
    tools = server.frames(CONV, "tool_call")
    assert [(t["data"]["name"], t["data"]["status"]) for t in tools] == [("lookup_order", "running"), ("lookup_order", "completed")]
    assert tools[0]["data"]["params"] == {"order_id": "ORD-42"} and tools[0]["data"]["id"] == tools[1]["data"]["id"]
    assert tools[1]["data"]["result"] == {"id": "ORD-42", "status": "shipped"}
    texts = [f["data"]["text"] for f in server.frames(CONV, "text")]
    assert texts == ["Order ORD-42 is shipped."]  # the node's own message; the model's answer was streamed

    await server.push(CONV, {"type": "resume", "answers": {interrupt_frame["id"]: "Yes"}})
    await server.wait_frame("run", CONV, data__status="finished")
    texts = [f["data"]["text"] for f in server.frames(CONV, "text")]
    assert texts == ["Order ORD-42 is shipped.", "Refund approved."]
    assert server.frames(CONV, "interrupt_resolved")[0]["data"] == {"answer": "Yes"}
    state = await graph.aget_state({"configurable": {"thread_id": CONV}})
    assert not state.next


@needs_311
async def test_typed_answer_resumes_the_graph(server, run_agent):
    graph = build_graph(["ok"])
    run_agent(serve(graph, make_agent(server)))
    await server.wait_connected()
    await server.user_text(CONV, "refund")
    await server.wait_frame("interrupt", CONV)
    await server.user_text(CONV, "No")
    await server.wait_frame("run", CONV, data__status="finished")
    assert server.frames(CONV, "text")[-1]["data"]["text"] == "Refund cancelled."


@needs_311
async def test_resume_after_a_restart_continues_from_the_checkpoint(server, run_agent):
    saver = InMemorySaver()
    first = make_agent(server)
    run_agent(serve(build_graph(["a"], saver), first))
    await server.wait_connected()
    await server.user_text(CONV, "refund")
    interrupt_frame = await server.wait_frame("interrupt", CONV)
    await first.stop()

    second = make_agent(server)
    run_agent(serve(build_graph(["b"], saver), second))
    await server.wait_connected(2)
    await server.push(CONV, {"type": "resume", "answers": {interrupt_frame["id"]: "Yes"}})
    await server.wait_for(lambda e: e.get("frame", {}).get("type") == "text" and e["frame"]["data"]["text"] == "Refund approved.")


async def test_a_plain_chat_model_streams(server, run_agent):
    model = GenericFakeChatModel(messages=iter([AIMessage(content="Hello from the model")]))
    run_agent(serve(model, make_agent(server)))
    await server.wait_connected()
    await server.user_text(CONV, "hi")
    await server.wait_frame("run", CONV, data__status="finished")
    assert genui_text(server.frames(CONV)) == "Hello from the model"
    assert server.frames(CONV, "text") == []


async def test_a_runnable_that_does_not_stream_answers_with_text(server, run_agent):
    chain = RunnableLambda(lambda text: f"upper: {text.upper()}")
    run_agent(serve(chain, make_agent(server), typing=False))
    await server.wait_connected()
    await server.user_text(CONV, "hi")
    await server.wait_frame("run", CONV, data__status="finished")
    assert [f["data"]["text"] for f in server.frames(CONV, "text")] == ["upper: HI"]
    assert server.frames(CONV, "typing") == []


async def test_tool_errors_become_error_traces(server, run_agent):
    @tool
    def broken(x: str) -> str:
        """Always fails."""
        raise ValueError("boom")

    async def run(text, config: RunnableConfig):
        try:
            await broken.ainvoke({"x": text}, config)
        except ValueError:
            return "sorry"

    run_agent(serve(RunnableLambda(run), make_agent(server)))
    await server.wait_connected()
    await server.user_text(CONV, "go")
    await server.wait_frame("run", CONV, data__status="finished")
    tools = server.frames(CONV, "tool_call")
    assert [t["data"]["status"] for t in tools] == ["running", "error"] and "boom" in tools[1]["data"]["error"]


# --- LangServe bridge ---------------------------------------------------------


def sse(*events):
    out = ""
    for name, data in events:
        out += f"event: {name}\ndata: {data}\n\n"
    return out


async def test_bridge_langserve_maps_remote_events(server, run_agent):
    import json

    bodies = []

    def handler(request: httpx.Request) -> httpx.Response:
        bodies.append((request.url.path, json.loads(request.content)))
        events = [
            ("data", json.dumps({"event": "on_chain_start", "run_id": "r0", "name": "chain", "data": {}, "parent_ids": []})),
            ("data", json.dumps({"event": "on_tool_start", "run_id": "t1", "name": "search", "data": {"input": {"q": "x"}}, "parent_ids": ["r0"]})),
            ("data", json.dumps({"event": "on_tool_end", "run_id": "t1", "name": "search", "data": {"output": "found"}, "parent_ids": ["r0"]})),
            ("data", json.dumps({"event": "on_chat_model_stream", "run_id": "m1", "name": "model", "data": {"chunk": {"content": "Hi ", "type": "AIMessageChunk"}}, "parent_ids": ["r0"]})),
            ("data", json.dumps({"event": "on_chat_model_stream", "run_id": "m1", "name": "model", "data": {"chunk": {"content": [{"type": "text", "text": "there"}], "type": "AIMessageChunk"}}, "parent_ids": ["r0"]})),
            ("data", json.dumps({"event": "on_chat_model_end", "run_id": "m1", "name": "model", "data": {}, "parent_ids": ["r0"]})),
            ("data", json.dumps({"event": "on_chain_end", "run_id": "r0", "name": "chain", "data": {"output": "Hi there"}, "parent_ids": []})),
            ("end", ""),
        ]
        return httpx.Response(200, headers={"content-type": "text/event-stream"}, text=sse(*events))

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    run_agent(bridge_langserve("http://langserve.local/faq", make_agent(server), http_client=client, input=lambda turn: {"question": turn.text}))
    await server.wait_connected()
    await server.user_text(CONV, "hello?")
    await server.wait_frame("run", CONV, data__status="finished")
    assert bodies == [("/faq/stream_events", {"input": {"question": "hello?"}, "kwargs": {}})]
    assert genui_text(server.frames(CONV)) == "Hi there"
    assert [t["data"]["status"] for t in server.frames(CONV, "tool_call")] == ["running", "completed"]
    assert server.frames(CONV, "text") == []
    await client.aclose()


async def test_bridge_langserve_error_reports_a_failed_turn(server, run_agent):
    def handler(request):
        return httpx.Response(500, text="kaputt")

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    run_agent(bridge_langserve("http://langserve.local", make_agent(server), http_client=client))
    await server.wait_connected()
    await server.user_text(CONV, "hello?")
    await server.wait_frame("run", CONV, data__status="error")
    assert server.frames(CONV, "error")[0]["data"]["code"] == "agent_error"
    await client.aclose()
