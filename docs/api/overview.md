---
title: REST API overview
description: Base URLs, API families, authentication, token kinds, error envelopes, rate limiting, pagination, idempotency and CORS for the Converger HTTP API.
sidebar_position: 1
---

Converger exposes three groups of HTTP endpoints, all served by the Phoenix router in
[`lib/converger_web/router.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/router.ex).
This page covers what is shared between them: base URLs, authentication, the token kinds and their claims,
error bodies, rate limiting, pagination, idempotency and CORS. The endpoint references are:

- [Tenant API](tenant-api.md): server-to-server API under `/api/v1`, for your backend and bots.
- [Client API](client-api.md): the Direct Line-inspired API under `/api/v1/converger`, for end-user clients (web chat, mobile apps).
- [Inbound webhooks](inbound.md): provider-facing endpoints under `/api/v1/channels/:channel_id`, called by WhatsApp, Infobip or your own systems.

:::info OpenAPI
There is no OpenAPI / Swagger description today: the repository has no `open_api_spex` dependency, no generated
spec and no `/api/docs` route. A machine-readable spec, Swagger UI and a single error envelope are
Planned ([#45](https://github.com/AimTune/converger/issues/45)). Until then, these pages and the controller tests
under [`test/converger_web/controllers`](https://github.com/AimTune/converger/tree/main/test/converger_web/controllers)
are the reference.
:::

## Base URLs

| Environment | Base URL | Notes |
| --- | --- | --- |
| Development (`mix phx.server`) | `http://localhost:4000` | Default endpoint port. |
| Production release | `https://<PHX_HOST>` | The endpoint URL is `https://$PHX_HOST:443`; the HTTP listener binds to `PORT` (default `4000`) behind your proxy. See [deployment](../deployment.md). |

All paths below are relative to the base URL. Every API path is versioned under `/api/v1`.

| Path prefix | Family | Authentication |
| --- | --- | --- |
| `/api/v1/tokens`, `/api/v1/conversations...`, `/api/v1/routing_rules...` | Tenant API | `x-api-key` (tenant API key) or `x-channel-token` (channel token, deprecated, see [migrating from the legacy surfaces](migrating-from-legacy.md)) |
| `/api/v1/channels/:channel_id/inbound`, `/api/v1/channels/:channel_id/status` | Inbound webhooks | Per-channel request signature, see [inbound](inbound.md) |
| `/api/v1/converger/tokens/generate` | Client API | `Authorization: Bearer <channel secret>` |
| `/api/v1/converger/...` (everything else) | Client API | `Authorization: Bearer <converger token>` |

Two WebSocket endpoints complement the REST API: `/socket/converger/websocket` (the Converger client socket,
joined with a converger token; its URL is returned as `streamUrl`; clients can also send activities on it with
`postActivity`) and `/socket/websocket` (legacy conversation channel, joined with a conversation token from
`POST /api/v1/tokens`; **deprecated**, see [migrating from the legacy surfaces](migrating-from-legacy.md)). See
[WebSocket](../websocket.md). The wire protocol for the client socket is Converger Protocol v1 (spec in progress,
[#21](https://github.com/AimTune/converger/issues/21), [#63](https://github.com/AimTune/converger/issues/63)).

Requests and responses are JSON (`content-type: application/json`), except the multipart upload endpoint and the
attachment download endpoint of the client API. The JSON routes go through Phoenix's `accepts ["json"]`; a request
with an `Accept` header that excludes JSON is rejected with `406`.

## Authentication

### Credentials at a glance

| Credential | Where it comes from | Sent as | Used by |
| --- | --- | --- | --- |
| Tenant API key | Created with the tenant (admin panel); format `cvg_live_` + 43 URL-safe Base64 chars | `x-api-key: <key>` | Tenant API |
| Channel token (deprecated) | Shown (and copyable) per channel in the admin panel, Channels page | `x-channel-token: <jwt>` | Tenant API: create conversation, issue conversation token, and accepted by every tenant-authenticated route |
| Conversation token (deprecated) | `POST /api/v1/tokens` | `token` param of the legacy socket `/socket/websocket` | Legacy WebSocket channel `conversation:<id>` |
| Channel secret | Generated per channel (admin panel) | `Authorization: Bearer <secret>` | `POST /api/v1/converger/tokens/generate` only |
| Converger token | `POST /api/v1/converger/tokens/generate`, `/tokens/refresh`, `/conversations` | `Authorization: Bearer <jwt>` | Client API and `/socket/converger/websocket` |

Channel tokens, conversation tokens, `POST /api/v1/tokens` and the legacy socket are deprecated
([#23](https://github.com/AimTune/converger/issues/23)) and will be removed no earlier than two minor releases and
six months after it. They keep working unchanged until then.
The tenant API key is not deprecated. See [migrating from the legacy surfaces](migrating-from-legacy.md).

API keys and channel secrets are stored hashed (and the channel secret also encrypted) and looked up by hash; see
[ADR-0012](../adr/0012-secrets-at-rest-and-audit-redaction.md). Rotating a tenant API key keeps the previous key
valid for a grace period (default 24 hours, `config :converger, :api_key_rotation_grace_period` in seconds).

:::warning
The tenant API key and channel secrets are server-side credentials. Never ship them to a browser or mobile app.
End-user clients get short-lived converger tokens from your backend, which exchanges the channel secret for them.
:::

### Tenant authentication (`x-api-key` / `x-channel-token`)

[`ConvergerWeb.Plugs.TenantAuth`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/tenant_auth.ex)
checks, in this order:

1. `x-api-key`: the key is hashed and matched against the current key or the previous key while its grace period
   lasts. The tenant must have status `active`.
2. `x-channel-token`: the token must be a **channel token**. Every token type is signed with the same key, so
   the claims decide: a channel token has `typ: "channel"` (tokens issued before that claim existed are
   recognised by `sub: "channel_<channel_id>"` and the absence of `conversation_id` and `type`). Its channel must
   exist, be `active` and belong to the token's tenant, and the tenant must be `active`. Conversation tokens and
   Converger client tokens (which end-user browsers hold) are rejected with `Invalid token`, even though they carry
   a `tenant_id`.

Failures return `401` with a flat string error:

```json
{ "error": "Unauthorized: Invalid or inactive API Key" }
```

| Message suffix | Cause |
| --- | --- |
| `Missing authentication headers` | Neither header present |
| `Invalid or inactive API Key` | Unknown key, expired previous key, or tenant not `active` |
| `Invalid token` | `x-channel-token` signature or expiry invalid, not a channel token, or its channel or tenant does not exist |
| `Channel is not active` | Channel token valid, channel deactivated |
| `Tenant is not active` | Channel token valid, tenant suspended |

Some endpoints apply stricter rules on top. `GET /api/v1/conversations` requires `x-api-key` and answers `403` to a
channel token. `POST /api/v1/conversations` and `POST /api/v1/tokens` do not run `TenantAuth` at all and
authenticate with `x-channel-token` only. See the [tenant API](tenant-api.md) for each route.

### Client authentication (`Authorization: Bearer`)

[`ConvergerWeb.Plugs.ConvergerAuth`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/converger_auth.ex)
reads `Authorization: Bearer <value>` and runs in one of two modes:

- **Secret mode** (`/tokens/generate` only): the value is first looked up as a channel secret of an `active`
  channel. If it is not one, the plug falls back to token mode, so a valid converger token is authenticated too and
  the controller rejects it with `400` (`"Token generation requires channel secret, not a token"`).
- **Token mode** (all other client routes): the value must be a valid converger token (signature, `exp`,
  `type: "converger"`), and the channel in its `channel_id` claim must still exist and be `active`.

Errors use a nested object:

```json
{ "error": { "code": "Unauthorized", "message": "Invalid or expired token" } }
```

| Status | `code` | `message` |
| --- | --- | --- |
| `401` | `Unauthorized` | `Missing or malformed Authorization header` |
| `401` | `Unauthorized` | `Invalid or expired token` |
| `403` | `Forbidden` | `Channel not found or inactive` (token valid, channel disabled or deleted) |

A disabled channel therefore invalidates every outstanding converger token for it immediately, even before `exp`.

### Token kinds and claims

All tokens are HS256 JWTs signed with the endpoint `secret_key_base`
([`Converger.Auth.Signer`](https://github.com/AimTune/converger/blob/main/lib/converger/auth/signer.ex)), so
rotating `SECRET_KEY_BASE` invalidates every issued token. Each also carries Joken's default registered claims:
`exp`, `iat`, `nbf`, `jti`, and `iss` / `aud` (both `"Joken"`), all validated on verification.

| Token | Module | Claims | TTL |
| --- | --- | --- | --- |
| Channel token | [`Converger.Auth.Token.generate_channel_token/1`](https://github.com/AimTune/converger/blob/main/lib/converger/auth/token.ex) | `typ: "channel"`, `channel_id`, `tenant_id`, `sub: "channel_<channel_id>"` | 3600 s (default `exp`) |
| Conversation token | `Converger.Auth.Token.generate_token/3` | `conversation_id`, `tenant_id`, `sub: <user_id>` | 3600 s (`expires_in: 3600` in the response) |
| Converger token | [`Converger.Auth.ConvergerToken`](https://github.com/AimTune/converger/blob/main/lib/converger/auth/converger_token.ex) | `type: "converger"`, `channel_id`, `tenant_id`, `sub: "converger_<channel_id>"`, optional `conversation_id`, optional `user_id` | 1800 s (`expires_in: 1800`) |

Every converger token is bound to **one channel**: conversations (and their activities, uploads and attachments)
on any other channel are reported as `404`, even within the same tenant. A converger token without
`conversation_id` is **unscoped**: it was issued by `/tokens/generate`, can create conversations and resume
(`GET /conversations/:id`) conversations of its channel, but cannot join a conversation over the WebSocket; the
socket needs the conversation token those endpoints return. A token with `conversation_id` is
**conversation-bound**: requests for any other conversation id are answered `403`
(`{"errors": {"detail": "Forbidden"}}`), and attachments of other conversations are reported as `404`.
`user_id` is copied from `user.id` at generation time and carried through refreshes; it identifies the end user's
socket (see [ADR-0020](../adr/0020-per-subject-socket-ids-and-presence.md)).

The channel token shown in the admin panel is regenerated on every render and expires one hour after it was
displayed.

## Error responses

The error body shape currently depends on where the error is raised. A single envelope is Planned
([#45](https://github.com/AimTune/converger/issues/45)); until then, clients should handle these shapes:

| Shape | Example | Raised by |
| --- | --- | --- |
| Flat string | `{"error": "Missing x-channel-token header"}` | `FallbackController` (string reasons), `TenantAuth`, rate limiter, upload and inbound specifics |
| Phoenix detail | `{"errors": {"detail": "Not Found"}}` | `FallbackController` for `:not_found` / `:unauthorized` / `:forbidden`, and Phoenix for exceptions (`ErrorJSON`) |
| Changeset errors | `{"errors": {"text": ["should be at most 65536 byte(s)"]}}` | Validation failures (`422`) |
| Coded object | `{"error": {"code": "Unauthorized", "message": "..."}}` | `ConvergerAuth` (client API) |
| Closed conversation | `{"error": "conversation_closed", "detail": "Conversation is closed"}` | Any activity write to a closed conversation (`409`) |

### Status codes

Mapped in [`ConvergerWeb.FallbackController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/fallback_controller.ex)
and [`ConvergerWeb.ErrorJSON`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/error_json.ex):

| Status | Body | When |
| --- | --- | --- |
| `400` | `{"error": "<message>"}` | Request-level problem reported as a string, e.g. `Missing x-channel-token header`, `Invalid cursor`, `Invalid watermark`, `Invalid channel_id`, `Missing file in upload` |
| `400` | `{"error": "Channel is inactive"}` | The addressed channel is disabled |
| `400` | `{"error": "Channel does not accept inbound messages"}` | Inbound message to an outbound-only channel |
| `400` | `{"errors": {"detail": "Bad Request"}}` | Malformed UUID in a path or lookup (`Ecto.Query.CastError`), or missing required body params (`Phoenix.ActionClauseError`) |
| `401` | `{"errors": {"detail": "Unauthorized"}}` | Invalid channel token, invalid inbound signature |
| `403` | `{"errors": {"detail": "Forbidden"}}` | Authenticated but not allowed (wrong conversation for the token, channel token where an API key is required) |
| `404` | `{"errors": {"detail": "Not Found"}}` | Unknown resource, or a resource of another tenant (tenant isolation never reveals existence), unknown route |
| `409` | `{"error": "conversation_closed", "detail": "Conversation is closed"}` | Activity posted to a closed conversation ([ADR-0017](../adr/0017-conversation-lifecycle-enforced-under-the-seq-lock.md)) |
| `409` | `{"error": "not_failed", "detail": "Only failed deliveries can be retried"}` | Replay of a delivery that is not `failed` ([tenant API](tenant-api.md#retry-a-delivery)) |
| `413` | `{"error": "File too large (max 10.0MB)"}` or `{"errors": {"detail": "Request Entity Too Large"}}` | Upload over the size limit (the second form when the whole multipart body exceeds the limit plus 1 MB) |
| `415` | `{"error": "File type application/octet-stream is not allowed"}` | Upload whose sniffed type is not allow-listed |
| `422` | `{"errors": {"<field>": ["<message>"]}}` | Changeset validation failed |
| `422` | `{"error": "Inbound message has no text and no attachments"}` | Empty generic inbound message |
| `429` | `{"error": "Too many requests. Please try again later."}` | Rate limit exceeded |
| `500` | `{"errors": {"detail": "Internal Server Error"}}` | Unhandled exception |
| `502` | `{"error": "File could not be stored, please retry"}` / `{"error": "Attachment storage unavailable"}` | Storage backend failure on upload / download |
| `503` | `{"error": "Activity could not be accepted, please retry"}` | The activity was rolled back because its delivery jobs could not be enqueued (transactional outbox, [ADR-0001](../adr/0001-transactional-outbox-with-oban.md)); safe to retry with an idempotency key |

Every response carries an `x-request-id` header (`Plug.RequestId`), which is also attached to the server log lines of
that request. Quote it when reporting a problem.

Responses to deprecated requests (`POST /api/v1/tokens` and any request authenticated with `x-channel-token`) also
carry the RFC 9745 header `Deprecation: @<unix time>` and
`Link: <https://converger.aimtune.dev/api/migrating-from-legacy>; rel="deprecation"`.

## Rate limiting

Hot paths are guarded by [`ConvergerWeb.Plugs.RateLimit`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/rate_limit.ex)
on top of Hammer ([ADR-0013](../adr/0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md)). Windows are fixed
and aligned to wall-clock time.

| Bucket | Applies to | Counted per | Default |
| --- | --- | --- | --- |
| `activity_create` | `POST /api/v1/conversations/:id/activities`, `POST /api/v1/converger/conversations/:id/activities` | tenant (shared by both APIs and the socket `postActivity` event) | 100 per 1 s |
| `upload` | `POST /api/v1/converger/conversations/:id/upload` | tenant | 10 per 1 s |
| `inbound` | `POST /api/v1/channels/:channel_id/inbound` and `/status` | channel (path parameter, checked before the channel is loaded) | 500 per 1 s |
| `token_generate` | `POST /api/v1/converger/tokens/generate`, `POST /api/v1/converger/tokens/refresh` | channel | 10 per 60 s |
| `token_create` | `POST /api/v1/tokens` | client IP | 10 per 60 s |

Limits are resolved from, in order: a per-tenant override in `tenants.limits` (for `activity_create`, `upload`,
`inbound`, `token_generate`), `config :converger, Converger.RateLimit, limits: %{...}`, then the defaults above.
With several nodes, set `RATE_LIMIT_BACKEND=cluster` so counters are shared; see
[rate limiting](../operations/rate-limiting.md).

A rejected request gets:

```http
HTTP/1.1 429 Too Many Requests
retry-after: 1
content-type: application/json; charset=utf-8

{"error":"Too many requests. Please try again later."}
```

`retry-after` is in whole seconds (at least `1`) until the current window ends. No `X-RateLimit-*` headers are
sent. `retry-after` is not in the CORS exposed headers, so browser code on another origin cannot read it; back off
with your own delay there.

## Pagination

Every list endpoint is bounded ([ADR-0018](../adr/0018-keyset-pagination.md),
[`Converger.Pagination`](https://github.com/AimTune/converger/blob/main/lib/converger/pagination.ex)). Two
strategies are used.

### Keyset cursors (conversations)

`GET /api/v1/conversations` is ordered newest first on `(inserted_at, id)` and continues strictly after the last row
of the previous page, so rows inserted meanwhile never shift pages.

| Param | Meaning |
| --- | --- |
| `limit` | Page size. Default `50`, capped at `500`. Missing, non-numeric or non-positive values use the default. |
| `cursor` | The previous response's `meta.next_cursor`. Omit (or send empty) for the first page. A malformed cursor returns `400 {"error": "Invalid cursor"}`. |

```json
{
  "data": [ { "id": "..." } ],
  "meta": { "next_cursor": "dHM6MjAyNi0xMC0wOVQxMjowMDowMC4xMjM0NTZafDNmNmQ...", "has_more": true, "limit": 50 }
}
```

`next_cursor` is `null` and `has_more` is `false` on the last page. The cursor is opaque. It is currently
URL-safe Base64 of `ts:<ISO 8601 timestamp>|<uuid>`, but clients must not build or parse it.

### Sequence watermarks (activities)

Activities are paged oldest first on the per-conversation `seq` that the server assigns under the conversation row
lock ([ADR-0006](../adr/0006-per-conversation-seq-and-opaque-watermarks.md)). The position is an opaque
**watermark**:

| Param | Meaning |
| --- | --- |
| `limit` | Default `100`, capped at `1000` (same clamping rules). |
| `watermark` | The previous response's watermark: return activities with a higher `seq`. Omit to start at the beginning of the conversation. |

The watermark is the `seq` of the last activity returned, encoded as URL-safe Base64 without padding of `seq:<n>`
(for example `c2VxOjQy` is `seq:42`). Resuming needs no database lookup. When a page is empty, the watermark you
sent is returned unchanged. Legacy watermarks (Base64 of an activity id, issued before `seq` existed) are still
accepted. The tenant API answers a malformed watermark with `400`; the client API starts from the beginning instead.
The response shapes differ per family; see [tenant API](tenant-api.md#list-activities) and
[client API](client-api.md#list-activities).

### Configuration

| Key (`config :converger, :pagination`) | Env var | Default |
| --- | --- | --- |
| `default_limit` | `PAGINATION_DEFAULT_LIMIT` | `50` |
| `max_limit` | `PAGINATION_MAX_LIMIT` | `500` |
| `activity_default_limit` | `PAGINATION_ACTIVITY_DEFAULT_LIMIT` | `100` |
| `activity_max_limit` | `PAGINATION_ACTIVITY_MAX_LIMIT` | `1000` |
| `ws_replay_limit` | `PAGINATION_WS_REPLAY_LIMIT` | `100` |
| `lookup_limit` | `PAGINATION_LOOKUP_LIMIT` | `1000` |

`GET /api/v1/routing_rules` is not paginated. It returns the whole list, sorted by name and hard-capped at
`lookup_limit` rows.

## Idempotency

Activity creation is idempotent per conversation when the caller supplies an idempotency key. The key is stored on
the activity, and `(conversation_id, idempotency_key)` is unique. A repeated request with the same key returns the
**original** activity with the same success status, and no second activity or delivery is created, even if the first
request's response was lost or the conversation has since been closed.

| Endpoint | Where the key goes |
| --- | --- |
| Tenant API `POST /api/v1/conversations/:id/activities` | `x-idempotency-key` header. A body field `idempotency_key` is ignored. |
| Client API `POST /api/v1/converger/conversations/:id/activities` | `x-idempotency-key` header |
| Generic webhook `POST /api/v1/channels/:id/inbound` | `idempotency_key` field in the JSON body |
| WhatsApp (Meta, Infobip) inbound | Automatic: the provider message id (`wamid...`, `messageId`) |

The upload endpoint takes no idempotency key. Use a key whenever you retry after a timeout, a `5xx` or a `503`.
Inbound batches are de-duplicated per message; see [inbound webhooks](inbound.md#idempotency-and-batches) and
[ADR-0015](../adr/0015-per-message-idempotent-inbound-batches.md).

## Mass assignment

Clients can only set an activity's `type`, `text`, `attachments` and `metadata`. The server sets `tenant_id`,
`conversation_id`, `sender`, `idempotency_key`, `seq` and `inserted_at`, ignoring any such fields in a body
([ADR-0005](../adr/0005-separate-client-and-system-changesets.md)). Every API renders activities from one canonical
serializer, so REST, WebSocket and outbound webhook payloads cannot drift
([ADR-0004](../adr/0004-single-canonical-activity-serializer.md)).

Activity limits (`config :converger, :activity_limits`), violations of which return `422`:

| Limit | Default |
| --- | --- |
| `type` | One of `message`, `event`, `typing`, `conversationUpdate`, `endOfConversation` |
| `max_text_bytes` | 65,536 bytes of `text` |
| `max_attachments` | 10 entries in `attachments` |
| `max_attachment_bytes` | 4,096 bytes per attachment object, measured as JSON |
| `max_metadata_bytes` | 16,384 bytes of `metadata`, measured as JSON |

## CORS

CORS is handled by `CORSPlug` in the endpoint, before routing, so it applies to every route including error
responses ([ADR-0010](../adr/0010-runtime-cors-and-opentelemetry-configuration.md)).

- Allowed origins come from `CORS_ORIGINS` (comma-separated; `*` allows any origin) and are read on every request,
  so a release picks them up without recompiling. Without it, the compile-time default is
  `http://127.0.0.1:5500` and `http://localhost:5500`.
- Allowed request headers: `x-channel-token`, `x-api-key`, `authorization`, plus CORSPlug's defaults
  (`Authorization`, `Content-Type`, `Accept`, `Origin`, `User-Agent`, `DNT`, `Cache-Control`, `X-Mx-ReqToken`,
  `Keep-Alive`, `X-Requested-With`, `If-Modified-Since`, `X-CSRF-Token`).
- Allowed methods: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `OPTIONS`. Preflights are answered `204`.
- No response headers are exposed.

:::note
`x-idempotency-key` is not in the allowed headers list, so a browser on another origin cannot send it: the
preflight does not allow it. Cross-origin browser clients currently post activities without an idempotency key,
or go through a same-origin backend.
:::

## Related

- [Tenant API reference](tenant-api.md)
- [Client API reference](client-api.md)
- [Inbound webhooks reference](inbound.md)
- [Security](../security.md) (client IPs behind proxies, which the per-IP limit relies on)
- [Outbound webhooks](../webhooks.md)
