---
title: "ADR-0021: CI quality gates and LF line endings"
sidebar_label: "0021 CI quality gates"
description: Every push and pull request runs format, warnings-as-errors compilation, Credo, Dialyzer, Sobelow, dependency audits, tests with coverage and a Docker build, and the repository enforces LF line endings.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#54](https://github.com/AimTune/converger/issues/54) |
| **Pull request** | [#92](https://github.com/AimTune/converger/pull/92) |
| **Related** | [ADR-0022](0022-deployment-hardening.md), [ADR-0023](0023-platform-and-dependency-baseline.md), [ADR-0025](0025-docusaurus-site-and-docs-with-every-change.md) |

This ADR records which automated checks gate a change to Converger, where they run, how a pre-existing codebase was brought to a clean baseline, and why the repository pins LF line endings.

## Context and problem statement

There was no `.github/workflows/` directory. Nothing ran the test suite on push or pull request, there was no static analysis, no dependency vulnerability scanning and no check that the Docker image still built. `mix precommit` existed as an alias but was enforced only by convention, and it contained a typo (`--warning-as-errors`) that meant it never actually failed on warnings.

The tree was also not clean enough to turn the gates on: it had two compile warnings (in `Adapter.parse_status_update/2`) and about a dozen test-compile warnings, so `--warnings-as-errors` would have failed on day one.

Separately, Windows contributors with `core.autocrlf=true` checked the tree out with CRLF line endings. The index was LF, but working copies were not, which made Credo's line-ending check and `mix format` noisy and produced CRLF-only diffs.

A security-sensitive, multi-tenant message hub with "zero data loss" as its core promise cannot rely on reviewers to notice a new compiler warning, a vulnerable transitive dependency or a broken Dockerfile.

## Decision drivers

- A pull request that introduces a compiler warning must fail.
- The same checks run locally (`mix precommit`) and in CI, so CI failures are reproducible.
- Security findings (Sobelow, `deps.audit`, retired Hex packages, image CVEs) are surfaced automatically.
- Slow checks must not make the feedback loop unbearable (Dialyzer PLTs are expensive).
- Turning the gates on must not create merge conflicts with the ten pull requests in flight at the time (#79 to #88).
- Consistent formatting results on Windows and Linux.

## Considered options

1. **GitHub Actions with separate lint, Dialyzer, test and Docker jobs, strict gates, and a per-check Credo baseline for in-flight files.**
2. **A single job running `mix precommit`.**
3. **Advisory-only checks** (report findings, never fail) until the code is cleaned up.
4. **A third-party CI service** (CircleCI, Buildkite) or a hosted code-quality service.

### Pros and cons of the options

**Option 1: parallel jobs, strict gates**

- Good: lint, Dialyzer and tests run in parallel; a format error is reported in about a minute instead of after the full suite.
- Good: each job is a named required check that branch protection can require.
- Good: the Dialyzer PLT gets its own cache keyed on Elixir/OTP and `mix.lock`.
- Bad: setup steps (checkout, BEAM, deps cache) are repeated per job.

**Option 2: one job running `precommit`**

- Good: exactly mirrors local runs.
- Bad: serial and slow; `precommit` auto-fixes formatting rather than checking it, so it cannot be used unchanged in CI.

**Option 3: advisory only**

- Good: no initial cleanup.
- Bad: warnings that never fail are ignored. The broken precommit alias already showed this.

**Option 4: external CI**

- Good: some offer better caching.
- Bad: another account and secret store; GitHub Actions is free for public repositories and integrates with code scanning and Dependabot.

## Decision

Chosen option: **option 1**, because it makes the gates strict from the first green run while keeping feedback fast and conflict-free for open work.

| Job | What it runs |
| --- | --- |
| `lint` ("Format, compile, Credo, Sobelow, audit") | `mix format --check-formatted`, `mix deps.unlock --check-unused`, `mix compile --warnings-as-errors --force`, `mix credo --strict`, `mix sobelow --config`, `mix hex.audit`, `mix deps.audit` |
| `dialyzer` | `MIX_ENV=dev`, PLTs in `priv/plts` cached separately and saved before Dialyzer runs, `mix dialyzer --format github` |
| `test` ("Test suite (coverage)") | `postgres:17` service, `mix coveralls.multiple --type local --type json --type lcov --warnings-as-errors`; coverage table in the job summary, JSON/lcov artifact, Codecov only when a `CODECOV_TOKEN` secret exists |
| `storage-integration` | MinIO and Azurite services, tagged storage tests |
| `docker.yml` | builds the image on every PR and on `main`; on `v*` tags pushes to GHCR with SBOM and provenance; Trivy scan uploaded as SARIF |

`--force` on the lint compile stops cached `_build` artifacts from hiding warnings, and `--warnings-as-errors` on the test run also fails on warnings in test files. Elixir and OTP versions come from one `env` block that must match the Dockerfile and `.tool-versions` ([ADR-0023](0023-platform-and-dependency-baseline.md)). `.github/dependabot.yml` covers mix, npm (`converger_js`, `website`), GitHub Actions and Docker.

To get a clean baseline without conflicting with open PRs, real findings were fixed (moduledocs, alias ordering, nesting, missing `Activity.t/0` and `Channel.t/0` types, compile warnings), while purely stylistic Credo findings in files that open PRs were editing were excluded per check in `.credo.exs` with comments. The rule is: remove a file's entry when you touch it. Reviewed Sobelow findings are skipped inline with `# sobelow_skip` and a justification; `Config.HTTPS` is ignored because TLS terminates at the proxy ([ADR-0022](0022-deployment-hardening.md)). The Sobelow pass also added a real Content-Security-Policy to the `:browser` pipeline.

`mix precommit` now runs the CI checks locally (compile with warnings as errors, `deps.unlock --unused`, `format`, `credo --strict`, `sobelow --config`, `hex.audit`, `deps.audit`, `test --warnings-as-errors`); it fixes rather than checks formatting. Dialyzer stays a separate `mix dialyzer` step because it is slow.

**Line endings.** `.gitattributes` sets `* text=auto eol=lf`, keeps CRLF for `*.bat` and `*.cmd`, marks binary assets, and pins `*.sh` and `rel/overlays/bin/*` to LF because release scripts run in Linux containers. The index was already 100% LF (`git ls-files --eol`), so no renormalization commit was needed. Enforcing it in the repository, instead of asking every contributor to configure `core.autocrlf`, makes `format --check-formatted` and Credo behave identically on every platform.

## Consequences

### Positive

- Warnings, formatting drift, Credo regressions, Sobelow findings and known-vulnerable dependencies fail the build.
- Coverage is visible on every PR without a third-party account.
- Dockerfile breakage is caught on the PR, not at release time.
- Windows checkouts get LF, so the tooling no longer reports phantom diffs.

### Negative and trade-offs

- The Credo baseline is technical debt by design; files stay excluded until someone touches them.
- Trivy only reports (`exit-code: "0"`); a fixable CRITICAL/HIGH CVE does not block a release yet.
- `mix.exs` acknowledges specific advisories in `hex: [ignore_advisories: [...]]` with justifications (cowlib, cloak); these need periodic review.
- `.dialyzer_ignore.exs` filters the Ecto.Multi `call_without_opaque` false positives that only appear on OTP 28. Its comment still says CI runs OTP 27, but CI now uses OTP 28.5 ([ADR-0023](0023-platform-and-dependency-baseline.md)), so the filters are active.
- Branch protection on `main` is a repository setting, not code, and has to be configured by a maintainer.
- Minutes of CI per push; the Dialyzer PLT build takes several minutes on a cold cache.

### Follow-ups

- Load-test harness with a nightly CI run: [#34](https://github.com/AimTune/converger/issues/34).
- Protocol conformance tests in CI: [#21](https://github.com/AimTune/converger/issues/21), [#65](https://github.com/AimTune/converger/issues/65).
- Windows developer setup for `bcrypt_elixir` (MSVC `nmake`): [#53](https://github.com/AimTune/converger/issues/53).
- OSS hygiene (CONTRIBUTING, templates): [#48](https://github.com/AimTune/converger/issues/48).

## Implementation

- Workflows: [`.github/workflows/ci.yml`](https://github.com/AimTune/converger/blob/main/.github/workflows/ci.yml), [`.github/workflows/docker.yml`](https://github.com/AimTune/converger/blob/main/.github/workflows/docker.yml) (Trivy action pinned to the v0.36.0 commit), [`.github/dependabot.yml`](https://github.com/AimTune/converger/blob/main/.github/dependabot.yml).
- Tool configuration: [`.credo.exs`](https://github.com/AimTune/converger/blob/main/.credo.exs) (`Nesting` max 3, `apply/3` allowed only in `adapter.ex`, per-check baselines), [`.sobelow-conf`](https://github.com/AimTune/converger/blob/main/.sobelow-conf), [`.dialyzer_ignore.exs`](https://github.com/AimTune/converger/blob/main/.dialyzer_ignore.exs), [`.gitattributes`](https://github.com/AimTune/converger/blob/main/.gitattributes).
- [`mix.exs`](https://github.com/AimTune/converger/blob/main/mix.exs): `credo`, `dialyxir`, `sobelow`, `mix_audit` (dev/test) and `excoveralls` (test); `test_coverage: [tool: ExCoveralls]`; the `dialyzer` and `hex` project options; the `precommit` alias.
- CSP: the `:browser` pipeline in [`router.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/router.ex).

Run locally:

```bash
mix deps.get
mix precommit        # lint + tests, fixes formatting and unused lock entries
mix dialyzer         # first run builds the PLT into priv/plts
mix coveralls.html   # coverage report in cover/excoveralls.html
```

## Links

- Issue [#54](https://github.com/AimTune/converger/issues/54), pull request [#92](https://github.com/AimTune/converger/pull/92)
- Epic [#57](https://github.com/AimTune/converger/issues/57) (v2.5 production hardening: security baseline)
- [gitattributes `eol`](https://git-scm.com/docs/gitattributes#_eol)
