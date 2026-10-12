"""REST clients: :class:`Converger` (sync) and :class:`AsyncConverger` (async)."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any, Union

import httpx

from . import _requests as r
from ._version import __version__
from .errors import ApiError
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

USER_AGENT = f"converger-python/{__version__}"

TokenProvider = Callable[[], Union[str, Awaitable[str]]]


def _client_kwargs(base_url: str, timeout: float, headers: dict[str, str] | None) -> dict[str, Any]:
    return {
        "base_url": base_url.rstrip("/"),
        "timeout": timeout,
        "headers": {"user-agent": USER_AGENT, "accept": "application/json", **(headers or {})},
    }


def _check(response: httpx.Response) -> Any:
    if response.status_code >= 400:
        raise ApiError.from_response(response.status_code, dict(response.headers), response.content)
    return response.json() if response.content else None


def _build(client: httpx.Client | httpx.AsyncClient, req: r.Request) -> httpx.Request:
    return client.build_request(
        req.method, req.path, params=req.params or None, headers=req.headers, json=req.json
    )


class Converger:
    """Synchronous Converger client.

    ``api_key`` (tenant API key) is needed for :attr:`tenant_api`;
    ``channel_secret`` for :meth:`ClientAPI.generate_token`. Both are
    server-side credentials: never ship them to a browser or app.
    """

    def __init__(
        self,
        base_url: str,
        *,
        api_key: str | None = None,
        channel_secret: str | None = None,
        timeout: float = 10.0,
        headers: dict[str, str] | None = None,
        transport: httpx.BaseTransport | None = None,
        http_client: httpx.Client | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.channel_secret = channel_secret
        self._http = http_client or httpx.Client(transport=transport, **_client_kwargs(base_url, timeout, headers))
        self.client_api = ClientAPI(self)
        self.tenant_api = TenantAPI(self)

    def _send(self, req: r.Request) -> Any:
        return req.parse(_check(self._http.send(_build(self._http, req))))

    def close(self) -> None:
        self._http.close()

    def __enter__(self) -> Converger:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()


class AsyncConverger:
    """Asynchronous Converger client (``httpx.AsyncClient``), plus the WebSocket client."""

    def __init__(
        self,
        base_url: str,
        *,
        api_key: str | None = None,
        channel_secret: str | None = None,
        timeout: float = 10.0,
        headers: dict[str, str] | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
        http_client: httpx.AsyncClient | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.channel_secret = channel_secret
        self._http = http_client or httpx.AsyncClient(
            transport=transport, **_client_kwargs(base_url, timeout, headers)
        )
        self.client_api = AsyncClientAPI(self)
        self.tenant_api = AsyncTenantAPI(self)

    async def _send(self, req: r.Request) -> Any:
        return req.parse(_check(await self._http.send(_build(self._http, req))))

    def socket(
        self,
        token: str | TokenProvider,
        *,
        conversation_id: str | None = None,
        watermark: int = 0,
        **kwargs: Any,
    ) -> Any:
        """A Protocol v1 socket to this server (see :class:`converger.protocol.ConvergerSocket`).

        Use it as ``async with client.socket(token) as sock: ...``.
        """
        from .protocol.socket import ConvergerSocket, ws_url

        return ConvergerSocket(
            ws_url(self.base_url), token, conversation_id=conversation_id, watermark=watermark, **kwargs
        )

    async def aclose(self) -> None:
        await self._http.aclose()

    async def __aenter__(self) -> AsyncConverger:
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.aclose()


class ClientAPI:
    """The client API under ``/api/v1/converger`` (converger tokens)."""

    def __init__(self, root: Converger) -> None:
        self._root = root

    def generate_token(self, *, user_id: str | None = None, scope: str | None = None) -> TokenResponse:
        """Exchange the channel secret for a converger token (``scope="channel"`` for agent sockets)."""
        return self._root._send(r.generate_token(self._root.channel_secret, user_id, scope))

    def refresh_token(self, token: str) -> TokenResponse:
        return self._root._send(r.refresh_token(token))

    def create_conversation(self, token: str) -> ConversationToken:
        """Start a conversation; the returned token is bound to it."""
        return self._root._send(r.create_conversation(token))

    def get_conversation(self, token: str, conversation_id: str, *, watermark: str | None = None) -> ConversationToken:
        return self._root._send(r.get_conversation(token, conversation_id, watermark))

    def close_conversation(self, token: str, conversation_id: str) -> ConversationStatus:
        return self._root._send(r.client_transition(token, conversation_id, "close"))

    def reopen_conversation(self, token: str, conversation_id: str) -> ConversationStatus:
        return self._root._send(r.client_transition(token, conversation_id, "reopen"))

    def post_activity(
        self,
        token: str,
        conversation_id: str,
        *,
        text: str | None = None,
        type: str | None = None,
        from_id: str | None = None,
        attachments: list[dict[str, Any]] | None = None,
        reply_to_id: str | None = None,
        channel_data: dict[str, Any] | None = None,
        idempotency_key: str | None = None,
    ) -> ResourceResponse:
        return self._root._send(
            r.client_post_activity(
                token,
                conversation_id,
                type=type,
                text=text,
                from_id=from_id,
                attachments=attachments,
                reply_to_id=reply_to_id,
                channel_data=channel_data,
                idempotency_key=idempotency_key,
            )
        )

    def list_activities(
        self, token: str, conversation_id: str, *, watermark: str | int | None = None, limit: int | None = None
    ) -> ClientActivityPage:
        return self._root._send(r.client_list_activities(token, conversation_id, watermark, limit))


class TenantAPI:
    """The tenant API under ``/api/v1`` (``x-api-key``)."""

    def __init__(self, root: Converger) -> None:
        self._root = root

    def list_conversations(
        self,
        *,
        limit: int | None = None,
        cursor: str | None = None,
        status: str | None = None,
        channel_id: str | None = None,
        external_id: str | None = None,
    ) -> Page[Conversation]:
        return self._root._send(
            r.list_conversations(
                self._root.api_key,
                limit=limit,
                cursor=cursor,
                status=status,
                channel_id=channel_id,
                external_id=external_id,
            )
        )

    def get_conversation(self, conversation_id: str) -> Conversation:
        return self._root._send(r.tenant_get_conversation(self._root.api_key, conversation_id))

    def close_conversation(self, conversation_id: str) -> Conversation:
        return self._root._send(r.tenant_transition(self._root.api_key, conversation_id, "close"))

    def reopen_conversation(self, conversation_id: str) -> Conversation:
        return self._root._send(r.tenant_transition(self._root.api_key, conversation_id, "reopen"))

    def post_activity(
        self,
        conversation_id: str,
        *,
        text: str | None = None,
        type: str | None = None,
        sender: str | None = None,
        attachments: list[dict[str, Any]] | None = None,
        metadata: dict[str, Any] | None = None,
        reply_to_id: str | None = None,
        idempotency_key: str | None = None,
    ) -> Activity:
        return self._root._send(
            r.tenant_post_activity(
                self._root.api_key,
                conversation_id,
                type=type,
                text=text,
                sender=sender,
                attachments=attachments,
                metadata=metadata,
                reply_to_id=reply_to_id,
                idempotency_key=idempotency_key,
            )
        )

    def list_activities(
        self, conversation_id: str, *, watermark: str | int | None = None, limit: int | None = None
    ) -> ActivityPage:
        return self._root._send(r.tenant_list_activities(self._root.api_key, conversation_id, watermark, limit))


class AsyncClientAPI:
    """Async variant of :class:`ClientAPI`."""

    def __init__(self, root: AsyncConverger) -> None:
        self._root = root

    async def generate_token(self, *, user_id: str | None = None, scope: str | None = None) -> TokenResponse:
        return await self._root._send(r.generate_token(self._root.channel_secret, user_id, scope))

    async def refresh_token(self, token: str) -> TokenResponse:
        return await self._root._send(r.refresh_token(token))

    async def create_conversation(self, token: str) -> ConversationToken:
        return await self._root._send(r.create_conversation(token))

    async def get_conversation(
        self, token: str, conversation_id: str, *, watermark: str | None = None
    ) -> ConversationToken:
        return await self._root._send(r.get_conversation(token, conversation_id, watermark))

    async def close_conversation(self, token: str, conversation_id: str) -> ConversationStatus:
        return await self._root._send(r.client_transition(token, conversation_id, "close"))

    async def reopen_conversation(self, token: str, conversation_id: str) -> ConversationStatus:
        return await self._root._send(r.client_transition(token, conversation_id, "reopen"))

    async def post_activity(
        self,
        token: str,
        conversation_id: str,
        *,
        text: str | None = None,
        type: str | None = None,
        from_id: str | None = None,
        attachments: list[dict[str, Any]] | None = None,
        reply_to_id: str | None = None,
        channel_data: dict[str, Any] | None = None,
        idempotency_key: str | None = None,
    ) -> ResourceResponse:
        return await self._root._send(
            r.client_post_activity(
                token,
                conversation_id,
                type=type,
                text=text,
                from_id=from_id,
                attachments=attachments,
                reply_to_id=reply_to_id,
                channel_data=channel_data,
                idempotency_key=idempotency_key,
            )
        )

    async def list_activities(
        self, token: str, conversation_id: str, *, watermark: str | int | None = None, limit: int | None = None
    ) -> ClientActivityPage:
        return await self._root._send(r.client_list_activities(token, conversation_id, watermark, limit))


class AsyncTenantAPI:
    """Async variant of :class:`TenantAPI`."""

    def __init__(self, root: AsyncConverger) -> None:
        self._root = root

    async def list_conversations(
        self,
        *,
        limit: int | None = None,
        cursor: str | None = None,
        status: str | None = None,
        channel_id: str | None = None,
        external_id: str | None = None,
    ) -> Page[Conversation]:
        return await self._root._send(
            r.list_conversations(
                self._root.api_key,
                limit=limit,
                cursor=cursor,
                status=status,
                channel_id=channel_id,
                external_id=external_id,
            )
        )

    async def get_conversation(self, conversation_id: str) -> Conversation:
        return await self._root._send(r.tenant_get_conversation(self._root.api_key, conversation_id))

    async def close_conversation(self, conversation_id: str) -> Conversation:
        return await self._root._send(r.tenant_transition(self._root.api_key, conversation_id, "close"))

    async def reopen_conversation(self, conversation_id: str) -> Conversation:
        return await self._root._send(r.tenant_transition(self._root.api_key, conversation_id, "reopen"))

    async def post_activity(
        self,
        conversation_id: str,
        *,
        text: str | None = None,
        type: str | None = None,
        sender: str | None = None,
        attachments: list[dict[str, Any]] | None = None,
        metadata: dict[str, Any] | None = None,
        reply_to_id: str | None = None,
        idempotency_key: str | None = None,
    ) -> Activity:
        return await self._root._send(
            r.tenant_post_activity(
                self._root.api_key,
                conversation_id,
                type=type,
                text=text,
                sender=sender,
                attachments=attachments,
                metadata=metadata,
                reply_to_id=reply_to_id,
                idempotency_key=idempotency_key,
            )
        )

    async def list_activities(
        self, conversation_id: str, *, watermark: str | int | None = None, limit: int | None = None
    ) -> ActivityPage:
        return await self._root._send(
            r.tenant_list_activities(self._root.api_key, conversation_id, watermark, limit)
        )
