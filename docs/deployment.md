---
sidebar_label: Deployment
description: Environment variables, secrets, TLS/HSTS, migrations, initial admin, backups and the upgrade/rollback runbook for running Converger in production.
---

# Deployment

Converger ships as a standard Elixir release (see the `Dockerfile`). All
deployment-specific settings are read from environment variables in
`config/runtime.exs` when the release boots, so the same build can be promoted
between environments without recompiling.

Contents:

- [Environment variables](#environment-variables)
- [Secrets and docker compose](#secrets-and-docker-compose)
- [TLS, HSTS and WebSocket origins](#tls-hsts-and-websocket-origins)
- [Migrations](#migrations) (separate step, advisory lock, zero-downtime rules)
- [Initial admin account](#initial-admin-account)
- [Backups and restore](#backups-and-restore)
- [Upgrade and rollback runbook](#upgrade-and-rollback-runbook)
- [Capacity guidance](#capacity-guidance)
- [Toolchain versions](#toolchain-versions)

## Environment variables

### Required in production

| Variable | Description |
| --- | --- |
| `DATABASE_URL` | Postgres connection URL, e.g. `ecto://USER:PASS@HOST/DATABASE`. The release refuses to boot without it. |
| `SECRET_KEY_BASE` | Secret used to sign/encrypt cookies and tokens. Generate one with `mix phx.gen.secret`. The release refuses to boot without it, if it is shorter than 64 bytes, or if it is a value that was published in this repository (see [docs/security.md](security.md#rotating-leaked-secrets)). |
| `CLOAK_KEY` | Base64-encoded 32-byte key that encrypts channel secrets at rest (issue #12), e.g. `openssl rand -base64 32`. Required by builds that include channel secret encryption; back it up together with the database (see [Backups](#backups-and-restore)). The demo key that was proposed for `docker-compose.yml` is rejected at boot. |

### HTTPS and origins

See [TLS, HSTS and WebSocket origins](#tls-hsts-and-websocket-origins).

| Variable | Default | Description |
| --- | --- | --- |
| `FORCE_SSL` | `true` (prod) | Redirect plain HTTP to `https://PHX_HOST` and send HSTS on HTTPS responses. Set `false` only when nothing can reach the app over plain HTTP. |
| `HSTS` | `true` | Send `strict-transport-security` on HTTPS responses (when `FORCE_SSL` is on). |
| `HSTS_MAX_AGE` | `31536000` | HSTS `max-age` in seconds. Start low (e.g. `300`) when first enabling it. |
| `HSTS_INCLUDE_SUBDOMAINS` | `false` | Add `includeSubDomains`. Only if every subdomain serves HTTPS. |
| `HSTS_PRELOAD` | `false` | Add `preload`. Only together with a long max-age and `includeSubDomains`, and after submitting to the preload list. |
| `FORCE_SSL_EXCLUDE_PATHS` | unset | Comma-separated paths served over plain HTTP without redirect (e.g. a load balancer health check path). Requests for host `localhost`/`127.0.0.1` are never redirected. |
| `CHECK_ORIGIN` | host of `PHX_HOST` | Comma-separated origins allowed to open browser WebSocket connections (LiveView, `/socket`, `/socket/converger`), e.g. `https://converger.example.com,//*.example.com`. Clients that send no `Origin` header (servers, mobile SDKs) are not affected. |

### Release scripts

| Variable | Default | Description |
| --- | --- | --- |
| `CREATE_DB` | `false` | `bin/migrate` creates the database first when `true` (needs `CREATEDB`; leave unset on managed databases). |
| `ADMIN_EMAIL` | `admin@converger.local` | Email of the first super admin created by `Converger.Release.seed_admin/0` / `priv/repo/seeds.exs`. |
| `ADMIN_PASSWORD` | generated | Password of that account. When unset, a random password is printed once and must be changed at first login. |

### HTTP server

| Variable | Default | Description |
| --- | --- | --- |
| `PHX_SERVER` | unset | When set (to any value), starts the HTTP endpoint. Required for releases (`PHX_SERVER=true bin/converger start`); `bin/server` (the Docker image's default command) sets it for you. |
| `PHX_HOST` | `example.com` | Public host name used when generating URLs (prod only). URLs are generated as `https://PHX_HOST:443`. |
| `PORT` | `4000` | Port the HTTP endpoint listens on (prod; also honoured in dev). |

WebSocket limits and draining are tuned with `WS_*` variables (frame size, message rate, joins, slow consumers,
drain delay and batches); see [WebSocket limits and draining](operations/websocket-limits.md#configuration).
Load balancers and Kubernetes probe `GET /health/live` and `GET /health/ready`.

### Database

| Variable | Default | Description |
| --- | --- | --- |
| `POOL_SIZE` | `10` | Ecto connection pool size (prod only). |
| `ECTO_IPV6` | unset | Set to `true` or `1` to connect to Postgres over IPv6 (prod only). |

### Security

| Variable | Default | Description |
| --- | --- | --- |
| `CORS_ORIGINS` | `http://127.0.0.1:5500,http://localhost:5500` | Comma-separated list of origins allowed by CORS, e.g. `https://app.example.com,https://admin.example.com`. Use `*` to allow any origin. Origins are resolved per request from the application env, so changing this on a release only needs a restart, not a rebuild. |
| `ADMIN_IP_WHITELIST` | `127.0.0.1,::1` | Comma-separated list of client IPs allowed to reach the `/admin` routes. |
| `TRUSTED_PROXIES` | unset | Comma-separated IPs/CIDRs of reverse proxies whose `X-Forwarded-For` and `X-Forwarded-Proto` headers are honoured. See [docs/security.md](security.md). |

### Clustering and metrics

| Variable | Default | Description |
| --- | --- | --- |
| `DNS_CLUSTER_QUERY` | unset | DNS name queried by `DNSCluster` to discover and connect other nodes (prod only). Clustering is disabled when unset. |
| `PROMETHEUS_PORT` | `9568` | Port of the Prometheus metrics exporter. Not started in `test` unless set. |

### Background jobs (Oban)

Deliveries are Oban jobs inserted in the same transaction as the activity
(transactional outbox). A job that was running when its node died
(`SIGKILL`, OOM kill, lost host) stays `executing` until Oban's Lifeline
plugin rescues it; only then is the delivery retried. See
[chaos testing](chaos.md).

| Variable | Default | Description |
| --- | --- | --- |
| `OBAN_LIFELINE_RESCUE_AFTER_SECONDS` | `1800` (30 min) | Seconds after which a job still `executing` is considered orphaned and made available again. Lower it to re-deliver sooner after a crash, but keep it well above the longest job runtime (a webhook delivery takes at most about 90 s: connect plus receive timeout), or a slow job that is still running is executed a second time. Receivers de-duplicate by `x-converger-delivery-id` either way. |
| `OBAN_LIFELINE_INTERVAL_SECONDS` | `60` | How often Lifeline looks for orphaned jobs. |

### Rate limiting

| Variable | Default | Description |
| --- | --- | --- |
| `RATE_LIMIT_BACKEND` | `cluster` when `DNS_CLUSTER_QUERY` is set, otherwise `local` | `local`: per-node ETS counters. `cluster`: per-node ETS counters replicated to every connected node over Phoenix PubSub, so limits apply across the cluster. |
| `RATE_LIMIT_SYNC_INTERVAL_MS` | `100` | How often the `cluster` backend broadcasts counter deltas to the other nodes. |

Default limits (requests per window; rejected requests get `429` with a
`Retry-After` header and emit `[:converger, :rate_limit, :exceeded]`
telemetry, exported as `converger_rate_limit_exceeded_count{bucket=...}`):

| Bucket | Default | Counted per | Applies to |
| --- | --- | --- | --- |
| `activity_create` | 100 / s | tenant | `POST /api/v1/conversations/:id/activities`, `POST /api/v1/converger/conversations/:id/activities` |
| `upload` | 10 / s | tenant | `POST /api/v1/converger/conversations/:id/upload` |
| `inbound` | 500 / s | channel | `POST /api/v1/channels/:id/inbound`, `POST /api/v1/channels/:id/status` |
| `token_generate` | 10 / min | channel | `POST /api/v1/converger/tokens/generate`, `/tokens/refresh` |
| `token_create` | 10 / min | client IP | `POST /api/v1/tokens` (legacy, unauthenticated) |
| `login_ip` | 5 failures / min | client IP | `/admin/login`, `/portal/login` |
| `login_account` | 5 failures / min | account | `/admin/login`, `/portal/login` |

Defaults can be changed for the whole installation with
`config :converger, Converger.RateLimit, limits: %{inbound: {1_000, 1_000}}`,
and per tenant (for the `activity_create`, `upload`, `inbound` and
`token_generate` buckets) with `Converger.Tenants.update_tenant_limits/3`,
which stores the override in `tenants.limits`, e.g.
`%{"inbound" => %{"limit" => 2000, "scale_ms" => 1000}}`. Overrides are cached
for 30s per node and invalidated cluster-wide when updated.

Login limits count failed attempts only. Once the IP or the account reaches
the limit, further attempts are rejected before the password is checked until
the window ends. Anyone who knows an account's identifier can trigger its
lock; the one-minute window keeps that bounded.

**Backend trade-offs.** Both backends use Hammer 7's fixed-window ETS counters
with windows aligned to wall-clock time, so a request costs one ETS update and
no database or network round trip.

- `local` is exact on a single node. Behind a load balancer with N nodes each
  node counts on its own, so a client can get up to N times the limit.
- `cluster` needs no extra infrastructure (it uses the Erlang distribution
  that `DNS_CLUSTER_QUERY` already sets up). Counter deltas are batched and
  broadcast every `RATE_LIMIT_SYNC_INTERVAL_MS`, so it is eventually
  consistent: a burst can overshoot by what the other nodes accept within one
  interval. Counters are in memory: a restarted node starts empty for the
  current window and catches up from the other nodes' next sync. Node clocks
  must be NTP-synchronised. Nodes that are not connected (netsplit) fall back
  to per-node limits.
- A Redis backend (`hammer_backend_redis`) would give exact global counters at
  the cost of a Redis round trip per request and another piece of
  infrastructure; a Postgres-backed counter was rejected because it would add
  a database write to every request on the paths the limits protect.

### OpenTelemetry tracing

Trace export is **disabled unless an OTLP endpoint is configured**. When neither
endpoint variable below is set, `config/runtime.exs` sets
`traces_exporter: :none` and no export requests are attempted. This applies to
dev as well: to send dev traces to the local collector from `docker-compose.yml`,
start the server with `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318`.
Export is always disabled in the test environment.

Spans are produced for Phoenix requests, Ecto queries, Oban job executions
(`opentelemetry_oban`), and outbound HTTP calls made through `Converger.HTTP`
(`opentelemetry_req`).

| Variable | Default | Description |
| --- | --- | --- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | Base URL of the OTLP collector, e.g. `http://otel-collector:4318`. `/v1/traces` is appended for traces. Setting it enables trace export. |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | unset | Full URL for traces only (no path is appended). Takes precedence over `OTEL_EXPORTER_OTLP_ENDPOINT`; setting it also enables export. |
| `OTEL_EXPORTER_OTLP_PROTOCOL` / `OTEL_EXPORTER_OTLP_TRACES_PROTOCOL` | `http_protobuf` | `http_protobuf` (port 4318) or `grpc` (port 4317). |
| `OTEL_EXPORTER_OTLP_HEADERS` / `OTEL_EXPORTER_OTLP_TRACES_HEADERS` | unset | Extra headers for export requests, as `key1=value1,key2=value2` (e.g. an API key for a hosted collector). |
| `OTEL_EXPORTER_OTLP_COMPRESSION` / `OTEL_EXPORTER_OTLP_TRACES_COMPRESSION` | none | Set to `gzip` to compress export requests. |
| `OTEL_SERVICE_NAME` | `converger` | Service name reported on every span. |
| `OTEL_RESOURCE_ATTRIBUTES` | unset | Extra resource attributes, as `key1=value1,key2=value2` (e.g. `deployment.environment=staging`). |
| `OTEL_TRACES_EXPORTER` | derived | Standard SDK override. Normally leave unset; `none` forces export off even when an endpoint is set. |
| `OTEL_SDK_DISABLED` | `false` | Set to `true` to disable the OpenTelemetry SDK entirely. |

The endpoint, protocol, headers and compression variables are read directly by
`opentelemetry_exporter`, and the service/resource/SDK variables by the
`opentelemetry` SDK, following the OpenTelemetry specification.

### Development and test only

These are read by `config/dev.exs` and `config/test.exs` and have no effect on
releases.

| Variable | Default | Description |
| --- | --- | --- |
| `DB_USERNAME` | `postgres` | Postgres user. |
| `DB_PASSWORD` | `postgres` | Postgres password. When developing against the compose `db` service, set it to the `POSTGRES_PASSWORD` from your `.env`. |
| `DB_HOSTNAME` | `localhost` | Postgres host. |
| `DB_NAME` | `converger_dev` / `converger_test` | Database name. In test, `MIX_TEST_PARTITION` is appended to the default. |
| `MIX_TEST_PARTITION` | unset | Suffix for the test database name, for running partitioned or concurrent test suites. |

## Example

Migrate once, then start any number of replicas:

```sh
export DATABASE_URL=ecto://converger:secret@db.internal/converger
export SECRET_KEY_BASE="..."   # from your secret store, never from git
export CLOAK_KEY="..."         # from your secret store, never from git
export PHX_HOST=converger.example.com
export TRUSTED_PROXIES=10.0.0.0/8
export CORS_ORIGINS=https://app.example.com
export OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318

bin/migrate        # one-off deploy step
bin/server         # on every replica (PHX_SERVER=true bin/converger start)
```

## Secrets and docker compose

No secret is committed to the repository. `docker-compose.yml` reads them from
a `.env` file next to it (gitignored and excluded from the Docker build
context); `.env.example` lists what is needed:

```sh
cp .env.example .env
# fill in POSTGRES_PASSWORD, SECRET_KEY_BASE, CLOAK_KEY, GF_SECURITY_ADMIN_PASSWORD
docker compose up -d
```

Every required value uses the `${VAR:?message}` form, so `docker compose up`
(and `docker compose config`) stops immediately with a message such as
`required variable SECRET_KEY_BASE is missing a value: SECRET_KEY_BASE is not
set. Copy .env.example to .env ...` instead of starting with a weak default.

Notes:

- Use URL-safe characters (e.g. `openssl rand -hex 24`) for
  `POSTGRES_PASSWORD`; it is embedded in `DATABASE_URL`.
- `POSTGRES_PASSWORD` is only applied when the Postgres volume is first
  initialised. For an existing `postgres_data` volume created with the old
  `postgres` password, either change it inside Postgres
  (`ALTER USER postgres PASSWORD '...'`) or recreate the volume.
- Postgres is published on `127.0.0.1:5432` only.
- In production, inject secrets from your platform's secret store
  (Kubernetes Secrets, AWS Secrets Manager/SSM, Vault, Fly secrets, ...) as
  environment variables. The release fails fast at boot (`config/runtime.exs`)
  when `DATABASE_URL`, `SECRET_KEY_BASE` or `CLOAK_KEY` are missing.

Secrets that were committed in the past must be rotated; see
[docs/security.md](security.md#rotating-leaked-secrets).

## TLS, HSTS and WebSocket origins

`ConvergerWeb.Plugs.ForceSSL` (a runtime-configured `Plug.SSL`) is **on by
default in production**: plain HTTP requests are redirected (301) to
`https://PHX_HOST`, and HTTPS responses carry
`strict-transport-security: max-age=31536000` (tune with the `HSTS_*`
variables). It is configured per boot from env vars, not at compile time, so
one image works with and without a proxy.

**Behind a TLS-terminating proxy or load balancer** (the usual setup), the app
sees plain HTTP from the proxy and learns the original scheme from
`X-Forwarded-Proto`. That header is honoured **only when the TCP peer is in
`TRUSTED_PROXIES`** (the same check `ConvergerWeb.Plugs.TrustedProxies` uses
for `X-Forwarded-For`, see [docs/security.md](security.md)). A client that
reaches the app directly cannot claim `X-Forwarded-Proto: https`. So:

1. Set `TRUSTED_PROXIES` to the proxy's addresses. Without it, every proxied
   request looks like plain HTTP and is redirected forever.
2. Make the proxy set (overwrite) `X-Forwarded-Proto` (nginx:
   `proxy_set_header X-Forwarded-Proto $scheme;`; ALB, GCP LB, Traefik and
   ingress-nginx do this by default).
3. If the load balancer health-checks over plain HTTP, either health-check the
   `localhost` host header, or list the path in `FORCE_SSL_EXCLUDE_PATHS`.
4. Roll HSTS out with a short `HSTS_MAX_AGE` first; browsers cache it.

Set `FORCE_SSL=false` only when TLS is enforced elsewhere and clients can never
reach the app over plain HTTP (the local `docker-compose.yml` does this, since
it serves `http://localhost:4000`).

WebSocket upgrades (`/socket`, `/socket/converger`, `/live`) are dispatched by
Phoenix before endpoint plugs, so they are not redirected. Do not expose the
plain HTTP port to clients; browsers that have seen HSTS upgrade `ws://` to
`wss://` on their own.

Browser WebSocket connections are also checked against `CHECK_ORIGIN`. By
default only the `PHX_HOST` host is accepted; set `CHECK_ORIGIN` explicitly when
the widget or admin UI is served from other origins (Phoenix wildcard syntax
such as `//*.example.com` is supported). Server-side and mobile clients that
send no `Origin` header are unaffected.

## Migrations

### A separate deploy step, exactly once

Replicas **do not** migrate on start. The image's default command is
`bin/server`; migrations run with `bin/migrate`
(`bin/converger eval "Converger.Release.migrate()"`) as a separate step that
must finish before new replicas start:

| Platform | How |
| --- | --- |
| docker compose | the one-shot `migrate` service; `app` waits for `service_completed_successfully` |
| Kubernetes | a `Job` (or Helm `pre-upgrade` hook / Argo CD `PreSync` hook) running `/app/bin/migrate` before the `Deployment` rolls |
| Fly.io | `[deploy] release_command = "/app/bin/migrate"` |
| Heroku / Render / Railway | release / pre-deploy command `/app/bin/migrate` |
| ECS / Nomad | a one-off task before updating the service |

As a second line of defence, `Converger.Repo` uses
`migration_lock: :pg_advisory_lock` (`config/config.exs`). If two runners start
at the same time (e.g. migrations wired as an init container on a
two-replica rolling deploy), the second one waits for the Postgres advisory
lock, then sees no pending migrations and exits. Each migration is applied
exactly once (covered by `test/converger/release_migration_lock_test.exs`).
Advisory locks are per session: run migrations over a direct connection or
PgBouncer in **session** mode, not transaction pooling.

`bin/migrate` with `CREATE_DB=true` also creates the database
(`Converger.Release.create_db/0`); leave it unset when the database already
exists or the role lacks `CREATEDB`.

To roll back a migration: `bin/converger eval
'Converger.Release.rollback(Converger.Repo, 20261008150000)'` (rolls back to,
and excluding, that version). Prefer a forward fix; see the runbook below.

### Zero-downtime schema changes: expand / contract

During a rolling deploy old and new code run side by side against the
**already migrated** schema. Every migration must therefore keep the
previous release working. Split incompatible changes over several releases:

1. **Expand** (release N): add nullable columns or columns with a constant
   default, new tables, and indexes with `create index(..., concurrently: true)`
   in a migration with `@disable_ddl_transaction true` (with the advisory
   lock strategy `@disable_migration_lock` is not needed; the runner keeps
   holding the lock). New code writes both the old and new shape.
2. **Migrate data** (release N or a background job): backfill in batches
   (e.g. 10k rows per `UPDATE ... WHERE id IN (...)`), not one statement over
   the whole table, so locks stay short and replicas keep up.
3. **Contract** (release N+1, after N is fully rolled out): add `NOT NULL`
   (first as `CHECK (col IS NOT NULL) NOT VALID`, then `VALIDATE CONSTRAINT`,
   then `SET NOT NULL`), drop old columns (stop reading them in N, drop in
   N+1), rename via add/copy/drop rather than `RENAME`.

Avoid in a single rolling deploy: `RENAME`/`DROP` of columns the old code
uses, `SET NOT NULL` on a column the old code does not write, changing a
column type (rewrites the table under `ACCESS EXCLUSIVE`), non-concurrent
index creation on large tables, and unbatched full-table `UPDATE`s. Set a
`lock_timeout` (e.g. `execute "SET lock_timeout TO '5s'"`) in risky
migrations so a blocked DDL fails fast instead of queueing all traffic behind it.

### Migrations that need a maintenance window

These existing migrations are **not** rolling-deploy safe. When upgrading
across them, stop the old release first (scale to zero or put the API behind a
maintenance page), run `bin/migrate`, then start the new release:

| Migration | Why |
| --- | --- |
| `20261008150000_add_seq_to_activities` | In one transaction it adds `activities.seq`, backfills **every** activity row with `row_number()`, sets `NOT NULL` and builds a non-concurrent unique index. `activities` is locked (`ACCESS EXCLUSIVE`) for the whole run, the table is fully rewritten (expect WAL roughly the table size and dead tuples; run `VACUUM ANALYZE activities` afterwards), and old code that inserts activities without `seq` fails once it commits. Time it on a restored copy of production first. |
| `20261008100000_encrypt_channel_secrets` (issue #12) | Rewrites every `channels` row with encrypted `secret`/`config` and drops the plaintext columns; old code cannot read the new values. Needs `CLOAK_KEY` at migration time. The table is small, so the window is short. |
| `20261008100001_hash_tenant_api_keys` (issue #12) | Replaces stored tenant API keys with hashes; old code can no longer authenticate tenants. |

`20261008120000_add_require_signature_to_channels` and
`20261009550000_add_must_change_password_to_admin_users` only add columns with
constant defaults (metadata-only on Postgres 11+) and are rolling-deploy safe.

## Initial admin account

There is no hard-coded admin password. Create the first super admin with:

```sh
ADMIN_EMAIL=ops@example.com ADMIN_PASSWORD='...' \
  bin/converger eval "Converger.Release.seed_admin()"   # release
mix run priv/repo/seeds.exs                             # dev (also part of mix ecto.setup)
```

Without `ADMIN_PASSWORD` a random password is generated and printed **once**,
and the account is flagged `must_change_password`: after logging in, the admin
is sent to `/admin/password` and cannot use the admin panel until the password
is changed. Nothing is created when an admin user already exists.

## Backups and restore

What to back up:

1. **The Postgres database** (all state: tenants, channels, conversations,
   activities, deliveries, Oban jobs, audit logs).
2. **`CLOAK_KEY`** (and any `CLOAK_RETIRED_KEYS`). Channel secrets are
   encrypted with it; a database backup is useless for channels without the
   key. Store it in your secret manager, separately from the database backups.
3. `SECRET_KEY_BASE` (losing it only logs everyone out and invalidates issued
   tokens, but keep it to avoid that).

### Logical backups (pg_dump)

Simple, portable, good for small and medium databases and for restore drills:

```sh
pg_dump --format=custom --no-owner --file=converger-$(date +%F).dump "$DATABASE_URL_PG"
```

(`DATABASE_URL_PG` is the same URL with a `postgres://` scheme.) Run it at
least daily from a host other than the database, keep several generations
(e.g. 7 daily, 4 weekly), encrypt them, and store them off-site (object
storage with versioning / object lock).

### Continuous archiving (WAL) and point-in-time recovery

For production, enable continuous WAL archiving so you can restore to any
moment, not just the last dump:

- Managed Postgres (RDS/Aurora, Cloud SQL, Azure, Crunchy Bridge, Supabase,
  ...): enable automated backups + PITR and set the retention window.
- Self-managed: use [pgBackRest](https://pgbackrest.org/) or
  [WAL-G](https://github.com/wal-g/wal-g) with `archive_mode = on`,
  `archive_command` pushing to object storage, and a weekly full + daily
  incremental base backup.

Monitor that archiving keeps working (`pg_stat_archiver.failed_count`,
age of the last archived WAL) and alert on it.

### Restore

```sh
createdb converger_restore
pg_restore --no-owner --dbname=postgres://.../converger_restore converger-YYYY-MM-DD.dump
# point DATABASE_URL at it, set the matching CLOAK_KEY, then:
bin/migrate      # applies any migrations newer than the backup
bin/server
```

For PITR, restore the base backup with your tool
(`pgbackrest restore --type=time --target='2026-10-08 12:00:00+00'`,
`wal-g backup-fetch` + `recovery_target_time`) into a new instance and switch
`DATABASE_URL` over.

### Restore drill

Restore a backup into a scratch database at least quarterly (and before
upgrades with a maintenance-window migration) and verify:

1. `pg_restore` / PITR completes and the time it takes fits your RTO.
2. The release boots against it with the production `CLOAK_KEY`, and the admin
   channel list shows channels (proves secrets decrypt).
3. Row counts of `conversations`, `activities` and `deliveries` match the
   source within the expected window (RPO).
4. A test conversation can be created and an activity posted.

Record the timings; they are the numbers to quote for RTO/RPO.

## Upgrade and rollback runbook

Before the upgrade:

1. Read the release notes / new migrations (`priv/repo/migrations`). Classify
   them: expand-only (rolling deploy) or [maintenance window](#migrations-that-need-a-maintenance-window).
2. Take (or confirm) a fresh backup / PITR point and note the time.
3. For long migrations, rehearse on a restored copy and time them.
4. Make sure new required env vars are set (the release fails fast at boot if
   they are missing; check the changelog and this document).

Rolling upgrade (expand-only migrations):

1. Build and push the new image.
2. Run `bin/migrate` once with the **new** image.
3. Roll the replicas to the new image (`bin/server`), one at a time. Use
   `GET /health/ready` as the readiness probe and give each replica a
   termination grace period of at least 60 s. On `SIGTERM` a replica turns
   not-ready, refuses new WebSockets, then closes its sockets in batches with
   1012 and a jittered `retryAfterMs`, so clients move to the other replicas
   without a reconnect storm. See
   [WebSocket limits and draining](operations/websocket-limits.md#draining-on-shutdown).
   Old and new replicas coexist safely.
4. Watch error rate, latency, Oban queue depth and delivery failures
   (Grafana/Prometheus) for a while.

Maintenance-window upgrade:

1. Announce the window; scale the old release to zero (or stop ingress).
2. Backup / note the PITR timestamp.
3. Run `bin/migrate` with the new image and wait for it to finish.
4. Start the new release, smoke test (`/admin`, create a conversation, post an
   activity, receive it over the WebSocket), reopen traffic.

Rollback:

- **Code-only rollback** (expand-only migrations): redeploy the previous
  image. The expanded schema is compatible with it; leave the migration in
  place.
- **Rolling back a migration**: only for migrations with a correct `down`, and
  only after scaling down the new release:
  `bin/converger eval 'Converger.Release.rollback(Converger.Repo, <version>)'`
  with the *new* image, then deploy the old one. Data written in the new shape
  may be lost.
- **Destructive migrations** (data rewrites such as the `activities.seq`
  backfill or channel encryption): restore the pre-upgrade backup / PITR point
  instead, accepting the loss of data written since. Prefer a forward fix when
  possible.

## Capacity guidance

Starting points; measure with your traffic (`test/load/performance_test.exs`,
the Prometheus metrics on `PROMETHEUS_PORT`):

- **Replicas**: at least 2 behind the load balancer for availability. The app is
  stateless apart from WebSocket connections; enable clustering with
  `DNS_CLUSTER_QUERY` so PubSub broadcasts reach sockets on every node.
- **CPU / memory**: 1 vCPU and 1 GiB per replica handles a few thousand idle
  WebSocket connections; each connected socket costs tens of KiB. Scale out on
  CPU and on connection count.
- **Database connections**: `replicas x POOL_SIZE` (+ Oban, + `bin/migrate`)
  must stay below Postgres `max_connections` with headroom. Start with
  `POOL_SIZE=10`; raise it when Ecto queue time (`converger.repo.query.queue_time`)
  grows. Use PgBouncer in session mode in front of many replicas.
- **Postgres**: `activities` and `deliveries` grow fastest; plan storage and
  autovacuum for them, and keep conversation expiry (Oban) enabled.
- **File descriptors**: raise `ulimit -n` (e.g. 65536) for many WebSocket
  connections; Bandit defaults are fine otherwise.
- **Per-socket memory** is bounded by the WebSocket limits (1 MiB hard frame
  cap, at most 1 000 frames buffered for a slow client); see
  [WebSocket limits and draining](operations/websocket-limits.md).

## Toolchain versions

`.tool-versions` (asdf / mise) pins the Elixir and Erlang/OTP versions used for
development; the `Dockerfile` build args (`ELIXIR_VERSION`, `OTP_VERSION`,
`DEBIAN_VERSION`) use the same versions. Bump them together.
