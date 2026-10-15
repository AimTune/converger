---
title: Server-side SDKs (Python, Go, Elixir)
description: The Python, Go and Elixir SDKs for backends that integrate with Converger - what they cover, the shared conformance suite, error normalization, the end-to-end test and releases.
sidebar_position: 2
---

Backends that integrate with Converger (bot runtimes, CRMs, ticketing systems) get thin, typed clients in three
languages. They live in this repository, next to the server, so a server change and the SDK change that follows it
land in one pull request. The design is recorded in
[ADR-0052](../adr/0052-server-side-sdks-in-the-monorepo-with-a-shared-conformance-suite.md).

| SDK | Package | Source | Page |
| --- | --- | --- | --- |
| Python 3.10+ | `converger` on PyPI | [`packages/client-python`](https://github.com/AimTune/converger/tree/main/packages/client-python) | [Python SDK](python.md) |
| Go 1.22+ | `github.com/AimTune/converger/packages/client-go` | [`packages/client-go`](https://github.com/AimTune/converger/tree/main/packages/client-go) | [Go SDK](go.md) |
| Elixir 1.15+ | `converger_client` on Hex | [`packages/client-elixir`](https://github.com/AimTune/converger/tree/main/packages/client-elixir) | [Elixir client](elixir.md) |

Browser, mobile and Node front ends use the [TypeScript SDK](typescript.md) ([#46](https://github.com/AimTune/converger/issues/46)).
AI agents and bots that serve a whole channel use the agent SDKs ([#67](https://github.com/AimTune/converger/issues/67)):
[Python agent SDK](agent-python.md) (`converger-agent`, with a LangChain / LangGraph adapter).

## What every SDK covers

| Area | Calls |
| --- | --- |
| [Client API](../api/client-api.md) (converger tokens) | generate token (channel secret), refresh token, create / get / close / reopen conversation, post activity (with idempotency key), list activities |
| [Tenant API](../api/tenant-api.md) (`x-api-key`) | list conversations (filters, keyset cursor), get / close / reopen conversation, post activity (with `sender` and idempotency key), list activities |
| [Protocol v1](../protocol/v1.md) socket | connect to `/socket/converger/v1` with subprotocol `converger.v1` and `Authorization: Bearer`, `hello` with watermark, send turns with a `clientId` and wait for the `ack`, receive frames, typing, read receipts |
| Resume | watermark tracking, duplicates dropped, gaps answered with `sync`, `replayTruncated`, `replay_unavailable` and `invalid_watermark` handled, reconnect with jittered exponential backoff, unacked sends re-sent with their original `clientId`, protocol `ping` every `idleTimeoutMs / 2` |
| [Webhook signatures](../webhooks.md#verifying-the-signature) | `verify_signature(headers, raw_body, secret)` with constant-time comparison, a 300 s timestamp tolerance and secret lists for rotation |

The remaining REST endpoints (routing rules, deliveries and dead letters, uploads, channel delivery state) come
with generated clients once the OpenAPI document of [#45](https://github.com/AimTune/converger/issues/45) exists.

A socket gives up (no reconnect) on close codes 4400 (unsupported protocol), 4401 (unauthorized or token expired;
one retry when the SDK was given a token *function* that can return a fresh token), 4403 (channel inactive or
forced disconnect) and 1008 (conversation not found). On 1012 and 4503 it waits the `retryAfterMs` of the close
reason before reconnecting.

## Errors

A non-2xx response becomes one error type per SDK (`ApiError`, `*APIError`, `%ConvergerClient.Error{}`) with the
same fields whatever error body the server used: the standard envelope
`{"error": {"code", "message", "details", "request_id"}}` of [#45](https://github.com/AimTune/converger/issues/45)
and every legacy shape listed in the [REST overview](../api/overview.md#error-responses).

| Field | Source |
| --- | --- |
| `status` | HTTP status |
| `code` | `error.code` of the envelope or coded object; `error` when the body is `{"error": "<code>", "detail": "..."}` (for example `conversation_closed`); otherwise derived from the status: `bad_request`, `unauthorized`, `forbidden`, `not_found`, `not_acceptable`, `conflict`, `payload_too_large`, `unsupported_media_type`, `validation_failed` (422), `rate_limited`, `internal`, `bad_gateway`, `unavailable`, else `http_<status>` |
| `message` | `error.message`, `detail`, the flat `error` string, `errors.detail`, `"validation failed"` for changeset errors, or the start of a non-JSON body |
| `details` | `error.details`, or the changeset error map |
| `request_id` | `error.request_id`, else the `x-request-id` header |
| `retry_after` | the `Retry-After` header in seconds (rate limits) |

## Shared conformance suite

There is no separate specification repository: the language-neutral test data is in
[`packages/conformance`](https://github.com/AimTune/converger/tree/main/packages/conformance), and every SDK's test
suite runs all of it.

| File | Pins |
| --- | --- |
| `webhook-signatures.json` | Signature [test vectors](../webhooks.md#test-vectors): `sign` cases (secret, timestamp, body, header) and `verify` cases (headers, body, secret, fixed clock, tolerance, expected result or error). Generated from the server's signer; a server test fails when they disagree. |
| `errors.json` | The error normalization above, one case per error shape. |
| `rest.json` | For each operation: the HTTP request the SDK must send (method, path, query, headers, JSON body) and the fields it must read from the response. |
| `protocol.json` | The resume state machine: the `hello` frame, then a sequence of received frames with the frames the SDK must deliver, the frames it must send (`sync`), scheduled sends and the watermark after each step. |

The rules behind `protocol.json` and the signature algorithm are written out in the suite's
[README](https://github.com/AimTune/converger/blob/main/packages/conformance/README.md). Each SDK also tests its
transport against an in-process fake of the native endpoint (handshake, replay, reconnect and resume, re-sent
unacked sends, terminal 4401, token refresh after 4401).

## End-to-end test against a real server

[`packages/conformance/integration/run.sh`](https://github.com/AimTune/converger/blob/main/packages/conformance/integration/run.sh)
starts the server (`PHX_SERVER=true mix run --no-halt packages/conformance/integration/server.exs`), which creates,
for each SDK, a tenant, a `websocket` client channel and a `webhook` channel that receives the client channel's
activities through a routing rule and points at `http://127.0.0.1:<port>/webhook` (Python 47801, Go 47802, Elixir
47803). Each SDK's integration test then:

1. generates a token with the channel secret and creates a conversation,
2. connects the socket, sends a turn and checks its `ack`,
3. posts a bot reply through the tenant API and receives it on the socket with the expected `seq`,
4. reads the conversation back over REST and checks idempotency keys,
5. receives the webhook delivery and verifies its signature with the webhook channel's secret,
6. closes the conversation and checks the normalized `409 conversation_closed` error.

For the agent SDKs (`agent-python`) the server also creates a tenant with a `websocket` widget channel routed to a
`websocket` bot channel: the agent connects to the bot channel with its secret, and an end user on the widget channel
sends turns through the server and receives the agent's tool trace, stream, text, interrupt and, after its `resume`,
the answer.

```bash
docker compose up -d db
mix deps.get
DB_NAME=converger_sdk PORT=4047 packages/conformance/integration/run.sh            # all three
PYTHON_DOCKER=1 packages/conformance/integration/run.sh python                      # Python in Docker
PYTHON_DOCKER=1 packages/conformance/integration/run.sh agent-python                # the Python agent SDK
```

`DB_NAME` selects a separate database (created and migrated by the script). The fixtures file
(`packages/conformance/integration/fixtures.json`) and the server log are git-ignored. CI runs the same script in
the `SDKs` workflow.

## CI and releases

`.github/workflows/sdks.yml` runs on changes to `packages/`, `lib/` and `priv/protocol/`: Python 3.10 and 3.13,
Go 1.22 and stable (`gofmt`, `go vet`, `go test -race`), the Elixir client (format, warnings as errors, tests), the
Python agent SDK (3.10 and 3.13) and its `examples/agents/langchain-faq` example, then the end-to-end job above
against a Postgres service.

| SDK | Tag | Workflow | Publishes to |
| --- | --- | --- | --- |
| Python | `client-python/vX.Y.Z` | `sdk-python-release.yml` | PyPI, with trusted publishing (OIDC, `pypi` environment); no token is stored |
| Go | `packages/client-go/vX.Y.Z` (and `packages/agent-go/vX.Y.Z` for the agent SDK) | `sdk-go-release.yml` | Nothing to upload: the tag is the release. The workflow tests the commit, warms `proxy.golang.org` and creates a GitHub release |
| Elixir | `client-elixir/vX.Y.Z` | `sdk-elixir-release.yml` | Hex, with the `HEX_API_KEY` secret (`hex` environment) |
| Elixir agent | `agent-elixir/vX.Y.Z` | `agent-elixir-release.yml` | Hex (`converger_agent`), with the same `HEX_API_KEY` secret (`hex` environment) |
| Python agent | none: run manually (`workflow_dispatch`, `publish` checked) | `agent-sdk-python-release.yml` | PyPI (`converger-agent`), trusted publishing as above. Unchecked, it only builds and tests |
| .NET agent | none: run manually (`workflow_dispatch`, `dry_run` unchecked) | `agent-dotnet-publish.yml` | nuget.org (`Converger.Agent`), with nuget.org trusted publishing (OIDC, `NuGet/login`, the `NUGET_USER` variable); no key is stored. With `dry_run` it only builds, tests and packs |

Each release workflow first checks that the tag matches the version in the package (`_version.py`, `Version` in
`client.go`, `@version` in `mix.exs`). Every package is MIT licensed and carries the license file. The one-time registry setup and the whole release flow are
on [Releasing the SDKs](releasing.md).

## Generated types

The models are hand-written today, in the shape the generators produce, so they can be swapped without changing
callers. Once [#45](https://github.com/AimTune/converger/issues/45) ships `priv/static/openapi.json`:

- Python: `packages/client-python/scripts/generate_models.sh` (datamodel-code-generator, Pydantic v2) writes
  `converger/_generated.py`.
- Go: `packages/client-go/scripts/generate.sh` (oapi-codegen, `oapi-codegen.yaml`) writes `internal/gen`.
- Elixir: the structs stay hand-written and are checked against the document.

The conformance suite is what keeps the swap safe: it pins requests and parsed fields, not the model classes.
