---
title: Errors
description: The single error envelope of the HTTP API, the stable error codes, their HTTP statuses and how they line up with Converger Protocol v1 error codes.
sidebar_position: 6
---

Every error response of the HTTP API, on every family (tenant API, client API, inbound webhooks), from controllers,
authentication and rate-limit plugs, and the exception handlers (unknown route, malformed request, crash), has the
same body ([ADR-0050](../adr/0050-openapi-spec-error-envelope-and-api-versioning.md)):

```json
{
  "error": {
    "code": "conversation_closed",
    "message": "Conversation is closed",
    "details": null,
    "request_id": "GBHDfGZ0bW5Sl2YAAAEB"
  }
}
```

| Key | Type | Meaning |
| --- | --- | --- |
| `code` | string | Stable, machine-readable key from the [list below](#error-codes). Branch on this. |
| `message` | string | Human-readable explanation. It may change between releases: show it, log it, never parse it. |
| `details` | object or `null` | Code-specific data, see [details](#details). |
| `request_id` | string or `null` | The request's `x-request-id` header (`Plug.RequestId`), also attached to the server log lines of that request. Quote it when reporting a problem. |

All four keys are always present. The body is described by the `ErrorResponse` schema of the
[OpenAPI document](openapi.md), and every operation lists the error statuses it can return.

The implementation is [`ConvergerWeb.APIError`](https://github.com/AimTune/converger/blob/main/lib/converger_web/api_error.ex)
(the code catalog), [`ConvergerWeb.FallbackController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/fallback_controller.ex)
(controller errors) and [`ConvergerWeb.ErrorJSON`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/error_json.ex)
(exceptions: the code is derived from the status and the message is the code's generic message, so no exception
text leaks).

## Error codes

The HTTP status is the code's usual status; where a code is answered with another status, the endpoint reference
says so. Codes that also exist in [Converger Protocol v1](../protocol/v1.md#122-error-codes) (WebSocket and SSE
`error` frames) are spelled the same and mean the same thing; the Protocol column gives the frame's `number`.

| Code | Status | Protocol | Meaning |
| --- | --- | --- | --- |
| `bad_request` | 400 | 1000 | Malformed request: invalid JSON, a missing or mistyped parameter, an invalid cursor or filter, a malformed UUID |
| `invalid_watermark` | 400 | 1003 | The watermark could not be decoded (tenant API; the client API restarts from the beginning instead) |
| `channel_inactive` | 400 | 2003 | The addressed channel is disabled. `403` when it is the channel of the presented Converger token |
| `inbound_not_supported` | 400 | - | Inbound message to an outbound-only channel |
| `unsupported_protocol` | 400 | 1002 | The WebSocket upgrade of `/socket/converger/v1` offered only subprotocols the server does not speak; `details.supported` lists them |
| `unauthorized` | 401 | 2000 | Missing or invalid credential: API key, channel token, Converger token, channel secret, inbound signature |
| `token_expired` | 401 | 2001 | The Converger token expired; refresh it (`POST /api/v1/converger/tokens/refresh` before expiry) or issue a new one |
| `token_revoked` | 401 | 2005 | The Converger token was revoked (its family or its end user, `POST /api/v1/converger/tokens/revoke`), was refreshed longer ago than the rotation grace period, or was refreshed again after that, which revokes its family. Get a new token from your backend. See [client tokens](../security/client-tokens.md) |
| `insufficient_permission` | 403 | 2004 | The Converger token's `perms` claim lacks the permission (`read`, `write`, `typing`) the operation needs; `details.required` names it |
| `forbidden` | 403 | 2002 | Authenticated but not allowed: a conversation-bound token used for another conversation, a channel token where the tenant API key is required, an IP outside the admin allowlist, a failed webhook verification |
| `not_found` | 404 | - | Unknown route or resource, or a resource of another tenant or channel: existence is never revealed. Protocol v1 uses `conversation_not_found` (4001) for conversations |
| `method_not_allowed` | 405 | - | The route does not accept this method |
| `not_acceptable` | 406 | - | The `Accept` header excludes JSON |
| `conflict` | 409 | - | The request conflicts with the current state of the resource |
| `conversation_closed` | 409 | 4000 | The conversation is closed; reopen it before posting activities ([ADR-0017](../adr/0017-conversation-lifecycle-enforced-under-the-seq-lock.md)) |
| `not_failed` | 409 | - | Replay of a delivery (`POST /api/v1/deliveries/:id/retry`) or redelivery of a platform webhook event (`POST /api/v1/webhook_events/:id/redeliver`) that is not `failed` |
| `payload_too_large` | 413 | 3001 | A size limit was exceeded (upload size, raw inbound body) |
| `unsupported_media_type` | 415 | - | The uploaded file's sniffed type is not allow-listed; `details.content_type` |
| `invalid_message` | 422 | 1004 | The activity failed validation; `details` has the errors per field |
| `validation_failed` | 422 | - | Another resource (a routing rule, a platform webhook subscription) failed validation; `details` has the errors per field |
| `unsupported_channel_type` | 422 | - | The channel type does not support the operation (pull outbox, message templates) |
| `invalid_channel_config` | 422 | - | The channel configuration lacks what the operation needs (for example `waba_id` to list templates) |
| `upgrade_required` | 426 | - | `/socket/converger/v1` only accepts WebSocket upgrades |
| `rate_limited` | 429 | 3000 | Rate limit hit; wait `Retry-After` seconds (`details.retry_after_ms`) |
| `internal` | 500 | 9000 | Unexpected server error |
| `upstream_unavailable` | 502 | - | A provider (template listing) or storage backend (upload, download) call failed |
| `unavailable` | 503 | 9001 | Retry later (`Retry-After`): the node is draining, the database is unavailable, or the activity could not be enqueued; `details.reason` says which |

New codes may be added in a minor release (see the [versioning policy](versioning.md)): treat an unknown code like
the generic code of its status (`4xx` as a client error, `5xx` as retryable).

## Details

| Code | `details` |
| --- | --- |
| `invalid_message`, `validation_failed` | Errors per field: `{"text": ["should be at most 65536 byte(s)"], "attachments": ["attachment 0: contentType can't be blank"]}` (the same map Protocol v1 puts in `error.data.details`) |
| `rate_limited` | `{"retry_after_ms": 830}` (CORS does not expose `Retry-After` to browsers on another origin; this is readable) |
| `unavailable` | `{"reason": "draining" \| "database_unavailable" \| "delivery_enqueue_failed", "retry_after_ms": 1400}` (`retry_after_ms` absent for `delivery_enqueue_failed`) |
| `unsupported_protocol` | `{"supported": ["converger.v1", "converger.v1+json", "converger.v1+msgpack"]}` |
| `payload_too_large` | `{"max_bytes": 10485760}` for uploads |
| `unsupported_media_type` | `{"content_type": "application/x-msdownload"}` |
| others | `null` |

Validation example:

```json
{
  "error": {
    "code": "invalid_message",
    "message": "Invalid message",
    "details": { "type": ["is invalid"] },
    "request_id": "GBHDfGZ0bW5Sl2YAAAEB"
  }
}
```

## Retrying

Retry `rate_limited` and `unavailable` after `Retry-After` (or `details.retry_after_ms`), and `internal` /
`upstream_unavailable` with backoff. Activity writes are safe to retry with an `x-idempotency-key`
([idempotency](overview.md#idempotency)). Do not retry other `4xx` codes unchanged.

## Not covered by the envelope

- Successful provider handshakes and provider-specific acknowledgements of [inbound webhooks](inbound.md) (TwiML,
  Slack challenges, Meta's `hub.challenge` echo) keep the body the provider expects.
- The Server-Sent Events stream and the WebSocket endpoints report errors after the connection is established as
  Protocol v1 `error` frames ([Protocol v1, section 12](../protocol/v1.md#12-errors)). Refusals before that (bad
  token, draining) are HTTP responses with the envelope.
- `/metrics` (Prometheus text) and `/health/*` (their own JSON status body), and the HTML admin and portal pages,
  including their CSV exports.

## Migrating from the earlier shapes

Before [#45](https://github.com/AimTune/converger/issues/45) the body depended on where the error was raised. HTTP
statuses did not change; only bodies did:

| Before | Now |
| --- | --- |
| `{"error": "Missing x-channel-token header"}` | `bad_request`, the string in `message` |
| `{"errors": {"detail": "Not Found"}}` (and `Forbidden`, `Unauthorized`, `Bad Request`) | `not_found` (`forbidden`, `unauthorized`, `bad_request`) |
| `{"errors": {"text": ["..."]}}` | `invalid_message` / `validation_failed`, the map in `details` |
| `{"error": {"code": "Unauthorized", "message": "..."}}` (client API) | `unauthorized`, `token_expired` or `channel_inactive` (the code is now snake_case) |
| `{"error": "Unauthorized: Invalid token"}` (tenant API) | `unauthorized`, `message` without the `Unauthorized: ` prefix |
| `{"error": "conversation_closed", "detail": "..."}` | `conversation_closed` |
| `{"error": "not_failed", "detail": "..."}` | `not_failed` |
| `{"error": "Too many requests. Please try again later."}` | `rate_limited` |
| `{"errors": {"detail": "Service Unavailable", "code": "database_unavailable"}}` | `unavailable`, `details.reason: "database_unavailable"` |
| `{"error": "unsupported WebSocket subprotocol", "supported": [...]}` | `unsupported_protocol`, `details.supported` |
| `Forbidden` (plain text, admin IP allowlist) | `forbidden` |
| empty `503` / `403` bodies of refused socket connections | `unavailable` / `forbidden` |
