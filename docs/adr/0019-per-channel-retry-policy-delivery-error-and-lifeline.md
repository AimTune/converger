---
title: "ADR-0019: Per-channel retry policy, classified delivery errors and the Oban Lifeline"
sidebar_label: "0019 Retry policy and Lifeline"
description: Retry limits, backoff and timeouts are resolved per channel, adapters classify failures as permanent or retryable with an optional Retry-After, and Oban Lifeline rescues jobs orphaned by crashed nodes.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#19](https://github.com/AimTune/converger/issues/19) |
| **Pull request** | [#85](https://github.com/AimTune/converger/pull/85) |
| **Related** | [ADR-0001](0001-transactional-outbox-with-oban.md), [ADR-0002](0002-broadway-for-throughput-oban-for-retries.md), [ADR-0003](0003-pipeline-is-the-only-delivery-path.md), [ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md) |

Every outbound delivery can fail. This ADR records who decides whether a failure is retried, how long to wait, when to give up, and how a delivery that was mid-flight on a crashed node is recovered.

## Context and problem statement

After [#70](https://github.com/AimTune/converger/pull/70) introduced a shared `Converger.Pipeline.RetryPolicy` (removing the hardcoded `>= 5` in `Deliveries.mark_attempt_failed/2` and making `ActivityDeliveryWorker` unique per `{activity_id, channel_id}`), three problems from [#19](https://github.com/AimTune/converger/issues/19) remained:

- **All failures were retried identically.** A WhatsApp `429` with `Retry-After: 30` was retried on the fixed `3^attempt * 10s` schedule, so the first retry came long after or long before the provider asked, and a `400` "invalid recipient" was retried four more times although it could never succeed. Permanent errors burned provider quota and delayed the dead-letter signal by hours.
- **One policy for every channel.** Retry count, backoff and request timeouts were global or per-adapter constants. A latency-sensitive webhook and a batchy WhatsApp integration had to share them.
- **Orphaned jobs.** A job that was `executing` when its node crashed (OOM, `kill -9`, a deploy that did not drain) stayed `executing` in `oban_jobs` forever. The delivery was neither sent nor retried: another data-loss path, next to the one closed by [ADR-0001](0001-transactional-outbox-with-oban.md).

## Decision drivers

- A permanent error must reach `failed` (the dead-letter state) after one attempt.
- A provider's `Retry-After` must be honoured.
- Operators can tune retries per channel without a deploy.
- One source of truth shared by the Oban worker, the Broadway hand-off ([ADR-0002](0002-broadway-for-throughput-oban-for-retries.md)) and `Converger.Deliveries`; the delivery record's `attempts` and the policy decide, not Oban's own counter.
- Old adapters that return a plain `{:error, term}` keep working.
- Jobs lost to crashed nodes are recovered automatically.

## Considered options

1. **Per-channel `retry_policy` map merged over adapter and global defaults, adapters return a structured `DeliveryError`, Oban Lifeline for orphans.**
2. **Keep a global policy, classify errors only by HTTP status inside the worker.**
3. **Rely on Oban's own `max_attempts` per worker and per job** (set `max_attempts` at insert time from the channel).
4. **Separate queues per channel or per error class** (for example a slow "rate limited" queue).

### Pros and cons of the options

**Option 1: per-channel policy plus `DeliveryError`**

- Good: the adapter is the only component that understands provider semantics (which statuses are permanent, where `Retry-After` lives), so classification happens there.
- Good: a three-level merge (global, adapter, channel) gives sensible defaults with targeted overrides.
- Good: the delivery row, not the job, owns the attempt count, so Broadway and Oban backends behave identically.
- Bad: two counters exist (the delivery's `attempts` and Oban's `attempt`), and the worker needs a high safety cap so Oban never stops first.
- Bad: the worker's `backoff/1` reloads the channel to resolve the policy.

**Option 2: global policy, status classification in the worker**

- Good: small change.
- Bad: the worker would need to know every provider's error shapes (Meta returns errors in the body, Infobip differently), and per-channel tuning is still impossible.

**Option 3: Oban `max_attempts` per job**

- Good: uses Oban's counter directly.
- Bad: fixed at insert time, so changing a channel's policy does not affect queued jobs, and the Broadway backend (which does not start in Oban) would need a second implementation.

**Option 4: queues per channel or error class**

- Good: isolation between noisy and quiet channels.
- Bad: queue count grows with tenants; it solves fairness rather than retry semantics. Fairness and isolation are tracked separately in [#31](https://github.com/AimTune/converger/issues/31).

## Decision

Chosen option: **option 1**, because it puts each decision where the knowledge is: providers' error semantics in adapters, tuning on the channel row, and the stop condition on the delivery record.

**Policy resolution.** `RetryPolicy.for_channel/1` merges, in order: the global `config :converger, :retry_policy` (struct defaults `max_attempts: 5`, `backoff: :exponential`, `base_ms: 10_000`, `max_ms: 1 hour`, `timeout_ms: 15_000`; the older `base_backoff_seconds` key is still honoured), the adapter's optional `retry_policy/0` callback (the webhook adapter sets `timeout_ms: 10_000`; WhatsApp uses the 15 s default), and the channel's `retry_policy` JSONB column. Backoff is `exponential` (`base * 3^attempt`), `linear` (`base * attempt`) or `fixed`, always capped at `max_ms`. The channel changeset rejects unknown keys, unknown backoff names and non-positive values.

**Error classification.** Adapters return `{:error, %Converger.Channels.DeliveryError{retryable?, retry_after_ms, status, reason}}`. `DeliveryError.from_http/4` treats `408`, `425`, `429` and every `5xx` as retryable and every other `4xx` as permanent; `from_transport/2` (timeouts, refused connections, DNS) is always retryable; `permanent/1` is for adapter-level errors such as a WhatsApp send without a recipient. `Retry-After` is parsed as delta-seconds or as an IMF-fixdate. A plain `{:error, term}` is treated as retryable.

**Flow.** A permanent error calls `Deliveries.mark_dead/2`, which dead-letters the delivery after one attempt, and the worker returns `{:cancel, reason}`. A retryable error calls `Deliveries.mark_attempt_failed/3` with the channel's policy; once `attempts >= max_attempts` the delivery is dead-lettered and the job cancelled. Otherwise the worker's `backoff/1` uses the provider's `Retry-After` when present, else the policy backoff (`Pipeline.retry_delay_ms/3`). `ActivityDeliveryWorker` keeps `max_attempts: 100` only as a safety cap above any sane channel policy. The Broadway hand-off (`Pipeline.schedule_retry/3`) uses the same rules.

**Orphans.** `Oban.Plugins.Lifeline` with `rescue_after: :timer.minutes(30)` moves jobs stuck in `executing` back to `available`. Deliveries time out within seconds (`timeout_ms`), so 30 minutes cannot rescue a job that is still legitimately running. A rescued job is safe to re-run because `Pipeline.deliver/2` returns `:ok` without calling the adapter when the delivery is already `sent`, `delivered` or `read` ([#70](https://github.com/AimTune/converger/pull/70)).

## Consequences

### Positive

- A `429` with `Retry-After: 30` is retried about 30 s later; a `400` invalid recipient is dead-lettered after one attempt and appears in the dead-letter listing.
- Operators tune `max_attempts`, backoff and timeouts per channel through the channel's `retry_policy` field, without a deploy.
- Crashed-node jobs are recovered without operator action.
- Adapter authors get one structured error type and helper constructors.

### Negative and trade-offs

- Misclassification is now possible in both directions: a provider that returns `400` for a transient condition will be dead-lettered immediately.
- Lifeline's 30-minute window delays recovery of orphaned jobs; lowering it risks double execution of long jobs. The window is global, not per queue.
- A rescued job may re-send if the node crashed after the provider accepted the message but before the delivery row was marked `sent`; delivery is at-least-once.
- `Retry-After` overrides the policy unbounded: a provider asking for hours delays the retry by hours (it is not capped by `max_ms`).
- Policy changes apply from the next attempt; the backoff already scheduled for a job is not recomputed.

### Follow-ups

- Per-channel circuit breakers, provider rate limits and tenant-fair queueing: [#31](https://github.com/AimTune/converger/issues/31).
- Dead-letter inspection and replay (API and admin UI): [#32](https://github.com/AimTune/converger/issues/32).
- Delivery telemetry, dashboards and alerts on dead-lettering: [#33](https://github.com/AimTune/converger/issues/33).
- Adapter behaviour v2 (`capabilities/0`, `config_schema/0`, health probes): [#36](https://github.com/AimTune/converger/issues/36).

## Implementation

- [`Converger.Pipeline.RetryPolicy`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline/retry_policy.ex): `default/0`, `for_channel/1`, `backoff_ms/2`, `exhausted?/2`, `validate/1`, plus the global shortcuts `max_attempts/0`, `backoff/1`, `exhausted?/1`.
- [`Converger.Channels.DeliveryError`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/delivery_error.ex): `from_http/4`, `from_transport/2`, `permanent/1`, `message/1`, `retry_after_ms/1`.
- [`Converger.Channels.Adapter`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapter.ex): optional `retry_policy/0` callback; adapters [`Webhook`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/webhook.ex), [`WhatsappMeta`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/whatsapp_meta.ex) and [`WhatsappInfobip`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/adapters/whatsapp_infobip.ex) return `DeliveryError` and use `RetryPolicy.for_channel(channel).timeout_ms` as the request timeout (an explicit webhook `receive_timeout` wins).
- [`Converger.Pipeline`](https://github.com/AimTune/converger/blob/main/lib/converger/pipeline.ex): `deliver/2` dead-letters permanent errors, `retryable?/1`, `schedule_retry/3`, `retry_delay_ms/3`.
- [`Converger.Deliveries`](https://github.com/AimTune/converger/blob/main/lib/converger/deliveries.ex): `mark_attempt_failed/3`, `mark_dead/2`; dead-lettering emits `[:converger, :deliveries, :dead_lettered]`.
- [`Converger.Workers.ActivityDeliveryWorker`](https://github.com/AimTune/converger/blob/main/lib/converger/workers/activity_delivery_worker.ex): `max_attempts: 100`, `unique: [keys: [:activity_id, :channel_id], period: :infinity]`, `backoff/1` with `Retry-After` precedence.
- [`Converger.Channels.Channel`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/channel.ex): `retry_policy` field and validation. Migration [`20261009190000_add_retry_policy_to_channels`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261009190000_add_retry_policy_to_channels.exs) adds `channels.retry_policy` (`map`, `NOT NULL`, default `{}`).
- Lifeline: the Oban plugin list in [`config/config.exs`](https://github.com/AimTune/converger/blob/main/config/config.exs).

Example channel override:

```json
{
  "retry_policy": {
    "max_attempts": 8,
    "backoff": "linear",
    "base_ms": 5000,
    "max_ms": 600000,
    "timeout_ms": 8000
  }
}
```

Tests: [`test/converger/pipeline/channel_retry_policy_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/pipeline/channel_retry_policy_test.exs) covers the three acceptance criteria (the orphan case runs Lifeline's own `Engine.rescue_jobs/3` on a two-hour-old executing job), the merge order, backoff strategies, validation, `DeliveryError` classification and `Retry-After` parsing. WhatsApp adapters accept `:whatsapp_req_options` (mirroring `:webhook_req_options`) so tests can plug in `Req.Test`. The Broadway hand-off is covered by [`test/converger/pipeline/broadway_retry_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger/pipeline/broadway_retry_test.exs).

## Links

- Issue [#19](https://github.com/AimTune/converger/issues/19), pull requests [#85](https://github.com/AimTune/converger/pull/85) and [#70](https://github.com/AimTune/converger/pull/70)
- Epic [#57](https://github.com/AimTune/converger/issues/57) (v2.5 production hardening: no data loss)
- [Oban.Plugins.Lifeline](https://hexdocs.pm/oban/Oban.Plugins.Lifeline.html)
- [RFC 9110, Retry-After](https://www.rfc-editor.org/rfc/rfc9110#field.retry-after)
