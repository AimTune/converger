"""End-to-end test against a real server (packages/conformance/integration).

Skipped unless CONVERGER_FIXTURES points at the fixtures file written by
packages/conformance/integration/server.exs.
"""

import asyncio
import json
import os
import uuid

import pytest

from converger import AsyncConverger, Converger, WebhookEvent, verify_signature

FIXTURES = os.environ.get("CONVERGER_FIXTURES")
pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(not FIXTURES, reason="set CONVERGER_FIXTURES to run against a real server"),
]


def fixtures():
    with open(FIXTURES, encoding="utf-8") as f:
        doc = json.load(f)
    fx = doc["python"]
    fx["base_url"] = os.environ.get("CONVERGER_BASE_URL", doc["base_url"])
    return fx


async def start_webhook_receiver(port):
    received: asyncio.Queue = asyncio.Queue()

    async def handle(reader, writer):
        head = await reader.readuntil(b"\r\n\r\n")
        lines = head.decode().split("\r\n")
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        body = await reader.readexactly(int(headers.get("content-length", "0")))
        writer.write(b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
        await writer.drain()
        writer.close()
        await received.put((headers, body))

    server = await asyncio.start_server(handle, "0.0.0.0", port)
    return server, received


async def test_end_to_end():
    fx = fixtures()
    marker = f"py-{uuid.uuid4()}"
    hook_server, hooks = await start_webhook_receiver(fx["webhook_port"])

    async with AsyncConverger(fx["base_url"], api_key=fx["api_key"], channel_secret=fx["channel_secret"]) as cvg:
        # create a conversation
        token = await cvg.client_api.generate_token(user_id="sdk-python")
        conv = await cvg.client_api.create_conversation(token.token)
        assert conv.conversation_id

        async with cvg.socket(conv.token, conversation_id=conv.conversation_id) as sock:
            welcome = await asyncio.wait_for(sock.recv(), 10)
            assert welcome["type"] == "welcome"

            # send over the socket: acked with a seq
            ack = await sock.send_text(f"{marker} ws")
            assert ack.seq >= 1

            # a bot reply through the tenant API arrives on the socket
            reply = await cvg.tenant_api.post_activity(conv.conversation_id, sender="bot", text=f"{marker} bot")
            while True:
                frame = await asyncio.wait_for(sock.recv(), 10)
                if frame.get("seq") == reply.seq:
                    assert frame["data"]["text"] == f"{marker} bot"
                    break
            assert sock.watermark == reply.seq

        # REST read-back with the client API
        page = await cvg.client_api.list_activities(conv.token, conv.conversation_id)
        assert [a.text for a in page.activities][:2] == [f"{marker} ws", f"{marker} bot"]

    # the webhook channel receives the activity, signed with its secret
    deadline = asyncio.get_running_loop().time() + 20
    verified = False
    while not verified:
        headers, body = await asyncio.wait_for(hooks.get(), max(0.1, deadline - asyncio.get_running_loop().time()))
        verify_signature(headers, body, fx["webhook_secret"])
        event = WebhookEvent.model_validate_json(body)
        verified = event.conversation_id == conv.conversation_id
    hook_server.close()


def test_sync_client_round_trip():
    fx = fixtures()
    with Converger(fx["base_url"], api_key=fx["api_key"], channel_secret=fx["channel_secret"]) as cvg:
        token = cvg.client_api.generate_token(user_id="sdk-python-sync")
        conv = cvg.client_api.create_conversation(token.token)
        res = cvg.client_api.post_activity(conv.token, conv.conversation_id, text="hi", idempotency_key="k-1")
        again = cvg.client_api.post_activity(conv.token, conv.conversation_id, text="hi", idempotency_key="k-1")
        assert res.id == again.id
        closed = cvg.tenant_api.close_conversation(conv.conversation_id)
        assert closed.status == "closed"
        from converger import ApiError

        with pytest.raises(ApiError) as exc:
            cvg.client_api.post_activity(conv.token, conv.conversation_id, text="late")
        assert exc.value.status == 409 and exc.value.code == "conversation_closed"
