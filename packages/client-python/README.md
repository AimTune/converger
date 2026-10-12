# converger (Python)

Server-side Python SDK for [Converger](https://converger.aimtune.dev): a REST client (sync and async, `httpx`),
a [Protocol v1](https://converger.aimtune.dev/protocol/v1) WebSocket client with resume (`websockets`), Pydantic
models, and outbound webhook signature verification.

```bash
pip install converger
```

Python 3.10+. Full documentation: [converger.aimtune.dev/sdk/python](https://converger.aimtune.dev/sdk/python).

## REST

```python
from converger import Converger

cvg = Converger("https://chat.example.com", api_key="cvg_live_...", channel_secret="...")

# Client API (converger tokens): your backend mints a token for an end user
token = cvg.client_api.generate_token(user_id="user-42")
conv = cvg.client_api.create_conversation(token.token)          # conversation-bound token
cvg.client_api.post_activity(conv.token, conv.conversation_id, text="Hi!", idempotency_key="msg-1")

# Tenant API (x-api-key): bots and CRMs
reply = cvg.tenant_api.post_activity(conv.conversation_id, sender="bot", text="Hello, how can I help?")
page = cvg.tenant_api.list_activities(conv.conversation_id)
```

`AsyncConverger` has the same methods as coroutines. Errors raise `converger.ApiError` with `status`, `code`,
`message`, `details`, `request_id` and `retry_after`, whatever error shape the server used.

## WebSocket (Protocol v1)

```python
import asyncio
from converger import AsyncConverger

async def main():
    async with AsyncConverger("https://chat.example.com", channel_secret="...") as cvg:
        token = await cvg.client_api.generate_token(user_id="user-42")
        conv = await cvg.client_api.create_conversation(token.token)
        async with cvg.socket(conv.token, conversation_id=conv.conversation_id) as sock:
            ack = await sock.send_text("Where is my order?")   # waits for the ack (id, seq)
            async for frame in sock:                            # persistent frames in seq order, once
                print(frame["type"], frame.get("data"))

asyncio.run(main())
```

The socket reconnects with jittered backoff, resumes from its watermark (`sock.watermark`; pass `watermark=` to
resume a stored position), re-sends unacknowledged sends with their original `clientId`, and answers gaps with
`sync`. Pass a callable as `token` to fetch a fresh token on every connect.

## Webhook signature verification

```python
from converger import WebhookSignatureError, verify_signature

verify_signature(headers, raw_body, secret)          # raises WebhookSignatureError(reason)
```

Always pass the **raw** body bytes. `secret` may be a list while you rotate secrets; `tolerance` (default 300 s)
bounds the timestamp age.

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
pip install -e '.[test]'
pytest                                   # unit + conformance (packages/conformance)
CONVERGER_FIXTURES=../conformance/integration/fixtures.json pytest -m integration
```

Models are hand-written today; `scripts/generate_models.sh` regenerates them from the OpenAPI document once
[#45](https://github.com/AimTune/converger/issues/45) ships `priv/static/openapi.json`.

Releases are tagged `client-python/vX.Y.Z` and published to PyPI by `.github/workflows/sdk-python-release.yml`.
