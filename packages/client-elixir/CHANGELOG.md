# Changelog

## 0.1.0 (unreleased)

- REST client for the client API and the tenant API (Req), with error normalization for the legacy shapes and the #45 envelope.
- Protocol v1 WebSocket client (`ConvergerClient.Socket`, Mint.WebSocket) with resume, gap sync and re-sending of unacked sends.
- `ConvergerClient.Webhook.verify_signature/4`.
