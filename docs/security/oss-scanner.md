---
title: Anthropic OSS Scanner
description: Converger is enrolled in Anthropic's OSS Scanner. What the scanner builds and reads from this repository, how reports arrive, how to triage them, and how to keep the scanner build working.
sidebar_position: 4
---

Converger is enrolled in [Anthropic's OSS Scanner](https://red.anthropic.com/oss-scanner/), a free, opt-in service
that builds an open-source project in an isolated VM, analyses it with no network access and emails what it finds
to the project's security contact, with a reproducer and a proposed patch where it has one. The enrolment is
[`projects/converger`](https://github.com/anthropics/oss-scanner/tree/main/projects/converger) in the
[anthropics/oss-scanner](https://github.com/anthropics/oss-scanner) repository
([#219](https://github.com/AimTune/converger/issues/219),
[ADR-0078](../adr/0078-anthropic-oss-scanner-enrolment.md)). Reports are model-generated and not reviewed by a
human before they are sent; Anthropic places no disclosure deadline on them and does not publish them.

## What the scanner reads from this repository

The enrolment entry only names the repository, the contact and two files that live here, so the build and the
guidance can change without a pull request to Anthropic:

| File | Purpose |
| --- | --- |
| [`.oss-scanner/Dockerfile`](https://github.com/AimTune/converger/blob/main/.oss-scanner/Dockerfile) | Builds Converger the way the scanner needs it: the pinned Elixir/OTP image, PostgreSQL 17 inside the image, every Hex and git dependency, the test and dev builds and the admin/portal assets. Built with the repository as context (`.dockerignore` applies) while the network is up; everything after that runs offline. |
| [`.oss-scanner/with-postgres.sh`](https://github.com/AimTune/converger/blob/main/.oss-scanner/with-postgres.sh) | Starts the image's Postgres cluster and runs a command, so `mix test` and `mix phx.server` work in the sandbox. |
| [`.oss-scanner/threat_model.md`](https://github.com/AimTune/converger/blob/main/.oss-scanner/threat_model.md) | Where untrusted input enters, the security goals (tenant isolation first), what matters most, how to exercise the code, how we rate severity, what to leave alone, and how we want reports and patches. |

This is not the release image: the root `Dockerfile` builds the production release
([Deployment](../deployment.md)). The scanner image is a development build with the test suite, so it is larger
and runs as root on purpose.

The build also runs the suite once; a failing test does not fail the build, but a build failure is emailed to the
primary contact, so keep the Dockerfile in sync with `.tool-versions` and the root `Dockerfile` when the toolchain
moves.

## Building it locally

```bash
docker build -f .oss-scanner/Dockerfile -t converger-oss-scanner .

# the suite, offline, as the scanner runs it
docker run --rm --network none converger-oss-scanner .oss-scanner/with-postgres.sh mix test

# a shell with Postgres up; MIX_ENV=dev mix phx.server boots the app on :4000
docker run --rm -it --network none -p 4000:4000 converger-oss-scanner .oss-scanner/with-postgres.sh
```

With a clone of anthropics/oss-scanner, `tools/check converger` does the same from the enrolment entry (clone of
`main`, build, Anthropic's tool layer, then a shell with the network off). It needs Python 3 with PyYAML and
Docker.

The [OSS Scanner workflow](https://github.com/AimTune/converger/blob/main/.github/workflows/oss-scanner.yml)
builds the image and runs the suite offline on pull requests that touch `.oss-scanner/`, `mix.exs`, `mix.lock`,
`.tool-versions` or `.dockerignore`, and once a week, so the enrolment does not break silently when dependencies
change.

## When a report arrives

Reports are emailed to the primary contact in `project.yaml` (the address in
[`SECURITY.md`](https://github.com/AimTune/converger/blob/main/SECURITY.md)) and carry an id of the form
`ANT-2026-XXXXXXXX`. Treat one like any private vulnerability report:

1. Reproduce it in the scanner image or a dev environment; the threat model's severity rubric decides the rating.
   Model-generated reports can be wrong; a false positive is answered by replying to the report email, which is
   also where feedback on the scanner goes.
2. For a confirmed finding, open a GitHub security advisory (private), fix it on `main` with a test, and publish
   the advisory as described in `SECURITY.md`. Mention the report id in the commit message or the advisory
   credits, for example `Discovered by Anthropic's OSS Scanner, as vulnerability ANT-2026-ABCD1234`.
3. Adjust `.oss-scanner/threat_model.md` when a report shows that the guidance was unclear (an out-of-scope
   finding, a mis-rated severity, a surface that was not listed).

Unvalidated findings have no 90-day clock. If Anthropic later validates a finding through its coordinated
disclosure process, it may be disclosed 90 days after we are notified of that validation.

## Pausing or leaving

Both are pull requests to anthropics/oss-scanner: set `disabled: true` in `projects/converger/project.yaml` to
pause reports, or delete `projects/converger/` to withdraw. Changing the contact or the file paths is an edit of
the same file.

## Related

- [Security model](overview.md) and [`SECURITY.md`](https://github.com/AimTune/converger/blob/main/SECURITY.md)
- [ADR-0078: Enrol in Anthropic's OSS Scanner with the build and threat model kept in this repository](../adr/0078-anthropic-oss-scanner-enrolment.md)
- [ADR-0021: CI quality gates](../adr/0021-ci-quality-gates-and-lf-line-endings.md) (Sobelow, audits, Trivy)
