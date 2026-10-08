---
title: Upgrades
description: How to upgrade and roll back Converger, the version and toolchain policy, the current dependency baseline, and the operator notes for every breaking change shipped so far.
sidebar_position: 5
---

This page collects what an operator needs before moving a Converger installation to a newer build: the procedure
in short, where versions and changes are recorded, the toolchain and dependency baseline, and one note per
breaking change that has shipped. The step-by-step runbook, backups and rollback options are in
[Deployment: Upgrade and rollback runbook](../deployment.md#upgrade-and-rollback-runbook).

## Procedure in short

1. **Read what changed.** `CHANGELOG.md` and the new files in `priv/repo/migrations`. Classify each migration as
   rolling-deploy safe or maintenance window using [Migrations and maintenance windows](migrations.md).
2. **Check configuration.** New required variables make the release refuse to boot, which is safe but causes an
   outage if you only find out during the rollout. Compare your environment with the
   [Configuration reference](configuration.md) and the notes below.
3. **Back up.** Database (or a PITR timestamp) and `CLOAK_KEY`. See
   [Backups and restore](../deployment.md#backups-and-restore).
4. **Migrate once** with the new image: `bin/migrate`.
5. **Roll out** the replicas (`bin/server`), or, for a maintenance-window migration, stop the old release before
   step 4 and start the new one after it.
6. **Watch** error rate, latency, Oban queues (`/admin/oban`) and dead-lettered deliveries.

Rollback: redeploy the previous image when the migrations were expand-only; for destructive migrations
(`activities.seq` backfill, channel secret encryption, API key hashing) restore the pre-upgrade backup instead.

## Versions and release notes

| Source | What it tells you |
| --- | --- |
| [`CHANGELOG.md`](https://github.com/AimTune/converger/blob/main/CHANGELOG.md) | Toolchain and dependency upgrades with notes, currently all under **Unreleased**. |
| [`VERSIONS.md`](https://github.com/AimTune/converger/blob/main/VERSIONS.md) | Feature roadmap grouped into milestones (v1.0 MVP to v3.0 Enterprise). These are planning milestones, not git tags or package versions, and some checkboxes lag behind the code (for example channel config encryption at rest is implemented). |
| Pull request descriptions | Each merged PR has a "Deployment notes" or "Breaking changes" section when operators must act. |
| `mix.exs` | Application version, currently `0.1.0`. |

No release has been tagged yet, so installations build their image from a commit on `main` (`docker build .`).
Record the commit SHA you deployed and tag your image with it rather than `latest`, so a rollback knows exactly
what to return to. The Docker workflow builds and scans the image on every pull request and push to `main`, but
publishes only for tags: pushing `vX.Y.Z` publishes `ghcr.io/aimtune/converger` with the tags `X.Y.Z`, `X.Y` and
`sha-<commit>`, plus an SBOM and provenance attestation.

Until tagged releases exist, treat every merge to `main` that adds a migration or a required variable as a
potential breaking change and read its PR.

## Toolchain

| Component | Version | Where it is pinned |
| --- | --- | --- |
| Elixir | 1.19.5 (OTP 28 build) | `.tool-versions` (`elixir 1.19.5-otp-28`), `Dockerfile` `ELIXIR_VERSION`, CI `ELIXIR_VERSION` |
| Erlang/OTP | 28.5.0.5 | `.tool-versions` (`erlang 28.5.0.5`), `Dockerfile` `OTP_VERSION`, CI `OTP_VERSION` |
| Build image | `hexpm/elixir:1.19.5-erlang-28.5.0.5-debian-bookworm-20260824-slim` | `Dockerfile` |
| Runtime image | `debian:bookworm-20260824-slim` | `Dockerfile` |
| Minimum Elixir | `~> 1.18` | `mix.exs` |
| PostgreSQL | 17 in compose and CI | `docker-compose.yml`, `.github/workflows/ci.yml` |

Bump `.tool-versions`, the `Dockerfile` build args and the CI `env` together; comments in each file point at the
others. The previous toolchain was Elixir 1.18.4 / OTP 27.2 (changed in
[#91](https://github.com/AimTune/converger/pull/91)).

PostgreSQL: the migrations use `sha256()` (Postgres 11+) and Oban's v14 migration adds an enum value inside a
transaction, which requires Postgres 12 or later. Development and CI run on 17.

Background: [ADR-0023](../adr/0023-platform-and-dependency-baseline.md).

## Dependency baseline

Locked versions on `main` (`mix.lock`) for the libraries operators and contributors most often ask about:

| Package | Version | Notes |
| --- | --- | --- |
| `phoenix` | 1.8.15 | The layouts load `phoenix.js` from jsDelivr at the matching version. |
| `phoenix_live_view` | 1.2.12 | Upgraded 1.0.18 to 1.1.33 in [#91](https://github.com/AimTune/converger/pull/91), then to 1.2.12 in [#104](https://github.com/AimTune/converger/pull/104). The CDN `phoenix_live_view.min.js` in the layouts is pinned to the same version, and a test fails if they drift. `LiveViewTest` uses `lazy_html`. |
| `oban` | 2.24.1 | Required by `oban_web`; needs the `oban_jobs` schema at v14 (migration `20261009131000`). |
| `oban_web` | 2.13.0 | Dashboard at `/admin/oban` (Apache-2.0). |
| `req` | 0.7.5 (`~> 0.7`) | Upgraded from 0.5.17 for the decompression-bomb fix. Webhook `method` is limited to `POST`, `PUT`, `PATCH`. |
| `hammer` | 7.5.0 | New API since 7.0; Converger wraps it in `Converger.RateLimit` ([Rate limiting](rate-limiting.md)). |
| `logger_json` | 7.0.4 | Configured as a formatter on `:default_handler` (see [Observability](observability.md#logging)); the 6.x configuration style still applies. |
| `bandit` | 1.12.5 | HTTP server. |
| `broadway` | 1.3.0 | Optional pipeline backend. |
| `gettext` | 1.0.2 | Backend uses `use Gettext.Backend`. |
| `dns_cluster` | 0.3.1 | `query:` option unchanged. |
| `joken` | 2.7.0 | JWT signing. |
| `cloak` / `cloak_ecto` | 1.1.4 / 1.3.0 | Two advisories acknowledged in `mix.exs` (affected ciphers and types are not used). |
| `opentelemetry` / `opentelemetry_exporter` | 1.7.0 / 1.10.0 | Plus `opentelemetry_phoenix` 2.0.1, `opentelemetry_ecto` 1.2.0, `opentelemetry_oban` 1.2.0, `opentelemetry_req` 1.0.0. |

The dependency upgrades are described in [#91](https://github.com/AimTune/converger/pull/91) (LiveView 1.1, Oban
2.24 and Oban Web, OpenTelemetry for Oban and Req, Elixir 1.19 / OTP 28),
[#93](https://github.com/AimTune/converger/pull/93) (LoggerJSON on the default handler) and
[#104](https://github.com/AimTune/converger/pull/104) (LiveView 1.2, gettext 1.0, LoggerJSON 7, dns_cluster 0.3,
joken 2.7, telemetry_metrics 1.2). Dependabot opens further updates; `mix hex.audit` and `mix deps.audit` run in CI.

## Breaking changes already shipped

Each note says what changed, who is affected and what to do. They apply when upgrading an installation built
before the change.

### Migrations no longer run on container start

Before [#90](https://github.com/AimTune/converger/pull/90) the image ran `create_db` and `migrate` on every start.
Now the default command is `bin/server`, which only starts the server.

- **Action:** add `/app/bin/migrate` as a pre-deploy step (compose `migrate` service, Kubernetes Job, Fly
  `release_command`, ...). See [Migrations and maintenance windows](migrations.md).

### Secrets are required and validated at boot

- `CLOAK_KEY` is required in production ([#79](https://github.com/AimTune/converger/pull/79)). It must be set
  **before** running the encryption migration. Losing it loses every channel secret and config.
- `SECRET_KEY_BASE` must be at least 64 bytes, and values once published in the repository are rejected
  ([#90](https://github.com/AimTune/converger/pull/90)). Rotating it logs everyone out and invalidates all issued
  tokens.
- `docker-compose.yml` no longer contains secrets: `cp .env.example .env` and fill in `POSTGRES_PASSWORD`,
  `SECRET_KEY_BASE`, `CLOAK_KEY`, `GF_SECURITY_ADMIN_PASSWORD`. An existing Postgres volume keeps its old password.
- **Action:** if you ever used the published values, follow
  [Rotating leaked secrets](../security.md#rotating-leaked-secrets).

### Channel secrets encrypted, tenant API keys hashed

[#79](https://github.com/AimTune/converger/pull/79), migrations `20261008100000` and `20261008100001`
(maintenance window).

- Existing API keys keep working, but **they can never be displayed again**: only a hash and a short prefix are
  stored. New keys start with `cvg_live_` and are shown once at creation or rotation.
- To hand out a key you no longer have, rotate it; the previous key stays valid for 24 hours.
- `Tenant.api_key` is virtual and `nil` on loaded tenants; scripts that read it from the database get nothing.
- The API key migration is irreversible. Audit logs written before the upgrade may still contain plaintext secrets.

### Inbound signatures enforced per channel

[#77](https://github.com/AimTune/converger/pull/77), migration `20261008120000`.

- **New channels** have `require_signature: true` and reject unsigned and legacy-signed (`sha256=...`) inbound
  and status webhooks with `401`. Sign with `x-converger-signature: t=...,v1=...`, or create the channel with
  `require_signature: false`.
- **Existing channels** were backfilled with `require_signature: false` and keep working, but every unsigned or
  legacy request logs a `DEPRECATED` warning. Switch the sender to the timestamped scheme, then enable the flag.
- New WhatsApp Meta channels need `config.app_secret` unless `require_signature` is `false`.
- WhatsApp Infobip has no native scheme: new Infobip channels must send `x-converger-signature` (for example via a
  signing proxy) or use `require_signature: false`.
- `/status` now verifies signatures; invalid ones get `401` instead of being accepted.

See [ADR-0009](../adr/0009-inbound-signature-scheme-and-per-channel-enforcement.md).

### Activity ordering by `seq`

[#78](https://github.com/AimTune/converger/pull/78), migration `20261008150000` (maintenance window).

- Activities are ordered and paginated by a per-conversation `seq`. Watermarks are opaque encodings of `seq`;
  legacy Base64 activity-id watermarks are still accepted for one release, so clients should store the new
  watermark values they receive.
- See [ADR-0006](../adr/0006-per-conversation-seq-and-opaque-watermarks.md).

### Closed conversations reject activities

[#84](https://github.com/AimTune/converger/pull/84). Posting to a closed conversation now returns `409`
`{"error": "conversation_closed"}` on REST, uploads and inbound webhooks, and an error reply on the WebSocket.
Close and reopen emit a `conversationUpdate` activity. Migration `20261009170000` moves `updated_at` forward so
the expiration job does not close active conversations after the upgrade.

### Rate limits are on

[#83](https://github.com/AimTune/converger/pull/83). Limits that did not exist before are enforced with the
defaults in [Rate limiting](rate-limiting.md). The Converger token limit is per channel instead of per IP.

- **Action:** give high-traffic tenants an override (`tenants.limits`) **before** deploying, set
  `TRUSTED_PROXIES` behind a proxy, and set `RATE_LIMIT_BACKEND=local` to opt out of the cluster backend.

### Webhook SSRF guard and method allowlist

[#87](https://github.com/AimTune/converger/pull/87).

- Webhook channels pointing at private, loopback or link-local addresses fail delivery permanently. Allow
  intentional internal targets with `WEBHOOK_ALLOWED_TARGETS`.
- `method` must be `POST`, `PUT` or `PATCH`. Reserved headers (`host`, `content-length`, `content-type`,
  hop-by-hop, `x-converger-*`) are rejected in config and stripped at request time for older channels.
- Redirects are no longer followed; a `3xx` counts as a failed delivery.
- Receivers can now verify `x-converger-signature` and deduplicate on `x-converger-delivery-id`
  ([Outbound webhooks](../webhooks.md)).

### HTTPS enforced in production, configurable WebSocket origins

[#90](https://github.com/AimTune/converger/pull/90).

- `FORCE_SSL` defaults to `true` in production: plain HTTP is redirected and HSTS is sent. Behind a TLS
  terminating proxy, set `TRUSTED_PROXIES`, or every request is redirected in a loop. Local compose sets
  `FORCE_SSL=false`.
- Browser WebSockets are accepted only from the `PHX_HOST` host unless `CHECK_ORIGIN` lists more origins. Widgets
  embedded on other sites need their origin in `CHECK_ORIGIN`.

### No default admin password

[#90](https://github.com/AimTune/converger/pull/90). Seeds no longer create `admin@converger.local` /
`admin123456`. The first super admin comes from `ADMIN_EMAIL` / `ADMIN_PASSWORD`, or gets a one-time generated
password and must change it at first login. Existing installations should change or delete the old seeded account.

### Authenticated attachments

[#80](https://github.com/AimTune/converger/pull/80). Files are served only through
`GET /api/v1/converger/attachments/:id` with a Converger token, never from `priv/static`. For releases, configure
`UPLOAD_STORAGE` (local disk on a persistent volume, or object storage); see [File storage](../storage.md).

### Bounded list queries

[#89](https://github.com/AimTune/converger/pull/89). Every list endpoint is paginated: a `limit` above the
configured maximum is capped, and the WebSocket join replays at most `ws_replay_limit` activities (default 100).
Clients that relied on receiving the whole history in one call must page with the returned watermark or cursor.

### Production logging configuration

[#93](https://github.com/AimTune/converger/pull/93). Earlier builds printed `FORMATTER CRASH` for every production
log line. If you maintain a fork with a customized `config/prod.exs`, configure LoggerJSON as the
`:default_handler` formatter as shown in [Observability](observability.md#logging).
