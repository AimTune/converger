# Changelog

## 0.1.1 (2026-10-16)

- First release from CI ([#188](https://github.com/AimTune/converger/issues/188)); no API changes.

## 0.1.0 (2026-10-15)

- REST client for the client API and the tenant API (Req), with error normalization for the legacy shapes and the #45 envelope.
- Protocol v1 WebSocket client (`ConvergerClient.Socket`, Mint.WebSocket) with resume, gap sync and re-sending of unacked sends.
- `ConvergerClient.Webhook.verify_signature/4`.
