---
title: "ADR-0034: Monthly partitioning of activities and deliveries, per-tenant retention and verified archives"
sidebar_label: "0034 Partitioning and retention"
description: activities is range partitioned by inserted_at and deliveries by their activity's inserted_at; per-partition unique indexes plus the conversation row lock keep seq and idempotency keys unique; there are no foreign keys on the partitioned tables; expired data is archived as verified JSONL.gz before a month is detached and dropped or a tenant's rows are deleted.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-09 |
| **Issue** | [#30](https://github.com/AimTune/converger/issues/30) |
| **Pull request** | [#124](https://github.com/AimTune/converger/pull/124) |
| **Related** | [ADR-0001](0001-transactional-outbox-with-oban.md), [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0015](0015-per-message-idempotent-inbound-batches.md), [ADR-0017](0017-conversation-lifecycle-enforced-under-the-seq-lock.md), [ADR-0007](0007-attachment-storage-with-hand-written-signing.md), [ADR-0022](0022-deployment-hardening.md) |

`activities` and `deliveries` are the two tables that grow with traffic. This ADR records how they are partitioned, how the uniqueness guarantees of [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md) and [ADR-0015](0015-per-message-idempotent-inbound-batches.md) survive partitioning, how per-tenant retention works on partitions that all tenants share, and how existing installations get there.

## Context and problem statement

The PRD targets 10M messages a day. `activities` and `deliveries` were plain heap tables with UUID primary keys: at that rate they reach billions of rows within a year, their indexes stop fitting in memory, and `DELETE`-based cleanup becomes impossible (a `DELETE` of one month is hours of locks, WAL and vacuum). There was no retention at all; `Oban.Plugins.Pruner` only prunes jobs. `ON DELETE CASCADE` from `tenants` into both tables made deleting a large tenant one statement that runs for hours.

The issue asked for monthly range partitioning on `inserted_at`, per-tenant retention (`tenants.retention_days`, default 365) with archival to object storage, time-based pruning of `channel_health_checks` and `audit_logs`, and a documented migration path. Three constraints made the obvious version incorrect:

1. **Uniqueness.** Postgres requires every unique index on a partitioned table to contain the partition key. `activities` has two global guarantees that do not: `(conversation_id, seq)` (gap-free per-conversation ordering, allocated under a row lock on `conversations`, [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), [ADR-0017](0017-conversation-lifecycle-enforced-under-the-seq-lock.md)) and `(conversation_id, idempotency_key)` (exactly-once inbound processing, [ADR-0015](0015-per-message-idempotent-inbound-batches.md)). `(conversation_id, seq, inserted_at)` would be accepted by Postgres and guarantee nothing.
2. **Foreign keys.** `deliveries.activity_id` and `attachments.activity_id` reference `activities(id)`, which is no longer unique on its own.
3. **Shared partitions, per-tenant retention.** A month partition holds every tenant's rows for that month. Dropping it applies one retention to everybody.

And the product principle: no data may be lost. Retention must never remove a row that is not in a verified archive, and every step must survive a crash half way.

## Decision drivers

- Dropping a month must take milliseconds and must not block writers (acceptance criterion).
- `seq` stays strictly increasing and gap-free per conversation; an idempotency key is never stored twice per conversation, whatever month the first copy is in.
- Zero data loss: archive, verify (object exists, size and SHA-256 match, row counts match), only then drop or delete. Idempotent and resumable.
- Per-tenant retention without giving up the fast path for the common case (all tenants on the default).
- Deleting a tenant must not hold locks for hours.
- No new infrastructure: native declarative partitioning (no `pg_partman`), the existing `Converger.Uploads.Storage` backends, Oban.
- A tested migration path for populated installations that fits the maintenance-window rules of [ADR-0022](0022-deployment-hardening.md).

## Considered options

Partition key and uniqueness:

1. **Range by `inserted_at` (month), uniqueness per partition plus application invariants** - unique indexes on each partition; `seq` uniqueness comes from the counter, idempotency is re-checked across partitions under the conversation lock.
2. **Range by `inserted_at` with an idempotency window** - only look for duplicate idempotency keys in the last N days.
3. **Range by the conversation's creation month** - every row of a conversation in one partition, so `(conversation_id, seq, conversation_inserted_at)` is a real global unique index.
4. **Hash by `conversation_id` (or tenant)** - uniqueness works, retention does not.
5. **Range on a time-ordered id (UUIDv7)** - the primary key alone becomes the partition key.

Foreign keys:

- **A. Composite foreign keys** `(activity_id, activity_inserted_at) -> activities (id, inserted_at)` and keep `ON DELETE CASCADE` from `tenants`/`conversations`/`channels`.
- **B. No foreign keys on the partitioned tables**, application-level integrity and batched purge jobs.

Per-tenant retention:

- **I. Platform-wide retention only** (one `retention_days` for everybody).
- **II. Partition by tenant hash x month** (sub-partitions).
- **III. Hybrid**: drop a month when every tenant with rows in it has expired; before that, archive and delete only the expired tenants' rows inside the live partition.

### Pros and cons of the options

#### 1. `inserted_at` + per-partition unique indexes + invariants

- Good, because retention is "drop the oldest partitions", the textbook case, and queries for recent data touch recent partitions.
- Good, because `seq` is already unique by construction: it is allocated by `UPDATE conversations SET last_seq = last_seq + 1 ... RETURNING` under the row lock and the increment rolls back with the insert. The per-partition unique index `(conversation_id, seq)` stays as a database-level backstop for the partition the row is written to (always the current month).
- Good, because idempotency stays exact: the create path re-checks `(conversation_id, idempotency_key)` across all partitions *after* taking the conversation row lock. Every insert into a conversation takes that lock first, so a concurrent insert with the same key has either committed (and is visible, `READ COMMITTED`) or is waiting for us. The per-partition unique index still rejects the common same-month race at the database level.
- Bad, because the idempotency lookup probes one index per partition (13 at the default retention). An index probe per month is microseconds; acceptable.
- Bad, because global uniqueness of `seq` is now an application invariant rather than a constraint. Mitigated: one code path allocates `seq` (`Converger.Activities.create_activity/2`), it is covered by the concurrency tests of [ADR-0006](0006-per-conversation-seq-and-opaque-watermarks.md), and the counter on `conversations` makes a duplicate impossible without bypassing that path.

#### 2. Idempotency window

- Good, because the lookup touches only recent partitions.
- Bad, because a provider that re-delivers after the window (WhatsApp retries for days; manual replays) creates a duplicate. Weaker than today's guarantee for a saving we do not need.

#### 3. Conversation creation month

- Good, because both unique indexes become real global constraints.
- Bad, because a long-lived conversation (participant-based resolution, [ADR-0016](0016-participant-based-conversation-resolution.md), reuses one conversation per external party for years) keeps writing into its first month's partition: old partitions never stop growing, and "drop data older than N days" no longer maps to dropping partitions.

#### 4. Hash partitioning

- Good, because it spreads write load and keeps unique indexes simple.
- Bad, because it does nothing for retention: every partition holds every month, so expiring data is a `DELETE` again.

#### 5. UUIDv7 range

- Good, because `id` alone becomes a valid primary key and foreign key target.
- Bad, because existing ids are random v4: the existing data cannot be mapped to ranges, and `seq`/idempotency still need option 1's treatment.

#### A. Composite foreign keys with cascades

- Good, because the database keeps integrity.
- Bad, because detaching a partition that has a foreign key requires a `SHARE ROW EXCLUSIVE` lock on the referenced table (Postgres must create action triggers for the now independent constraint). Measured on Postgres 17: `DETACH PARTITION ... CONCURRENTLY` on a partitioned `activities` with a foreign key to `conversations` waited behind an ordinary `UPDATE conversations` (the `seq` increment) until its lock timeout; without the foreign key it ran alongside concurrent writers. That lock would block every activity insert while a month is dropped, violating the first driver.
- Bad, because cascades from `tenants`, `conversations` and `channels` into billions of rows are exactly the multi-hour delete the issue describes; per-insert foreign-key checks also cost a lookup per row.

#### B. No foreign keys, application integrity

- Good, because detach and drop touch nothing but the partition, and inserts skip the foreign-key lookups.
- Good, because deletions become batched jobs that never hold long locks.
- Bad, because orphans are possible if something deletes rows behind the application's back (raw SQL). Retention still archives orphaned rows (a tenant that no longer exists counts as expired), so they are eventually archived and dropped, not lost or kept forever.

#### I. Platform-wide retention

- Good, because it is the simplest: always drop.
- Bad, because the issue requires per-tenant retention, and different contracts (30 days vs 7 years) are a real requirement.

#### II. Tenant hash x month

- Good, because a tenant's month could be dropped alone if the hash bucket held one tenant.
- Bad, because buckets hold many tenants, so it only shrinks the problem; partition count multiplies (16 buckets x 24 months x 2 tables = 768 tables) and planning time with it.

#### III. Hybrid

- Good, because the common case (every tenant on the default) is a detach and drop.
- Good, because a tenant with a shorter retention than the others in the same month is still served exactly: its rows are archived and deleted in bounded batches from the live partition (a `DELETE` of one tenant's month, not of everybody's), and the partition is dropped once the last tenant expires.
- Bad, because a tenant with a very long retention keeps old partitions alive for everybody else, whose rows are then deleted row by row. Mitigated by the platform minimum and by documenting the trade-off; a follow-up can move such tenants to their own partition set if it becomes common.

## Decision

Chosen: **option 1** (monthly range on `inserted_at`, uniqueness per partition plus invariants), **B** (no foreign keys on the partitioned tables) and **III** (hybrid per-tenant retention), because together they keep every existing guarantee, make the common retention path a metadata operation that does not block writers, and need no new infrastructure.

Details:

- **`activities`** is range partitioned by `inserted_at`, one partition per calendar month (UTC), named `activities_pYYYY_MM`. Primary key `(id, inserted_at)`. Parent-level indexes: `(tenant_id, id)`, `(conversation_id, inserted_at)`, partial `(idempotency_key)`. Per-partition unique indexes, created with every partition: `(conversation_id, seq)` and partial `(conversation_id, idempotency_key)`. `Ecto.Changeset.unique_constraint/3` matches them by name suffix.
- **`deliveries`** is range partitioned by a new column **`activity_inserted_at`**, the `inserted_at` of its activity, not by its own `inserted_at`. A delivery therefore always lives in its activity's month: the unique index `(activity_id, channel_id, activity_inserted_at)` on the parent is a real global constraint (an activity has exactly one `inserted_at`), and a month's activities and deliveries are archived and dropped together even when a delivery is created weeks after its activity (retries). `deliveries` also gets `tenant_id`, so per-tenant archive and purge need no join. Both are copied from the activity when the delivery is created.
- **No foreign keys** from or to the partitioned tables (`activities -> tenants, conversations`, `deliveries -> activities, channels`, `attachments -> activities`). Deleting a tenant, channel or conversation deletes the row (small tables keep their cascades) and enqueues `Converger.Workers.PurgeWorker` in the same transaction, which removes the activities and deliveries in batches of 5,000. `Activities.delete_activity/1` deletes its deliveries itself.
- **Partitions** are created ahead of time (current month to three months ahead) by the migration, on boot and daily (`PartitionMaintenanceWorker`), as plain tables that are then attached (`ATTACH PARTITION` takes `SHARE UPDATE EXCLUSIVE` on the parent). There is no `DEFAULT` partition: it would forbid `DETACH ... CONCURRENTLY`.
- **Retention** (`Converger.Retention`, monthly `RetentionWorker`, unique while incomplete): for every month that ended at least `min_retention_days` (30) ago, if every tenant with rows in it is past its `tenants.retention_days` (default 365, at least the minimum), the month's two partitions are detached with `DETACH PARTITION ... CONCURRENTLY` (it waits for older transactions but never blocks reads or writes), each tenant's rows are exported from the detached tables, every object is downloaded again and its SHA-256 and size checked, the archived row count must equal the partition's row count, and only then are the tables dropped. Otherwise the expired tenants' rows are archived and deleted from the live partitions, one verified part per transaction (`SELECT ... FOR UPDATE`, upload, read back, record, `DELETE`). A detached partition whose archive has not finished is picked up first by the next run; nothing is dropped on any failure.
- **Archive format** (`Converger.Archive`): gzip-compressed JSON Lines, every column as `row_to_json` produces it, `archive/<tenant_id>/<YYYY-MM>/<table>-<NNNNN>.jsonl.gz`, at most 50,000 rows per part, deterministic part numbers (a retried part overwrites the same object), manifest table `archive_parts`. Storage is a `Converger.Uploads.Storage` backend, by default the attachment storage, optionally another bucket. Parquet was not chosen: it needs a native dependency and nothing reads the archive but the importer and humans. `mix converger.archive.import` (and `Converger.Release.import_archive/1`) re-imports a tenant-month, an object or a local file, creating partitions as needed, with `ON CONFLICT DO NOTHING`.
- **Other tables**: `channel_health_checks` (7 days) and `audit_logs` (365 days) are pruned daily by `PruneWorker` in batches of 10,000; each window is configurable and can be disabled.
- **Migration path** (`Converger.Partitions.Conversion`): create partitioned shadow tables and mirror triggers on the legacy tables, copy in primary-key batches (`FOR SHARE` + `ON CONFLICT DO NOTHING`, resumable cursor), then swap in one transaction under `ACCESS EXCLUSIVE` after a final catch-up and a row-count check; the legacy tables are kept as `*_legacy` on populated installations. Fresh and small installations do all of it inside `bin/migrate`. Above 1,000,000 activities the migration refuses to copy inline: the operator runs `Converger.Release.prepare_partitioning/0` online first and only the swap needs the maintenance window.

## Consequences

### Positive

- Dropping a month is a detach plus `DROP TABLE`, measured with 8 writers inserting activities through the normal code path the whole time (`test/load/partition_drop_benchmark_test.exs`, Docker Desktop on Windows, Postgres 17):

  | Rows per table and month | `DETACH ... CONCURRENTLY` (both tables) | `DROP TABLE` (both) | Slowest insert during the drop | `DELETE` of the same rows |
  | --- | --- | --- | --- | --- |
  | 200,000 | 45 ms | 149 ms | 56 ms | 1,010 ms |
  | 1,000,000 | 31 ms | 400 ms | 18 ms | 2,911 ms |

  Writers were never blocked (the slowest insert during the drop was below the writers' normal p99 of 62 ms in the larger run). `DELETE` grows linearly with the month and leaves dead tuples and WAL behind; detach is constant and the drop only unlinks files. The 100M-row run from the issue was not done on this machine.
- Recent data and its indexes live in small partitions; old months stop costing cache and vacuum.
- Every guarantee of ADR-0006, ADR-0015 and ADR-0017 is kept; idempotency is now also correct across month boundaries.
- Per-tenant retention with an exact, verified archive, and a re-import path.
- Deleting a tenant no longer runs one multi-hour statement.

### Negative and trade-offs

- **Maintenance window** on existing installations for the swap (and for the whole conversion on installations below the inline threshold). Old releases cannot write `deliveries` once it is partitioned.
- Lookups by `id` alone (`Repo.get(Activity, id)`, delivery receipts by id) probe one index per partition. Fine at 13-25 partitions; the per-partition cost is an index probe.
- The idempotency re-check adds one query per insert that carries an idempotency key.
- Integrity is enforced by the application: raw SQL deletes leave orphans (retention eventually archives them).
- An insert into a month without a partition fails. Partitions are kept three months ahead and checked daily and on boot; a delivery created for an activity whose month was already dropped fails (its job is retried and eventually discarded).
- Re-imported rows are subject to retention again.
- A tenant with a much longer retention than the others turns everyone else's expiry in those months into batched deletes.

### Follow-ups

- Attachments (files and rows) of expired activities are not yet archived or removed.
- Parquet export, if analytics needs it.
- A dedicated partition set for tenants with exceptional retention, if it becomes common.
- Batched deletion of `conversations` for very large tenants (they still cascade from `tenants`, but are orders of magnitude fewer than activities).

## Implementation

- `Converger.Partitions` ([`lib/converger/partitions.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/partitions.ex)): naming, `ensure_partitions/1`, `create_partition/3`, `detach/3`, `drop_detached/3`.
- `Converger.Partitions.Conversion`: legacy to partitioned conversion (prepare, copy, swap), used by migration `20261010300100_partition_activities_and_deliveries` and `Converger.Release.prepare_partitioning/0`.
- `Converger.Retention`, `Converger.Archive`, `Converger.Archive.Part`; workers `RetentionWorker`, `PartitionMaintenanceWorker`, `PruneWorker`, `PurgeWorker`; cron in `config/config.exs`, queue `maintenance`.
- Migration `20261010300000_add_retention_and_archive_parts` (`tenants.retention_days`, `archive_parts`).
- `Converger.Activities.create_activity/2` (idempotency re-check under the lock), `Converger.Deliveries.create_delivery/2` (copies `tenant_id` and `activity_inserted_at`), `Tenants.delete_tenant/2`, `Channels.delete_channel/2`, `Conversations.delete_conversation/1` (purge jobs).
- Tests: `test/converger/partitions_test.exs`, `test/converger/partitions/conversion_test.exs` (populated legacy tables, writes between copy batches, swap, rollback on mismatch), `test/converger/retention_test.exs` (both retention paths, upload failure and resume, checksum mismatch, re-import), the MinIO case in `test/converger/uploads/storage_integration_test.exs`, and the `:benchmark`-tagged `test/load/partition_drop_benchmark_test.exs`.

## Links

- [Data retention and archive](../operations/retention.md)
- [Migrations: partitioning activities and deliveries](../operations/migrations.md#partitioning-activities-and-deliveries-20261010300100)
- [Data model](../architecture/data-model.md)
- [File storage: archive layout](../storage.md#retention-archive)
- PostgreSQL: [table partitioning](https://www.postgresql.org/docs/17/ddl-partitioning.html), [`ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY`](https://www.postgresql.org/docs/17/sql-altertable.html)
