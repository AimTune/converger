---
title: "ADR-0028: Dead-letter replay resets the delivery in place and always goes through Oban"
sidebar_label: "0028 Dead-letter replay"
description: A replayed dead letter keeps its delivery row, is flipped from failed to pending under a status guard, gets a fresh attempt budget and one Oban job inserted in the same transaction, whatever the pipeline backend, and is audited per delivery.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-09 |
| **Issue** | [#32](https://github.com/AimTune/converger/issues/32) |
| **Pull request** | Pending |
| **Related** | [ADR-0001](0001-transactional-outbox-with-oban.md), [ADR-0002](0002-broadway-for-throughput-oban-for-retries.md), [ADR-0012](0012-secrets-at-rest-and-audit-redaction.md), [ADR-0018](0018-keyset-pagination.md), [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md) |

## Context and problem statement

A delivery that exhausts its retries, hits a permanent provider error or is halted by middleware ends `status: "failed"` ([ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md)). Until [#32](https://github.com/AimTune/converger/issues/32) it was only a count on the admin dashboard. To recover, an operator had to find the rows with SQL, reset `attempts` by hand (otherwise the first failure dead-letters the delivery again) and insert an `ActivityDeliveryWorker` job from a remote console. Nothing recorded who did it.

The issue asks for inspection (`GET /api/v1/deliveries`), single and bulk replay (API, admin panel and tenant portal), CSV export, and that a replay "resets `attempts`, records `retried_by` and a new audit log entry, and enqueues through the configured pipeline backend". The acceptance criteria are that a failed delivery replayed after fixing the webhook URL ends `sent`, and that a bulk replay of 1 000 deliveries enqueues exactly 1 000 jobs.

## Decision drivers

- **No duplicates.** Two operators, or two bulk calls, replaying the same delivery must produce one job. A delivery must never have two live jobs.
- **No lost replays.** A replay that was reported as done must have a job, also if the node crashes right after ([ADR-0001](0001-transactional-outbox-with-oban.md)).
- **Bounded work.** A bulk replay of 10 000 rows must not hold one long transaction or lock rows that another call could work on.
- **Traceability.** Who replayed what and when must be visible on the delivery and in the audit log.
- **One delivery record per `(activity, channel)`**: receipts, webhooks (`x-converger-delivery-id`) and the UI already key on it.

## Considered options

1. **Reset in place, enqueue through Oban in the same transaction** - `UPDATE deliveries SET status = 'pending', attempts = 0, ... WHERE status = 'failed'`, then insert the job and the audit entry before commit.
2. **Reset in place, enqueue through the configured backend** - same reset, then call the backend (Oban job, Broadway push or inline delivery) after commit.
3. **Create a new delivery row per replay** - keep the failed row as history and insert a fresh one.
4. **Retry the cancelled Oban job** (`Oban.retry_job/1`), as Oban Web does.

### Pros and cons of the options

#### Option 1: in place, Oban in the transaction

- Good, because the status guard on the `UPDATE` is the single point of truth: whoever flips the row enqueues, everyone else gets `not_failed`.
- Good, because the job, the reset and the audit entry commit or roll back together, like the activity outbox.
- Good, because it matches how automatic retries already work for every backend: "Broadway for throughput, Oban for retries" ([ADR-0002](0002-broadway-for-throughput-oban-for-retries.md)).
- Bad, because a Broadway deployment sees replays in Oban, not in its Kafka or RabbitMQ topic.

#### Option 2: in place, configured backend

- Good, because it follows the issue text literally.
- Bad, because Broadway and Inline cannot enqueue transactionally: a crash after commit loses the replay, which breaks the second driver. Inline would also deliver 10 000 messages synchronously inside an HTTP request.

#### Option 3: new row per replay

- Good, because each attempt series keeps its own history.
- Bad, because it breaks the unique `(activity_id, channel_id)` index that receipts, the webhook delivery id and the transcript badges rely on.

#### Option 4: retry the Oban job

- Good, because it needs no code.
- Bad, because it does not reset `attempts` (the first failure dead-letters the delivery again), is not audited, and the job is gone after 24 hours (Pruner). Deliveries failed by a provider receipt have a `completed` job, not a cancelled one.

## Decision

Chosen option: **"Reset in place, enqueue through Oban in the same transaction"**, because it is the only option that meets both the no-duplicate and the no-loss drivers, and it reuses the retry path every backend already has.

- `Deliveries.retry_delivery/2` and `retry_dead_letters/3` flip rows with `UPDATE ... WHERE status = 'failed' RETURNING *`, set `attempts = 0`, increment `retry_count`, set `retried_by` (`"<actor type>:<actor id>"`) and `retried_at`, and insert one `ActivityDeliveryWorker` job per flipped row and one audit entry (`action: "retry"`, `resource_type: "delivery"`) per row, in the same transaction.
- Jobs are inserted with `Oban.insert_all/1`, skipping pairs that still have an incomplete (`available`, `scheduled`, `executing`, `retryable`, `suspended`) job. The worker's own unique option is not used for replays: its states include `completed`, which would swallow the replay of a delivery that was sent and later failed by a provider receipt, and per-job unique inserts take an advisory lock and a query each, too slow for bulk replays.
- Bulk replays run in chunks of 500, oldest failure first. Each chunk selects its rows with `FOR UPDATE SKIP LOCKED` and commits on its own. The `to` bound is capped at the call's start time, so a replay that fails again during the call (a permanent error fails after one attempt) is not replayed twice. One call replays at most `bulk_retry_limit` (default 10 000) and reports `has_more`.
- Deliveries on inactive channels are not replayed.
- Listing uses keyset pagination on `(updated_at, id)` ([ADR-0018](0018-keyset-pagination.md)) with new indexes `(status, updated_at, id)` and `(channel_id, status, updated_at, id)`. `from`/`to` filter on `updated_at`, the failure time of a dead letter.
- The payload preview is the canonical activity with `Converger.Secrets.redact/1` applied ([ADR-0012](0012-secrets-at-rest-and-audit-redaction.md)). CSV exports carry no payloads.

## Consequences

### Positive

- Operators and tenants can find, understand and replay dead letters without SQL or a console, and every replay is attributable.
- Concurrent and repeated replays are safe; the 1 000-delivery acceptance test asserts exactly 1 000 distinct jobs and that a second call replays nothing.

### Negative and trade-offs

- `attempts` no longer counts all attempts ever made for a delivery, only those since the last replay. `retry_count` and the audit log keep the history.
- A replay re-sends the activity. A delivery failed by a provider receipt may have reached the provider before; replay is at-least-once, like retries.
- Bulk replays write one audit row per delivery (10 000 rows for a full call). That keeps each delivery's history queryable by `resource_id`.

### Follow-ups

- Automatic replay when a channel's circuit breaker closes needs the breaker: [#31](https://github.com/AimTune/converger/issues/31).
- Exporting `[:converger, :deliveries, :retried]` and `:dead_lettered` as metrics: [#33](https://github.com/AimTune/converger/issues/33).

## Implementation

- [`lib/converger/deliveries.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/deliveries.ex): `search_deliveries/2`, `cast_filters/1`, `payload_preview/1`, `retry_delivery/2`, `retry_dead_letters/3`.
- [`lib/converger_web/controllers/delivery_controller.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/delivery_controller.ex) and `delivery_json.ex`: `GET /api/v1/deliveries`, `POST /api/v1/deliveries/:id/retry`, `POST /api/v1/channels/:channel_id/deliveries/retry`.
- [`lib/converger_web/live/deliveries_page.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/live/deliveries_page.ex) with `Admin.DeliveryLive` and `Portal.DeliveryLive`; [`delivery_export_controller.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/delivery_export_controller.ex) for CSV.
- Migrations `20261010032000_add_replay_tracking_to_deliveries` and `20261010032100_add_dead_letter_indexes_to_deliveries`.
- Config: `config :converger, :dead_letters, bulk_retry_limit: 10_000, export_limit: 10_000`.
- Tests: `test/converger/deliveries_retry_test.exs` (both acceptance criteria), `test/converger_web/controllers/delivery_controller_test.exs`, `test/converger_web/live/delivery_live_test.exs`.

## Links

- [Delivery and retries: replaying dead letters](../delivery.md#replaying-dead-letters)
- [Tenant API: deliveries](../api/tenant-api.md#deliveries)
- [Deliveries](../concepts/deliveries.md)
