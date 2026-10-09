---
title: "ADR-0022: Deployment hardening: one-shot migrations, runtime ForceSSL, fail-fast secrets"
sidebar_label: "0022 Deployment hardening"
description: Migrations run as a separate step under a Postgres advisory lock, HTTPS and HSTS are enforced at runtime while trusting only known proxies, and the release refuses to boot with missing, weak or leaked secrets.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#55](https://github.com/AimTune/converger/issues/55) |
| **Pull request** | [#90](https://github.com/AimTune/converger/pull/90) |
| **Related** | [ADR-0010](0010-runtime-cors-and-opentelemetry-configuration.md), [ADR-0011](0011-custom-trusted-proxies-plug.md), [ADR-0012](0012-secrets-at-rest-and-audit-redaction.md), [ADR-0018](0018-keyset-pagination.md), [ADR-0021](0021-ci-quality-gates-and-lf-line-endings.md), [ADR-0023](0023-platform-and-dependency-baseline.md) |

This ADR records how a Converger release is deployed safely: when schema migrations run, how HTTPS is enforced behind a proxy, and what the release checks about its secrets before it serves traffic. The operator runbook lives in [deployment](../deployment.md) and the secret-rotation procedure in [security](../security.md).

## Context and problem statement

The deployment path had several independent hazards, each of which could cause an outage or a compromise:

- **Concurrent migrations.** The Docker entrypoint ran `create_db` and `migrate` on every container start. A rolling deploy with two replicas therefore ran migrations concurrently. Ecto's default migration lock is a table lock inside the migration transaction, which does not cover `@disable_ddl_transaction` migrations such as `create index(..., concurrently: true)` ([ADR-0018](0018-keyset-pagination.md) needs them).
- **Committed secrets.** `docker-compose.yml`, the file people copy to servers, shipped a hardcoded `SECRET_KEY_BASE` and `GF_SECURITY_ADMIN_PASSWORD=admin`. `SECRET_KEY_BASE` also signs Converger conversation and channel tokens, so anyone with the published value could forge sessions and tokens on any deployment that kept it. Seeds created `admin@converger.local` / `admin123456`.
- **No HTTPS enforcement.** `force_ssl`/HSTS was commented out. Phoenix's built-in `force_ssl` endpoint option is compile-time, and with `rewrite_on: [:x_forwarded_proto]` it trusts that header from **any** client, so a direct client could claim to be on HTTPS.
- **`check_origin` not configurable**: it defaulted to the endpoint host (`example.com` unless `PHX_HOST` was set).
- No backup, restore, upgrade or rollback documentation, and the Dockerfile toolchain (Elixir 1.18 / OTP 27) did not match development (1.19 / OTP 28).

## Decision drivers

- A rolling deploy of N replicas applies each migration exactly once.
- No secret in git; a deployment that still uses a published secret must not start.
- HTTPS by default in production, without letting clients spoof the scheme.
- Configuration at runtime from environment variables, consistent with [ADR-0010](0010-runtime-cors-and-opentelemetry-configuration.md).
- Works on Docker Compose, Kubernetes and PaaS platforms (Fly `release_command` and similar).

## Considered options

For migrations:

1. **Separate one-shot migrate step plus `migration_lock: :pg_advisory_lock`** - the image no longer migrates on start; a `bin/migrate` overlay runs as an init container, Job, hook or compose service, and the advisory lock makes concurrent runs safe anyway.
2. **Keep migrate-on-start, rely on Ecto's default table lock.**
3. **Leader election among replicas** (only one replica migrates).

For HTTPS:

1. **A runtime `ForceSSL` plug** wrapping `Plug.SSL`, configured from env, that honours `X-Forwarded-Proto` only from peers that `TrustedProxies` accepted.
2. **Phoenix endpoint `force_ssl` option** with `rewrite_on`.
3. **Leave TLS entirely to the proxy** (no app-level redirect or HSTS).

For leaked secrets:

1. **Fail fast at boot**: minimum length and SHA-256 fingerprint deny-list of published values.
2. **Rewrite git history** to remove the values.
3. **Document rotation only.**

### Pros and cons of the options

- **Separate step + advisory lock**: correct by construction and also safe if a platform runs it twice; covers concurrent-index migrations. Bad: every deploy pipeline must add a pre-deploy step, and the advisory lock requires a session-mode connection (not PgBouncer transaction pooling).
- **Migrate-on-start**: zero pipeline changes, but concurrent runs with non-transactional migrations are unsafe, and every replica start pays the migration check.
- **Leader election**: correct, but adds clustering requirements for a problem Postgres solves with one lock.
- **Runtime ForceSSL plug**: secure behind proxies, configurable per environment without rebuilding. Bad: custom code to maintain, and WebSocket upgrades are dispatched by Phoenix before endpoint plugs, so the proxy must still enforce `wss`.
- **Endpoint `force_ssl`**: built in, but compile-time and spoofable through `X-Forwarded-Proto`.
- **Proxy only**: simplest, but a misconfigured proxy silently serves plain HTTP with no HSTS.
- **Fail fast**: protects every deployment, including ones whose operators never read the advisory. Bad: an upgrade can refuse to boot until the operator rotates.
- **History rewrite**: breaks every clone and fork, and the values are already public, so it removes nothing.
- **Docs only**: depends on every operator reading them.

## Decision

**Migrations run once.** The image's default command is `/app/bin/server`, which starts the release and never migrates. `/app/bin/migrate` runs `Converger.Release.migrate()` (and `Release.create_db()` first when `CREATE_DB=true`) as a separate step: the compose `migrate` one-shot service, with `app` depending on it via `service_completed_successfully`; a Kubernetes Job or Helm hook; a Fly `release_command`. `Converger.Repo` is configured with `migration_lock: :pg_advisory_lock` (retry interval 1 s), so concurrent runners wait for the lock holder, find nothing pending and exit 0. `Release.migrate/0` retries once on the fresh-database race where two runners both try to create `schema_migrations` before the lock is taken. Schema changes follow expand/contract so the old release keeps working during a rolling deploy; the migration adding `admin_users.must_change_password` is expand-only.

**HTTPS.** `ConvergerWeb.Plugs.ForceSSL` reads `:converger, :force_ssl` on every call and delegates to `Plug.SSL`. It sets `rewrite_on: [:x_forwarded_proto]` only when `TrustedProxies` recorded the peer in `conn.private[:peer_remote_ip]`, that is, when the TCP peer is a trusted proxy ([ADR-0011](0011-custom-trusted-proxies-plug.md)). It runs right after `TrustedProxies` and before `Plug.Static`, so static assets are covered.

| Variable | Default (prod) | Effect |
| --- | --- | --- |
| `FORCE_SSL` | `true` | redirect HTTP to `https://PHX_HOST`; `false` disables the plug |
| `HSTS` | `true` | send `strict-transport-security` |
| `HSTS_MAX_AGE` | `31536000` | HSTS `max-age` in seconds |
| `HSTS_INCLUDE_SUBDOMAINS` | `false` | `includeSubDomains` |
| `HSTS_PRELOAD` | `false` | `preload` |
| `FORCE_SSL_EXCLUDE_PATHS` | empty | comma-separated paths exempt from the redirect (`localhost` and `127.0.0.1` hosts are always exempt) |
| `CHECK_ORIGIN` | unset (endpoint host) | comma-separated allowed WebSocket origins; set but empty raises at boot |

**Secrets fail fast.** `config/runtime.exs` raises when `SECRET_KEY_BASE` is missing or shorter than 64 bytes, when `CLOAK_KEY` is missing, and when the SHA-256 of `SECRET_KEY_BASE` or `CLOAK_KEY` matches a value published in this repository (the old compose key and the demo `CLOAK_KEY` from [#79](https://github.com/AimTune/converger/pull/79)). History is not rewritten; [security](../security.md) lists the leaked values and how to rotate each. `docker-compose.yml` reads `POSTGRES_PASSWORD`, `SECRET_KEY_BASE`, `CLOAK_KEY` and `GF_SECURITY_ADMIN_PASSWORD` with `${VAR:?message}`, so `docker compose up` without a `.env` fails with "Copy .env.example to .env ...". `.env.example` is committed, `.env` is ignored by git and Docker, and Postgres is published on loopback only.

**Admin bootstrap.** `Accounts.bootstrap_super_admin/1` (used by `Release.seed_admin/0` and `seeds.exs`) takes `ADMIN_EMAIL`/`ADMIN_PASSWORD` when set; otherwise it generates a random password, prints it once and sets `must_change_password`. Flagged admins are redirected to `/admin/password` (plug and LiveView `on_mount` hook) until they change it.

The toolchain was aligned in the same change (`.tool-versions` and Dockerfile on Elixir 1.19.5 / OTP 28.5.0.5); that baseline is recorded in [ADR-0023](0023-platform-and-dependency-baseline.md).

## Consequences

### Positive

- Two `bin/migrate` containers started together on a fresh database both exit 0; one applies all migrations, the other none.
- No deployment can keep running on a published `SECRET_KEY_BASE` or demo `CLOAK_KEY`.
- HTTPS and HSTS are on by default in production and cannot be spoofed by a direct client.
- A documented runbook: env var reference, TLS behind proxies, migrations and expand/contract, backups (`pg_dump` plus WAL archiving/PITR), restore drill, upgrade and rollback, capacity guidance ([deployment](../deployment.md)).

### Negative and trade-offs

- **Operator action required on upgrade**: pipelines must run `/app/bin/migrate` before starting the new release; deployments using the leaked key must rotate it before the release will boot.
- With `FORCE_SSL` on and `TRUSTED_PROXIES` unset, every request behind a TLS-terminating proxy is redirected to https (a redirect loop through the proxy). This is the safe failure but a common first-deploy surprise.
- The advisory lock does not work behind PgBouncer in transaction-pooling mode; migrations need a direct or session-mode connection.
- WebSocket upgrades bypass `ForceSSL`; `wss` must be enforced by the proxy.
- The fingerprint deny-list only knows values published here; it is not a general weak-secret detector.
- Some migrations (the `activities.seq` backfill `20261008150000` and the secret-encryption migrations `20261008100000`/`20261008100001`) still need a maintenance window; the lock makes them safe, not online.

### Follow-ups

- Health and readiness endpoints, k8s manifests and multi-node clustering: [#29](https://github.com/AimTune/converger/issues/29).
- Graceful degradation and readiness flip under database pressure: [#35](https://github.com/AimTune/converger/issues/35).
- Socket draining on shutdown for zero-downtime deploys: [#27](https://github.com/AimTune/converger/issues/27), decided in [ADR-0027](0027-websocket-limits-backpressure-and-draining.md).
- Admin 2FA, password reset and session expiry: [#52](https://github.com/AimTune/converger/issues/52).
- Making Trivy blocking for releases ([ADR-0021](0021-ci-quality-gates-and-lf-line-endings.md)).

## Implementation

- [`Converger.Release`](https://github.com/AimTune/converger/blob/main/lib/converger/release.ex): `create_db/0`, `migrate/0` (with the one-time retry), `rollback/2`, `seed_admin/0`, `reencrypt_secrets/0`.
- Release overlays [`rel/overlays/bin/migrate`](https://github.com/AimTune/converger/blob/main/rel/overlays/bin/migrate) and [`rel/overlays/bin/server`](https://github.com/AimTune/converger/blob/main/rel/overlays/bin/server); [`Dockerfile`](https://github.com/AimTune/converger/blob/main/Dockerfile) `CMD ["/app/bin/server"]`; [`docker-compose.yml`](https://github.com/AimTune/converger/blob/main/docker-compose.yml) `migrate` service; [`.env.example`](https://github.com/AimTune/converger/blob/main/.env.example).
- Advisory lock: `migration_lock: :pg_advisory_lock` and `migration_advisory_lock_retry_interval_ms: 1_000` for `Converger.Repo` in [`config/config.exs`](https://github.com/AimTune/converger/blob/main/config/config.exs).
- [`ConvergerWeb.Plugs.ForceSSL`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/force_ssl.ex), plugged in [`ConvergerWeb.Endpoint`](https://github.com/AimTune/converger/blob/main/lib/converger_web/endpoint.ex) after [`ConvergerWeb.Plugs.TrustedProxies`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/trusted_proxies.ex).
- Secret checks, `CHECK_ORIGIN` and the `FORCE_SSL`/`HSTS_*` parsing in [`config/runtime.exs`](https://github.com/AimTune/converger/blob/main/config/runtime.exs).
- Admin bootstrap: [`Converger.Accounts`](https://github.com/AimTune/converger/blob/main/lib/converger/accounts.ex) `bootstrap_super_admin/1`, [`ConvergerWeb.AdminPasswordController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/admin_password_controller.ex), the redirect in [`ConvergerWeb.Plugs.Auth`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/auth.ex) and [`ConvergerWeb.Live.AuthHooks`](https://github.com/AimTune/converger/blob/main/lib/converger_web/live/auth_hooks.ex); migration [`20261009550000_add_must_change_password_to_admin_users`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261009550000_add_must_change_password_to_admin_users.exs).

Tests: [`test/converger/release_migration_lock_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/release_migration_lock_test.exs), [`test/converger_web/plugs/force_ssl_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/plugs/force_ssl_test.exs), [`test/converger_web/check_origin_config_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/check_origin_config_test.exs), [`test/converger/accounts_bootstrap_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/accounts_bootstrap_test.exs) and [`test/converger_web/controllers/admin_password_controller_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/admin_password_controller_test.exs). The two-replica migration run and the boot refusal with a missing, short or leaked `SECRET_KEY_BASE` were verified manually against the built image.

## Links

- Issue [#55](https://github.com/AimTune/converger/issues/55), pull request [#90](https://github.com/AimTune/converger/pull/90)
- Epic [#57](https://github.com/AimTune/converger/issues/57) (v2.5 production hardening: security baseline)
- [Deployment guide](../deployment.md), [security notes](../security.md)
- [Ecto.Migrator and `migration_lock`](https://hexdocs.pm/ecto_sql/Ecto.Adapters.Postgres.html#module-migration-options)
