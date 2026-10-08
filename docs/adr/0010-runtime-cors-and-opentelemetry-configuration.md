---
title: "ADR-0010: CORS origins and OpenTelemetry export are configured at runtime"
sidebar_label: "0010 Runtime CORS and OTel"
description: CORS origins are resolved per request from application env, and OTLP trace export is enabled only when the standard OTEL_* endpoint variables are set.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#10](https://github.com/AimTune/converger/issues/10) |
| **Pull request** | [#76](https://github.com/AimTune/converger/pull/76) |
| **Related** | [ADR-0011](0011-custom-trusted-proxies-plug.md), [ADR-0022](0022-deployment-hardening.md) |

Converger ships as an Elixir release that is built once and configured per environment through environment variables read by `config/runtime.exs`. This ADR records two settings that silently ignored that rule (browser CORS origins and the OpenTelemetry exporter endpoint) and the general principle adopted to fix them: anything an operator sets per deployment must be read at runtime, never baked in at compile time.

## Context and problem statement

Two production settings did not work in a release:

- **CORS**: `ConvergerWeb.Endpoint` configured `CORSPlug` with `Application.compile_env(:converger, :cors_origins, ...)`. `config/runtime.exs` did set `:cors_origins` from `CORS_ORIGINS`, but compile-time config is fixed when the release is built. Production builds therefore always allowed only the two localhost development origins (`http://127.0.0.1:5500`, `http://localhost:5500`). Browser clients on any real domain were blocked by the preflight, and setting `CORS_ORIGINS` had no visible effect.
- **OpenTelemetry**: `config/config.exs` hardcoded the OTLP exporter endpoint to `http://localhost:4318`, and `prod.exs` did not override it. In production, traces were exported to a port where nothing listened, so they went nowhere, while the exporter still tried to connect. Inside `docker-compose.yml` the bundled collector was reachable at `otel-collector:4318`, not at `localhost`, so even the demo stack lost its traces. The standard `OTEL_EXPORTER_OTLP_ENDPOINT` variable was not honored.

Both bugs share a root cause: values that vary per deployment were resolved at build time.

## Decision drivers

- One release artifact must work in every environment; changing an env var must not require a rebuild.
- Standard tooling conventions should apply (the OpenTelemetry `OTEL_*` variables are understood by operators and by hosted collectors).
- No export attempts, connection errors or log noise when tracing is not configured.
- The endpoint plug pipeline is compiled with `plug_init_mode: :compile` in prod, so any runtime hook must be compatible with that.
- Every supported env var must be documented in one place.

## Considered options

1. **Resolve CORS origins per request through a function, and configure the OTLP exporter in `runtime.exs` from the standard `OTEL_*` variables** (export off by default).
2. **Keep compile-time config and require a rebuild per environment** - document that `CORS_ORIGINS` must be set at build time.
3. **Read CORS origins once at boot** (for example in `init/1` with `plug_init_mode: :runtime`, or into `:persistent_term`).
4. **Custom env vars for tracing** (for example `CONVERGER_OTEL_ENDPOINT`) and keep the localhost default.

### Pros and cons of the options

**Option 1: per-request origin function, standard OTEL_* in runtime.exs**

- Good: `cors_plug` 3.x accepts a 0- or 1-arity function for `:origin`; an external function capture survives `plug_init_mode: :compile`.
- Good: origins can even be changed on a running node (`Application.put_env/3`), which also makes the behavior testable.
- Good: the OTLP exporter and the SDK already read the remaining `OTEL_*` variables natively, so Converger only has to decide whether export is on.
- Good: no exporter is started when no endpoint is set.
- Bad: one `Application.get_env/3` call per request (an ETS read; negligible).

**Option 2: compile-time config, rebuild per environment**

- Good: no code change.
- Bad: contradicts the release model and the documented `CORS_ORIGINS` variable.
- Bad: container images could not be promoted from staging to production unchanged.

**Option 3: read once at boot**

- Good: no per-request lookup.
- Bad: `plug_init_mode: :runtime` changes the whole endpoint pipeline for one option; a boot-time cache needs its own invalidation and makes tests stateful.
- Bad: no practical gain over an ETS read per request.

**Option 4: custom tracing env vars**

- Good: full control over naming.
- Bad: operators and hosted collectors expect `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_HEADERS` and friends; duplicating them invites drift.
- Bad: keeping `localhost:4318` as the default still exports into the void in production.

## Decision

Chosen option: **"Per-request CORS origin function and standard OTEL_* configuration in runtime.exs"**, because it fixes both bugs with the least new surface, follows established conventions, and works with the prod plug compilation mode.

Details:

- `ConvergerWeb.Endpoint` plugs `CORSPlug` with `origin: &__MODULE__.cors_origins/0`. `cors_origins/0` returns `Application.get_env(:converger, :cors_origins, [])` on every request. `config/runtime.exs` parses `CORS_ORIGINS` as a comma-separated list, trims whitespace and drops empty entries. A `*` entry is supported by `cors_plug` as a wildcard.
- `config/config.exs` sets `traces_exporter: :none` and the service name `converger`. `config/runtime.exs` switches to `{:opentelemetry_exporter, %{}}` only when `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` or `OTEL_EXPORTER_OTLP_ENDPOINT` is set to a non-blank value, and never in the test environment. Dev follows the same rule: it does not export by default and opts in with `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318`.
- Protocol, headers, compression, service name, resource attributes and `OTEL_SDK_DISABLED` are left to `opentelemetry_exporter` and the SDK, which read the standard variables themselves.
- `docker-compose.yml` sets `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318` for the `app` service so the bundled collector receives traces.
- [`docs/deployment.md`](../deployment.md) became the single reference for every env var that `runtime.exs` reads.

## Consequences

### Positive

- Setting `CORS_ORIGINS` on a release changes `Access-Control-Allow-Origin` without recompiling.
- Production nodes no longer attempt OTLP export to a non-existent localhost collector; tracing is opt-in and uses the standard variables.
- Hosted collectors that need auth headers or gRPC work with no Converger-specific code (`OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_PROTOCOL`).
- The "runtime, not compile time" rule set here was reused for trusted proxies ([ADR-0011](0011-custom-trusted-proxies-plug.md)), the admin whitelist and the HTTPS/origin settings ([ADR-0022](0022-deployment-hardening.md)).

### Negative and trade-offs

- **Behavior change for dev**: traces are no longer exported by default in development; developers who relied on the localhost collector must set `OTEL_EXPORTER_OTLP_ENDPOINT`.
- CORS origins are still a single global list; there is no per-tenant origin allowlist.
- CORS only governs browser HTTP requests. WebSocket origin checks are a separate setting (`check_origin`, see [ADR-0022](0022-deployment-hardening.md)), so operators have to configure both.
- A misconfigured `CORS_ORIGINS` fails closed (browsers blocked) with no server-side error, which can be confusing to debug.

### Follow-ups

- [#33](https://github.com/AimTune/converger/issues/33): delivery and pipeline telemetry, dashboards and alert rules on top of the trace and metric export.
- [#48](https://github.com/AimTune/converger/issues/48): documentation site, which publishes the env var reference.

## Implementation

- Endpoint: [`lib/converger_web/endpoint.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/endpoint.ex) (`plug CORSPlug, origin: &__MODULE__.cors_origins/0, ...` and `cors_origins/0`). Allowed request headers include `x-channel-token`, `x-api-key` and `authorization` on top of the `cors_plug` defaults.
- Defaults: [`config/config.exs`](https://github.com/AimTune/converger/blob/main/config/config.exs) (`cors_origins`, `config :opentelemetry, resource: ..., traces_exporter: :none`).
- Runtime: [`config/runtime.exs`](https://github.com/AimTune/converger/blob/main/config/runtime.exs) (`CORS_ORIGINS` parsing; OTLP exporter switch on `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` / `OTEL_EXPORTER_OTLP_ENDPOINT`).
- Test env: [`config/test.exs`](https://github.com/AimTune/converger/blob/main/config/test.exs) forces `traces_exporter: :none`.
- Instrumentation libraries (unchanged by this ADR): `opentelemetry_phoenix`, `opentelemetry_ecto`, `opentelemetry_oban`, `opentelemetry_req`.

| Variable | Default | Effect |
| --- | --- | --- |
| `CORS_ORIGINS` | `http://127.0.0.1:5500,http://localhost:5500` | Comma-separated allowed browser origins, resolved per request. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | Enables OTLP trace export to this base URL. |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | unset | Full traces URL; takes precedence and also enables export. |
| `OTEL_SERVICE_NAME` | `converger` | Service name on every span (read by the SDK). |
| `OTEL_SDK_DISABLED` | `false` | Disables the SDK entirely (read by the SDK). |

Tests: [`test/converger_web/endpoint_cors_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/endpoint_cors_test.exs) changes `:cors_origins` at runtime and checks an OPTIONS preflight (with `Origin` and `Access-Control-Request-Method`), a normal request, and the `*` wildcard. The OTEL switch was verified with `Config.Reader.read!/2` on `config/runtime.exs` for the unset, set and test cases.

## Links

- Issue [#10](https://github.com/AimTune/converger/issues/10), pull request [#76](https://github.com/AimTune/converger/pull/76)
- [Deployment and environment variables](../deployment.md)
