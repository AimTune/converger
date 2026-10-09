---
title: Contributing
description: How to set up a development environment, name branches and commits, run the same checks as CI, and keep the documentation and ADRs up to date with every change.
sidebar_position: 95
---

Thanks for helping with Converger. This page covers the workflow from a fresh clone to a merged pull request:
local setup, branch and commit conventions, the checks CI runs (and how to run them first), Windows specifics,
and the rule that every change ships with its documentation.

## Development setup

The full walkthrough is in [Getting started](./getting-started.md). In short:

- Install the toolchain from `.tool-versions` (Elixir `1.19.5-otp-28`, Erlang `28.5.0.5`), for example with asdf
  or mise, and a PostgreSQL server (CI and compose use 17).
- `mix setup` runs `deps.get` and `ecto.setup` (create, migrate, seed). The seed creates the first `super_admin`
  from `ADMIN_EMAIL` / `ADMIN_PASSWORD`, or prints a one-time password.
- `mix phx.server` starts the app on `http://localhost:4000` (admin panel at `/admin`).
- Database settings come from `DB_USERNAME`, `DB_PASSWORD`, `DB_HOSTNAME`, `DB_NAME` (defaults
  `postgres` / `postgres` / `localhost` / `converger_dev`); see the
  [Configuration reference](operations/configuration.md#database).
- Optional: `cp .env.example .env`, fill it in, and `docker compose up -d` for Prometheus, Grafana, Jaeger and the
  OpenTelemetry collector ([Observability](operations/observability.md#local-observability-stack)).

## Branches, commits and pull requests

- Branch from `main`, one topic per branch, named `<type>/<issue>-<short-description>` (for example
  `fix/13-rate-limiting`, `chore/dependabot-updates`).
- Commit messages and PR titles follow [Conventional Commits](https://www.conventionalcommits.org/):
  `type(optional scope): summary`, imperative mood, lower case. Types used so far: `feat`, `fix`, `test`, `ci`,
  `build`, `chore`; use `docs` for documentation-only changes (for example `feat(rate-limit): Hammer 7, cluster-wide limits on hot
  paths, login lockout`, `chore(deps): apply pending Dependabot updates`). Reference the issue in the title or body
  (`(#13)`, `Closes #56`).
- Keep commits focused; do not mix formatting-only changes into functional commits.
- PR descriptions explain the **problem**, the **changes**, the **checks** you ran, and, when operators must do
  something, a **Deployment notes** or **Breaking changes** section (new required variables, migrations that need
  a maintenance window, behavior changes for integrators). Those sections feed
  [Upgrades](operations/upgrades.md).
- Dependency updates arrive from Dependabot (`mix`, `converger_js` npm, GitHub Actions, Docker; weekly).

## Checks

### Run `mix precommit` before pushing

The `precommit` alias in `mix.exs` mirrors the CI `lint` and `test` jobs. It runs in the `test` environment (so
it needs Postgres) and **fixes** formatting and unused lock entries instead of only reporting them:

```bash
mix precommit
```

| Step | What it does |
| --- | --- |
| `compile --warnings-as-errors --force` | Full recompile; any warning fails |
| `deps.unlock --unused` | Removes unused entries from `mix.lock` |
| `format` | Formats the code (`.formatter.exs`) |
| `credo --strict` | Static analysis (`.credo.exs`) |
| `sobelow --config` | Security analysis (`.sobelow-conf`) |
| `hex.audit` | Retired Hex packages |
| `deps.audit` | Dependencies with known vulnerabilities (`mix_audit`) |
| `test --warnings-as-errors` | Test suite (creates and migrates the test database first); warnings in test files fail too |

Dialyzer is slow and runs separately:

```bash
mix dialyzer
```

The first run builds the PLTs in `priv/plts`. Warnings that are accepted go in `.dialyzer_ignore.exs` with a
reason. Accepted Sobelow findings get an inline `# sobelow_skip [...]` with a justification comment; acknowledged
Hex advisories go in `mix.exs` under `hex: [ignore_advisories: ...]`, also with a reason.

To debug failures: `mix test test/path/to/file_test.exs`, `mix test --failed`.

### What CI runs

[`.github/workflows/ci.yml`](https://github.com/AimTune/converger/blob/main/.github/workflows/ci.yml) runs on every
pull request and on pushes to `main`, with Elixir and OTP from the workflow `env` (kept in sync with
`.tool-versions` and the `Dockerfile`):

| Job | Steps |
| --- | --- |
| Format, compile, Credo, Sobelow, audit (`lint`) | `mix format --check-formatted`, `mix deps.unlock --check-unused`, `mix compile --warnings-as-errors --force`, `mix credo --strict`, `mix sobelow --config`, `mix hex.audit`, `mix deps.audit` |
| Dialyzer | `mix dialyzer --format github` in `MIX_ENV=dev`, PLTs cached per Elixir/OTP/lockfile |
| Test suite (coverage) | Postgres 17 service; `mix coveralls.multiple --type local --type json --type lcov --warnings-as-errors`; coverage summary on the run page, `cover/excoveralls.json` and `cover/lcov.info` uploaded as an artifact, Codecov upload when `CODECOV_TOKEN` is configured |
| Storage integration (MinIO, Azurite) | MinIO and Azurite services; `mix test test/converger/uploads/storage_integration_test.exs --only minio --only azurite` with `MINIO_ENDPOINT`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, `AZURITE_ENDPOINT` |

[`.github/workflows/docker.yml`](https://github.com/AimTune/converger/blob/main/.github/workflows/docker.yml) builds
the image on every pull request (no push) and scans it with Trivy (report-only); `v*` tags publish it to GHCR. The
documentation workflow is described [below](#the-docs-required-check).

The reasoning behind these gates is in [ADR-0021](./adr/0021-ci-quality-gates-and-lf-line-endings.md).

To run the storage integration tests locally, start the same services and export the variables:

```bash
docker run -d --name minio -p 9000:9000 -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin bitnamilegacy/minio:latest
docker run -d --name azurite -p 10000:10000 mcr.microsoft.com/azure-storage/azurite
MINIO_ENDPOINT=http://localhost:9000 MINIO_ACCESS_KEY=minioadmin MINIO_SECRET_KEY=minioadmin \
AZURITE_ENDPOINT=http://127.0.0.1:10000/devstoreaccount1 \
  mix test test/converger/uploads/storage_integration_test.exs --only minio --only azurite
```

### Asynchronous assertions

`test/test_helper.exs` raises ExUnit's `assert_receive_timeout` to 1 s, so `assert_receive`,
`assert_reply` and `assert_push` tolerate a busy CI runner; they still return as soon as the message
arrives. Don't pass short explicit timeouts to them, and use `refute_receive` (100 ms default) for
negative checks. Tests that need wall-clock windows (rate limits, lockouts) must not depend on landing
inside one; see `start_in_fresh_window/2` in `test/converger_web/controllers/rate_limiting_test.exs`.

## Line endings and Windows

`.gitattributes` sets `* text=auto eol=lf`: files are stored and checked out with LF on every platform (only
`*.bat` and `*.cmd` keep CRLF), so `mix format --check-formatted` and diffs behave the same on Windows as on Linux
CI, even with `core.autocrlf=true`. Release scripts (`rel/overlays/bin/*`, `*.sh`) must stay LF because they run in
Linux containers. If your clone predates the rule, run `git add --renormalize .` once.

Notes for developing on Windows:

- `bcrypt_elixir` compiles a C NIF and needs the Microsoft C++ Build Tools. Run `mix` from an
  "x64 Native Tools Command Prompt", or call `vcvars64.bat` first, for example in a small wrapper script:

  ```powershell
  cmd /c '"C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul && mix deps.compile bcrypt_elixir'
  ```

- Environment variables in PowerShell: `$env:DB_PASSWORD = "postgres"; mix test`.
- To run several test suites at once (for example in two worktrees), give each a partition so they use separate
  databases and upload directories: `$env:MIX_TEST_PARTITION = "2"; mix test`. The Prometheus listener is off in
  test, so suites do not compete for port 9568.
- The release overlays are POSIX shell scripts; test release behavior with the Docker image rather than natively.

## Documentation with every change

Documentation lives in `docs/` and is published as this site. It is part of the change, not a follow-up:

- **Every PR must update the relevant `docs/` pages.** New or changed endpoints, configuration keys, environment
  variables, defaults, error codes, migrations, operational procedures and security behavior are documented in
  the same PR that introduces them. If a migration needs a maintenance window, add it to
  [Migrations and maintenance windows](operations/migrations.md); if operators must act, add a note to
  [Upgrades](operations/upgrades.md).
- **Architectural decisions require a new or updated ADR** in `docs/adr/`: new dependencies or infrastructure,
  changes to the delivery pipeline, data model, security model, protocol or public API contracts, and any
  decision a future contributor would otherwise have to rediscover. Follow
  [How we write ADRs](./adr/how-we-write-adrs.md) and start from the [template](./adr/template.md). The policy itself is
  [ADR-0025](./adr/0025-docusaurus-site-and-docs-with-every-change.md).
- **The pull request template** ([`.github/pull_request_template.md`](https://github.com/AimTune/converger/blob/main/.github/pull_request_template.md))
  has a documentation checklist: the `docs/` pages you updated, the ADR you added or updated (or "no architectural
  decision involved"), or "no documentation impact" with the reason, and whether `npm run build` passes. Tick only
  what is true; reviewers check it.

### The "Docs required" check

The `Docs required` job in `.github/workflows/docs.yml` fails a pull request that changes files under `lib/`,
`config/` or `priv/repo/migrations/` without changing anything under `docs/`.

Some changes genuinely need no documentation (an internal refactor with no
observable change, a log message tweak, a `config/` change that only affects the test environment). The escape hatch:

1. A maintainer adds the label `no-docs` to the PR.
2. The PR description states why no documentation change is needed.
3. Adding or removing the label re-runs the `Docs required` job automatically (the workflow listens to the
   `labeled` and `unlabeled` events), and it passes with a notice.

Do not use `no-docs` to postpone documentation that is needed; open the docs change in the same PR instead.

### Writing docs

Pages are Docusaurus 3 documents in plain Markdown (CommonMark, not MDX): no JSX or raw HTML, placeholders such as
`<token>` inside backticks or code blocks. Each file starts with front matter (`title`, `description`,
`sidebar_position`); folders get a `_category_.json`. Link to other pages with relative paths including `.md`, to
code with absolute GitHub URLs, and mark unimplemented features as "Planned" with the issue link.

### Preview the site locally

The site lives in `website/` and reads the repository's `docs/` folder. It needs Node.js 20 or later:

```bash
cd website
npm ci
npm start        # dev server with live reload, usually http://localhost:3000
npm run build    # production build into website/build; run it before pushing docs changes
```

The production build fails on broken links and broken Markdown links, so a renamed page or a wrong relative path is
caught in the "Build site" job of the PR.

`npm start` and the Grafana container from `docker compose` both default to port 3000; stop one or run
`npm start -- --port 3001`.
