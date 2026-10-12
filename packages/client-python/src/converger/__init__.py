"""Server-side Python SDK for Converger.

* :class:`Converger` / :class:`AsyncConverger`: REST clients for the client API
  (``client_api``) and the tenant API (``tenant_api``).
* :class:`ConvergerSocket`: Protocol v1 WebSocket client with resume.
* :func:`verify_signature`: outbound webhook signature verification.
"""

from ._version import __version__
from .client import AsyncConverger, Converger
from .errors import ApiError, ConnectionClosed, ConvergerError, ProtocolError, WebhookSignatureError
from .models import (
    Ack,
    Activity,
    ActivityPage,
    ChannelAccount,
    ClientActivity,
    ClientActivityPage,
    Conversation,
    ConversationStatus,
    ConversationToken,
    Page,
    Participant,
    ResourceResponse,
    TokenResponse,
    WebhookEvent,
)
from .protocol import ConvergerSocket, Session
from .webhooks import SIGNATURE_HEADER, is_valid_signature, sign, verify_signature

__all__ = [
    "Ack",
    "Activity",
    "ActivityPage",
    "ApiError",
    "AsyncConverger",
    "ChannelAccount",
    "ClientActivity",
    "ClientActivityPage",
    "ConnectionClosed",
    "Conversation",
    "ConversationStatus",
    "ConversationToken",
    "Converger",
    "ConvergerError",
    "ConvergerSocket",
    "Page",
    "Participant",
    "ProtocolError",
    "ResourceResponse",
    "SIGNATURE_HEADER",
    "Session",
    "TokenResponse",
    "WebhookEvent",
    "WebhookSignatureError",
    "__version__",
    "is_valid_signature",
    "sign",
    "verify_signature",
]
