---
title: Partition drop and archive at scale
sidebar_label: Partition retention at scale
description: Retention of one monthly partition (detach, archive, verify, drop) measured with 10M and 30M rows per table while writers insert, the scaling of each step, and the 100M-row figures extrapolated from them (not measured).
sidebar_position: 4
---

# Partition drop and archive at scale

Exit criterion of [epic #59](https://github.com/AimTune/converger/issues/59): *partition drop and archive verified on
a 100M-row dataset*. The maintainer chose **scaled evidence** for it: the whole retention path is measured with 10M
and 30M rows per table, the steps are checked for how they scale, and the 100M figures are **extrapolated from
those two runs, not measured**. The 100M run did not fit this machine's time and disk budget (about 78 GB of
partitions alone, see below).

The design being measured is [ADR-0034](../adr/0034-monthly-partitioning-and-per-tenant-retention.md). Its own
measurements (200k and 1M rows, detach and drop only, no archive) are in that ADR.

## What runs

`test/load/partition_drop_benchmark_test.exs`, test `retention_archive` (excluded from the default suite):

1. Seeds one far-past month (March 2001) with `BENCH_ROWS` activities and one delivery per activity, so
   `BENCH_ROWS` rows in each of the two partitions. Random UUID primary keys, as in production; activity text of
   16 bytes (narrow rows keep the disk use down; every other column is filled as the application fills it).
   The tables are filled first and their indexes built afterwards with the same statements
   `Converger.Partitions.create_partition/2` runs, so the schema is identical to a production partition
   (indexes built by sort come out somewhat more compact than indexes grown by inserts). The month is then
   vacuumed, frozen and checkpointed, as a month old enough to expire would be.
2. Starts 8 writers that insert activities through `Converger.Activities.create_activity/2` (into the current
   month) for the whole run, and lets them run alone for 10 s.
3. Calls **`Converger.Retention.run(months: [~D[2001-03-01]])`**, the code path of the monthly `RetentionWorker`,
   with the production settings: `DETACH PARTITION ... CONCURRENTLY`, and the archive written through
   `Converger.Uploads.LocalStorage` (50,000 rows per part). Retention detaches both partitions, exports every row
   as gzipped JSON Lines, downloads every object again and checks its size and SHA-256, checks that the archived
   row count equals the partition's row count, and only then drops the tables.
4. Times each step from the code path itself (Repo telemetry for the `DETACH` and `DROP` statements and the
   commit that follows the `DROP`, the `[:converger, :archive, :part]` event for each part) and checks the result:
   `archive_parts` holds exactly `BENCH_ROWS` rows per table, every part is marked verified, and six random parts
   are decompressed again and their lines counted against the manifest.

```bash
DB_NAME=converger_bench MIX_ENV=test mix do ecto.create, ecto.migrate
DB_NAME=converger_bench BENCH_ROWS=10000000 BENCH_TEXT_BYTES=16 BENCH_ARCHIVE_DIR=/tmp/archive \
  BENCH_OUT=bench.jsonl mix test test/load/partition_drop_benchmark_test.exs --only retention_archive
DB_NAME=converger_bench BENCH_ROWS=30000000 BENCH_TEXT_BYTES=16 BENCH_ARCHIVE_DIR=/tmp/archive \
  BENCH_OUT=bench.jsonl mix test test/load/partition_drop_benchmark_test.exs --only retention_archive
MIX_ENV=test mix ecto.drop   # with the same DB_NAME
```

The test removes the partitions, the manifest rows and the archive directory it created.

**Machine**: Windows 11, Docker Desktop (WSL 2), 12 vCPUs and 31 GiB visible to Docker. Postgres 17.11
(`postgres:17-alpine`) with its default settings (`shared_buffers` 128 MB, `max_wal_size` 1 GB), in the shared
development container, dedicated database. Converger ran on the host (`MIX_ENV=test`), the archive went to the
host's local disk. The machine was otherwise idle (only the Postgres container running, 10-24 % CPU before each
run). Measured on 2026-10-15 on top of `main` at `772e42e`.

## Results

| Rows per table (activities + deliveries) | 10,000,000 + 10,000,000 | 30,000,000 + 30,000,000 | Scaling |
| --- | --- | --- | --- |
| Partition size on disk (both, with indexes) | 7.8 GB | 23.3 GB | linear |
| `DETACH ... CONCURRENTLY` (both tables) | 168 ms | 24 ms | constant (metadata) |
| Export (both tables) | 349.0 s | 1,016.2 s | linear |
| Verify: read every object back, size + SHA-256 | 1.7 s | 5.1 s | linear |
| **Archive total** (export + verify) | **350.8 s** | **1,021.2 s** | **linear**, ×2.91 for ×3 rows |
| Archive throughput | 57,017 rows/s | 58,753 rows/s | constant |
| Archive size (gzipped JSON Lines) | 930 MB, 400 parts | 2,787 MB, 1,200 parts | linear |
| `DROP TABLE` statement (both) | 12.7 ms | 13.7 ms | constant |
| `DROP TABLE` commit, files unlinked (both) | 2,023 ms | 6,190 ms | linear (see below) |
| `Retention.run/1` total | 353.1 s | 1,027.5 s | linear |
| Archived rows = partition rows, every part verified | yes, 10M + 10M | yes, 30M + 30M | |
| Spot check (6 parts decompressed, lines = manifest, SHA-256) | pass | pass | |
| Inserts by the 8 writers during the run / during detach or drop | 89,577 / 733 | 282,997 / 2,325 | |
| Insert p50 / p99 during retention | 26.3 / 122.0 ms | 26.6 / 109.7 ms | |
| Insert p50 / p99 before retention (writers alone, 10 s) | 154.1 / 651.7 ms | 22.9 / 90.4 ms | |
| Slowest insert during the detach | 288 ms | 38 ms | |
| Slowest insert during the drop | 91 ms | 55 ms | |
| Slowest insert during the whole run | 1,150 ms | 828 ms | |

