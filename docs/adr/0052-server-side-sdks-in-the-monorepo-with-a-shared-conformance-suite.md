---
title: "ADR-0052: Server-side SDKs in the monorepo, a shared conformance suite and signature vectors generated from the server"
sidebar_label: "0052 Server-side SDKs"
description: The Python, Go and Elixir SDKs live in packages/ of the server repository, share a language-neutral conformance suite (REST, errors, protocol resume, webhook signature vectors generated from the server's signer), hand-write generator-shaped models until the OpenAPI document exists, and release from per-language tags.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-12 |
| **Issue** | [#47](https://github.com/AimTune/converger/issues/47) |
| **Pull request** | [#144](https://github.com/AimTune/converger/pull/144) |
| **Related** | [ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md), [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md), [ADR-0030](0030-native-websocket-endpoint-and-fallback-transports.md), [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md) |

## Context and problem statement

Backend integrators (bot runtimes, CRMs) talk to Converger from Python, Go and Elixir. Each of them re-implemented
the same three things by hand from the docs: the REST calls, the Protocol v1 socket with resume, and the
verification of outbound webhook signatures 46](https://github.com/AimTune/converger/issues/46),
ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md)). The last
one is the dangerous one: a verifier that differs from the signer in a detail (header parsing, timestamp boundary,
case of the hex digest, raw versus re-serialized body) either rejects genuine deliveries or, worse, accepts forged
ones.

Issue [#47](https://github.com/AimTune/converger/issues/47) asks for SDKs in the three languages, a signature
helper verified against documented test vectors, conformance tests shared with the protocol work, and release
automation. Two inputs did not exist yet: the OpenAPI document and standard error envelope of
[#45](https://github.com/AimTune/converger/issues/45), and the separate "spec repository" the issue mentions for
the conformance suite. The TypeScript SDK ([#46](https://github.com/AimTune/converger/issues/46), ADR-0051) was
being built at the same time.

## Decision drivers

- A signature verifier must agree with the server's signer byte for byte, and must keep agreeing when the signer
  changes.
- One behaviour (watermark resume, error mapping) must not drift between four SDKs.
- Server changes that affect clients should be caught in the same pull request.
- The SDKs must be usable before #45 lands, and switch to generated types without breaking callers.
- No publishing credentials stored where avoidable.

## Considered options

1. **SDKs in `packages/` of this repository, with a language-neutral conformance suite in `packages/conformance`**
   that every SDK runs, signature vectors generated from the server's signer.
2. **One repository per SDK** (`converger-python`, `converger-go`, `converger_client`) plus a spec repository with
   the conformance suite.
3. **Generate everything from a spec** (OpenAPI generators for REST, no hand-written socket client) and wait for #45.

### Pros and cons of the options

**Option 1: monorepo packages and an in-repo conformance suite**

- Good: the server test that pins the signature vectors and the SDK tests that consume them run on the same commit;
  a signer change cannot merge without regenerated vectors and passing SDKs.
- Good: the end-to-end test starts the real server from the same checkout, so CI tests the SDKs against the code
  they ship with.
- Good: no cross-repository versioning of the suite.
- Bad: Go modules in a subdirectory need prefixed tags (`packages/client-go/vX.Y.Z`) and a long import path.
- Bad: language toolchains (Python, Go, a second mix project) in one repository and one CI.

**Option 2: one repository per SDK**

- Good: idiomatic layout and short import paths per ecosystem.
- Bad: the conformance suite and the vectors must be versioned and vendored into four repositories; drift is
  detected late, after a server release.
- Bad: four places to change for one protocol change.

**Option 3: generate everything**

- Good: least hand-written code.
- Bad: blocked on #45; generators do not produce a resuming WebSocket client or a signature verifier, which are
  the parts integrators get wrong.

## Decision

Chosen option: **"SDKs in `packages/` with a shared in-repo conformance suite"**, because it is the only option in
which a change to the signer, the protocol or the REST shapes fails the SDK tests in the same pull request.

- **Layout**: `packages/client-python` (PyPI `converger`, `httpx` sync and async, Pydantic v2, `websockets`),
  `packages/client-go` (module `github.com/AimTune/converger/packages/client-go`, `github.com/coder/websocket`,
  the maintained successor of `nhooyr.io/websocket`), `packages/client-elixir` (Hex `converger_client`, `Req`,
  `Mint.WebSocket`; the server has no frame structs to share, frames are maps validated by the JSON Schemas).
- **Conformance suite** (`packages/conformance`): `webhook-signatures.json`, `errors.json`, `rest.json`,
  `protocol.json` and the rules in its README. Each SDK's own test suite loads the files from the checkout.
- **Signature vectors from the server**: `scripts/generate_signature_vectors.exs` builds the vectors by calling
  `Converger.Channels.InboundSignature.sign/3`, the function the webhook adapter uses;
  `test/converger/channels/webhook_signature_vectors_test.exs` asserts that the signer still produces every `sign`
  vector and that the documented vector in `docs/webhooks.md` is the first one. `verify` vectors fix the clock, so
  boundary, rotation and malformed cases are deterministic. The verifiers reject the legacy `sha256=` form, which
  outbound webhooks never send, and compare the hex digest as sent, like the server.
- **Protocol resume as a pure state machine** in every SDK (`Session`): the transport feeds it frames and executes
  what it returns (deliver, send now, send later). `protocol.json` tests it without sockets; each SDK separately
  tests its transport against an in-process fake of the native endpoint. Own sends are acked without an echo, so
  acked seqs above the watermark are remembered and absorbed instead of being treated as gaps; `heartbeat.headSeq`
  detects a lost tail.
- **Errors**: one error type per SDK with `status`, `code`, `message`, `details`, `request_id`, `retry_after`,
  mapped from the #45 envelope and every legacy shape by the rules in `errors.json`.
- **Types until #45**: hand-written models in the shape the generators produce (snake_case fields with wire
  aliases), plus generator configuration (`datamodel-code-generator` for Python, `oapi-codegen` for Go), checked
  against a sample document. The conformance suite pins requests and parsed fields, not classes, so the swap is
  safe.
- **End-to-end test**: `packages/conformance/integration/run.sh` starts the server with fixtures for each SDK (a
  client channel and a signed webhook channel routed from it) and runs each SDK's integration test: create a
  conversation, send over the socket, receive a bot reply with the right seq, verify a real webhook delivery.
- **Releases**: per-language tags (`client-python/v*`, `packages/client-go/v*`, `client-elixir/v*`), each workflow
  checks that the tag matches the package version. PyPI uses trusted publishing (OIDC), Go needs only the tag,
  Hex uses an environment secret.

## Consequences

### Positive

- Integrators get a verifier that is tested against the server's own signer, in four languages, on every change.
- Resume behaviour is specified once, as data, and every SDK (including future ones) can prove it follows it.
- A server change that breaks an SDK fails CI in the pull request that makes it (the `SDKs` workflow runs on
  `lib/**` changes).

### Negative and trade-offs

- The Go import path is long and Go tags carry the directory prefix.
- CI is broader: Python, Go and a second mix project, and an end-to-end job that compiles the server in dev mode.
- REST coverage is the conversation and activity surface (client and tenant APIs); routing rules, deliveries,
  uploads and channel controls wait for generated clients.
- The Elixir package cannot be published to Hex until a license is added to its metadata; the project license is a
  maintainer decision.
- The Python socket client is async only.

### Follow-ups

- [#45](https://github.com/AimTune/converger/issues/45): run the generators against `priv/static/openapi.json`,
  alias the hand-written models to the generated ones, and extend `rest.json` to the remaining endpoints.
- [#64](https://github.com/AimTune/converger/issues/64) / [#67](https://github.com/AimTune/converger/issues/67):
  channel-scoped sockets (`{conversationId, frame}` envelopes, `hello.watermarks`) for agent and bot backends.
- [#49](https://github.com/AimTune/converger/issues/49): platform event webhooks reuse the signature scheme, so the
  same verifiers and vectors apply.

## Implementation

- Conformance suite: [`packages/conformance`](https://github.com/AimTune/converger/tree/main/packages/conformance)
  (vector generator in `scripts/`, end-to-end runner and fixtures in `integration/`).
- Server test: [`test/converger/channels/webhook_signature_vectors_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/channels/webhook_signature_vectors_test.exs).
- SDKs: [`packages/client-python`](https://github.com/AimTune/converger/tree/main/packages/client-python),
  [`packages/client-go`](https://github.com/AimTune/converger/tree/main/packages/client-go),
  [`packages/client-elixir`](https://github.com/AimTune/converger/tree/main/packages/client-elixir).
- CI: `.github/workflows/sdks.yml`; releases: `sdk-python-release.yml`, `sdk-go-release.yml`,
  `sdk-elixir-release.yml`.

## Links

- [Server-side SDKs](../sdk/server-sdks.md), [Python](../sdk/python.md), [Go](../sdk/go.md), [Elixir](../sdk/elixir.md)
- [Outbound webhooks: verifying the signature](../webhooks.md#verifying-the-signature)
- [Converger Protocol v1](../protocol/v1.md)
