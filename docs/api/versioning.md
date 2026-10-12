---
title: Versioning and deprecation policy
description: How the HTTP API is versioned, which changes are additive, how endpoints are deprecated with Deprecation and Sunset headers, and the 12-month support window.
sidebar_position: 7
---

This policy covers the HTTP API (`/api/v1/...`, described by the [OpenAPI document](openapi.md)). The WebSocket wire
protocol has its own, compatible rules in [Protocol v1, section 13](../protocol/v1.md#13-compatibility-and-deprecation).
Decided in [ADR-0050](../adr/0050-openapi-spec-error-envelope-and-api-versioning.md).

## The version is in the URL

Every route is under a major version: `/api/v1`. A **breaking change** ships under a new prefix (`/api/v2`), next to
the old one. Within a major version only additive changes are made, so a client written against `v1` keeps working.

## Additive changes (no new version)

These can ship in any release and never require a new prefix. Clients must tolerate them:

- new endpoints, new optional request fields, new optional query parameters, new headers;
- new response fields (ignore keys you do not know);
- new values of open enumerations, such as activity types, delivery statuses or `circuit_state` (handle unknown
  values gracefully);
- new [error codes](errors.md#error-codes) (treat an unknown code like its status class);
- looser validation (a limit raised, a field made optional).

## Breaking changes (new version)

- removing or renaming an endpoint, a field or an enumeration value;
- changing a field's type or meaning, or making an optional request field required;
- changing an HTTP status or an error code for an existing condition;
- stricter validation of input that used to be accepted;
- changing authentication requirements of an existing endpoint.

A security fix may tighten behaviour within a version when there is no safe alternative; it is called out in the
[changelog](https://github.com/AimTune/converger/blob/main/CHANGELOG.md).

## Deprecation and sunset

An endpoint (or a whole version) is retired in two steps:

1. **Deprecated.** It keeps working unchanged. Its responses carry the RFC 9745 header
   `Deprecation: @<unix time>` (since when) and `Link: <migration guide>; rel="deprecation"`, it is marked
   `deprecated: true` in the OpenAPI document, each use is logged and counted
   (`[:converger, :deprecated, :use]` telemetry), and the docs name the replacement.
2. **Sunset announced.** Once the removal date is decided, responses also carry the RFC 8594 header
   `Sunset: <HTTP-date>` and `Link: <...>; rel="sunset"`. After that date the endpoint may be removed.

**Support window:** a deprecated endpoint, and a previous major version after its successor ships, is supported for
at least **12 months** after the deprecation is announced; the `Sunset` date is never earlier than that.

Server code marks a deprecated endpoint with
[`ConvergerWeb.Plugs.Deprecated`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/deprecated.ex):

```elixir
plug ConvergerWeb.Plugs.Deprecated,
     [deprecated_at: ~U[2026-10-09 00:00:00Z],
      sunset_at: ~U[2027-10-09 00:00:00Z],
      link: "https://converger.aimtune.dev/api/migrating-from-legacy"]
     when action in [:create]
```

or `ConvergerWeb.Plugs.Deprecated.put_headers/2` when the decision is per request.

## Currently deprecated

| Surface | Deprecated since | Sunset | Replacement |
| --- | --- | --- | --- |
| `POST /api/v1/tokens` | 2026-10-09 ([#23](https://github.com/AimTune/converger/issues/23)) | not set | `POST /api/v1/converger/tokens/generate` |
| `x-channel-token` authentication (incl. `POST /api/v1/conversations`) | 2026-10-09 | not set | tenant API key, or a Converger token |
| legacy socket `/socket` | 2026-10-09 | not set | `/socket/converger` |

Details in [migrating from the legacy surfaces](migrating-from-legacy.md). The legacy surfaces were announced with a
minimum of two minor releases and six months; under this policy their `Sunset` date will be at least 12 months after
2026-10-09.

## Watching for changes

- The committed [`priv/static/openapi.json`](https://github.com/AimTune/converger/blob/main/priv/static/openapi.json)
  changes in the same pull request as the code; diff it between releases.
- Send the `Deprecation` and `Sunset` headers to your logs or metrics to find deprecated calls.
