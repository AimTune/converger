---
title: "ADR-0043: Delivery SLO telemetry on the adapter call, polled database gauges, and alert rules as tested Prometheus rules"
sidebar_label: "0043 Delivery SLO telemetry"
description: Delivery attempts are timed around the adapter call with outcome tags, pipeline lag is measured from the activity insert, connections are counted in a node-local registry, database-backed gauges are polled with zero-fill, the hand-rolled metric list stays (no PromEx), and dashboards and alert rules ship as provisioned files with promtool tests and a chaos test.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-10 |
| **Issue** | [#33](https://github.com/AimTune/converger/issues/33) |
| **Pull request** | to be added |
| **Related** | [ADR-0010](0010-runtime-cors-and-opentelemetry-configuration.md), [ADR-0019](0019-per-channel-retry-policy-delivery-error-and-lifeline.md), [ADR-0020](0020-per-subject-socket-ids-and-presence.md), [ADR-0027](0027-websocket-limits-backpressure-and-draining.md), [ADR-0031](0031-per-channel-circuit-breaker-rate-limit-and-tier-queues.md) |

## Context and problem statement

`ConvergerWeb.Telemetry` exported Phoenix, Ecto and VM metrics, a counter of created activities and a few breaker
counters. Nothing measured what the product promises: that deliveries succeed, how long they take, how long an
activity waits before it leaves the pipeline, how many clients are connected, how deep the queues are and how many
deliveries are dead. Most timings were `last_value` gauges (the latest sample), which cannot give a percentile. The
provisioned Grafana dashboard could not show an SLO and there were no alert rules
([#33](https://github.com/AimTune/converger/issues/33)).

The questions to settle: where to measure a delivery, how to label it without exploding cardinality, how to count
open connections in a cluster, how to get gauges that only the database knows, whether to adopt PromEx, and how to
ship and test dashboards and alerts.

## Decision drivers

- Measure the same thing for every pipeline backend (Oban, Broadway, inline).
- A dead endpoint must keep an alert firing even after the circuit breaker stops the failures.
- Bounded label cardinality by default; per-tenant series only when asked for.
- A gauge must not drift or freeze when a process crashes or the database blips.
- No new runtime dependency and no new infrastructure.
- Alert rules are code: reviewed, unit tested and exercised against a real node.

## Considered options

1. **Where to time a delivery**: (a) the Oban job (`oban.job.stop`), (b) `Converger.Pipeline.deliver/2` as a whole,
   (c) only the adapter call inside it, with the outcome decided after the bookkeeping.
2. **Tenant label**: (a) always, (b) never, (c) opt in.
3. **Open connections**: (a) `ConvergerWeb.Sockets.count/1` on the Presence tracker, (b) +1/-1 `sum` of
   connect/disconnect events, (c) a node-local `Registry` the poller counts.
4. **Database gauges** (queue depth, dead letters, open circuits): (a) derive from Oban/Ecto events, (b) a periodic
   query on every node, (c) a periodic query on one elected node.
5. **Metric library**: (a) adopt PromEx, (b) keep `TelemetryMetricsPrometheus` and the hand-rolled list.
6. **Alerts**: (a) Grafana-managed alert rules, (b) Prometheus rule files with `promtool` tests.

### Pros and cons of the options

#### 1. Where to time a delivery

- (a) Covers only the Oban backend; job duration includes parking, snoozing and DB work.
- (b) Mixes the provider's latency with our own queries (delivery row, middleware, retry bookkeeping).
- (c) The latency is the provider's (what an SLO on "delivery latency" means), works for every backend, and the
  outcome tag can still say whether a failure was retried or dead-lettered. Chosen.

#### 2. Tenant label

- (a) Every tenant multiplies the delivery histogram (12 buckets × channel types × statuses) and Prometheus memory.
- (b) Small installations with a few important tenants lose a useful breakdown.
- (c) `METRICS_TENANT_LABEL=true` adds `tenant_id` to the delivery, lag and inbound series. The events always carry
  `tenant_id`, so a custom handler can aggregate per tenant without the label. Chosen.

#### 3. Open connections

- (a) Counts *subjects* (a user with three tabs counts once) per channel, is eventually consistent across nodes,
  and is keyed by channel id (an unbounded label). It answers "who is online", not "how loaded is this node".
- (b) Drifts for ever when a process is killed without running `terminate/2`.
- (c) A process registers when its connection is established and the `Registry` drops it when it exits, however it
  exits. Counting is O(connections) per poll, which is cheap every 10 s. Per-node values sum to the cluster total.
  Chosen; connect/disconnect counters are still emitted for rates.

#### 4. Database gauges

- (a) Oban events say what happened to a job, not how many are waiting; there is no event for "this many dead
  letters exist".
- (b) Three small grouped queries (`oban_jobs` by queue and state, failed deliveries by channel type through the
  status index, channels whose breaker is not closed) every `METRICS_POLL_INTERVAL_MS` (15 s) per node. Every node
  reports the same value, so queries aggregate with `max`. Chosen.
- (c) Saves N-1 queries per interval but needs leader election and loses the gauge when the leader dies.

#### 5. Metric library

- (a) PromEx brings plugins and dashboards for Phoenix, Ecto, Oban and Broadway, but replaces the reporter, its
  dashboards duplicate ours and use its own naming, and it does not know Converger's events, which are the point
  of this change.
- (b) The list in `ConvergerWeb.Telemetry.metrics/0` stays readable, adding Oban and Broadway metrics is a few lines,
  and nothing changes for deployments. Chosen; revisit if the list keeps growing.

#### 6. Alerts

- (a) Lives in Grafana's database or provisioning format, hard to unit test, tied to Grafana.
- (b) Works with any Prometheus or Alertmanager setup, `promtool test rules` checks every rule on synthetic series in
  CI time, and the same file runs in the chaos test. Chosen.

## Decision

- `Converger.Pipeline` times only the adapter call of every attempt (`Converger.Telemetry.delivery_attempt/4`),
  inside an OpenTelemetry span `converger.delivery`, and emits `[:converger, :delivery, :attempt | :stop |
  :exception]`. The `status` of `:stop` is `sent`, `pending` (WebSocket hand-off), `failed` (retried) or `dead`.
  When the activity leaves the pipeline, `[:converger, :pipeline, :lag]` reports the time since its `inserted_at`,
  tagged `retry` so the lag alert can ignore backoff.
- Latencies are histograms in milliseconds with fixed buckets: requests 5 ms to 10 s, deliveries 10 ms to 30 s, lag
  50 ms to 15 min, database 0.5 ms to 1 s. The former `last_value` timings for requests, router dispatch, channel
  messages, total query time, pool wait and Oban exceptions became histograms.
- `tenant_id` is an opt-in label (`config :converger, :metrics, tenant_label:`).
- `ConvergerWeb.ClientConnections` is a duplicate-key `Registry` labelled `{socket, transport}`; `SocketGuard`
  (Phoenix sockets, including long-poll), `ProtocolSocket` and the SSE stream register into it. Frames are counted
  in the same places as the limits.
- A second `:telemetry_poller` reads the database gauges every `poll_interval_ms`, zero-filling every known label
  combination, so a gauge never keeps the last non-zero value after its rows are gone. Each poll is wrapped
  (`ConvergerWeb.Telemetry.safely/2`) because `telemetry_poller` removes a measurement for good the first time it
  raises, which a database blip or the boot order (the poller starts before the Repo) would otherwise trigger.
- The circuit breaker emits `[:converger, :circuit, :state_change]` for every transition, including the probe's
  move to `half_open`.
- Dashboards (Delivery SLO, Realtime, Pipeline) are provisioned JSON in `docker/grafana/provisioning/dashboards/`;
  the Prometheus data source gets a fixed uid so they resolve it. Alert rules are `docker/prometheus/alerts.yml`,
  with `alerts.test.yml` for `promtool`. `ConvergerChannelCircuitOpen` complements the success-rate alert, because
  an open breaker parks deliveries and the success rate stops seeing failures.
- `test/chaos/alerts.sh` kills the webhook target of a loaded node and waits for Prometheus to fire the delivery
  alerts and resolve the breaker alert.

## Consequences

### Positive

- Delivery success rate, p50/p95/p99 latency per channel type, pipeline lag, connections, frames, queue depth,
  retries and dead letters are all queryable, and the dashboards and alerts are versioned with the code.
- Logs carry the trace id of the delivery span (the OpenTelemetry API sets `otel_trace_id` in the `Logger` metadata,
  and LoggerJSON writes it as `trace`), so a slow delivery in Jaeger leads to its logs.
- The connection gauge cannot drift.

### Negative and trade-offs

- Changing timings from `last_value` to histograms renames their series (`_bucket`, `_sum`, `_count`); queries on the
  bare names return nothing. Noted in the changelog and the observability page.
- Every node runs the three gauge queries; with many nodes, lengthen `METRICS_POLL_INTERVAL_MS`.
- The connection gauge is per node; a cluster-wide "unique users online" still needs Presence.
- Per-tenant breakdowns need the opt-in label or a custom handler.
- Alert thresholds (99%, 5 s, 50 ms, 1000 jobs) are starting points, not tuned to a measured baseline.

### Follow-ups

- Load testing harness with published baselines, which will populate the dashboards and calibrate the thresholds:
  [#34](https://github.com/AimTune/converger/issues/34).
- The metrics are served on the main port behind `METRICS_TOKEN` since
  [ADR-0037](0037-libcluster-clustering-health-endpoints-and-metrics-on-the-main-port.md); the new metrics share
  that registry, and `config :converger, :metrics` holds both its `token` / `allowed_ips` and this ADR's
  `tenant_label` / `poll_interval_ms`. With many clustered nodes, the database gauges could move to one node.
- Moving the channel adapters to `Converger.HTTP`, so each provider request gets its own client span under
  `converger.delivery`.

## Implementation

- [`Converger.Telemetry`](https://github.com/AimTune/converger/blob/main/lib/converger/telemetry.ex): delivery span,
  lag, inbound and frame events, polled database gauges.
- [`ConvergerWeb.Telemetry`](https://github.com/AimTune/converger/blob/main/lib/converger_web/telemetry.ex): metric
  definitions, buckets, the tenant label switch and the two pollers.
- [`ConvergerWeb.ClientConnections`](https://github.com/AimTune/converger/blob/main/lib/converger_web/client_connections.ex),
  hooks in `ConvergerWeb.SocketGuard`, `ConvergerWeb.ProtocolSocket` and `ConvergerWeb.ConvergerAPI.EventStreamController`.
- `Converger.Pipeline.run_delivery/3`, `Converger.Inbound.receive_message/3`, `Converger.Channels.Circuit`.
- Config: `config :converger, :metrics` (`tenant_label`, `poll_interval_ms`), `METRICS_TENANT_LABEL`,
  `METRICS_POLL_INTERVAL_MS`.
- `docker/grafana/provisioning/`, `docker/prometheus/alerts.yml`, `docker/prometheus/alerts.test.yml`,
  `test/chaos/alerts.sh`.
- Tests: `test/converger/telemetry_test.exs` (events per outcome, trace id in log metadata, zero-filled gauges, a
  Prometheus scrape of every metric definition), the connection test in
  `test/converger_web/channels/socket_guard_test.exs`, `promtool test rules`, and the alert chaos test.

## Links

- [Observability](../operations/observability.md)
- [Configuration reference](../operations/configuration.md#metrics-and-health)
- [Chaos testing](../chaos.md#alert-rules-chaos-test)
