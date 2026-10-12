---
title: "ADR-0050: OpenAPI 3.1 from controller annotations, one error envelope, URL versioning with Deprecation and Sunset"
sidebar_label: "0050 OpenAPI and errors"
description: The HTTP API is described by an OpenAPI 3.1 document generated from open_api_spex controller annotations and committed (CI fails on drift), every error response uses one envelope {code, message, details, request_id} with codes shared with Protocol v1, and breaking changes get a new URL version while retired endpoints announce themselves with Deprecation and Sunset headers and a 12-month window.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-12 |
| **Issue** | [#45](https://github.com/AimTune/converger/issues/45) |
| **Pull request** | to be linked |
| **Related** | [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md), [ADR-0026](0026-one-client-socket-stack-and-shape-checked-legacy-tokens.md), [ADR-0044](0044-bulkheaded-pools-and-graceful-degradation-under-database-pressure.md) |

## Context and problem statement

There was no machine-readable description of the HTTP API: integrators and the SDK authors (TypeScript SDK
[#46](https://github.com/AimTune/converger/issues/46), server SDKs [#47](https://github.com/AimTune/converger/issues/47))
had to read the docs and the Elixir source. Error bodies depended on where an error was raised: `FallbackController`
answered `{"error": "..."}` for strings and `{"errors": {"detail": ...}}` for atoms, changesets were
`{"errors": {field: [...]}}`, `ConvergerAuth` sent `{"error": {"code": "Unauthorized", "message": ...}}`, `TenantAuth`
`{"error": "Unauthorized: ..."}`, the database-pressure plug `{"errors": {"detail", "code"}}`, `AdminAuth` plain text
and refused socket connections an empty body. A client could not handle errors generically, and a generated SDK could
not type them. There was also no written rule for how the API may change.

## Decision drivers

- One source of truth: the description must come from the code and cannot drift silently.
- SDKs generate types from it, so every resource needs a named schema.
- One error shape for every path, including plugs and exception handlers, aligned with the Protocol v1 `error` frame
  codes clients already handle on the WebSocket.
- No new runtime dependency beyond a mature library; no behaviour change for successful responses.
- Clients need predictable rules for change and retirement.

## Considered options

1. **open_api_spex annotations on the controllers, document generated and committed** - spec next to the code,
   checked in tests and CI.
2. **Hand-written `openapi.yaml`** - flexible, but nothing ties it to the code; it drifts.
3. **Generate from tests (recorded responses)** - accurate for what tests cover, silent about the rest, no named schemas.

For errors: **(a)** one envelope `{"error": {code, message, details, request_id}}` everywhere, **(b)** RFC 9457
`application/problem+json`, **(c)** keep the shapes and document them.

### Pros and cons of the options

#### Option 1

- Good, because the operation sits next to the action and `OpenApiSpex.TestAssertions` checks real responses against it.
- Good, because the router supplies the paths: a new route without an operation is caught by a test.
- Bad, because open_api_spex models OpenAPI 3.0; 3.1 needs an export step (below).

#### Option 2

- Good, because any OpenAPI 3.1 feature is available.
- Bad, because it duplicates the controllers and nothing fails when they diverge.

#### Option 3

- Good, because examples are real.
- Bad, because untested paths are missing and schemas are anonymous.

#### Envelope (a) versus problem+json (b)

- (a) is what `ConvergerAuth` and the Protocol v1 frame already looked like (`code` + `message` + `details`), so the
  SDKs share one error type across REST and WebSocket; `request_id` ties a report to the server logs.
- (b) is a standard, but its `type` URIs and `title` / `detail` split add nothing for these clients, and it would
  diverge from the frame shape.

## Decision

Chosen: **option 1 with envelope (a)**.

- **Spec.** Controllers `use OpenApiSpex.ControllerSpecs` and declare an `operation` per action with a stable
  `operationId`. Resource schemas and the shared error responses live in `ConvergerWeb.ApiSchemas` as named
  components; `ConvergerWeb.ApiSpec` collects the paths from the router. `ApiSpec.to_json/0` exports **OpenAPI 3.1**:
  it rewrites 3.0 `nullable` to `type: [..., "null"]` (or `anyOf` with `null` for references) and sorts keys.
  `mix openapi.spec.json` (an alias of `mix converger.openapi`) writes `priv/static/openapi.json`, which is committed;
  `--check` fails on drift. CI runs the check and `redocly lint`.
- **Swagger UI** at `/api/docs` and the document at `/api/openapi.json`, on in dev and test, off in prod unless
  `API_DOCS_ENABLED=true` (404 otherwise). Bearer and API-key security schemes make "Try it out" work. The page gets
  its own CSP: the cdnjs origin and a per-request script nonce.
- **Errors.** `ConvergerWeb.APIError` holds the code catalog (code, default status, default message) and renders
  `{"error": {"code", "message", "details", "request_id"}}` with all four keys always present.
  `FallbackController`, `ErrorJSON` (exceptions: code from status, generic message), `TenantAuth`, `ConvergerAuth`
  (now distinguishing `token_expired`), `AdminAuth`, `RateLimit` (`details.retry_after_ms`), `DbUnavailable`,
  `SocketGuard` refusals and the controller-specific errors all use it. HTTP statuses are unchanged. Codes shared
  with Protocol v1 (`bad_request`, `invalid_watermark`, `invalid_message`, `unauthorized`, `token_expired`,
  `forbidden`, `channel_inactive`, `rate_limited`, `payload_too_large`, `conversation_closed`, `internal`,
  `unavailable`) are spelled the same; a test enforces it.
- **Versioning.** Breaking changes get a new URL prefix (`/api/v2`); additive changes (fields, endpoints, enum
  values, error codes) ship without one. A deprecated endpoint sends `Deprecation: @<unix>` (RFC 9745) and
  `Link: rel="deprecation"`, later `Sunset: <HTTP-date>` (RFC 8594) and `rel="sunset"`, via
  `ConvergerWeb.Plugs.Deprecated`, and is supported for at least 12 months after the deprecation is announced.

## Consequences

### Positive

- SDKs generate types from `priv/static/openapi.json`, including a single `ErrorResponse` / `ErrorCode`.
- Clients branch on one `code` field for REST and WebSocket errors, and can quote `request_id`.
- A response that does not match its schema, a route without an operation or an uncommitted spec change fails CI.

### Negative and trade-offs

- **Breaking for clients that parsed error bodies** (`{"error": "..."}`, `{"errors": {...}}`, `code: "Unauthorized"`).
  Statuses did not change. This ships inside `v1` as a one-time alignment before the SDKs exist, documented in
  [errors](../api/errors.md#migrating-from-the-earlier-shapes); later error-shape changes follow the versioning policy.
- open_api_spex is a 3.0 library: the 3.1 export is a small rewrite we own, and tests validate with 3.0 semantics.
- Every new endpoint needs an annotation and a regenerated, committed document.

### Follow-ups

- [#46](https://github.com/AimTune/converger/issues/46), [#47](https://github.com/AimTune/converger/issues/47): SDKs
  generate from the document.
- Set `Sunset` dates for the legacy surfaces of [#23](https://github.com/AimTune/converger/issues/23).
- Optionally validate requests at runtime with `OpenApiSpex.Plug.CastAndValidate` (today only responses are checked,
  in tests).

## Implementation

- [`lib/converger_web/api_error.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/api_error.ex),
  [`api_schemas.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/api_schemas.ex),
  [`api_spec.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/api_spec.ex),
  [`plugs/api_docs.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/api_docs.ex),
  [`plugs/deprecated.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/deprecated.ex),
  [`lib/mix/tasks/converger.openapi.ex`](https://github.com/AimTune/converger/blob/main/lib/mix/tasks/converger.openapi.ex),
  [`priv/static/openapi.json`](https://github.com/AimTune/converger/blob/main/priv/static/openapi.json).
- Config: `config :converger, :api_docs, enabled:`; `API_DOCS_ENABLED` in `config/runtime.exs`.
- Tests: `test/converger_web/api_contract_test.exs` (every operation, `assert_api_response/1`),
  `api_error_envelope_test.exs` (every error path, `assert_api_error/3`), `api_spec_test.exs` (drift, refs, 3.1,
  Swagger UI), `plugs/deprecated_test.exs`.

## Links

- [Errors](../api/errors.md), [Versioning and deprecation policy](../api/versioning.md),
  [OpenAPI and Swagger UI](../api/openapi.md), [REST API overview](../api/overview.md)
- [Protocol v1, section 12: errors](../protocol/v1.md#12-errors)
- RFC 9745 (Deprecation header), RFC 8594 (Sunset header)
