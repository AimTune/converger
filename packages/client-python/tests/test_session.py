import pytest

from converger.protocol import Session
from conftest import load

SCENARIOS = load("protocol.json")["scenarios"]


def label(frame):
    seq = frame.get("seq")
    return f"{frame['type']}:{seq}" if isinstance(seq, int) else frame["type"]


@pytest.mark.parametrize("scenario", SCENARIOS, ids=lambda s: s["name"])
def test_protocol_scenario(scenario):
    init = scenario["initial"]
    session = Session(init.get("watermark", 0), init.get("conversation_id"))
    assert session.hello() == scenario["hello"]
    for i, step in enumerate(scenario["steps"]):
        out = session.on_frame(step["recv"])
        expect = step["expect"]
        where = f"step {i} ({step['recv']['type']})"
        assert [label(f) for f in out.deliver] == expect.get("deliver", []), where
        assert out.send == expect.get("send", []), where
        assert [{"after_ms": s.after_ms, "frame": s.frame} for s in out.schedule] == expect.get("schedule", []), where
        if "watermark" in expect:
            assert session.watermark == expect["watermark"], where
