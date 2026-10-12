"""Request building and response parsing shared by the sync and async clients."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import quote

from .errors import ConvergerError
from .models import (
    Activity,
    ActivityPage,
    ClientActivityPage,
    Conversation,
    ConversationStatus,
    ConversationToken,
    Page,
    ResourceResponse,
    TokenResponse,
)


@dataclass
class Request:
    method: str
    path: str
    parse: Callable[[Any], Any]
    params: dict[str, str] = field(default_factory=dict)
    headers: dict[str, str] = field(default_factory=dict)
    json: Any = None


def _seg(value: str) -> str:
    return quote(str(value), safe="")


def _compact(**kwargs: Any) -> dict[str, Any]:
    return {k: v for k, v in kwargs.items() if v is not None}


def _params(**kwargs: Any) -> dict[str, str]:
    return {k: str(v) for k, v in kwargs.items() if v is not None}


def _bearer(token: str | None, what: str) -> dict[str, str]:
    if not token:
        raise ConvergerError(f"{what} is required")
    return {"authorization": f"Bearer {token}"}


def _idem(key: str | None) -> dict[str, str]:
    return {"x-idempotency-key": key} if key else {}


def _data(model: Any) -> Callable[[Any], Any]:
    return lambda body: model.model_validate(body["data"])


# --- Client API ---------------------------------------------------------------


def generate_token(secret: str | None, user_id: str | None, scope: str | None) -> Request:
    body: dict[str, Any] = {}
    if user_id is not None:
        body["user"] = {"id": user_id}
    if scope is not None:
        body["scope"] = scope
    return Request(
        "POST",
        "/api/v1/converger/tokens/generate",
        TokenResponse.model_validate,
        headers=_bearer(secret, "channel_secret"),
        json=body,
    )


def refresh_token(token: str) -> Request:
    return Request("POST", "/api/v1/converger/tokens/refresh", TokenResponse.model_validate, headers=_bearer(token, "token"))


def create_conversation(token: str) -> Request:
    return Request("POST", "/api/v1/converger/conversations", ConversationToken.model_validate, headers=_bearer(token, "token"))


def get_conversation(token: str, conversation_id: str, watermark: str | None) -> Request:
    return Request(
        "GET",
        f"/api/v1/converger/conversations/{_seg(conversation_id)}",
        ConversationToken.model_validate,
        params=_params(watermark=watermark),
        headers=_bearer(token, "token"),
    )


def client_transition(token: str, conversation_id: str, action: str) -> Request:
    return Request(
        "POST",
        f"/api/v1/converger/conversations/{_seg(conversation_id)}/{action}",
        ConversationStatus.model_validate,
        headers=_bearer(token, "token"),
    )


def client_post_activity(
    token: str,
    conversation_id: str,
    *,
    type: str | None,
    text: str | None,
    from_id: str | None,
    attachments: list[dict[str, Any]] | None,
    reply_to_id: str | None,
    channel_data: dict[str, Any] | None,
    idempotency_key: str | None,
) -> Request:
    body = _compact(
        type=type,
        text=text,
        attachments=attachments,
        replyToId=reply_to_id,
        channelData=channel_data,
    )
    if from_id is not None:
        body["from"] = {"id": from_id}
    return Request(
        "POST",
        f"/api/v1/converger/conversations/{_seg(conversation_id)}/activities",
        ResourceResponse.model_validate,
        headers={**_bearer(token, "token"), **_idem(idempotency_key)},
        json=body,
    )


def client_list_activities(token: str, conversation_id: str, watermark: str | int | None, limit: int | None) -> Request:
    return Request(
        "GET",
        f"/api/v1/converger/conversations/{_seg(conversation_id)}/activities",
        ClientActivityPage.model_validate,
        params=_params(watermark=watermark, limit=limit),
        headers=_bearer(token, "token"),
    )


# --- Tenant API -----------------------------------------------------------------


def _key(api_key: str | None) -> dict[str, str]:
    if not api_key:
        raise ConvergerError("api_key is required for the tenant API")
    return {"x-api-key": api_key}


def _conversation_page(body: Any) -> Page[Conversation]:
    meta = body.get("meta") or {}
    return Page[Conversation].model_validate({"data": body["data"], **meta})


def _activity_page(body: Any) -> ActivityPage:
    meta = body.get("meta") or {}
    return ActivityPage.model_validate({"data": body["data"], **meta})


def list_conversations(
    api_key: str | None,
    *,
    limit: int | None,
    cursor: str | None,
    status: str | None,
    channel_id: str | None,
    external_id: str | None,
) -> Request:
    return Request(
        "GET",
        "/api/v1/conversations",
        _conversation_page,
        params=_params(limit=limit, cursor=cursor, status=status, channel_id=channel_id, external_id=external_id),
        headers=_key(api_key),
    )


def tenant_get_conversation(api_key: str | None, conversation_id: str) -> Request:
    return Request("GET", f"/api/v1/conversations/{_seg(conversation_id)}", _data(Conversation), headers=_key(api_key))


def tenant_transition(api_key: str | None, conversation_id: str, action: str) -> Request:
    return Request(
        "POST", f"/api/v1/conversations/{_seg(conversation_id)}/{action}", _data(Conversation), headers=_key(api_key)
    )


def tenant_post_activity(
    api_key: str | None,
    conversation_id: str,
    *,
    type: str | None,
    text: str | None,
    sender: str | None,
    attachments: list[dict[str, Any]] | None,
    metadata: dict[str, Any] | None,
    reply_to_id: str | None,
    idempotency_key: str | None,
) -> Request:
    return Request(
        "POST",
        f"/api/v1/conversations/{_seg(conversation_id)}/activities",
        _data(Activity),
        headers={**_key(api_key), **_idem(idempotency_key)},
        json=_compact(
            type=type,
            sender=sender,
            text=text,
            attachments=attachments,
            metadata=metadata,
            reply_to_id=reply_to_id,
        ),
    )


def tenant_list_activities(
    api_key: str | None, conversation_id: str, watermark: str | int | None, limit: int | None
) -> Request:
    return Request(
        "GET",
        f"/api/v1/conversations/{_seg(conversation_id)}/activities",
        _activity_page,
        params=_params(watermark=watermark, limit=limit),
        headers=_key(api_key),
    )