Reading the table:

- **Detach is constant.** `DETACH PARTITION ... CONCURRENTLY` changes catalog entries; 24-168 ms at both sizes
  (and 25-45 ms at 200k and 1M rows in ADR-0034). The difference between the two runs is noise, not size.
- **Archive is linear.** Export and verification process a fixed number of rows per second (57-59k rows/s on this
  machine), so tripling the rows multiplied the time by 2.91. The export dominates: each 50,000-row part is an index
  range scan, `row_to_json`, gzip and a write; verification only reads the objects back.
- **The `DROP TABLE` statement is constant; its commit is not, on this machine.** Postgres unlinks the table's
  files when the transaction commits, and on Docker Desktop's virtual disk that took about 0.2 s per GB of
  partition. Writers are never blocked by it: the detached tables are no longer part of `activities` or
  `deliveries`, so the drop locks nothing the writers use, and the slowest insert during the drop (55-91 ms) was
  within the writers' normal p99. How long unlinking takes depends on the filesystem; it was not measured on a
  Linux server.
- **Writers were not blocked** by any step: every insert during the detach or the drop finished within the
  1-second budget (slowest 288 ms), the p99 during the 17-minute archive of the 30M run (110 ms) is close to the
  writers alone (90 ms), and the slowest single insert of the whole run was 828 ms (1,150 ms at 10M), during the
  export, while Postgres was also serving the export's index scans on the same 128 MB of shared buffers. The 10M
  "before" window ran right after the seed's vacuum and checkpoint and is not representative; the 30M one is.
- **Zero loss**: in both runs every row of both partitions is in a verified archive part (`archive_parts` sums to
  exactly 10M and 30M per table), and the partitions were dropped only after that.

## 100M rows: extrapolated, not measured

> **Extrapolated, not measured.** These figures come from a straight-line fit through the 10M and 30M runs above,
> `t(N) = a + b × N` with N the rows per table in millions, on the same machine and settings. No 100M-row run was
> made.

| Rows per table | 100,000,000 + 100,000,000 (**extrapolated**) | Fit |
| --- | --- | --- |
| Partition size on disk (both) | about 78 GB | 0.774 GB per million rows |
| `DETACH ... CONCURRENTLY` (both) | tens of ms (constant) | no growth measured from 200k to 30M rows |
| `DROP TABLE` statement (both) | about 15 ms (constant) | 12.7 → 13.7 ms |
| `DROP TABLE` commit (unlink, both) | about 21 s, writers not blocked | 208 ms per million rows |
| Archive total (export + verify) | about 3,370 s (56 min) | `15.6 s + 33.52 s × N` |
| `Retention.run/1` total | about 3,390 s (57 min) | `15.9 s + 33.72 s × N` |
| Archive size | about 9.3 GB, 4,000 parts | 92.9 MB per million rows |

What the extrapolation rests on, and its limits:

- Archive throughput was the same at 10M and 30M (57k and 59k rows/s), so the export is linear in rows. It stays
  linear only while each part's index range scan stays cheap: at 100M rows per table the partitions (about 78 GB)
  are far larger than the memory available to Postgres here, so heap fetches go to disk more often and the real
  time could be higher than the fit. A month of 100M rows is about 3.3M messages a day, a third of the PRD target
  of 10M a day; at the target a month is about 300M rows per table, about 2.8 hours of archive at this
  throughput. Retention runs monthly in the background and the archive does not block writers, so that is a
  duration, not an outage. It is single-threaded today (one part at a time).
- Detach and the drop statement do not depend on the row count. The unlink at commit grows with the partition size
  and does not block writers.
- Disk: during retention the partition stays on disk until the archive is verified, so the archive storage needs
  room for about 12 % of the partition size (gzipped JSON Lines of these narrow rows), and Postgres needs no extra
  space (no `DELETE`, no WAL beyond the catalog changes).

## Related

- [ADR-0034: monthly partitioning, per-tenant retention and verified archives](../adr/0034-monthly-partitioning-and-per-tenant-retention.md)
- [Data retention and archive](../operations/retention.md)
- [Benchmarks and load testing](index.md)
