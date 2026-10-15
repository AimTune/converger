"""Test fixtures: the fake server of converger_agent.testing, validating every
frame the agent sends against priv/protocol/v1 (hello, ping, auth, and
client-envelope -> agent-frame for conversation frames).
"""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Any

import pytest
from jsonschema import Draft202012Validator
from referencing import Registry, Resource

from converger_agent.testing import FakeServer, genui_text  # noqa: F401 - re-exported for the tests

ROOT = Path(__file__).resolve().parents[3]
SCHEMAS = Path(os.environ.get("CONVERGER_SCHEMAS_DIR", ROOT / "priv" / "protocol" / "v1"))
BASE = "https://converger.aimtune.dev/schemas/protocol/v1/"

CONV = "c0a8012e-7d3b-4c5e-9f1a-2b3c4d5e6f70"
CONV2 = "d1b9123f-8e4c-4d6f-8a2b-3c4d5e6f7081"


def _registry() -> Registry:
    resources = []
    for path in SCHEMAS.rglob("*.schema.json"):
        schema = json.loads(path.read_text(encoding="utf-8"))
        uri = schema.get("$id") or BASE + path.relative_to(SCHEMAS).as_posix()
        resources.append((uri, Resource.from_contents(schema)))
    assert resources, f"no protocol schemas under {SCHEMAS}"
    return Registry().with_resources(resources)


REGISTRY = _registry()


def validator(relative: str) -> Draft202012Validator:
    return Draft202012Validator({"$ref": BASE + relative}, registry=REGISTRY)


ENVELOPE = validator("frames/channel/client-envelope.schema.json")
BARE = {
    "hello": validator("frames/client/hello.schema.json"),
    "ping": validator("frames/client/ping.schema.json"),
    "auth": validator("frames/client/auth.schema.json"),
}


def assert_valid(frame: dict[str, Any]) -> None:
    """Validate a frame the agent sent (bare connection frame or conversation envelope)."""
    if "type" in frame:
        schema = BARE.get(frame["type"])
        assert schema is not None, f"unexpected bare frame {frame}"
        errors = list(schema.iter_errors(frame))
    else:
        errors = list(ENVELOPE.iter_errors(frame))
    assert not errors, f"{frame} is invalid: {[e.message for e in errors]}"


@pytest.fixture
async def server():
    srv = await FakeServer(validate=assert_valid).start()
    yield srv
    await srv.stop()
    assert not srv.invalid, f"the agent sent invalid frames: {srv.invalid}"
    native = [f for f in srv.duplicates if f.get("type") in ("tool_call", "skill", "genui", "interrupt", "interrupt_resolved")]
    assert not native, f"native frames the server would drop as duplicates: {native}"


@pytest.fixture
async def run_agent():
    """Start ``agent.run()`` in the background; stopped at teardown."""
    started = []

    def start(agent):
        task = asyncio.ensure_future(agent.run())
        started.append((agent, task))
        return task

    yield start
    for agent, task in started:
        await agent.stop()
        try:
            await asyncio.wait_for(task, 5)
        except BaseException:  # noqa: BLE001 - a terminal close is what some tests expect
            pass
