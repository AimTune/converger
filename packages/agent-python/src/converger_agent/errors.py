"""Exceptions raised by converger-agent."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any


class ConvergerError(Exception):
    """A structured error: an ``error`` frame from the server (docs/protocol/v1.md, section 12) or an SDK failure.

    ``code`` is the stable string key (``rate_limited``, ``conversation_not_found``, ...),
    ``retryable`` says whether the same frame may be sent again later (after ``retry_after_ms``).
    """

    def __init__(
        self,
        message: str,
        *,
        code: str = "error",
        retryable: bool = False,
        retry_after_ms: int | None = None,
        number: int | None = None,
        details: Mapping[str, Any] | None = None,
        conversation_id: str | None = None,
        client_id: str | None = None,
        frame_type: str | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.retryable = retryable
        self.retry_after_ms = retry_after_ms
        self.number = number
        self.details = dict(details or {})
        self.conversation_id = conversation_id
        self.client_id = client_id
        self.frame_type = frame_type

    @classmethod
    def from_frame(cls, data: Mapping[str, Any] | None, conversation_id: str | None = None) -> ConvergerError:
        """Build from the ``data`` of an ``error`` frame."""
        data = data or {}
        retry = data.get("retryAfterMs")
        number = data.get("number")
        details = data.get("details")
        return cls(
            str(data.get("message") or data.get("code") or "error"),
            code=str(data.get("code") or "error"),
            retryable=bool(data.get("retryable", False)),
            retry_after_ms=retry if isinstance(retry, int) else None,
            number=number if isinstance(number, int) else None,
            details=details if isinstance(details, Mapping) else None,
            conversation_id=conversation_id,
            client_id=data.get("clientId") if isinstance(data.get("clientId"), str) else None,
            frame_type=data.get("frameType") if isinstance(data.get("frameType"), str) else None,
        )

    def __repr__(self) -> str:
        return f"{type(self).__name__}(code={self.code!r}, message={self.message!r}, retryable={self.retryable})"


class ConnectionClosed(ConvergerError):
    """The agent socket closed for good (a terminal close code, or :meth:`Agent.stop`)."""

    def __init__(self, close_code: int | None, reason: str = "") -> None:
        terminal = {4400: "unsupported_protocol", 4401: "unauthorized", 4403: "forbidden"}
        super().__init__(
            f"connection closed ({close_code}){': ' + reason if reason else ''}",
            code=terminal.get(close_code or 0, "connection_closed"),
        )
        self.close_code = close_code
        self.reason = reason
