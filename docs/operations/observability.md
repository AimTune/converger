---
title: Observability
description: Structured JSON logs with trace ids, Prometheus metrics on /metrics for delivery SLOs, pipeline and realtime, health and readiness endpoints, OpenTelemetry traces, Grafana dashboards, alert rules and channel health checks.
sidebar_position: 2
---

Converger exposes three signals: JSON logs on stdout, Prometheus metrics at `/metrics` on the main port, and OpenTelemetry
traces exported over OTLP. Load balancers and Kubernetes probe `/health/live` and `/health/ready`. On top of that, a periodic job scores the health of every external channel and can
alert tenants. This page describes what is emitted today, how to collect it, and what is planned. The variables
mentioned here are listed in the [Configuration reference](configuration.md).

## Logging

| Environment | Format | Level |
| --- | --- | --- |
| dev | `[level] message` (console) | debug |
| test | console | warning |
| prod | JSON, one object per line (LoggerJSON) | info |

In production `config/prod.exs` installs `LoggerJSON.Formatters.Basic` as the formatter of Erlang's
`:default_handler` (LoggerJSON 6+ is a `:logger` formatter; configuring it as a backend or as a `format:`
callback either does nothing or crashes every log line, see
[#93](https://github.com/AimTune/converger/pull/93)):

```elixir
config :logger, :default_handler,
  formatter:
    {LoggerJSON.Formatters.Basic,
     metadata: :all,
     redactors: [
       {LoggerJSON.Redactors.RedactKeys,
        ~w(api_key secret token password access_token app_secret verify_token x-api-key x-channel-token authorization)}
     ]}
```

All metadata is included, and the values of the listed keys are replaced with `"[REDACTED]"`. A typical line:

```json
{"message":"Delivery dead-lettered","time":"2026-10-08T12:00:00.000Z","severity":"warning","metadata":{"delivery_id":"...","activity_id":"...","channel_id":"..."}}
```

- `Plug.RequestId` sets `request_id` metadata for every HTTP request and returns it in the `x-request-id`
  response header; quote it when correlating a client error with server logs.
- Log lines written inside a span carry its trace and span id (`trace`, `span`); see
  [Correlating logs and traces](#correlating-logs-and-traces).
- Security-relevant events are logged as warnings with structured metadata, for example
  `Authentication failure: ...` (tenant API), `Rejected inbound request: signature required` /
  `invalid signature` with `channel_id`, `DEPRECATED: accepted inbound request with no signature`, and
  `Delivery dead-lettered`.
- Collect stdout with your platform's log pipeline. The compose stack provisions a Loki data source in Grafana,
  but ships no log collector (Promtail, Grafana Alloy or a Docker logging driver must be added).

## Metrics

### Prometheus endpoint

`ConvergerWeb.Telemetry` aggregates the metrics in a `TelemetryMetricsPrometheus.Core` registry, and
`ConvergerWeb.Plugs.Metrics` serves them **on the main HTTP port**:

| Setting | Value |
| --- | --- |
| Port | `PORT` (the app's own port, default `4000`) |
| Path | `GET /metrics` (Prometheus text format 0.0.4) |
| Authentication | `Authorization: Bearer <METRICS_TOKEN>`, or a client IP in `METRICS_ALLOWED_IPS` (IPs/CIDRs) |
| Neither configured | `404`: metrics are off (secure by default) |
| Wrong or missing credentials | `401` with `www-authenticate: Bearer realm="metrics"` |

The plug runs in the endpoint after `TrustedProxies` (so the allowlist sees the real client IP behind trusted
proxies) and before `ForceSSL` (so an in-cluster scrape over plain HTTP to the pod IP is not redirected). The
token is compared in constant time. In development `config/dev.exs` allows loopback and private ranges, so the
compose Prometheus can scrape `mix phx.server` without a token.

Prometheus scrape configuration with a token:

```yaml
scrape_configs:
  - job_name: converger
    metrics_path: /metrics
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/converger-token
    static_configs:
      - targets: ["converger.internal:4000"]
```

On Kubernetes, scrape the pods directly (for example with a `PodMonitor` whose `bearerTokenSecret` points at
`METRICS_TOKEN` in the `converger-env` Secret) so that every replica is scraped, not one behind the Service.
See [Kubernetes](kubernetes.md).

:::note
Until [#29](https://github.com/AimTune/converger/issues/29) the metrics were served by a separate,
unauthenticated listener on port `9568`. That listener is now off unless `PROMETHEUS_PORT` is set explicitly
(it then serves `/metrics` without authentication, as before, on that port only). Prefer the main port with
`METRICS_TOKEN`; see [Upgrades](upgrades.md#metrics-moved-to-the-main-port).
:::

### Exported metrics

Telemetry metric names are converted to Prometheus names by replacing `.` with `_`
(`converger.rate_limit.exceeded.count` becomes `converger_rate_limit_exceeded_count`). A histogram
(`distribution`) is exported as `<name>_bucket{le="..."}`, `<name>_sum` and `<name>_count`; all histograms are in
milliseconds.

Gauges marked *polled* are reported by every node (`ConvergerWeb.Telemetry` reads them every
`METRICS_POLL_INTERVAL_MS`, 15 s by default). The ones read from the database have the same value on every node:
aggregate them with `max`, not `sum`. Each known label combination is always reported, with `0` when empty.

#### Delivery and pipeline metrics

Emitted by [`Converger.Telemetry`](https://github.com/AimTune/converger/blob/main/lib/converger/telemetry.ex) for
every backend (Oban, Broadway, inline): the adapter call of each delivery attempt is timed, and only the adapter
call (not the bookkeeping around it).

| Metric | Type | Tags | Meaning |
| --- | --- | --- | --- |
| `converger.delivery.attempt.count` | counter | `channel_type`, `retry` | Delivery attempts. `retry="true"` for every attempt after the first, so `rate(...{retry="true"})` is the retry rate. |
| `converger.delivery.stop.duration` | histogram (ms) | `channel_type`, `status` | Adapter call latency per attempt, by outcome: `sent` (accepted by the provider), `pending` (handed to a WebSocket client, receipt pending), `failed` (will be retried), `dead` (dead-lettered: permanent error or out of retries). Its `_count` is the attempt count by outcome, the basis of the success rate. |
| `converger.delivery.exception.count` | counter | `channel_type`, `kind` | Adapter calls that raised (the job fails and Oban retries it). |
| `converger.pipeline.lag.duration` | histogram (ms) | `channel_type`, `retry` | From the activity's `inserted_at` to the attempt that sent (or handed off) its delivery. With `retry="true"` the lag includes the retry backoff. |
| `converger.deliveries.dead_lettered.count` | counter | | Deliveries dead-lettered. |
| `converger.deliveries.retried.count` | counter (sum) | | Dead letters replayed ([Replaying dead letters](../delivery.md#replaying-dead-letters)). |
| `converger.deliveries.dead_letters.size` | gauge, polled | `channel_type` | Dead-lettered deliveries currently stored (`status = failed`). |
| `converger.inbound.received.count` | counter | `channel_type`, `outcome` | Messages received on a channel (inbound webhook, a `websocket` channel's client or a [broker channel](../channels/brokers.md) consumer): `created`, `duplicate` (idempotency key seen before), `rejected` (invalid), `error`. |
| `converger.broker.dead_lettered.count` | counter | `channel_type`, `reason` | Consumed broker messages written to the channel's dead-letter topic or queue: `reason` is `poison` (never acceptable) or `retries_exhausted` ([broker channels](../channels/brokers.md#poison-messages-and-retries)). |
| `converger.broker.retry.count` | counter | `channel_type` | Consumed broker messages retried in place after a transient failure. |
| `converger.circuit.state_change.count` | counter | `channel_type`, `to`, `reason` | Circuit breaker transitions (`to`: `open`, `half_open`, `closed`, `paused`). |
| `converger.channels.circuit.count` | gauge, polled | `channel_type`, `state` | Channels whose breaker is `open`, `half_open` or `paused`. |
| `converger.oban.queue.depth` | gauge, polled | `queue`, `state` | Oban jobs per queue in `available`, `scheduled`, `retryable` and `executing`. Parked deliveries and retry backoffs are `scheduled`. |

`METRICS_TENANT_LABEL=true` adds a `tenant_id` tag to `converger.delivery.stop.duration`,
`converger.pipeline.lag.duration` and `converger.inbound.received.count`. It is off by default: every tenant
multiplies those series (times every histogram bucket), which is fine for a handful of tenants and expensive for
thousands. The telemetry events always carry `tenant_id` in their metadata, so a custom handler can use it either way.

#### Realtime metrics

Client connections are counted by [`ConvergerWeb.ClientConnections`](https://github.com/AimTune/converger/blob/main/lib/converger_web/client_connections.ex),
a node-local registry. Labels: `socket` is `user` (legacy `/socket`), `converger` (`/socket/converger`) or
`protocol` (native Protocol v1), and `transport` is `websocket`, `longpoll` or `sse`.

| Metric | Type | Tags | Meaning |
| --- | --- | --- | --- |
| `converger.ws.connections.count` | gauge, polled | `socket`, `transport` | Open client connections on this node. A process is dropped from the registry when it exits, however it exits, so the gauge cannot drift. Sum it across nodes. |
| `converger.ws.connected.count`, `converger.ws.disconnected.count` | counter | `socket`, `transport` | Connections opened and closed. A connection killed without running its callbacks is not counted as disconnected, but it does leave the gauge. |
| `converger.ws.frame.count` | counter (sum) | `socket`, `transport`, `direction` | WebSocket frames: `in` is every frame a client sends (including heartbeats and frames refused by a limit), `out` every frame pushed to it. Phoenix replies to a client's own messages are not counted as `out`. |

#### Platform metrics

| Metric | Type | Tags | Source |
| --- | --- | --- | --- |
| `phoenix.endpoint.stop.duration` | histogram (ms) | | Every HTTP request |
| `phoenix.router_dispatch.stop.duration`, `.exception.duration` | histogram (ms) | `route` | Router dispatch |
| `phoenix.channel_handled_in.duration` | histogram (ms) | `event` | Incoming channel messages |
| `phoenix.endpoint.start.system_time`, `phoenix.router_dispatch.start.system_time` | last value (ms) | `route` for the router | Request start times |
| `phoenix.socket_connected.duration`, `phoenix.channel_joined.duration` | last value (ms) | | WebSocket connect / channel join |
| `phoenix.socket_drain.count` | sum | | Socket draining on shutdown |
| `phoenix.http.request_count` | counter | `status` | `[:phoenix, :endpoint, :stop]` |
| `phoenix.socket_connected.count`, `phoenix.channel_joined.count` | counter | | Connects and joins (cumulative; open connections are `converger.ws.connections.count`) |
| `converger.repo.query.total_time`, `.queue_time` | histogram (ms) | | Ecto queries. `queue_time` is the wait for a pool connection: pool saturation. |
| `converger.repo.query.decode_time`, `.query_time`, `.idle_time` | last value (ms) | | Ecto queries |
| `converger.repo.query_count` | counter | | Ecto queries |
| `converger.background_repo.query.queue_time` | histogram (ms) | | Wait for a background pool connection (Oban jobs; [Database pools](database.md)) |
| `converger.repo.pool.queue_time_ms` | last value (ms) | | Average interactive pool wait over the last `DB_QUEUE_WINDOW_MS`; readiness reports `degraded` above `READY_DB_QUEUE_MS` |
| `converger.db.unavailable.count` | counter | `source` | Answers turned into retryable errors (`503`, `unavailable`, `replay_unavailable`) because the database was unavailable: `http`, `socket`, `channel`, `protocol`, `sse` |
| `vm.memory.total` | last value (KB) | | VM |
| `vm.total_run_queue_lengths.total`, `.cpu`, `.io` | last value | | Scheduler run queues |
| `oban.job.stop.duration`, `oban.job.exception.duration` | histogram (ms) | `queue`, `worker`, `state` | Every Oban job execution (`state`: `success`, `cancelled`, `snoozed`, `failure`, `discard`) |
| `broadway.batch_processor.stop.duration` | histogram (ms) | `topology_name` | Broadway delivery batches (Broadway backend only) |
| `broadway.processor.message.exception.count` | counter | `topology_name` | Broadway processor crashes |
| `converger.activities.create.count` | counter | | Every created activity |
| `converger.rate_limit.exceeded.count` | counter | `bucket` | Rejected rate-limited requests and login lockouts |
| `converger.channel.circuit_opened.count` | counter | `channel_type`, `reason` | Delivery circuit breaker opened (`failures`, `unhealthy`, `probe_failed`); see [circuit breaker](../delivery.md#circuit-breaker) |
| `converger.channel.circuit_closed.count` | counter | `channel_type` | Breaker closed by a successful probe |
| `converger.channel.paused.count`, `converger.channel.resumed.count` | counter | `channel_type` | Manual pause / resume of a channel's deliveries |
| `converger.deliveries.parked.count` | counter | `channel_type`, `reason` | Delivery jobs parked (`open`, `paused`) |
| `converger.deliveries.rate_limited.count` | counter | `channel_type` | Deliveries snoozed by the channel's outbound rate limit |
| `converger.socket.limit.count` | counter | `reason` | WebSocket limit hits: `rate_limited`, `payload_too_large`, `frame_too_large`, `too_many_joins`, `slow_consumer`, `ephemeral_dropped`, `draining` (see [WebSocket limits](websocket-limits.md)) |

:::note Changed in #33
`phoenix.endpoint.stop.duration`, `phoenix.router_dispatch.stop.duration` / `.exception.duration`,
`phoenix.channel_handled_in.duration`, `converger.repo.query.total_time` / `.queue_time` and
`oban.job.exception.duration` used to be `last_value` gauges (the latest sample). They are histograms now, so a
query on the bare name returns nothing: use `histogram_quantile(0.95, sum by (le) (rate(<name>_bucket[5m])))`.
`phoenix.http.request_count` now actually carries its `status` tag (the tag was missing from the event metadata,
so the counter was never incremented).
:::

`converger.repo.pool.queue_time_ms` (the interactive pool's average wait) growing is the signal to raise `POOL_SIZE` (see [Database pools and pressure](database.md#sizing)).

### Telemetry events

The events behind the metrics above, for custom handlers (`:telemetry.attach/4`):

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:converger, :delivery, :attempt]` | `count` | `channel_id`, `channel_type`, `tenant_id`, `delivery_id`, `activity_id`, `attempt` (1-based), `retry` |
| `[:converger, :delivery, :stop]` | `duration` (native) | as `:attempt`, plus `status` |
| `[:converger, :delivery, :exception]` | `duration` (native) | as `:attempt`, plus `kind`, `reason` |
| `[:converger, :pipeline, :lag]` | `duration` (ms) | as `:attempt`, plus `status` (`sent`, `pending`) |
| `[:converger, :inbound, :received]` | `count` | `channel_id`, `channel_type`, `tenant_id`, `outcome` |
| `[:converger, :broker, :dead_lettered]` | `count` | `channel_id`, `channel_type`, `tenant_id`, `reason` (`:poison`, `:retries_exhausted`) |
| `[:converger, :broker, :retry]` | `count` | `channel_id`, `channel_type` |
| `[:converger, :ws, :connected]`, `[:converger, :ws, :disconnected]` | `count` | `socket`, `transport` |
| `[:converger, :ws, :frame]` | `count` | `socket`, `transport`, `direction` |
| `[:converger, :ws, :connections]` | `count` (polled) | `socket`, `transport` |
| `[:converger, :circuit, :state_change]` | `count` | `channel_id`, `channel_type`, `tenant_id`, `to`, `reason` |
| `[:converger, :oban, :queue]` | `depth` (polled) | `queue`, `state` |
| `[:converger, :deliveries, :dead_letters]` | `size` (polled) | `channel_type` |
| `[:converger, :channels, :circuit]` | `count` (polled) | `channel_type`, `state` |
| `[:converger, :deliveries, :dead_lettered]` | `attempts` | `delivery_id`, `activity_id`, `channel_id`, `error` |
| `[:converger, :deliveries, :retried]` | `count` | `delivery_ids` (dead letters replayed by one transaction: a single retry or one bulk chunk) |
| `[:converger, :middleware, :exception]` | `count` | `middleware`, `type`, `activity_id`, `channel_id`, `kind`, `reason`, `stacktrace` (no metric) |
| `[:converger, :rate_limit, :exceeded]` | `count` | `bucket`, `key`, `limit`, `scale_ms`, `retry_after_ms` |
| `[:converger, :deprecated, :use]` | `count` (always 1) | `surface` (`:legacy_socket`, `:token_endpoint` for `POST /api/v1/tokens`, `:channel_token` for other `x-channel-token` uses), `tenant_id`, and `conversation_id` for the socket (no metric) |

Oban, Ecto, Phoenix, Broadway and Bandit also emit their standard telemetry events.

Every use of a deprecated surface also logs a `Deprecated <surface> used` warning (once per connection for the legacy
socket, once per request for HTTP) with `deprecated` and `tenant_id` in the log metadata. Search for these warnings
to find integrations that still need to [migrate](../api/migrating-from-legacy.md).

The reasoning (which events, histogram buckets, the opt-in tenant label, the connection registry, polling the
database) is in [ADR-0043](../adr/0043-delivery-slo-telemetry-dashboards-and-alert-rules.md).

## Tracing with OpenTelemetry

`Converger.Application.start/2` instruments:

| Library | Setup | Spans |
| --- | --- | --- |
| Phoenix (Bandit adapter) | `OpentelemetryPhoenix.setup(adapter: :bandit)` | One server span per HTTP request, named by route |
| Ecto | `OpentelemetryEcto.setup([:converger, :repo])` | One span per query |
| Oban | `OpentelemetryOban.setup()` | One span per job execution (deliveries, expiration, health checks) |
| Req | `OpentelemetryReq.attach/2` inside [`Converger.HTTP`](https://github.com/AimTune/converger/blob/main/lib/converger/http.ex) | Client spans for requests made through `Converger.HTTP`, optionally with W3C `traceparent` propagation |
| Converger | [`Converger.Telemetry`](https://github.com/AimTune/converger/blob/main/lib/converger/telemetry.ex) | `converger.delivery` around the adapter call of every delivery attempt, with `converger.channel.id`, `converger.channel.type`, `converger.tenant.id`, `converger.delivery.id`, `converger.activity.id` and `converger.delivery.attempt` attributes; status `error` when the attempt fails |

Currently only the tenant health-alert webhook goes through `Converger.HTTP`. The channel adapters (webhook,
WhatsApp Meta, Infobip) and the storage backends still call `Req` directly, so their outbound requests have no
client span of their own; the `converger.delivery` span (a child of the Oban job span) covers the adapter call.

### Correlating logs and traces

Setting the current span (OpenTelemetry does it for every span above) puts `otel_trace_id` and `otel_span_id` in
the process's `Logger` metadata. The production formatter (`LoggerJSON.Formatters.Basic`) turns them into top-level
`trace` and `span` fields, so every log line written inside a request, a job or a delivery attempt carries the trace
id:

```json
{"message":"Activity delivered","severity":"info","trace":"4bf92f3577b34da6a3ce929d0e0e4736","span":"00f067aa0ba902b7","metadata":{"activity_id":"...","channel_id":"...","channel_type":"webhook"}}
```

Search Loki (or any log store) for the trace id shown in Jaeger to get the logs of that trace, and the other way round.

Export is off unless `OTEL_EXPORTER_OTLP_ENDPOINT` or `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` is set (then
`config/runtime.exs` enables `opentelemetry_exporter`), and always off in test. Spans are still created when export
is off, so the trace ids in the logs are always there. The remaining standard `OTEL_*`
variables (protocol, headers, compression, service name, resource attributes) are read by the exporter and SDK.
The full table is in [Configuration reference](configuration.md#opentelemetry-tracing), and the reasoning in
[ADR-0010](../adr/0010-runtime-cors-and-opentelemetry-configuration.md).

```bash
# Send dev traces to the compose collector
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 mix phx.server
```

## Local observability stack

`docker compose up -d` starts the app together with:

| Service | URL | Role |
| --- | --- | --- |
| Prometheus | `http://localhost:9090` | Scrapes `host.docker.internal:4000/metrics` (the dev server) every 15 s and evaluates the [alert rules](#alert-rules) (`docker/prometheus/`) |
| Grafana | `http://localhost:3000` (password from `GF_SECURITY_ADMIN_PASSWORD`) | Data sources Prometheus (uid `Prometheus`), Jaeger and Loki; the [dashboards](#dashboards) below |
| OpenTelemetry Collector | OTLP HTTP on `localhost:4318` | Receives OTLP (HTTP and gRPC), exports traces to Jaeger and OTLP metrics on `:8889` |
| Jaeger | `http://localhost:16686` | Trace UI |
| Loki | `http://localhost:3100` | Log store (no collector configured) |

### Dashboards

Provisioned from `docker/grafana/provisioning/dashboards/` (tagged `converger`, linked to each other):

| Dashboard | Panels |
| --- | --- |
| Converger / Delivery SLO | Success rate (overall and per channel type, against the 99% SLO), delivery latency p50 / p95 / p99 per channel type and by outcome, attempts by outcome, retries, dead letters, open circuits and breaker transitions, and the Prometheus alerts currently firing. Filter by channel type. |
| Converger / Realtime | Open connections (total, by socket and transport, per node), connects and disconnects, frames in and out per second, pipeline lag p50 / p95 / p99 (first attempts and after retries), WebSocket limit hits, inbound messages by outcome. |
| Converger / Pipeline | Oban jobs available / scheduled / retryable / executing per queue, job duration p95 and outcomes, retries, dead-lettering, replays and parked deliveries, dead letters by channel type, database pool wait and query time p95 per node, Broadway batch duration. |
| Converger Overview | HTTP request rate by status, open client connections, activity creation rate, query time p95. |

The JSON files are the source of truth: edit a dashboard in Grafana, export it, and commit the file.

## Admin dashboards

- **Oban Web** at `/admin/oban`: queues, job states, retries, errors. Behind the admin IP whitelist and session;
  `super_admin` and `admin` can retry, cancel and delete jobs and pause queues, `viewer` is read-only
  (`ConvergerWeb.ObanResolver`).
- **Admin dashboard** at `/admin`: tenant, channel, conversation and activity counts, channels by mode, delivery
  counts by status, and the latest health of each channel (updated live).
- Phoenix LiveDashboard is not installed.

## Health endpoints

Two unauthenticated JSON endpoints, served by `ConvergerWeb.Plugs.Health` before any other endpoint plug (no
`ForceSSL` redirect, no request log line, no telemetry), so load balancers and kubelets can probe the pod IP over
plain HTTP:

| Endpoint | Answers | Use it for |
| --- | --- | --- |
| `GET /health/live` | always `200 {"status":"ok"}` while the VM runs and the endpoint accepts requests | liveness / startup probes. It never touches the database, so a database outage does not restart every replica. |
| `GET /health/ready` | `200 {"status":"ready","checks":{...}}` when every check passes, otherwise `503` with `"status":"draining"` (the node is shutting down), `"degraded"` (only the `pool` check failed: the database pool is saturated) or `"unavailable"` (any other failed check) | readiness probes and load balancer health checks |

Readiness checks (`Converger.Health.readiness/0`):

| Check | Fails when | Reason in the response |
| --- | --- | --- |
| `database` | `SELECT 1` fails or takes longer than 1 s | `database unavailable` |
| `oban` | the Oban supervisor is not running | `oban not running` |
| `draining` | the node is shutting down (`ConvergerWeb.Drain.draining?/0`) | `draining` |
| `migrations` | a migration shipped with this release is not in `schema_migrations` (reads the table directly, so it does not wait for the migration lock while `bin/migrate` runs; cached once everything is applied) | `migrations pending: N` |
| `pool` | the interactive pool's average wait over the last `DB_QUEUE_WINDOW_MS` (5 s) is at least `READY_DB_QUEUE_MS` (200 ms; `0` disables), see [Database pools and pressure](database.md#readiness) | `database pool saturated` |

```json
{"status": "unavailable", "reasons": ["migrations pending: 1"],
 "checks": {"database": "ok", "oban": "ok", "draining": "ok", "migrations": "error", "pool": "ok"}}
```

The response only carries short reasons; details such as connection errors are logged
(`Readiness check failed: ...`).

**Draining.** The draining state comes from `ConvergerWeb.Drain`
([ADR-0027](../adr/0027-websocket-limits-backpressure-and-draining.md)), the last child of the application
supervisor: on SIGTERM it is stopped first, flips readiness to `503 draining`, refuses new sockets and waits
`WS_DRAIN_DELAY_MS` (5 s) before the endpoint drains its WebSockets in batches. Use `/health/ready` as the load
balancer and Kubernetes readiness probe with a period shorter than that delay; see
[WebSocket limits and draining](websocket-limits.md#draining-on-shutdown). On Kubernetes the manifests also add a
`preStop` sleep so the endpoint removal propagates before SIGTERM.

## Channel health checks

[`Converger.Workers.ChannelHealthWorker`](https://github.com/AimTune/converger/blob/main/lib/converger/workers/channel_health_worker.ex)
runs every 5 minutes (Oban cron, `default` queue) for every active `webhook`, `whatsapp_meta` and
`whatsapp_infobip` channel. [`Converger.Channels.Health`](https://github.com/AimTune/converger/blob/main/lib/converger/channels/health.ex)
computes the delivery failure rate over the last 60 minutes and stores a row in `channel_health_checks`:

| Status | Failure rate |
| --- | --- |
| `healthy` | below 10% |
| `degraded` | 10% up to 50% |
| `unhealthy` | 50% or more |
| `unknown` | no deliveries in the window |

When a channel's status changes (compared with its previous check):

1. the change is logged (`Channel health changed: ...`);
2. `health_changed` is broadcast on the `channel_health` PubSub topic, which the admin dashboard and channel
   list (`/admin`, `/admin/channels`) use for live updates;
3. if the tenant has `alert_webhook_url`, a JSON alert is posted to it (fire and forget, 10 s timeout):

```json
{
  "event": "channel_health_changed",
  "channel_id": "...",
  "channel_name": "support-whatsapp",
  "tenant_id": "...",
  "previous_status": "healthy",
  "new_status": "degraded",
  "failure_rate": 0.25,
  "total_deliveries": 40,
  "failed_deliveries": 10,
  "checked_at": "2026-10-08T12:05:00.000000Z"
}
```

Health check rows older than 7 days are pruned by the same job.

## Alert rules

`docker/prometheus/alerts.yml` holds Prometheus alerting rules; the compose Prometheus loads them (`rule_files`),
and the Delivery SLO dashboard lists the firing ones. Load the same file into your own Prometheus (or convert it to
Grafana-managed or Alertmanager-routed alerts) and route `severity` to your pager.

| Alert | Fires when | Severity | What to do |
| --- | --- | --- | --- |
| `ConvergerDeliverySuccessRateLow` | Fewer than 99% of the delivery attempts of a channel type succeed (`sent` or `pending`) for 5 minutes, with at least 20 attempts in the window | critical | Find the failing channels (Delivery SLO dashboard, `Delivery dead-lettered` and `Activity delivery failed` logs, channel health); usually a provider or customer endpoint is down or rejecting requests. |
| `ConvergerChannelCircuitOpen` | At least one channel's circuit breaker is open or half open for 1 minute | warning | The endpoint keeps failing, so its deliveries are parked: the success rate alert goes quiet once the breaker opens, this one keeps firing until a probe succeeds. Check the endpoint; [pause the channel](../delivery.md#circuit-breaker) if the outage is known. |
| `ConvergerDeadLettersGrowing` | The dead letters of a channel type grew over the last 15 minutes, for 5 minutes | warning | Deliveries are out of retries or permanently rejected. Fix the cause, then [replay them](../delivery.md#replaying-dead-letters). |
| `ConvergerPipelineLagHigh` | The p95 pipeline lag of first attempts is above 5 s for 5 minutes | warning | Deliveries wait too long in the queues: check the Pipeline dashboard (queue depth, job duration, pool wait), queue concurrency and slow providers. |
| `ConvergerDeliveryBacklog` | More than 1000 jobs are available in a delivery queue for 10 minutes | warning | Work is enqueued faster than it is done. Raise the queue's concurrency or add nodes; check the database. |
| `ConvergerDatabasePoolSaturated` | The p95 wait for a database connection on a node is above 50 ms for 5 minutes | warning | Raise `POOL_SIZE` (within the database's connection limit) or find the slow queries; see [Capacity guidance](../deployment.md#capacity-guidance). |
| `ConvergerMetricsDown` | Prometheus cannot scrape a node for 2 minutes | critical | The node is down, or its metrics port is unreachable. |

The thresholds are starting points: copy the file and tune them to your traffic. `alerts.test.yml` next to it has
[`promtool`](https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/) unit tests for every
rule; run them after a change:

```bash
docker run --rm -v "$PWD/docker/prometheus:/w" --entrypoint promtool \
  prom/prometheus:v2.55.0 test rules /w/alerts.test.yml
```

The [alert chaos test](../chaos.md#alert-rules-chaos-test) checks the delivery alerts end to end against a real
node: it kills a webhook target under load and waits for Prometheus to fire them.

Other signals worth watching, without a provisioned rule:

- `rate(phoenix_http_request_count{status=~"5.."}[5m])` above your baseline;
- `converger_repo_pool_queue_time_ms` consistently above a few milliseconds (pool saturation), and
  `rate(converger_db_unavailable_count[5m]) > 0` (requests answered `503` because the database was unavailable);
- `rate(converger_rate_limit_exceeded_count[5m])` by `bucket` (abuse, or limits set too low);
- `rate(converger_socket_limit_count{reason="slow_consumer"}[5m])` (clients on slow networks, or a node too busy to
  write to its sockets) and the other `reason`s (abusive clients, or WebSocket limits set too low);
- channel health transitions to `unhealthy` (from the alert webhook or the logs), and the `channel.circuit_opened`
  alert webhook.
