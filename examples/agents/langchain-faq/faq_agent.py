"""An FAQ agent for Converger: LangGraph + Claude, served with converger_agent.langchain.

One process answers every conversation routed to its `websocket` bot channel,
whatever channel the end user writes from (a WhatsApp number, the web widget,
...). See README.md.

    export CONVERGER_URL=http://localhost:4000
    export CONVERGER_CHANNEL_SECRET=...     # the bot channel's secret
    export ANTHROPIC_API_KEY=...
    python faq_agent.py

FAQ_AGENT_FAKE_MODEL=1 swaps Claude for a canned fake model (no API key needed).
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
from typing import Any

from langchain_core.language_models import BaseChatModel
from langchain_core.messages import AIMessage, SystemMessage
from langchain_core.runnables import RunnableConfig
from langchain_core.tools import tool
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph import END, START, MessagesState, StateGraph
from langgraph.types import interrupt

from converger_agent import Agent
from converger_agent.langchain import serve

FAQ: dict[str, str] = {
    "shipping": "Orders ship within 1 business day. Delivery takes 2-4 business days in Turkiye and 5-10 days abroad.",
    "returns": "You can return an item within 30 days. Start a return from Orders > Return item; the courier pickup is free.",
    "refund": "Refunds go back to the original payment method within 5 business days after the return arrives.",
    "payment": "We accept cards, bank transfer and pay-at-door (cash or card, +15 TRY).",
    "hours": "Support answers every day between 09:00 and 22:00 (UTC+3).",
}

KEYWORDS: dict[str, tuple[str, ...]] = {
    "shipping": ("ship", "delivery", "deliver", "kargo", "where is my order", "track"),
    "returns": ("return", "iade", "send back"),
    "refund": ("refund", "money back"),
    "payment": ("pay", "card", "cash", "installment"),
    "hours": ("hour", "open", "when can"),
}

# Turns that pause the graph for an explicit choice (LangGraph interrupt).
ESCALATE = re.compile(r"\b(human|agent|person|operator|refund me|i want a refund|temsilci)\b", re.IGNORECASE)

SYSTEM = (
    "You are the customer support assistant of an online shop. Answer in the user's language, "
    "in at most three short sentences, using only the FAQ entries below. If they do not cover "
    "the question, say so and offer to connect the user with a human.\n\nFAQ:\n{faq}"
)


@tool
def search_faq(question: str) -> list[dict[str, str]]:
    """Find the FAQ entries relevant to a customer question."""
    text = question.lower()
    hits = [{"topic": topic, "answer": FAQ[topic]} for topic, words in KEYWORDS.items() if any(w in text for w in words)]
    return hits or [{"topic": topic, "answer": answer} for topic, answer in FAQ.items()]


def make_model() -> BaseChatModel:
    """Claude by default; FAQ_AGENT_FAKE_MODEL=1 for a canned model (tests, demos without a key)."""
    if os.environ.get("FAQ_AGENT_FAKE_MODEL"):
        return fake_model(delay=float(os.environ.get("FAQ_AGENT_FAKE_DELAY", "0.05")))
    from langchain_anthropic import ChatAnthropic

    return ChatAnthropic(model=os.environ.get("FAQ_AGENT_MODEL", "claude-sonnet-5-5"), max_tokens=512, streaming=True)


def fake_model(replies: list[str] | None = None, delay: float = 0.0) -> BaseChatModel:
    """Canned replies, streamed word by word with `delay` seconds between tokens (like a real model)."""
    from itertools import cycle

    from langchain_core.language_models.fake_chat_models import GenericFakeChatModel

    class PacedFakeChatModel(GenericFakeChatModel):
        delay: float = 0.0

        async def _astream(self, *args: Any, **kwargs: Any):  # type: ignore[override]
            async for chunk in super()._astream(*args, **kwargs):
                yield chunk
                if self.delay:
                    await asyncio.sleep(self.delay)

    canned = replies or ["Orders ship within 1 business day and arrive in 2-4 business days."]
    return PacedFakeChatModel(messages=cycle(AIMessage(content=r) for r in canned), delay=delay)


def build_graph(model: BaseChatModel, checkpointer: Any = None):
    """route -> answer (search_faq tool + streamed model answer) | escalate (interrupt)."""

    def route(state: MessagesState) -> str:
        last = state["messages"][-1]
        return "escalate" if ESCALATE.search(str(last.content)) else "answer"

    # Nodes take `config` and pass it on: before Python 3.11 asyncio does not
    # propagate it to the tool and model calls (needed for streaming events).
    async def answer(state: MessagesState, config: RunnableConfig) -> dict[str, Any]:
        question = str(state["messages"][-1].content)
        entries = await search_faq.ainvoke({"question": question}, config)
        faq = "\n".join(f"- {e['topic']}: {e['answer']}" for e in entries)
        reply = await model.ainvoke([SystemMessage(SYSTEM.format(faq=faq)), *state["messages"]], config)
        return {"messages": [reply]}

    def escalate(state: MessagesState) -> dict[str, Any]:
        choice = interrupt(
            {
                "title": "Shall I connect you with a human agent?",
                "text": "A support agent can take over this conversation.",
                "actions": [
                    {"label": "Yes, connect me", "value": "yes"},
                    {"label": "No, thanks", "value": "no"},
                ],
            }
        )
        if str(choice).strip().lower() in ("yes", "y", "evet", "yes, connect me", "1"):
            text = "Done: a human agent will join this conversation shortly."
        else:
            text = "No problem. Ask me anything about shipping, returns, refunds or payment."
        return {"messages": [AIMessage(content=text)]}

    graph = StateGraph(MessagesState)
    graph.add_node("answer", answer)
    graph.add_node("escalate", escalate)
    graph.add_conditional_edges(START, route, {"answer": "answer", "escalate": "escalate"})
    graph.add_edge("answer", END)
    graph.add_edge("escalate", END)
    # Interrupts need a checkpointer; use a persistent one (Postgres, SQLite)
    # so a paused conversation survives a restart.
    return graph.compile(checkpointer=checkpointer or InMemorySaver())


def make_agent(graph: Any, **agent_kwargs: Any) -> Agent:
    """The graph served on the channel; the thread id is the Converger conversation id."""
    return serve(graph, **agent_kwargs)


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    url = os.environ.get("CONVERGER_URL", "http://localhost:4000")
    credentials: dict[str, Any] = (
        {"token": os.environ["CONVERGER_TOKEN"]} if os.environ.get("CONVERGER_TOKEN") else {"channel_secret": os.environ["CONVERGER_CHANNEL_SECRET"]}
    )
    agent = make_agent(
        build_graph(make_model()),
        url=url,
        group=os.environ.get("CONVERGER_AGENT_GROUP", "faq"),
        text_fallback=os.environ.get("CONVERGER_TEXT_FALLBACK", "") not in ("", "0", "false"),
        **credentials,
    )
    asyncio.run(agent.run())


if __name__ == "__main__":
    main()
