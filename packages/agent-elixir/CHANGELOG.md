# Changelog

## 0.1.1 (2026-10-16)

- First release from CI ([#188](https://github.com/AimTune/converger/issues/188)); no API changes.

## 0.1.0 (2026-10-15)

- `use ConvergerAgent` behaviour (`handle_turn/2`, optional `handle_error/1`) and the functional
  `ConvergerAgent.start_link(handler: fn turn, reply -> ... end)` form, on one channel-scoped Protocol v1 WebSocket
  (Mint.WebSocket).
- Per-conversation turn queues (one task per busy conversation), `run` started / finished / error around each handler.
- `ConvergerAgent.Reply`: `text/3`, `message/3` (wait for the ack), `ask/3` (interrupt and resume), `tool_call/2`,
  `typing/2`, `send_frame/2`, `end_run/1`.
- Reconnect with jittered backoff and `retryAfterMs`, per-conversation watermarks in `hello`, replay deduplication,
  re-sending of unacked sends with their `clientId`, terminal close codes.
- Passes the shared agent conformance fixture (`packages/conformance/agent.json`).
