# Changelog

## 0.1.1 (2026-10-16)

- First version on NuGet (0.1.0 was not published there), released from CI with nuget.org trusted publishing ([#188](https://github.com/AimTune/converger/issues/188)); no API changes.

## 0.1.0 (2026-10-15)

- First version of the Converger agent SDK for .NET (#67): one channel-scoped Protocol v1 WebSocket serves every
  conversation of a channel. Turns queued per conversation, run frames around each handler, text, typed messages,
  tool calls, typing, raw frames, interrupts (`AskAsync`), acks with structured `ConvergerException` errors,
  reconnect with jittered backoff and `retryAfterMs`, 4401 token refresh, per-conversation watermarks and re-sending
  of unacked messages after a reconnect.
- Passes the shared agent conformance fixture (`packages/conformance/agent.json`).
