---
title: "ADR-0018: Keyset pagination for growing tables, seq pages for activities, hard caps for small tables"
sidebar_label: "0018 Keyset pagination"
description: Every user-facing list query is bounded, using keyset cursors on (inserted_at, id), seq-based pages for activities and a logged hard cap for small operator-managed tables.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#18](https://github.com/AimTune/converger/issues/18) |
| **Pull request** | [#89](https://github.com/AimTune/converger/pull/89) |
| **Related** | [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0017](0017-conversation-lifecycle-enforced-under-the-seq-lock.md), [ADR-0022](0022-deployment-hardening.md), [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md) |

This ADR records how Converger bounds list queries: which pagination strategy each kind of table uses, how cursors are encoded, and how the WebSocket replay hands off to REST.

## Context and problem statement

Several list queries had no limit:

- `Activities.list_activities_for_conversation/1` returned the whole history. `GET /conversations/:id/activities` without a watermark and the WebSocket join replay both used it, so a long-lived conversation (a support chat that runs for months, an IoT stream) became a multi-megabyte response, a slow query and a large message pushed into one channel process.
- `Conversations.list_conversations/1`, `Channels.list_channels/0`, the audit log listing and the LiveView pages (`ConversationLive`, `AuditLogLive`, `TenantUserLive`) loaded entire tables into memory. The audit log page also ran `COUNT(*)` for "Page X of Y".

Conversations, activities, deliveries and audit logs only grow, so each of these was a latent outage: memory spikes in the admin node and request timeouts that got worse every day.

## Decision drivers

- No context function returns an unbounded list for user-facing data.
- Page cost must not depend on how deep the client is (page 1 and page 200 cost the same).
- Concurrent inserts must not shift or duplicate rows between pages.
- Cursors are opaque, so the server can change the encoding later.
- Existing response shapes stay compatible; only fields are added.
- Admin pages stay responsive at 100k conversations.

## Considered options

1. **Keyset (seek) pagination** on `(inserted_at, id)` with an opaque cursor, plus `seq` pages for activities and a hard cap for small tables.
2. **`LIMIT`/`OFFSET` pagination** with page numbers.
3. **Postgres cursors (`DECLARE ... CURSOR`)** held per client session.
4. **Only cap results** (a fixed `LIMIT` everywhere, no continuation).

### Pros and cons of the options

**Option 1: keyset**

- Good: every page is an index range scan; cost is independent of depth.
- Good: stable under inserts, because the next page starts strictly after the last row seen.
- Good: activities already have a gap-free per-conversation `seq` ([ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md)), which is a perfect key.
- Bad: no random access ("jump to page 37") and no total count without a separate query.
- Bad: needs composite indexes matching each sort order.

**Option 2: offset**

- Good: simplest to implement; page numbers and totals are familiar in admin UIs.
- Bad: page N costs O(N) because Postgres must read and discard the skipped rows.
- Bad: rows inserted while a client pages shift the window, causing duplicates or skipped rows.

**Option 3: server-side cursors**

- Good: consistent snapshot while paging.
- Bad: holds a connection and a transaction per paging client, which does not fit stateless REST or a pooled Ecto setup.

**Option 4: cap only**

- Good: trivial; fixes the memory problem.
- Bad: data beyond the cap becomes unreachable, which is unacceptable for transcripts and audit logs.

## Decision

Chosen option: **keyset pagination** (option 1), applied as three strategies chosen by table shape:

| Strategy | Tables | Key | API |
| --- | --- | --- | --- |
| Keyset cursor | conversations, audit logs, tenant users, deliveries | `(inserted_at, id)`; dead letters use `(updated_at, id)` | `cursor`, `limit` -> `next_cursor`, `has_more` |
| Sequence pages | activities | per-conversation `seq` | `watermark`, `limit` -> `watermark`, `has_more` |
| Hard cap | tenants, channels, routing rules, admin users | none | `bounded_all/2`, logs a warning when the cap is hit |

Keyset wins because the growing tables are append-mostly and are read newest-first or oldest-first, never by page number. With `OFFSET`, page N costs O(N) and concurrent inserts shift the pages; with a keyset, every page is an index seek, which the benchmark confirmed (first page 3 ms, page 202 1 ms at 100k rows). The cursor is `Base.url_encode64("ts:" <> iso8601 <> "|" <> uuid)` without padding; clients must treat it as opaque. An invalid cursor is an error (`{:error, :invalid_cursor}`), not a silent restart.

Small operator-managed tables are needed whole for dropdowns and are orders of magnitude smaller than the cap, so a page UI would be overkill; `bounded_all/2` fetches `cap + 1` rows and logs a warning when it truncates, so an incomplete dropdown is visible in logs.

Page sizes are configuration, not constants, and request limits are clamped instead of rejected:

| Key (`config :converger, :pagination`) | Default | Env override |
| --- | --- | --- |
| `default_limit` / `max_limit` | 50 / 500 | `PAGINATION_DEFAULT_LIMIT` / `PAGINATION_MAX_LIMIT` |
| `activity_default_limit` / `activity_max_limit` | 100 / 1000 | `PAGINATION_ACTIVITY_DEFAULT_LIMIT` / `PAGINATION_ACTIVITY_MAX_LIMIT` |
| `ws_replay_limit` | 100 | `PAGINATION_WS_REPLAY_LIMIT` |
| `lookup_limit` | 1000 | `PAGINATION_LOOKUP_LIMIT` |

The WebSocket replay on join is capped at `ws_replay_limit`. The Converger `activitySet` frame carries `has_more`; when it is `true` the client continues over `GET /api/v1/converger/conversations/:id/activities?watermark=` from the frame's watermark and de-duplicates by activity id against live frames. The legacy `conversation:*` channel pushes a `replay_truncated` event `{has_more, last_activity_id}` after a truncated replay. Keeping bulk history on REST keeps channel processes and frames small.

## Consequences

### Positive

- Every user-facing list is bounded; the remaining `Repo.all` calls are internal (routing resolution, cycle detection, health checks, aggregates).
- Page cost is flat with depth; admin pages stay responsive at 100k conversations (`/admin/conversations` mount 161 ms, "Load more" 10 ms in the seeded benchmark).
- New tenant endpoint `GET /api/v1/conversations` with `cursor`, `limit`, `status`, `channel_id`.
- LiveView tables use `stream/3` with "Load more"; transcripts open at the latest activities with "Load earlier" (`page_recent_activities/2` with `:before_seq`).

### Negative and trade-offs

- **Behaviour change**: both activity endpoints used to return the full history when no watermark was given; they now return one page (100 by default). Clients that need everything must follow `has_more`.
- No total counts and no "Page X of Y" in the audit log UI.
- Five new composite indexes cost write amplification on hot tables. They were built `concurrently` in a migration with `@disable_ddl_transaction` and `@disable_migration_lock`.
- The dead-letter listing orders by `(updated_at, id)`, which has no dedicated composite index; it uses the existing `deliveries(status)` index and sorts the `failed` rows, which is fine while the dead-letter set stays small (DLQ tooling in [#32](https://github.com/AimTune/converger/issues/32)).
- `AuditLogs.list_audit_logs/2` keeps limit/offset for backward compatibility (its limit is now clamped); the admin page no longer uses it.
- On the Converger API an invalid watermark still starts from the beginning (legacy behaviour); on the tenant API it returns 400. The two APIs differ here.

### Follow-ups

- Table partitioning and retention for `activities` and `deliveries`: [#30](https://github.com/AimTune/converger/issues/30). Keyset on `seq`/`inserted_at` is partition-friendly.
- Integer `seq` watermarks on the wire for Converger Protocol v1: [#63](https://github.com/AimTune/converger/issues/63), see [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md).
- Admin panel modernization with search and filters: [#50](https://github.com/AimTune/converger/issues/50).
- Consistent error envelope and documented pagination in OpenAPI: [#45](https://github.com/AimTune/converger/issues/45).

## Implementation

- [`Converger.Pagination`](https://github.com/AimTune/converger/blob/main/lib/converger/pagination.ex): `config/1`, `clamp_limit/2`, `keyset/2` and `keyset!/2` (options `:limit`, `:cursor`, `:direction`, `:field`, `:preload`), `bounded_all/2`, `split/2`, `encode_cursor/2`, `decode_cursor/1`. The page struct is [`Converger.Pagination.Page`](https://github.com/AimTune/converger/blob/main/lib/converger/pagination/page.ex) (`entries`, `next_cursor`, `has_more`, `limit`).
- [`Converger.Activities`](https://github.com/AimTune/converger/blob/main/lib/converger/activities.ex): `page_activities_since/3` and `page_recent_activities/2`; every `list_activities_*` function returns one bounded page.
- Context functions: `Conversations.paginate_conversations/2` (filters `tenant_id`, `channel_id`, `status`, `q`), `AuditLogs.paginate_audit_logs/2`, `Deliveries.paginate_deliveries/2`, `Deliveries.paginate_dead_letters/2`, `Accounts.paginate_tenant_users/2`.
- WebSocket: [`ConvergerWeb.ConvergerChannel`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/converger_channel.ex) (`has_more` in `activitySet`) and [`ConvergerWeb.ConversationChannel`](https://github.com/AimTune/converger/blob/main/lib/converger_web/channels/conversation_channel.ex) (`replay_truncated`).
- Configuration: [`config/config.exs`](https://github.com/AimTune/converger/blob/main/config/config.exs) and the `PAGINATION_*` overrides in [`config/runtime.exs`](https://github.com/AimTune/converger/blob/main/config/runtime.exs).
- Migration [`20261009180000_add_keyset_pagination_indexes`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261009180000_add_keyset_pagination_indexes.exs): `conversations(inserted_at, id)`, `conversations(tenant_id, inserted_at, id)`, `audit_logs(inserted_at, id)`, `tenant_users(inserted_at, id)`, `deliveries(inserted_at, id)`.

Tests: [`test/converger/pagination_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/pagination_test.exs) (clamping, cursor round-trip and invalid cursors, a keyset walk with timestamp ties in both directions, activity pages, `bounded_all` cap), [`test/converger_web/pagination_api_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/pagination_api_test.exs) (REST paging, WS replay cap then REST continuation, `replay_truncated`), [`test/converger_web/live/pagination_live_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/live/pagination_live_test.exs) (Load more and Load earlier). The 100k-row benchmark is [`test/load/pagination_benchmark_test.exs`](https://github.com/AimTune/converger/blob/main/test/load/pagination_benchmark_test.exs), run with `mix test test/load/pagination_benchmark_test.exs --include benchmark`.

## Links

- Issue [#18](https://github.com/AimTune/converger/issues/18), pull request [#89](https://github.com/AimTune/converger/pull/89)
- Epic [#57](https://github.com/AimTune/converger/issues/57) (v2.5 production hardening)
- [Use the Index, Luke: paging through results](https://use-the-index-luke.com/no-offset)
