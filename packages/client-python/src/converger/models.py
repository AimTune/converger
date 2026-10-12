"""Response models.

Hand-written to match the server today (docs/api/client-api.md and
docs/api/tenant-api.md). Once the OpenAPI document of #45 ships at
``priv/static/openapi.json``, ``scripts/generate_models.sh`` generates
equivalent models into ``converger/_generated.py``; the names below stay the
public API and become aliases of the generated classes.

Every model keeps unknown fields (``extra="allow"``), so fields the server
adds later are not lost.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any, Generic, TypeVar

from pydantic import BaseModel, ConfigDict, Field

T = TypeVar("T")


class _Model(BaseModel):
    model_config = ConfigDict(extra="allow", populate_by_name=True)


# --- Client API (/api/v1/converger, camelCase on the wire) -------------------


class TokenResponse(_Model):
    """``POST /tokens/generate`` and ``/tokens/refresh``."""

    conversation_id: str | None = Field(default=None, alias="conversationId")
    token: str
    expires_in: int


class ConversationToken(_Model):
    """``POST /conversations`` and ``GET /conversations/:id``: a conversation-bound token."""

    conversation_id: str = Field(alias="conversationId")
    token: str
    expires_in: int
    stream_url: str | None = Field(default=None, alias="streamUrl")


class ConversationStatus(_Model):
    """``POST /conversations/:id/close`` and ``/reopen`` on the client API."""

    conversation_id: str = Field(alias="conversationId")
    status: str


class ResourceResponse(_Model):
    """``POST /conversations/:id/activities`` on the client API."""

    id: str


class ChannelAccount(_Model):
    id: str
    name: str | None = None


class ClientActivity(_Model):
    """An activity as the client API renders it."""

    id: str
    type: str
    from_: ChannelAccount | None = Field(default=None, alias="from")
    text: str | None = None
    timestamp: datetime | None = None
    attachments: list[dict[str, Any]] = Field(default_factory=list)
    conversation_id: str | None = Field(default=None, alias="conversationId")
    channel_data: dict[str, Any] = Field(default_factory=dict, alias="channelData")
    reply_to_id: str | None = Field(default=None, alias="replyToId")
    edited_at: datetime | None = Field(default=None, alias="editedAt")
    deleted_at: datetime | None = Field(default=None, alias="deletedAt")


class ClientActivityPage(_Model):
    activities: list[ClientActivity]
    watermark: str | None = None
    has_more: bool = False


# --- Tenant API (/api/v1, snake_case on the wire) ------------------------------


class Participant(_Model):
    id: str
    external_id: str | None = None
    display_name: str | None = None
    opted_out_at: datetime | None = None


class Conversation(_Model):
    id: str
    status: str
    metadata: dict[str, Any] = Field(default_factory=dict)
    channel_id: str | None = None
    origin_channel_id: str | None = None
    tenant_id: str | None = None
    participant_id: str | None = None
    participant: Participant | None = None
    channels: list[dict[str, Any]] | None = None
    inserted_at: datetime | None = None
    updated_at: datetime | None = None


class Activity(_Model):
    """The canonical activity (tenant API, webhooks, delivery payloads)."""

    id: str
    type: str
    sender: str | None = None
    text: str | None = None
    attachments: list[dict[str, Any]] = Field(default_factory=list)
    metadata: dict[str, Any] = Field(default_factory=dict)
    idempotency_key: str | None = None
    seq: int | None = None
    reply_to_id: str | None = None
    edited_at: datetime | None = None
    deleted_at: datetime | None = None
    conversation_id: str | None = None
    tenant_id: str | None = None
    inserted_at: datetime | None = None


class WebhookEvent(Activity):
    """The body of an outbound webhook: the canonical activity plus ``timestamp``."""

    timestamp: datetime | None = None


class Page(_Model, Generic[T]):
    """A keyset page (``meta.next_cursor``)."""

    data: list[T]
    next_cursor: str | None = None
    has_more: bool = False
    limit: int | None = None


class ActivityPage(_Model):
    """A watermark page of the tenant API (``meta.watermark``)."""

    data: list[Activity]
    watermark: str | None = None
    has_more: bool = False
    limit: int | None = None


# --- Protocol v1 -----------------------------------------------------------------


class Ack(_Model):
    """The server's ``ack`` for a send with a ``clientId``."""

    client_id: str = Field(alias="clientId")
    id: str
    seq: int
    timestamp: int | None = None
    duplicate: bool = False
