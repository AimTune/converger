"""Transport-independent Protocol v1 resume state machine.

The rules are in ``packages/conformance/README.md`` and are checked by the
scenarios in ``packages/conformance/protocol.json``.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

PROTOCOL = "converger/1"

Frame = dict[str, Any]


@dataclass
class Scheduled:
    after_ms: int
    frame: Frame


@dataclass
class Step:
    deliver: list[Frame] = field(default_factory=list)
    send: list[Frame] = field(default_factory=list)
    schedule: list[Scheduled] = field(default_factory=list)


def _seq(frame: Frame) -> int | None:
    seq = frame.get("seq")
    return seq if isinstance(seq, int) and not isinstance(seq, bool) else None


class Session:
    """Tracks the watermark of one conversation across reconnects."""

    def __init__(self, watermark: int = 0, conversation_id: str | None = None) -> None:
        self.watermark = watermark
        self.conversation_id = conversation_id
        self.sync_pending = False
        self.own: set[int] = set()

    def hello(self) -> Frame:
        frame: Frame = {"type": "hello", "protocol": PROTOCOL, "watermark": self.watermark}
        if self.conversation_id is not None:
            frame["conversationId"] = self.conversation_id
        return frame

    def sync_frame(self) -> Frame:
        return {"type": "sync", "watermark": self.watermark}

    def _advance(self, seq: int) -> None:
        self.watermark = seq
        while self.watermark + 1 in self.own:
            self.watermark += 1
            self.own.discard(self.watermark)
        self.own = {s for s in self.own if s > self.watermark}

    def _sync(self, step: Step) -> None:
        if not self.sync_pending:
            step.send.append(self.sync_frame())
            self.sync_pending = True

    def on_frame(self, frame: Frame) -> Step:
        step = Step()
        ftype = frame.get("type")
        seq = _seq(frame)

        if ftype == "welcome":
            data = frame.get("data") or {}
            new_id = data.get("conversationId")
            if self.conversation_id is not None and new_id != self.conversation_id:
                self.watermark = 0
                self.own.clear()
            if new_id is not None:
                self.conversation_id = new_id
            self.sync_pending = False
            step.deliver.append(frame)
        elif ftype == "ack":
            if seq is not None:
                if seq == self.watermark + 1:
                    self._advance(seq)
                elif seq > self.watermark + 1:
                    self.own.add(seq)
        elif seq is not None:
            if seq <= self.watermark or seq in self.own:
                pass
            elif seq == self.watermark + 1:
                step.deliver.append(frame)
                self._advance(seq)
                self.sync_pending = False
            else:
                self._sync(step)
        elif ftype == "heartbeat":
            head = frame.get("headSeq")
            if isinstance(head, int) and head > self.watermark:
                self._sync(step)
        elif ftype == "replayTruncated":
            step.deliver.append(frame)
            step.send.append(self.sync_frame())
            self.sync_pending = True
        elif ftype == "error":
            data = frame.get("data") or {}
            code = data.get("code")
            step.deliver.append(frame)
            if code == "replay_unavailable":
                after = data.get("retryAfterMs")
                step.schedule.append(Scheduled(after if isinstance(after, int) else 1000, self.sync_frame()))
                self.sync_pending = True
            elif code == "invalid_watermark" and "clientId" not in data:
                self.watermark = 0
                self.own.clear()
                step.send.append(self.sync_frame())
                self.sync_pending = True
        elif ftype == "tokenRefreshed":
            pass
        else:
            step.deliver.append(frame)
        return step
