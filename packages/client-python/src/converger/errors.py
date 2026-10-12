"""Exceptions raised by the Converger SDK."""

from __future__ import annotations

import json
from collections.abc import Mapping
from typing import Any

# Default error codes by HTTP status, used when the body does not carry one
# (packages/conformance/errors.json).
STATUS_CODES: dict[int, str] = {
    400: "bad_request",
    401: "unauthorized",
    403: "forbidden",
    404: "not_found",
    406: "not_acceptable",
    409: "conflict",
    413: "payload_too_large",
    415: "unsupported_media_type",
    422: "validation_failed",
    429: "rate_limited",
    500: "internal",
    502: "bad_gateway",
    503: "unavailable",
}


class ConvergerError(Exception):
    """Base class of every error raised by this package."""


class ApiError(ConvergerError):
    """A non-2xx HTTP response.

    The fields are the same whatever error shape the server used: the
    standard envelope ``{"error": {"code", "message", "details",
    "request_id"}}`` (#45) or one of the legacy shapes.
    """

    def __init__(
        self,
        status: int,
        code: str,
        message: str,
        details: Any = None,
        request_id: str | None = None,
        retry_after: int | None = None,
        body: Any = None,
    ) -> None:
        super().__init__(f"{status} {code}: {message}" if message else f"{status} {code}")
        self.status = status
        self.code = code
        self.message = message
        self.details = details
        self.request_id = request_id
        self.retry_after = retry_after
        self.body = body

    @classmethod
    def from_response(cls, status: int, headers: Mapping[str, str], raw: bytes | str) -> ApiError:
        text = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else raw
        lower = {k.lower(): v for k, v in headers.items()}
        try:
            body: Any = json.loads(text) if text.strip() else None
            is_json = True
        except ValueError:
            body, is_json = None, False

        code: str | None = None
        message = ""
        details: Any = None
        request_id: str | None = None
        err = body.get("error") if isinstance(body, dict) else None
        errors = body.get("errors") if isinstance(body, dict) else None

        if isinstance(err, dict):
            if isinstance(err.get("code"), str):
                code = err["code"]
            message = err.get("message") if isinstance(err.get("message"), str) else ""
            details = err.get("details")
            if isinstance(err.get("request_id"), str):
                request_id = err["request_id"]
        elif isinstance(err, str) and isinstance(body.get("detail"), str):
            code, message = err, body["detail"]
        elif isinstance(err, str):
            message = err
        elif isinstance(errors, dict) and isinstance(errors.get("detail"), str):
            message = errors["detail"]
        elif isinstance(errors, dict):
            message, details = "validation failed", errors
        elif not is_json:
            message = text.strip()[:200]

        if code is None:
            code = STATUS_CODES.get(status, f"http_{status}")
        if request_id is None:
            request_id = lower.get("x-request-id")
        retry_after: int | None = None
        ra = lower.get("retry-after")
        if ra is not None and ra.strip().isdigit():
            retry_after = int(ra.strip())

        return cls(status, code, message, details, request_id, retry_after, body if is_json else text)


class WebhookSignatureError(ConvergerError):
    """A webhook signature did not verify.

    ``reason`` is one of ``missing_signature``, ``no_secret``,
    ``malformed_signature``, ``timestamp_out_of_tolerance`` or
    ``invalid_signature``.
    """

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


class ProtocolError(ConvergerError):
    """An ``error`` frame from the Protocol v1 socket, or a refused send."""

    def __init__(self, data: Mapping[str, Any]) -> None:
        self.data = dict(data)
        self.code: str = str(self.data.get("code", "unknown"))
        self.retryable: bool = bool(self.data.get("retryable", False))
        self.retry_after_ms: int | None = self.data.get("retryAfterMs")
        super().__init__(f"{self.code}: {self.data.get('message', '')}".rstrip(": "))


class ConnectionClosed(ConvergerError):
    """The socket closed for good (no further reconnect)."""

    def __init__(self, code: int | None, reason: str = "") -> None:
        super().__init__(f"connection closed ({code}) {reason}".strip())
        self.code = code
        self.reason = reason
