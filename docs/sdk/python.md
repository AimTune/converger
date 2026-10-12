---
title: Python SDK (converger)
description: The server-side Python SDK - sync and async REST clients, the Protocol v1 WebSocket client with resume, Pydantic models and webhook signature verification with FastAPI and Flask examples.
sidebar_position: 3
---

`converger` is the server-side Python SDK: REST clients built on `httpx` (sync and async), a
[Protocol v1](../protocol/v1.md) WebSocket client with resume built on `websockets`, Pydantic v2 models and
webhook signature verification. Source:
[`packages/client-python`](https://github.com/AimTune/converger/tree/main/packages/client-python). What all SDKs
share is described in [Server-side SDKs](server-sdks.md).

```bash
pip install converger
```

Python 3.10 or later. Dependencies: `httpx`, `pydantic` 2, `websockets` 13 or later.

## Clients

```python
from converger import Converger, AsyncConverger

cvg = Converger("https://chat.example.com", api_key="cvg_live_...", channel_secret="...")
```

| Argument | Used for |
| --- | --- |
| `api_key` | `cvg.tenant_api` (`x-api-key`) |
| `channel_secret` | `cvg.client_api.generate_token()` (`Authorization: Bearer <secret>`) |
| `timeout`, `headers`, `transport`, `http_client` | passed to `httpx` |

Both are server-side credentials; never ship them to a browser or app. `AsyncConverger` has the same methods as
coroutines and adds `socket()`.

### Client API (`cvg.client_api`)

| Method | Endpoint | Returns |
| --- | --- | --- |
| `generate_token(user_id=None, scope=None)` | `POST /api/v1/converger/tokens/generate` | `TokenResponse` |
| `refresh_token(token)` | `POST /api/v1/converger/tokens/refresh` | `TokenResponse` |
| `create_conversation(token)` | `POST /api/v1/converger/conversations` | `ConversationToken` (`conversation_id`, conversation-bound `token`, `stream_url`) |
| `get_conversation(token, id, watermark=None)` | `GET /api/v1/converger/conversations/:id` | `ConversationToken` |
| `close_conversation(token, id)`, `reopen_conversation(token, id)` | `POST .../close`, `.../reopen` | `ConversationStatus` |
| `post_activity(token, id, text=, type=, from_id=, attachments=, reply_to_id=, channel_data=, idempotency_key=)` | `POST .../activities` | `ResourceResponse` (`id`) |
| `list_activities(token, id, watermark=None, limit=None)` | `GET .../activities` | `ClientActivityPage` (`activities`, `watermark`, `has_more`) |

### Tenant API (`cvg.tenant_api`)

| Method | Endpoint | Returns |
| --- | --- | --- |
| `list_conversations(limit=, cursor=, status=, channel_id=, external_id=)` | `GET /api/v1/conversations` | `Page[Conversation]` (`data`, `next_cursor`, `has_more`) |
| `get_conversation(id)`, `close_conversation(id)`, `reopen_conversation(id)` | `/api/v1/conversations/:id[...]` | `Conversation` |
| `post_activity(id, text=, type=, sender=, attachments=, metadata=, reply_to_id=, idempotency_key=)` | `POST .../activities` | `Activity` (with `seq`) |
| `list_activities(id, watermark=None, limit=None)` | `GET .../activities` | `ActivityPage` (`data`, `watermark`, `has_more`) |

Models keep unknown fields (`model_extra`), so fields the server adds later are not lost.

### Errors

Every non-2xx response raises `converger.ApiError` with `status`, `code`, `message`, `details`, `request_id`,
`retry_after` and the raw `body` ([normalization rules](server-sdks.md#errors)).

```python
from converger import ApiError

try:
    cvg.client_api.post_activity(token, conversation_id, text="late")
except ApiError as err:
    if err.code == "conversation_closed":
        ...
```

## WebSocket (Protocol v1)

```python
import asyncio
from converger import AsyncConverger

async def main():
    async with AsyncConverger("https://chat.example.com", channel_secret="...") as cvg:
        token = await cvg.client_api.generate_token(user_id="user-42")
        conv = await cvg.client_api.create_conversation(token.token)

        async with cvg.socket(conv.token, conversation_id=conv.conversation_id) as sock:
            ack = await sock.send_text("Where is my order?")   # Ack(client_id, id, seq, duplicate)
            async for frame in sock:                            # dicts, persistent frames in seq order, once
                print(frame["type"], frame.get("data"))

asyncio.run(main())
```

| `ConvergerSocket` | |
| --- | --- |
| `cvg.socket(token, conversation_id=None, watermark=0, **options)` | `token` is a string or a (sync or async) callable that returns a fresh token on every connect |
| `await sock.send_text(text, client_id=None, metadata=None, reply_to=None)` | waits for the `ack`; raises `ProtocolError` (`code`, `retryable`, `retry_after_ms`) when refused |
| `await sock.send_message(type, data, ...)` | any message type |
| `await sock.recv()` / `async for frame in sock` | the next frame for the application; raises `ConnectionClosed` (`code`, `reason`) once the socket ended for good |
| `await sock.typing(True)`, `await sock.read(watermark=None)`, `await sock.refresh(token)` | `typing`, `read` and `auth` frames |
| `sock.watermark`, `sock.conversation_id`, `sock.welcome` | resume position, conversation, last `welcome` data |
| options | `reconnect=True`, `max_retries=None`, `backoff_initial=0.5`, `backoff_max=30`, `open_timeout=10`, `ack_timeout=30`, `headers` |

Store `sock.watermark` to resume a later connection exactly where this one stopped.
`converger.protocol.Session` is the transport-independent resume state machine if you bring your own transport.

## Webhook signature verification

```python
from converger import WebhookSignatureError, verify_signature, is_valid_signature

verify_signature(headers, raw_body, secret)                  # raises WebhookSignatureError(reason)
verify_signature(headers, raw_body, [new_secret, old_secret]) # while rotating
is_valid_signature(headers, raw_body, secret, tolerance=300)  # bool
```

`headers` is any mapping or list of pairs (Starlette, Werkzeug, httpx and plain dicts work; names are matched
case-insensitively). Pass the **raw** body bytes. `reason` is one of `missing_signature`, `no_secret`,
`malformed_signature`, `timestamp_out_of_tolerance`, `invalid_signature`. See
[verifying the signature](../webhooks.md#verifying-the-signature).

### FastAPI

```python
from fastapi import FastAPI, HTTPException, Request
from converger import WebhookEvent, WebhookSignatureError, verify_signature

app = FastAPI()

@app.post("/converger/webhook")
async def webhook(request: Request):
    body = await request.body()
    try:
        verify_signature(request.headers, body, CONVERGER_WEBHOOK_SECRET)
    except WebhookSignatureError as exc:
        raise HTTPException(status_code=401, detail=exc.reason)
    event = WebhookEvent.model_validate_json(body)
    # deduplicate on request.headers["x-converger-delivery-id"]
    return {"ok": True}
```

### Flask

```python
from flask import Flask, abort, request
from converger import WebhookEvent, WebhookSignatureError, verify_signature

app = Flask(__name__)

@app.post("/converger/webhook")
def webhook():
    body = request.get_data()
    try:
        verify_signature(request.headers, body, CONVERGER_WEBHOOK_SECRET)
    except WebhookSignatureError:
        abort(401)
    event = WebhookEvent.model_validate_json(body)
    return {"ok": True}
```

## Development

```bash
cd packages/client-python
pip install -e '.[test]'
pytest                       # unit, transport and conformance tests
```

The end-to-end test is described in [Server-side SDKs](server-sdks.md#end-to-end-test-against-a-real-server).
Releases are tags `client-python/vX.Y.Z`.
