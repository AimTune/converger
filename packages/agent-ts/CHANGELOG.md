# Changelog

## 0.1.0 (unreleased)

- First release: `createAgent` serves every conversation of a Converger channel from one channel-scoped Protocol v1
  socket with `onTurn(async (turn, reply) => ...)`. `reply.text`, `stream` (genui text chunks), `message`,
  `toolCall`, `ui`, `ask` (interrupt / resume), `typing`, `end`; `run` frames around handlers; per-conversation turn
  queues; agent groups; reconnect with jittered backoff and per-conversation watermarks; acked, idempotent,
  paced sends; `turn.history()` over `sync`; `channelTokenProvider`; `@converger/agent/testing` with a fake server.
