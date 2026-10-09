---
title: Observability
description: Structured JSON logs, Prometheus metrics, OpenTelemetry traces, the Oban dashboard and channel health checks, and what is still missing.
sidebar_position: 2
---

Converger exposes three signals: JSON logs on stdout, Prometheus metrics on a separate port, and OpenTelemetry
traces exported over OTLP. On top of that, a periodic job scores the health of every external channel and can
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
- Security-relevant events are logged as warnings with structured metadata, for example
  `Authentication failure: ...` (tenant API), `Rejected inbound request: signature required` /
  `invalid signature` with `channel_id`, `DEPRECATED: accepted inbound request with no signature`, and
  `Delivery dead-lettered`.
- Collect stdout with your platform's log pipeline. The compose stack provisions a Loki data source in Grafana,
  but ships no log collector (Promtail, Grafana Alloy or a Docker logging driver must be added).

## Metrics

### Prometheus endpoint

`ConvergerWeb.Telemetry` starts `TelemetryMetricsPrometheus` on its own listener:

| Setting | Value |
| --- | --- |
| Port | `PROMETHEUS_PORT`, default `9568` (disabled in test unless the variable is set) |
| Path | `/metrics` |
| Authentication | none |

:::warning
The metrics listener is unauthenticated and separate from the main endpoint, so `TRUSTED_PROXIES`,
`ADMIN_IP_WHITELIST` and `FORCE_SSL` do not apply to it. Expose it only on an internal network (do not publish
the port on a public load balancer). Serving metrics on the main port behind authentication is Planned
([#29](https://github.com/AimTune/converger/issues/29)).
:::

Prometheus scrape configuration (the compose stack scrapes the app on the Docker host):

```yaml
scrape_configs:
  - job_name: converger
    static_configs:
      - targets: ["converger.internal:9568"]
```

### Exported metrics

Telemetry metric names are converted to Prometheus names by replacing `.` with `_`
(`converger.rate_limit.exceeded.count` becomes `converger_rate_limit_exceeded_count`).

| Metric | Type | Tags | Source |
| --- | --- | --- | --- |
| `phoenix.endpoint.start.system_time`, `phoenix.endpoint.stop.duration` | last value (ms) | | Every HTTP request |
| `phoenix.router_dispatch.start.system_time`, `.stop.duration`, `.exception.duration` | last value (ms) | `route` | Router dispatch |
| `phoenix.socket_connected.duration`, `phoenix.channel_joined.duration` | last value (ms) | | WebSocket connect / channel join |
| `phoenix.channel_handled_in.duration` | last value (ms) | `event` | Incoming channel messages |
| `phoenix.socket_drain.count` | sum | | Socket draining on shutdown |
| `phoenix.http.request_count` | counter | `status` | `[:phoenix, :endpoint, :stop]` |
| `phoenix.socket_connected.count`, `phoenix.channel_joined.count` | counter | | Connects and joins (cumulative, not currently open connections) |
| `converger.repo.query.total_time`, `.decode_time`, `.query_time`, `.queue_time`, `.idle_time` | last value (ms) | | Ecto queries |
| `converger.repo.query_count` | counter | | Ecto queries |
| `vm.memory.total` | last value (KB) | | VM |
| `vm.total_run_queue_lengths.total`, `.cpu`, `.io` | last value | | Scheduler run queues |
| `oban.job.exception.duration` | last value (ms) | | Failed Oban job executions |
| `converger.activities.create.count` | counter | | Every created activity |
| `converger.rate_limit.exceeded.count` | counter | `bucket` | Rejected rate-limited requests and login lockouts |
| `converger.channel.circuit_opened.count` | counter | `channel_type`, `reason` | Delivery circuit breaker opened (`failures`, `unhealthy`, `probe_failed`); see [circuit breaker](../delivery.md#circuit-breaker) |
| `converger.channel.circuit_closed.count` | counter | `channel_type` | Breaker closed by a successful probe |
| `converger.channel.paused.count`, `converger.channel.resumed.count` | counter | `channel_type` | Manual pause / resume of a channel's deliveries |
| `converger.deliveries.parked.count` | counter | `channel_type`, `reason` | Delivery jobs parked (`open`, `paused`) |
| `converger.deliveries.rate_limited.count` | counter | `channel_type` | Deliveries snoozed by the channel's outbound rate limit |

Most timings are `last_value` gauges, which show the latest sample rather than a distribution. Use them for
"is anything wrong" checks, and use traces for latency analysis. `converger.repo.query.queue_time` growing is
the signal to raise `POOL_SIZE` (see [Capacity guidance](../deployment.md#capacity-guidance)).

### Telemetry events without a metric

These events are emitted but not yet exported. Attach your own handler (or add a metric in
`ConvergerWeb.Telemetry.metrics/0`) if you need them:

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:converger, :deliveries, :dead_lettered]` | `attempts` | `delivery_id`, `activity_id`, `channel_id`, `error` |
| `[:converger, :middleware, :exception]` | `count` | `middleware`, `type`, `activity_id`, `channel_id`, `kind`, `reason`, `stacktrace` |
| `[:converger, :rate_limit, :exceeded]` | `count` | `bucket`, `key`, `limit`, `scale_ms`, `retry_after_ms` (exported as the counter above, by `bucket`) |

Oban, Ecto, Phoenix and Bandit also emit their standard telemetry events.

## Tracing with OpenTelemetry

`Converger.Application.start/2` instruments:

| Library | Setup | Spans |
| --- | --- | --- |
| Phoenix (Bandit adapter) | `OpentelemetryPhoenix.setup(adapter: :bandit)` | One server span per HTTP request, named by route |
| Ecto | `OpentelemetryEcto.setup([:converger, :repo])` | One span per query |
| Oban | `OpentelemetryOban.setup()` | One span per job execution (deliveries, expiration, health checks) |
| Req | `OpentelemetryReq.attach/2` inside [`Converger.HTTP`](https://github.com/AimTune/converger/blob/main/lib/converger/http.ex) | Client spans for requests made through `Converger.HTTP`, optionally with W3C `traceparent` propagation |

Currently only the tenant health-alert webhook goes through `Converger.HTTP`. The channel adapters (webhook,
WhatsApp Meta, Infobip) and the storage backends still call `Req` directly, so their outbound requests appear
only inside the surrounding Oban or Phoenix span, without a client span of their own.

Export is off unless `OTEL_EXPORTER_OTLP_ENDPOINT` or `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` is set (then
`config/runtime.exs` enables `opentelemetry_exporter`), and always off in test. The remaining standard `OTEL_*`
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
| Prometheus | `http://localhost:9090` | Scrapes `host.docker.internal:9568` every 15 s (`docker/prometheus/prometheus.yml`) |
| Grafana | `http://localhost:3000` (password from `GF_SECURITY_ADMIN_PASSWORD`) | Data sources Prometheus, Jaeger and Loki; dashboard "Converger Overview" |
| OpenTelemetry Collector | OTLP HTTP on `localhost:4318` | Receives OTLP (HTTP and gRPC), exports traces to Jaeger and OTLP metrics on `:8889` |
| Jaeger | `http://localhost:16686` | Trace UI |
| Loki | `http://localhost:3100` | Log store (no collector configured) |

The provisioned dashboard (`docker/grafana/provisioning/dashboards/converger_overview.json`) has four panels:
HTTP request rate by status, "Active WebSocket Connections" (`phoenix_socket_connected_count`, which is a
cumulative connect counter rather than a gauge of open sockets), activity creation rate, and the last Ecto query
time.

## Admin dashboards

- **Oban Web** at `/admin/oban`: queues, job states, retries, errors. Behind the admin IP whitelist and session;
  `super_admin` and `admin` can retry, cancel and delete jobs and pause queues, `viewer` is read-only
  (`ConvergerWeb.ObanResolver`).
- **Admin dashboard** at `/admin`: tenant, channel, conversation and activity counts, channels by mode, delivery
  counts by status, and the latest health of each channel (updated live).
- Phoenix LiveDashboard is not installed.

## Health endpoints

There is no `/health` or readiness endpoint yet. Until one exists:

- use a TCP probe on `PORT` for liveness and readiness;
- if the load balancer health-checks over plain HTTP while `FORCE_SSL` is on, either send `Host: localhost` or add
  the probe path to `FORCE_SSL_EXCLUDE_PATHS` (see [Deployment](../deployment.md#tls-hsts-and-websocket-origins));
- gate rollouts on `bin/migrate` finishing (see [Migrations and maintenance windows](migrations.md)).

`GET /health/live` and `GET /health/ready` (database, Oban, draining, migrations) and Kubernetes manifests are
Planned ([#29](https://github.com/AimTune/converger/issues/29)).

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

## What to alert on today

With the current metrics, reasonable starting alerts are:

- `rate(phoenix_http_request_count{status=~"5.."}[5m])` above your baseline;
- `converger_repo_query_queue_time` consistently above a few milliseconds (pool saturation);
- `rate(converger_rate_limit_exceeded_count[5m])` by `bucket` (abuse, or limits set too low);
- channel health transitions to `unhealthy` (from the alert webhook or the logs);
- `increase(converger_channel_circuit_opened_count[5m]) > 0`, or the `channel.circuit_opened` alert webhook (a channel stopped receiving deliveries);
- `converger_deliveries_parked_count` growing for a channel that stays open (the endpoint is still down);
- `Delivery dead-lettered` warnings in the logs.

Delivery and pipeline telemetry (success rate, latency histograms, pipeline lag, queue depth, dead-letter size,
WebSocket gauges), SLO dashboards and alert rules are Planned
([#33](https://github.com/AimTune/converger/issues/33)).
