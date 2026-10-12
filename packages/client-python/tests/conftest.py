import json
import os
from pathlib import Path

import pytest

CONFORMANCE = Path(
    os.environ.get("CONVERGER_CONFORMANCE_DIR", Path(__file__).resolve().parents[2] / "conformance")
)


def load(name: str):
    with open(CONFORMANCE / name, encoding="utf-8") as f:
        return json.load(f)


def norm(name: str) -> str:
    return name.replace("_", "").lower()


def resolve(obj, path: str):
    """Follow a conformance result path (see packages/conformance/rest.json)."""
    for seg in path.split("."):
        if seg.isdigit():
            obj = obj[int(seg)]
        elif isinstance(obj, dict):
            matches = [k for k in obj if norm(k) == norm(seg)]
            assert matches, f"{seg!r} not in {list(obj)}"
            obj = obj[matches[0]]
        else:
            names = list(type(obj).model_fields) + list((obj.model_extra or {}).keys())
            matches = [n for n in names if norm(n) == norm(seg)]
            assert matches, f"{seg!r} not in {names}"
            obj = getattr(obj, matches[0])
    return obj


@pytest.fixture
def conformance():
    return load
