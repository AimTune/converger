# Changelog

## 0.1.1 (2026-10-16)

- First release from CI with npm trusted publishing and provenance ([#188](https://github.com/AimTune/converger/issues/188)); no API changes.

## 0.1.0 (2026-10-15)

- First release: `createAgent` serves every conversation of a Converger channel from one channel-scoped Protocol v1
  socket with `onTurn(async (turn, reply) => ...)`. `reply.text`, `stream` (genui text chunks), `message`,
  `toolCall`, `ui`, `ask` (interrupt / resume), `typing`, `end`; `run` frames around handlers; per-conversation turn
  queues; agent groups; reconnect with jittered backoff and per-conversation watermarks; acked, idempotent,
  paced sends; `turn.history()` over `sync`; `channelTokenProvider`; `@converger/agent/testing` with a fake server.
- Protocol types are generated from the Protocol v1 JSON Schemas (`priv/protocol/v1`) by
  `scripts/generate-types.mjs` (`pnpm run generate:types`); the public frame type names are unchanged. New: the
  message data types (`ButtonsMessageData`, `CardMessageData`, ...), `MessageDataMap` (`reply.message(type, data)`
  checks `data` for the vocabulary's types) and every schema type under the `protocol` namespace.
