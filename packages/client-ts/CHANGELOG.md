# Changelog

## 0.1.0 (2026-10-15)

- First release: `ConvergerClient` / `Conversation` for Converger Protocol v1 with jittered reconnects honouring
  `retryAfterMs`, watermark resume, a persistent outbox with exactly-once sends by `clientId`, token refresh before
  expiry, typed events, REST helpers (tokens, conversations, history paging, uploads) and native, Phoenix and SSE
  transports. Reconnect delays are capped at 10 s (`maxDelayMs`, #198), with `retryAfterMs` as a floor.
