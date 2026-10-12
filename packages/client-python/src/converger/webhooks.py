"""Verification of Converger outbound webhook signatures.

Every webhook request carries::

    x-converger-signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>

The rules (and the test vectors every SDK runs) are in
``packages/conformance/webhook-signatures.json``.
"""

from __future__ import annotations

import hashlib
import hmac
import re
import time
from collections.abc import Iterable, Mapping, Sequence
from typing import Union

from .errors import WebhookSignatureError

SIGNATURE_HEADER = "x-converger-signature"
DEFAULT_TOLERANCE = 300

Headers = Union[Mapping[str, str], Iterable[tuple[str, str]]]

_INT = re.compile(r"^[+-]?[0-9]+$")


def _header(headers: Headers, name: str) -> str | None:
    items = headers.items() if isinstance(headers, Mapping) else headers
    # Mapping-like objects (Starlette, Werkzeug, httpx) are case-insensitive
    # already; plain dicts are not, so compare names ourselves.
    for key, value in items:
        if key.lower() == name:
            return value
    return None


def sign(secret: str, body: bytes | str, timestamp: int | None = None) -> str:
    """Build an ``x-converger-signature`` value (useful for tests)."""
    t = int(time.time()) if timestamp is None else timestamp
    return f"t={t},v1={_hmac(secret, t, body)}"


def _hmac(secret: str, t: int, body: bytes | str) -> str:
    raw = body.encode("utf-8") if isinstance(body, str) else body
    return hmac.new(secret.encode("utf-8"), f"{t}.".encode() + raw, hashlib.sha256).hexdigest()


def verify_signature(
    headers: Headers,
    body: bytes | str,
    secret: str | Sequence[str],
    *,
    tolerance: int = DEFAULT_TOLERANCE,
    now: float | None = None,
) -> None:
    """Verify a webhook request; raise :class:`WebhookSignatureError` if it is not genuine.

    ``body`` must be the raw request body exactly as received (bytes), not
    re-serialized JSON. ``secret`` is the channel secret, or a list of
    secrets while rotating. Comparison is constant-time.
    """
    value = _header(headers, SIGNATURE_HEADER)
    if not value:
        raise WebhookSignatureError("missing_signature")

    secrets = [secret] if isinstance(secret, str) else list(secret)
    secrets = [s for s in secrets if s]
    if not secrets:
        raise WebhookSignatureError("no_secret")

    timestamp: str | None = None
    v1: list[str] = []
    for part in value.split(","):
        key, sep, val = part.strip().partition("=")
        if not sep:
            continue
        if key == "t" and timestamp is None:
            timestamp = val
        elif key == "v1":
            v1.append(val)

    if timestamp is None or not _INT.match(timestamp) or not v1:
        raise WebhookSignatureError("malformed_signature")
    t = int(timestamp)

    current = time.time() if now is None else now
    if abs(int(current) - t) > tolerance:
        raise WebhookSignatureError("timestamp_out_of_tolerance")

    matched = False
    for s in secrets:
        expected = _hmac(s, t, body)
        for candidate in v1:
            # Evaluate every pair so timing does not reveal which matched.
            matched |= hmac.compare_digest(expected.encode(), candidate.encode())
    if not matched:
        raise WebhookSignatureError("invalid_signature")


def is_valid_signature(
    headers: Headers,
    body: bytes | str,
    secret: str | Sequence[str],
    *,
    tolerance: int = DEFAULT_TOLERANCE,
    now: float | None = None,
) -> bool:
    """Like :func:`verify_signature`, but return a boolean."""
    try:
        verify_signature(headers, body, secret, tolerance=tolerance, now=now)
    except WebhookSignatureError:
        return False
    return True
