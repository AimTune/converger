# Deployment

Converger ships as a standard Elixir release (see the `Dockerfile`). All
deployment-specific settings are read from environment variables in
`config/runtime.exs` when the release boots, so the same build can be promoted
between environments without recompiling.

## Environment variables

### Required in production

| Variable | Description |
| --- | --- |
| `DATABASE_URL` | Postgres connection URL, e.g. `ecto://USER:PASS@HOST/DATABASE`. The release refuses to boot without it. |
| `SECRET_KEY_BASE` | Secret used to sign/encrypt cookies and tokens. Generate one with `mix phx.gen.secret`. The release refuses to boot without it. |

### HTTP server

| Variable | Default | Description |
| --- | --- | --- |
| `PHX_SERVER` | unset | When set (to any value), starts the HTTP endpoint. Required for releases (`PHX_SERVER=true bin/converger start`); `docker-compose.yml` sets it for the `app` service. |
| `PHX_HOST` | `example.com` | Public host name used when generating URLs (prod only). URLs are generated as `https://PHX_HOST:443`. |
| `PORT` | `4000` | Port the HTTP endpoint listens on (prod; also honoured in dev). |

### Database

| Variable | Default | Description |
| --- | --- | --- |
| `POOL_SIZE` | `10` | Ecto connection pool size (prod only). |
| `ECTO_IPV6` | unset | Set to `true` or `1` to connect to Postgres over IPv6 (prod only). |

### Security

| Variable | Default | Description |
| --- | --- | --- |
| `CORS_ORIGINS` | `http://127.0.0.1:5500,http://localhost:5500` | Comma-separated list of origins allowed by CORS, e.g. `https://app.example.com,https://admin.example.com`. Use `*` to allow any origin. Origins are resolved per request from the application env, so changing this on a release only needs a restart, not a rebuild. |
| `ADMIN_IP_WHITELIST` | `127.0.0.1,::1` | Comma-separated list of client IPs allowed to reach the `/admin` routes. |

### Clustering and metrics

| Variable | Default | Description |
| --- | --- | --- |
| `DNS_CLUSTER_QUERY` | unset | DNS name queried by `DNSCluster` to discover and connect other nodes (prod only). Clustering is disabled when unset. |
| `PROMETHEUS_PORT` | `9568` | Port of the Prometheus metrics exporter. |

### OpenTelemetry tracing

Trace export is **disabled unless an OTLP endpoint is configured**. When neither
endpoint variable below is set, `config/runtime.exs` sets
`traces_exporter: :none` and no export requests are attempted. This applies to
dev as well: to send dev traces to the local collector from `docker-compose.yml`,
start the server with `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318`.
Export is always disabled in the test environment.

| Variable | Default | Description |
| --- | --- | --- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | Base URL of the OTLP collector, e.g. `http://otel-collector:4318`. `/v1/traces` is appended for traces. Setting it enables trace export. |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | unset | Full URL for traces only (no path is appended). Takes precedence over `OTEL_EXPORTER_OTLP_ENDPOINT`; setting it also enables export. |
| `OTEL_EXPORTER_OTLP_PROTOCOL` / `OTEL_EXPORTER_OTLP_TRACES_PROTOCOL` | `http_protobuf` | `http_protobuf` (port 4318) or `grpc` (port 4317). |
| `OTEL_EXPORTER_OTLP_HEADERS` / `OTEL_EXPORTER_OTLP_TRACES_HEADERS` | unset | Extra headers for export requests, as `key1=value1,key2=value2` (e.g. an API key for a hosted collector). |
| `OTEL_EXPORTER_OTLP_COMPRESSION` / `OTEL_EXPORTER_OTLP_TRACES_COMPRESSION` | none | Set to `gzip` to compress export requests. |
| `OTEL_SERVICE_NAME` | `converger` | Service name reported on every span. |
| `OTEL_RESOURCE_ATTRIBUTES` | unset | Extra resource attributes, as `key1=value1,key2=value2` (e.g. `deployment.environment=staging`). |
| `OTEL_TRACES_EXPORTER` | derived | Standard SDK override. Normally leave unset; `none` forces export off even when an endpoint is set. |
| `OTEL_SDK_DISABLED` | `false` | Set to `true` to disable the OpenTelemetry SDK entirely. |

The endpoint, protocol, headers and compression variables are read directly by
`opentelemetry_exporter`, and the service/resource/SDK variables by the
`opentelemetry` SDK, following the OpenTelemetry specification.

### Development and test only

These are read by `config/dev.exs` and `config/test.exs` and have no effect on
releases.

| Variable | Default | Description |
| --- | --- | --- |
| `DB_USERNAME` | `postgres` | Postgres user. |
| `DB_PASSWORD` | `postgres` | Postgres password. |
| `DB_HOSTNAME` | `localhost` | Postgres host. |
| `DB_NAME` | `converger_dev` / `converger_test` | Database name. In test, `MIX_TEST_PARTITION` is appended to the default. |
| `MIX_TEST_PARTITION` | unset | Suffix for the test database name, for running partitioned or concurrent test suites. |

## Example

```sh
DATABASE_URL=ecto://converger:secret@db.internal/converger \
SECRET_KEY_BASE="$(mix phx.gen.secret)" \
PHX_SERVER=true \
PHX_HOST=converger.example.com \
CORS_ORIGINS=https://app.example.com \
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318 \
OTEL_SERVICE_NAME=converger \
bin/converger start
```
