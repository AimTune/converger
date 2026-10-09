# Changelog

## Unreleased

### Partitioning, retention and archive for activities and deliveries (#30)

**Maintenance window** on existing installations (migration `20261010300100`); see
`docs/operations/migrations.md`. Design: `docs/adr/0026-monthly-partitioning-and-per-tenant-retention.md`.

- `activities` (by `inserted_at`) and `deliveries` (by the new `activity_inserted_at`) are monthly range
  partitioned tables, with no foreign keys. `deliveries` gains `tenant_id`. Partitions are created three months
  ahead (migration, boot, daily `PartitionMaintenanceWorker`).
- Existing installations convert with shadow tables, batched copy and swap; above 1,000,000 activities run
  `Converger.Release.prepare_partitioning/0` online first.
- Per-tenant retention: `tenants.retention_days` (default 365, minimum `RETENTION_MIN_DAYS`=30). The monthly
  `RetentionWorker` archives expired months as verified JSONL.gz to the attachment storage
  (`archive/<tenant>/<YYYY-MM>/`, manifest `archive_parts`), then detaches and drops the partitions, or deletes
  only the expired tenant's rows. `mix converger.archive.import` / `Converger.Release.import_archive/1`
  re-import archives.
- Daily `PruneWorker`: `channel_health_checks` (7 days) and `audit_logs` (365 days), configurable with
  `HEALTH_CHECK_RETENTION_DAYS` / `AUDIT_LOG_RETENTION_DAYS`.
- Deleting a tenant, channel or conversation purges its activities and deliveries in batches
  (`PurgeWorker`) instead of one cascading delete.
- Idempotency keys are now also honoured when the first copy is in an older month.
- Benchmark `test/load/partition_drop_benchmark_test.exs` (`--include benchmark`).

### Converger Protocol v1 specification (#21, refs #63 #68)

Documentation and schemas only; no server behaviour changes.

- `docs/protocol/v1.md`: the WebSocket wire protocol, a superset profile of mekik/1
  (handshake, frame envelope, replay and watermark semantics, acks, receipts, typing,
  presence, channel-scoped sockets, limits, error and close codes, deprecation policy,
  mekik/1 compatibility table). Every feature is marked implemented or planned with
  its issue.
- `docs/protocol/messages.md`: the rich message vocabulary (chativa-compatible) and
  the per-channel downgrade matrix.
- `docs/adr/0024-converger-protocol-v1-as-superset-of-mekik-1.md`: the decisions behind the spec (merged with the ADR from the docs site).
- JSON Schemas (draft 2020-12) for every frame and message type in `priv/protocol/v1/`,
  with example sessions.
- `test/protocol/`: conformance suite validating the schemas, the examples in the
  docs and mekik's golden fixtures (vendored, MIT). Adds `jsv` 0.26 as a test-only
  dependency (with `abnf_parsec`, `texture`, `nimble_parsec`).
- Announced change: from v3.0 (#22) the watermark becomes the integer `seq` in v1 frames
  and in the REST `activitySet`; the opaque base64url watermarks stay accepted for one
  more release (`docs/protocol/v1.md`, section 6.5).

### Chaos test: kill the node during load (#57)

- New chaos harness (`test/chaos/run.sh`, docs/chaos.md, manual/nightly
  `Chaos` workflow): SIGKILLs the app container while REST and WebSocket
  clients send, then verifies zero acked messages lost, no duplicates,
  gap-free `seq` and complete webhook delivery.
- Fixed: re-pushing a legacy WebSocket `new_activity` after a lost reply
  stored the message twice. The push now takes an optional `idempotency_key`
  (stored as `ws:<sender>:<key>`, unique per conversation) and the `ok` reply
  carries the activity `id` and `seq`.
- Added `OBAN_LIFELINE_RESCUE_AFTER_SECONDS` / `OBAN_LIFELINE_INTERVAL_SECONDS`
  to re-deliver jobs orphaned by a crashed node sooner than the 30 minute
  default (unchanged).

### Dependency and platform upgrades (#56)

Toolchain:

- Elixir 1.19.5 / Erlang/OTP 28.5.0.5, pinned in `.tool-versions` and used by
  the `Dockerfile` (`hexpm/elixir:1.19.5-erlang-28.5.0.5-debian-bookworm-20260824-slim`,
  previously 1.18.4 / OTP 27.2). `mix.exs` now requires Elixir `~> 1.18`.

Upgraded:

| Package | From | To | Notes |
| --- | --- | --- | --- |
| `hammer` | 6.2.1 | 7.5.0 | New API, done in #13 (rate limiting). |
| `phoenix_live_view` | 1.0.18 | 1.1.33 | CDN `phoenix_live_view.js` in the layouts was still 0.20.17; it is now pinned to the locked version and a test fails if they drift. `LiveViewTest` now uses `lazy_html`; `floki` was removed (unused). |
| `phoenix` | 1.8.3 | 1.8.15 | CDN `phoenix.js` bumped from 1.7.14 to match. |
| `oban` | 2.20.3 | 2.24.1 | Required by `oban_web` 2.13. Needs the `oban_jobs` schema at v14 (migration `20261009131000`). |
| `bandit` | 1.10.2 | 1.12.5 | Latest minor. |
| `broadway` | 1.2.1 | 1.3.0 | Latest minor. |
| transitive | | | `ecto`/`ecto_sql` 3.14, `plug` 1.20, `phoenix_pubsub` 2.4, `postgrex` 0.22.4, `decimal` 3.1 (not used directly), `websock_adapter` 0.6, `cowboy` 2.19. |

Added:

- `oban_web` 2.13 (Apache-2.0, free on hex.pm since Oban 2.19), mounted at
  `/admin/oban` behind the admin IP whitelist and admin session.
  `super_admin`/`admin` get full access and `viewer` gets read-only access
  (`ConvergerWeb.ObanResolver`).
- `opentelemetry_oban` 1.2: a span for every job execution
  (`OpentelemetryOban.setup/0`).
- `opentelemetry_req` 1.0 via `Converger.HTTP`, used by tenant alert
  webhooks. The channel adapters move to it once the open adapter PRs
  (#82, #85, #87) land.

Deferred in #56, applied afterwards (Dependabot #95, #97, #98, #99, #101, #103):

| Package | From | To | Notes |
| --- | --- | --- | --- |
| `phoenix_live_view` | 1.1.33 | 1.2.12 | Only breaking change is the trimmed global-attributes list (none used). Layout CDN scripts bumped to 1.2.12 (the version-drift test covers them). |
| `req` | 0.5.17 | 0.7.5 | Upgraded to 0.7.5 (`~> 0.7`) for the decompression-bomb fix (only in >= 0.6.1), via #92. The webhook adapter and its `Req.Test` stubs pass on 0.7; custom methods are limited to POST/PUT/PATCH (#87). |
| `gettext` | 0.26.2 | 1.0.2 | No breaking changes; the backend already uses `use Gettext.Backend`. |
| `logger_json` | 6.2.1 | 7.0.4 | The `{LoggerJSON.Formatters.Basic, opts}` handler config and `RedactKeys` are unchanged; JSON output and redaction re-verified. |
| `dns_cluster` | 0.2.0 | 0.3.1 | Adds SRV queries; the `query:` option used here is unchanged. |
| `joken`, `telemetry_metrics` | 2.6.2, 1.1.0 | 2.7.0, 1.2.0 | Compatible minor updates. |

Already handled elsewhere:

- OpenTelemetry exporter configuration is read at runtime from the standard
  `OTEL_*` variables (#76). Verified unchanged.
- WhatsApp Graph API version (`v18.0`) is made configurable in #82.
