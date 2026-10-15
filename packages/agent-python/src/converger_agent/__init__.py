"""converger-agent: serve every conversation of a Converger channel from Python.

One channel-scoped Protocol v1 socket carries the turns of every conversation
routed to the agent's channel (WhatsApp, Telegram, the web widget, ...); the
agent answers with text, rich messages, token streams, tool traces, GenUI and
interrupts. See https://converger.aimtune.dev/sdk/agent-python.
"""

from ._version import __version__
from .agent import Agent, channel_token_source, http_base, ws_url
from .errors import ConnectionClosed, ConvergerError
from .turn import DEFAULT_ACTIONS, Message, Reply, Stream, Turn

__all__ = [
    "DEFAULT_ACTIONS",
    "Agent",
    "ConnectionClosed",
    "ConvergerError",
    "Message",
    "Reply",
    "Stream",
    "Turn",
    "__version__",
    "channel_token_source",
    "http_base",
    "ws_url",
]
