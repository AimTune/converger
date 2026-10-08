---
title: "ADR-0023: Platform and dependency baseline (OTP 28.5, Elixir 1.19.5, LiveView, Oban 2.24, Req 0.7, LoggerJSON)"
sidebar_label: "0023 Platform baseline"
description: One pinned Elixir/OTP toolchain for development, CI and the Docker image, current Phoenix, LiveView, Oban and Req versions, LoggerJSON on the default handler, and a minimal bcrypt cost in tests.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#56](https://github.com/AimTune/converger/issues/56) |
| **Pull request** | [#91](https://github.com/AimTune/converger/pull/91), [#93](https://github.com/AimTune/converger/pull/93), [#104](https://github.com/AimTune/converger/pull/104), [#105](https://github.com/AimTune/converger/pull/105) |
| **Related** | [ADR-0010](0010-runtime-cors-and-opentelemetry-configuration.md), [ADR-0012](0012-secrets-at-rest-and-audit-redaction.md), [ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md), [ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md), [ADR-0021](0021-ci-quality-gates-and-lf-line-endings.md), [ADR-0022](0022-deployment-hardening.md) |

This ADR records the toolchain and the major library versions Converger is built on, why they were chosen before the larger refactors, and the configuration fixes that came with them. It is a baseline, not a freeze: Dependabot ([ADR-0021](0021-ci-quality-gates-and-lf-line-endings.md)) keeps proposing updates, and `CHANGELOG.md` records each decision.

## Context and problem statement

Several parts of the stack were old or inconsistent, and the planned work (UI modernization, rate limiting, protocol work) would have been built on APIs that were about to change:

- **Toolchain drift.** Development used Elixir 1.19 / OTP 28, while the Dockerfile built with `1.18.4-erlang-27.2`. Code that compiled and passed locally was shipped with a different compiler and VM, and Dialyzer findings differed by OTP version.
- **Client/server LiveView mismatch.** The server ran `phoenix_live_view` 1.0.18, but the admin and portal layouts loaded `phoenix_live_view.js` **0.20.17** and `phoenix.js` 1.7.14 from jsDelivr. Nothing detected the mismatch.
- **No job visibility.** Oban 2.20 had no dashboard; operators inspected `oban_jobs` with SQL.
- **Traces stopped at the job boundary.** There were no spans for Oban job execution or outbound Req calls.
- **Production logs were broken.** Found while testing [#90](https://github.com/AimTune/converger/pull/90): every log line in the prod image printed `FORMATTER CRASH`. `config/prod.exs` used LoggerJSON 5.x backend configuration (ignored by 6.x, so the redactors never ran) and `format: {LoggerJSON.Formatters.Basic, :format}` on `:default_formatter`, which made `Logger` call the formatter with the wrong arguments.
- **Req was behind** on 0.5.x; automatic decompression without a size limit (a decompression-bomb risk) is fixed only in Req 0.6.1 and later.
- **Flaky CI test.** `RateLimitingTest` "admin login lockout" sometimes got 302 instead of 429: seven bcrypt operations at the default cost of 12 could take more than the 5 s the test guarantees before its 60 s fixed window rolls over, so the five failures landed in two windows.

## Decision drivers

- One toolchain version everywhere (developer machines, CI, image), with a single file as the source.
- Upgrade low-risk dependencies early, before new code depends on old APIs.
- Detect drift automatically (CDN scripts vs. locked versions).
- Operators get job visibility without new services.
- Production logs must be structured JSON with secrets redacted.
- Avoid conflicts with the adapter PRs open at the time ([#82](https://github.com/AimTune/converger/pull/82), [#85](https://github.com/AimTune/converger/pull/85), [#87](https://github.com/AimTune/converger/pull/87)).
- Tests must be deterministic on slow CI runners.

## Considered options

1. **Upgrade in small, separately reviewable steps to current stable versions, pin the toolchain in `.tool-versions`, add drift tests**, deferring risky majors until their call sites have been reviewed.
2. **One big-bang upgrade of everything** (`mix deps.update --all`, including Req 0.7 and LiveView 1.2) in a single PR.
3. **Stay on the existing versions** and only fix the broken logger config.
4. **Track versions only in the Dockerfile** and let developers use whatever is installed.

### Pros and cons of the options

- **Option 1** - Good: each step is bisectable and has its own notes in `CHANGELOG.md`; risky majors (Req 0.7 changes GET-with-body to POST and replaces the plug/finch steps) get a dedicated review. Bad: several PRs and a temporary period on intermediate versions (LiveView 1.1 before 1.2).
- **Option 2** - Good: one migration. Bad: a failure is hard to attribute, and it would have conflicted with every open adapter PR.
- **Option 3** - Good: no risk now. Bad: the UI modernization needs LiveView 1.1+, Oban Web needs Oban 2.24, and the gap only grows.
- **Option 4** - Good: no extra file. Bad: exactly the drift that caused the problem.

## Decision

Chosen option: **option 1**. The resulting baseline:

| Component | Version | Notes |
| --- | --- | --- |
| Erlang/OTP | 28.5.0.5 | `.tool-versions`, Dockerfile `OTP_VERSION`, CI `OTP_VERSION` |
| Elixir | 1.19.5 (`1.19.5-otp-28`) | `mix.exs` requires `~> 1.18` |
| Base images | `hexpm/elixir:1.19.5-erlang-28.5.0.5-debian-bookworm-20260824-slim`, runner `debian:bookworm-20260824-slim` | |
| `phoenix` | 1.8.15 | CDN `phoenix.min.js` pinned to the same version |
| `phoenix_live_view` | 1.1.33 in [#91](https://github.com/AimTune/converger/pull/91), now 1.2.12 ([#104](https://github.com/AimTune/converger/pull/104)) | CDN `phoenix_live_view.min.js` pinned; `LiveViewTest` uses `lazy_html`, `floki` removed |
| `oban` / `oban_web` | 2.24.1 / 2.13.0 | `oban_jobs` schema migrated v12 to v14 |
| `opentelemetry_oban` / `opentelemetry_req` | 1.2 / 1.0 | job spans; Req spans through `Converger.HTTP` |
| `req` | 0.7.5 (`~> 0.7`) | decompression-bomb fix (>= 0.6.1); webhook custom methods limited to POST/PUT/PATCH |
| `bandit` / `broadway` | 1.12.5 / 1.3.0 | latest minors |
| `hammer` | 7.5.0 | new API, decided in [ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md) |
| `logger_json` | 7.0.4 | formatter on `:default_handler` |
| `gettext`, `dns_cluster`, `joken`, `telemetry_metrics` | 1.0.2, 0.3.1, 2.7.0, 1.2.0 | Dependabot batch in [#104](https://github.com/AimTune/converger/pull/104) |

Specific choices and their reasons:

- **Oban Web** is Apache-2.0 and free on hex.pm since Oban 2.19, so job visibility costs no new service. It is mounted at `/admin/oban` in a non-aliased `/admin` scope with the same `:browser, :admin_auth, :admin_session, :require_admin` pipelines and the `ensure_admin_user` on_mount hook as the admin panel. `ConvergerWeb.ObanResolver` maps roles: `super_admin` and `admin` get full access, `viewer` read-only, anyone else is sent to `/admin/login`.
- **CDN pinning plus a test.** The app has no JS bundler, so the layouts load Phoenix and LiveView from jsDelivr. `layouts_js_version_test.exs` fails when the pinned script versions differ from `mix.lock`. The `:phoenix_live_view` compiler for colocated hooks is not enabled because there is no bundler to pick them up.
- **Req 0.7 deferred, then applied.** [#91](https://github.com/AimTune/converger/pull/91) held Req at `~> 0.5.17` because 0.6 removed automatic decompression and 0.7 changed method and step semantics, which needed a review of the webhook adapter and its `Req.Test` stubs. After that review it moved to `~> 0.7` (0.7.5) for the decompression-bomb fix; `CHANGELOG.md` records it.
- **LoggerJSON on the default handler** ([#93](https://github.com/AimTune/converger/pull/93)), as LoggerJSON 6+ documents: `config :logger, :default_handler, formatter: {LoggerJSON.Formatters.Basic, metadata: :all, redactors: [{LoggerJSON.Redactors.RedactKeys, [...]}]}`. The redacted keys are `api_key`, `secret`, `token`, `password`, `access_token`, `app_secret`, `verify_token`, `x-api-key`, `x-channel-token` and `authorization`. The 7.x upgrade kept this configuration unchanged.
- **Minimal bcrypt cost in tests** ([#105](https://github.com/AimTune/converger/pull/105)): `config :bcrypt_elixir, :log_rounds, 1` in `config/test.exs`, as `phx.gen.auth` does. Hashing strength is irrelevant in tests and timing must be predictable; production keeps the library default.

## Consequences

### Positive

- The same compiler and VM in development, CI and production; `.tool-versions` is the single reference (the CI `env` block and Dockerfile `ARG`s say "keep in sync").
- Server and browser LiveView versions cannot drift silently.
- Operators can inspect, retry and cancel jobs at `/admin/oban` with role-based access.
- Oban jobs and Req calls appear in traces when OpenTelemetry export is enabled ([ADR-0010](0010-runtime-cors-and-opentelemetry-configuration.md)).
- Production logs are valid JSON with secrets redacted.
- The lockout test no longer flakes.

### Negative and trade-offs

- **Deploy ordering**: Oban 2.24 refuses to start on the v12 `oban_jobs` schema, so migration `20261009131000` must run before the new release starts ([ADR-0022](0022-deployment-hardening.md)). The v13/v14 migrations only add, so old nodes keep working during a rolling deploy.
- After the deploy, browsers must reload `/admin` and `/portal` to fetch the new LiveView JS.
- Loading JS from a CDN is a third-party dependency for the admin UI and needs a CSP allowance for jsDelivr ([ADR-0021](0021-ci-quality-gates-and-lf-line-endings.md)).
- Only the tenant alert webhook (`Channels.Health`) uses `Converger.HTTP` so far; channel adapters still call Req directly and produce no Req spans.
- `config/prod.exs` is not loaded in tests, so the logger configuration is verified manually, not by the suite.
- Three version declarations (`.tool-versions`, Dockerfile, CI) must be bumped together; nothing enforces it yet.
- The test bcrypt cost makes test hashes worthless outside tests, which is intended.

### Follow-ups

- Move channel adapters to `Converger.HTTP` for end-to-end traces: delivery telemetry in [#33](https://github.com/AimTune/converger/issues/33).
- UI modernization with a bundler (enables colocated hooks): [#50](https://github.com/AimTune/converger/issues/50).
- Windows setup for `bcrypt_elixir` (needs MSVC `nmake`): [#53](https://github.com/AimTune/converger/issues/53).
- Changelog and release hygiene: [#48](https://github.com/AimTune/converger/issues/48).

## Implementation

- Toolchain: [`.tool-versions`](https://github.com/AimTune/converger/blob/main/.tool-versions), [`Dockerfile`](https://github.com/AimTune/converger/blob/main/Dockerfile), the `env` block of [`.github/workflows/ci.yml`](https://github.com/AimTune/converger/blob/main/.github/workflows/ci.yml).
- Dependencies: [`mix.exs`](https://github.com/AimTune/converger/blob/main/mix.exs), [`mix.lock`](https://github.com/AimTune/converger/blob/main/mix.lock); decisions in [`CHANGELOG.md`](https://github.com/AimTune/converger/blob/main/CHANGELOG.md).
- Oban: migration [`20261009131000_upgrade_oban_jobs_to_v14`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261009131000_upgrade_oban_jobs_to_v14.exs); `oban_dashboard("/oban", ...)` in [`router.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/router.ex); [`ConvergerWeb.ObanResolver`](https://github.com/AimTune/converger/blob/main/lib/converger_web/oban_resolver.ex); `OpentelemetryOban.setup()` in [`Converger.Application`](https://github.com/AimTune/converger/blob/main/lib/converger/application.ex).
- [`Converger.HTTP`](https://github.com/AimTune/converger/blob/main/lib/converger/http.ex): `Req.new |> OpentelemetryReq.attach |> Req.request`, with `propagate_trace_headers` for tenant webhooks.
- Logging: [`config/prod.exs`](https://github.com/AimTune/converger/blob/main/config/prod.exs). Test bcrypt cost: [`config/test.exs`](https://github.com/AimTune/converger/blob/main/config/test.exs).

Tests: [`test/converger_web/oban_dashboard_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/oban_dashboard_test.exs) (session required, IP whitelist 403, admin reaches the dashboard mount, role mapping), [`test/converger_web/components/layouts_js_version_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/components/layouts_js_version_test.exs), [`test/converger/http_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/http_test.exs) and [`test/converger_web/controllers/rate_limiting_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/rate_limiting_test.exs). Oban runs `testing: :inline` in tests, which does not start `Oban.Met`, so the dashboard test asserts that the request reaches the mount rather than a full render.

## Links

- Issue [#56](https://github.com/AimTune/converger/issues/56); pull requests [#91](https://github.com/AimTune/converger/pull/91), [#93](https://github.com/AimTune/converger/pull/93), [#104](https://github.com/AimTune/converger/pull/104), [#105](https://github.com/AimTune/converger/pull/105)
- Epic [#57](https://github.com/AimTune/converger/issues/57) (v2.5 production hardening)
- [Oban Web](https://hexdocs.pm/oban_web), [LoggerJSON](https://hexdocs.pm/logger_json)
