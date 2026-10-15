import json

import httpx
import pytest

from converger import ApiError, AsyncConverger, Converger
from conftest import load, resolve

DOC = load("rest.json")
CASES = DOC["cases"]


def call(api, op: str, a: dict):
    """Map a conformance operation onto the SDK (same for sync and async namespaces)."""
    ns, name = op.split(".")
    target = api.client_api if ns == "client_api" else api.tenant_api
    act = a.get("activity", {})
    if op == "client_api.generate_token":
        return target.generate_token(user_id=a.get("user_id"), scope=a.get("scope"))
    if op == "client_api.refresh_token":
        return target.refresh_token(a["token"])
    if op == "client_api.create_conversation":
        return target.create_conversation(a["token"])
    if op == "client_api.get_conversation":
        return target.get_conversation(a["token"], a["conversation_id"], watermark=a.get("watermark"))
    if op == "client_api.close_conversation":
        return target.close_conversation(a["token"], a["conversation_id"])
    if op == "client_api.reopen_conversation":
        return target.reopen_conversation(a["token"], a["conversation_id"])
    if op == "client_api.post_activity":
        return target.post_activity(
            a["token"],
            a["conversation_id"],
            type=act.get("type"),
            text=act.get("text"),
            from_id=act.get("from_id"),
            attachments=act.get("attachments"),
            reply_to_id=act.get("reply_to_id"),
            channel_data=act.get("channel_data"),
            idempotency_key=a.get("idempotency_key"),
        )
    if op == "client_api.list_activities":
        return target.list_activities(a["token"], a["conversation_id"], watermark=a.get("watermark"), limit=a.get("limit"))
    if op == "tenant_api.list_conversations":
        return target.list_conversations(
            limit=a.get("limit"),
            cursor=a.get("cursor"),
            status=a.get("status"),
            channel_id=a.get("channel_id"),
            external_id=a.get("external_id"),
        )
    if op == "tenant_api.get_conversation":
        return target.get_conversation(a["conversation_id"])
    if op == "tenant_api.close_conversation":
        return target.close_conversation(a["conversation_id"])
    if op == "tenant_api.reopen_conversation":
        return target.reopen_conversation(a["conversation_id"])
    if op == "tenant_api.post_activity":
        return target.post_activity(
            a["conversation_id"],
            type=act.get("type"),
            text=act.get("text"),
            sender=act.get("sender"),
            attachments=act.get("attachments"),
            metadata=act.get("metadata"),
            reply_to_id=act.get("reply_to_id"),
            idempotency_key=a.get("idempotency_key"),
        )
    if op == "tenant_api.list_activities":
        return target.list_activities(a["conversation_id"], watermark=a.get("watermark"), limit=a.get("limit"))
    raise AssertionError(f"unknown operation {op}")


def handler_for(case, seen):
    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        resp = case["response"]
        return httpx.Response(resp["status"], headers=resp.get("headers", {}), content=json.dumps(resp["body"]).encode())

    return handler


def check_request(case, request: httpx.Request):
    exp = case["request"]
    assert request.method == exp["method"]
    assert request.url.path == exp["path"]
    assert dict(request.url.params) == exp["query"]
    for name, value in exp["headers"].items():
        assert request.headers.get(name, "").split(";")[0] == value, name
    if "json" in exp:
        assert json.loads(request.content) == exp["json"]


def check_outcome(case, result=None, error=None):
    if "error" in case:
        assert isinstance(error, ApiError), f"expected ApiError, got {error!r}"
        for key, value in case["error"].items():
            assert getattr(error, key) == value, key
    else:
        assert error is None, error
        for path, value in case["result"].items():
            assert resolve(result, path) == value, path


def client_kwargs():
    c = DOC["client"]
    return {"api_key": c["api_key"], "channel_secret": c["channel_secret"]}


@pytest.mark.parametrize("case", CASES, ids=lambda c: c["name"])
def test_rest_sync(case):
    seen = []
    api = Converger(DOC["client"]["base_url"], transport=httpx.MockTransport(handler_for(case, seen)), **client_kwargs())
    result, error = None, None
    try:
        result = call(api, case["operation"], case["args"])
    except ApiError as exc:
        error = exc
    assert len(seen) == 1
    check_request(case, seen[0])
    check_outcome(case, result, error)


@pytest.mark.parametrize("case", CASES, ids=lambda c: c["name"])
async def test_rest_async(case):
    seen = []
    api = AsyncConverger(
        DOC["client"]["base_url"], transport=httpx.MockTransport(handler_for(case, seen)), **client_kwargs()
    )
    result, error = None, None
    try:
        result = await call(api, case["operation"], case["args"])
    except ApiError as exc:
        error = exc
    await api.aclose()
    assert len(seen) == 1
    check_request(case, seen[0])
    check_outcome(case, result, error)


def test_tenant_api_requires_api_key():
    from converger import ConvergerError

    api = Converger("http://x", transport=httpx.MockTransport(lambda r: httpx.Response(200)))
    with pytest.raises(ConvergerError):
        api.tenant_api.get_conversation("c")
