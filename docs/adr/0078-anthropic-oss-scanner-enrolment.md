---
title: "ADR-0078: Enrol in Anthropic's OSS Scanner with the build and threat model kept in this repository"
sidebar_label: "0078 Anthropic OSS Scanner enrolment"
description: Converger opts in to Anthropic's free vulnerability scanning; the scanner's Dockerfile, a Postgres-in-image wrapper and the threat model live under .oss-scanner/ here, the enrolment entry in anthropics/oss-scanner only points at them.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-20 |
| **Issue** | [#219](https://github.com/AimTune/converger/issues/219) |
| **Pull request** | (this PR) |
| **Related** | [ADR-0021](0021-ci-quality-gates-and-lf-line-endings.md), [ADR-0057](0057-pluggable-password-hasher-and-dev-container.md), [ADR-0073](0073-mit-license-and-community-health-files.md) |

## Context and problem statement

Converger is a multi-tenant messaging backbone: it terminates authentication for tenants, their staff and their
end users, verifies webhooks from a dozen providers, makes server-side requests to tenant-supplied URLs and stores
provider secrets. The security review so far is the CI gates of [ADR-0021](0021-ci-quality-gates-and-lf-line-endings.md)
(Sobelow, dependency audits, Dialyzer, Trivy on the image), tests written for known classes of bugs
(`test/converger_web/security_review_test.exs`, `protocol_token_security_test.exs`) and maintainer review. There
is no external, ongoing review of the code for logic-level vulnerabilities such as a missing tenant scope on a new
endpoint, and a volunteer project cannot buy one.

Anthropic's [OSS Scanner](https://red.anthropic.com/oss-scanner/) is a free, opt-in service: a pull request to
[anthropics/oss-scanner](https://github.com/anthropics/oss-scanner) adds `projects/<name>/project.yaml` naming the
repository, a security contact, a Dockerfile that builds the project and optionally a threat model. The scanner
builds the image with network access, then analyses it with none and emails model-generated findings (with a
reproducer and a proposed patch where available) to the contact. Findings are not human-reviewed, are not
published and carry no disclosure deadline unless Anthropic later validates one through its coordinated
disclosure process. The question is whether to enrol, and where the Dockerfile and threat model should live.

## Decision drivers

- An ongoing, independent look for vulnerabilities in the security-critical paths (tenant isolation, token
  handling, inbound signatures, SSRF guard, uploads), at no cost.
- The scanner must be able to compile Converger, run the suite and boot a node **offline**: the suite needs
  PostgreSQL, the dev build needs the standalone tailwind/esbuild binaries, and two dependencies are git checkouts.
- The build and the guidance will change with the code (new adapters, new surfaces, toolchain bumps); updating them
  must not need a pull request to Anthropic each time.
- Reports go to a public address; the project already publishes `hamzaagareng@gmail.com` in `SECURITY.md`.
- Signing up accepts Anthropic's terms, and the first enrolment PR requires signing their CLA (for the enrolment
  files only; it does not touch Converger's MIT, no-CLA policy of [ADR-0073](0073-mit-license-and-community-health-files.md)).

## Considered options

1. **Do not enrol**: keep the current CI gates and manual review only.
2. **Enrol, keep the Dockerfile and threat model next to `project.yaml` in anthropics/oss-scanner.**
3. **Enrol, keep the Dockerfile and threat model in this repository under `.oss-scanner/`**, and point
   `project.yaml` at them.

### Pros and cons of the options

#### Do not enrol

- Good, because nothing new to maintain and no third party builds the code.
- Bad, because the only review of security-relevant logic stays the maintainers' own; the project's whole purpose
  is to sit between tenants and their providers, and a missed scope check is a cross-tenant leak.

#### Dockerfile and threat model in anthropics/oss-scanner

- Good, because this repository stays untouched.
- Bad, because every toolchain bump (`.tool-versions`, the root `Dockerfile`) or new surface needs a second pull
  request in a repository we do not control, reviewed by Anthropic; the files would drift from the code and a
  failed build is only noticed when the contact gets an email. Anthropic also recommends the in-repository option.

#### Dockerfile and threat model in this repository (chosen)

- Good, because the files are versioned with the code they describe, reviewed in the same pull requests, and
  the docs rule ([ADR-0025](0025-docusaurus-site-and-docs-with-every-change.md)) applies to them. The
  enrolment entry is six lines that only change when the contact or the paths change.
- Good, because CI can build the image and run the suite offline on changes to the build inputs and weekly, so
  the enrolment cannot break silently.
- Bad, because the repository gains a second Dockerfile that is deliberately unlike the release image (development
  build, PostgreSQL inside, runs as root), which must not be confused with it.

## Decision

Chosen option: **"Dockerfile and threat model in this repository"**. Converger enrols with
`projects/converger/project.yaml` in anthropics/oss-scanner naming `https://github.com/AimTune/converger#main`,
the `SECURITY.md` contact, `dockerfile: .oss-scanner/Dockerfile` and `threat_model: .oss-scanner/threat_model.md`.

The scanner image is a **development build with PostgreSQL 17 inside**: the pinned `hexpm/elixir` base of the
root `Dockerfile`, build tools for the NIFs, PGDG PostgreSQL, `mix deps.get` for every environment, the `test` and
`dev` compiles, the tailwind/esbuild binaries and built assets, both databases created and migrated, and one run of
`mix test` whose failures are logged but do not fail the build (a build failure emails the contact). A small
wrapper, `.oss-scanner/with-postgres.sh`, starts the cluster before any command, so `mix test` and `mix phx.server`
work with the network off.

The threat model follows Anthropic's template and leads with tenant isolation; it lists every surface where
untrusted input enters, the security goals, the components that matter most, how to drive the code, the severity
rubric, what to leave alone (documented limitations, dev-only configuration, acknowledged advisories) and how we
want reports and patches.

Reports are handled like any private report under `SECURITY.md`; a confirmed finding becomes a GitHub security
advisory and the fix credits the report id. The scanner's findings are never pasted into public issues.

## Consequences

### Positive

- Continuous, free review of the security-critical code paths with reproducers and patch proposals.
- The scanner build doubles as a check that the project builds and tests from a clean clone on Linux with the
  pinned toolchain, independent of CI caches.

### Negative and trade-offs

- A second Dockerfile to keep in sync with `.tool-versions` and the root `Dockerfile` (the CI job and a comment
  in each file point at the other).
- Reports are unreviewed model output: triage time goes into false positives as well as real findings.
- The build takes longer than the release image (two compiles, the suite); it must stay inside the scanner's
  45-minute build budget, so the CI job is also the early warning when it grows.

### Follow-ups

- Revisit the threat model when a report shows the guidance was unclear, and after each new channel adapter or
  authentication surface.
- Consider a PGP key for encrypted reports once the project has a security alias instead of a personal address
  (`pgp` cannot be combined with `auto_ccs`).

## Implementation

- `.oss-scanner/Dockerfile`, `.oss-scanner/with-postgres.sh`, `.oss-scanner/threat_model.md` in this repository.
- `.github/workflows/oss-scanner.yml`: builds the image and runs `mix test` with `--network none` on pull requests
  that touch the build inputs, on `main`, weekly and on demand.
- `projects/converger/project.yaml` in [anthropics/oss-scanner](https://github.com/anthropics/oss-scanner)
  (validated with its `tools/validate.py`).
- Documentation: [Anthropic OSS Scanner](../security/oss-scanner.md), the
  [Security model](../security/overview.md#static-analysis-and-supply-chain) and `SECURITY.md`.

## Links

- [Anthropic OSS Scanner](https://red.anthropic.com/oss-scanner/) and its
  [terms](https://red.anthropic.com/oss-scanner/terms/)
- [anthropics/oss-scanner README](https://github.com/anthropics/oss-scanner#readme) (enrolment rules, templates,
  `tools/validate.py`, `tools/check`)
- [Anthropic OSS Scanner](../security/oss-scanner.md) documentation page
