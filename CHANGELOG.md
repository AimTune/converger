# Changelog

## Unreleased

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
