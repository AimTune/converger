---
title: OpenAPI and Swagger UI
description: The OpenAPI 3.1 description of the HTTP API, how it is generated and checked, Swagger UI at /api/docs with bearer authentication, and generating SDK types from it.
sidebar_position: 8
---

The HTTP API is described by an **OpenAPI 3.1** document, generated from the controllers with
[`open_api_spex`](https://hexdocs.pm/open_api_spex) ([ADR-0050](../adr/0050-openapi-spec-error-envelope-and-api-versioning.md)).

| Where | What |
| --- | --- |
| [`priv/static/openapi.json`](https://github.com/AimTune/converger/blob/main/priv/static/openapi.json) | The committed document. SDKs ([TS SDK, #46](https://github.com/AimTune/converger/issues/46); [server SDKs, #47](https://github.com/AimTune/converger/issues/47)) generate their types from it. |
| `GET /api/openapi.json` | The same document, served by a running instance (when API docs are enabled). |
| `GET /api/docs` | Swagger UI (when API docs are enabled). |

## What it covers

Every operation of the three families: the tenant API (`/api/v1/...`), the client API (`/api/v1/converger/...`) and
the inbound webhooks (`/api/v1/channels/{channel_id}/inbound|status`), with a stable `operationId` (for example
`listConversations`, `postActivity`), request bodies, parameters and every response, error responses included.

- **Named schemas.** Every resource is a component schema (`Conversation`, `Activity`, `ClientActivity`,
  `Delivery`, `RoutingRule`, `WebhookSubscription`, `WebhookEvent`, `ActivitySet`, ...), so generated SDKs get one
  named type per resource.
- **One error schema.** All error responses reference `ErrorResponse`, the [error envelope](errors.md); its `code`
  is the `ErrorCode` enumeration.
- **Security schemes.** `apiKey` (`x-api-key`), `channelToken` (`x-channel-token`, deprecated),
  `channelSecret` and `convergerToken` (HTTP bearer), `convergerTokenQuery` (`?token=` for SSE) and
  `inboundSignature` (`x-converger-signature`).
- **Deprecations.** Deprecated operations are marked `deprecated: true` ([versioning policy](versioning.md)).

Not described: the WebSocket endpoints and their frames (see [Protocol v1](../protocol/v1.md) and its JSON
Schemas), the admin and portal pages, `/metrics` and `/health/*`.

## Swagger UI

`/api/docs` renders the document with Swagger UI. **Authorize** takes a credential per scheme: paste a tenant API
key for `apiKey`, a channel secret for `channelSecret` or a Converger token for `convergerToken` (without the
`Bearer ` prefix), then use **Try it out** on any operation; requests go to the instance that served the page.
The authorization is kept across reloads (`persistAuthorization`).

Swagger UI is loaded from cdnjs; the page has its own Content-Security-Policy that allows that origin and the
page's inline boot script by nonce.

### Enabling it

| Environment | Default | Setting |
| --- | --- | --- |
| dev, test | on | `config :converger, :api_docs, enabled: true` (`config/dev.exs`, `config/test.exs`) |
| prod | **off** | set `API_DOCS_ENABLED=true` (`false` turns it off again) |

Disabled, `/api/docs` and `/api/openapi.json` answer `404 not_found`. The document reveals no secrets (it is
public in the repository), but an internet-facing instance usually has no reason to serve it; "Try it out" sends
real requests with real credentials.

## Generating and checking the document

The document is built from code, so changing a controller, its `operation` annotation or a schema in
[`ConvergerWeb.ApiSchemas`](https://github.com/AimTune/converger/blob/main/lib/converger_web/api_schemas.ex) changes it:

```bash
mix openapi.spec.json            # rewrite priv/static/openapi.json, then commit it
mix openapi.spec.json --check    # exit non-zero when the committed file is out of date
```

`mix openapi.spec.json` is an alias of `mix converger.openapi` (it replaces open_api_spex's own task of the same
name, which writes OpenAPI 3.0). open_api_spex models OpenAPI 3.0, so the export rewrites `nullable` to 3.1's
`type: [..., "null"]`; keys are sorted for stable diffs.

CI (the lint job in `.github/workflows/ci.yml`) fails when the committed file drifts from the code
(`mix openapi.spec.json --check`) and validates it with Redocly CLI (`redocly lint`). The test suite checks the same
drift (`test/converger_web/api_spec_test.exs`), and every controller response in
`test/converger_web/api_contract_test.exs` is checked against its operation's schema with
`OpenApiSpex.TestAssertions`, so the document cannot silently diverge from what the server sends.

### Annotating a new endpoint

```elixir
use OpenApiSpex.ControllerSpecs
import ConvergerWeb.ApiSchemas

tags ["Conversations"]
security [%{"apiKey" => []}]

operation :show,
  summary: "Get a conversation",
  operation_id: "getConversation",
  parameters: [id: path_id("Conversation id")],
  responses:
    with_errors(%{200 => json_schema("The conversation", ref("ConversationResponse"))}, [400, 401, 404])
```

Add new resource schemas to `ConvergerWeb.ApiSchemas`, regenerate the document, and assert the response in a test
with `assert_api_response(conn)` (or `assert_api_error(conn, status, code)` for errors, both in
`ConvergerWeb.ConnCase`).

## Generating SDK types

Any OpenAPI 3.1 generator works on the committed file, for example:

```bash
npx openapi-typescript priv/static/openapi.json -o src/schema.d.ts
```
