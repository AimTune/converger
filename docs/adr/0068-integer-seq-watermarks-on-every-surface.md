---
title: "ADR-0068: The watermark is the integer seq on REST and every v1 surface"
sidebar_label: "0068 Integer seq watermarks"
description: The Converger REST API, the tenant API and every Protocol v1 surface emit the integer seq as the watermark; inputs accept the integer, its decimal string and the pre-v1 opaque forms for one release, reported as a deprecated surface; only the legacy Phoenix activitySet keeps the opaque string.
---

| | |
| --- | --- |
| **Status** | Proposed |
| **Date** | 2026-10-14 |
| **Issue** | [#63](https://github.com/AimTune/converger/issues/63) |
| **Pull request** | (this PR) |
| **Related** | [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md) (its opaque-watermark part is superseded), [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md), [ADR-0050](0050-openapi-spec-error-envelope-and-api-versioning.md), [ADR-0052](0052-server-side-sdks-in-the-monorepo-with-a-shared-conformance-suite.md) |

## Context and problem statement

[ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md) made the client-facing watermark an
opaque token: URL-safe Base64 of `seq:<n>`. [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md)
then defined Converger Protocol v1 as a superset of mekik/1, where the watermark is the integer
`seq` itself, and planned the migration in section 6.5 of the [spec](../protocol/v1.md#65-the-watermark-and-its-migration):
v3.0 emits the integer in every v1 frame and in REST `activitySet.watermark`, keeps the string on
the legacy Phoenix `activitySet`, and accepts every form for one release.

The v1 frames (native WebSocket, gRPC, SSE) already carried integers. REST still returned the
opaque string, so a client that read history over REST and resumed over a v1 socket had to convert
between two encodings of the same number (every SDK shipped a decoder for it). The tenant API
(`meta.watermark` of `GET /api/v1/conversations/:id/activities`) used the same opaque form and the
section 6.5 table did not mention it.

## Decision drivers

- One watermark encoding across REST, v1 frames, SSE and gRPC, identical to mekik/1.
- No client breaks during the window: a stored opaque watermark must keep working.
- Operators need to find the clients still sending opaque watermarks before the forms are dropped.
- The legacy Phoenix binding is frozen until it is removed; changing its payloads now helps no one.

## Considered options

1. **Integer on REST (Converger and tenant API) and v1, string on the legacy Phoenix binding;
   every input accepts all forms, opaque ones reported as deprecated**
2. **Integer on the Converger REST API only, tenant API unchanged**
3. **Emit both** (`watermark` integer plus a `legacyWatermark` string) during the window

### Pros and cons of the options

#### Option 1

- Good, because a single type (`integer`) describes the watermark in the whole OpenAPI document
  except the legacy binding, and the migration ends with "integer everywhere" for every surface.
- Good, because clients that pass the watermark back unchanged keep working: the server accepts
  what it used to emit.
- Bad, because typed clients that declared the field as a string must widen it (a breaking change
  for strict deserialisers, acceptable in the v3.0 major release).

#### Option 2

- Good, because tenant integrations see no change now.
- Bad, because the tenant API would then need its own migration later, and the two APIs would
  disagree on the type of the same position.

#### Option 3

- Good, because no deserialiser breaks.
- Bad, because it doubles the field, and the string would have to be removed again one release
  later, which is the same break, deferred.

## Decision

Chosen option: **"Option 1"**, because it reaches the end state of section 6.5 for every surface
in one step, without breaking clients that treat the watermark as a token to hand back.

- **Emitted**: the integer seq of the last activity served, a JSON number, in
  `activitySet.watermark` (`GET /api/v1/converger/conversations/:id/activities`, both directions
  and `format=frames`), in `meta.watermark` of the tenant API, and (as before) in every v1 frame.
  On an empty page the server returns the position the client sent, as an integer whatever form it
  came in (a legacy activity-id watermark is resolved to that activity's seq); `null` without one.
- **Legacy Phoenix binding** (`/socket/converger`, `ConvergerChannel`): `activitySet.watermark`,
  the `postActivity` reply and the `replay_unavailable` error keep the opaque string for one
  release. Its join payload, `ack` and `read` accept the integer as well.
- **Accepted** on every input (`ConvergerWeb.Protocol.parse_watermark/2`): the integer, its
  decimal string, base64url of `seq:<n>` and the base64url legacy activity UUID.
- **Deprecation**: an opaque watermark sent to a surface that emits integers (Converger REST,
  tenant API, v1 `hello` / `sync` / `hello.watermarks`, SSE) logs a warning and emits
  `[:converger, :deprecated, :use]` with `surface: :opaque_watermark` and `api:` (`:converger`,
  `:tenant`, `:protocol`, `:sse`). No `Deprecation` response header: the endpoint itself is not
  deprecated. The legacy Phoenix binding does not report it, because it still emits the string.
- **OpenAPI**: response `watermark` fields are `integer`, nullable; `watermark` query parameters
  are `oneOf` integer or string (the string branch marked deprecated).

## Consequences

### Positive

- REST and socket positions are the same number: a client can resume a v1 socket from a REST page
  and page REST from a v1 frame without decoding anything.
- The section 6.5 end state ("integer only") is now a pure removal of input forms.

### Negative and trade-offs

- **Breaking for typed clients**: SDKs and integrations that declared `watermark` as a string must
  accept a number. The SDKs in `packages/` accept both and pass the value back unchanged.
- A client of the legacy Phoenix binding that pages the rest of a truncated replay over REST sends
  the binding's opaque watermark, which is reported as deprecated although the server issued it.
  The binding is itself deprecated, so the report still points at a client to migrate.

### Follow-ups

- The release that drops the opaque input forms (and switches the legacy Phoenix binding to the
  integer, or removes it) is announced in the changelog one release ahead.

## Implementation

- `ConvergerWeb.Protocol.parse_watermark/2` (accepts every form; `deprecation:` reports opaque
  ones) and `watermark_seq/2` (the integer for an empty page).
- `ConvergerWeb.ConvergerAPI.ActivityController` and `ConvergerWeb.ActivityController` emit the
  integer; `ConvergerWeb.Deprecation` has the `:opaque_watermark` surface.
- `ConvergerWeb.ConvergerChannel` and `ConvergerWeb.ConversationSignals` parse inputs with
  `parse_watermark/2`; `Converger.ConvergerAPI.Watermark.encode/1` is used only by the legacy
  binding.
- Tests: `test/converger_web/pagination_api_test.exs` (integer emitted on both REST APIs, the three
  input forms, deprecation telemetry, legacy `activitySet` unchanged),
  `test/converger_web/protocol_socket_test.exs`, `test/converger_web/controllers/event_stream_controller_test.exs`,
  and the shared REST conformance cases in `packages/conformance/rest.json`.

## Links

- [Protocol v1, section 6.5](../protocol/v1.md#65-the-watermark-and-its-migration)
- [Client API: activities](../api/client-api.md)
- [API overview: watermark pagination](../api/overview.md)
