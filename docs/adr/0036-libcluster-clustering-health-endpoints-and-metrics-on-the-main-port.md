---
title: "ADR-0036: libcluster clustering, health endpoints and metrics on the main port"
sidebar_label: "0036 Clustering and health"
description: Nodes discover each other with libcluster strategies chosen at runtime, readiness is an unauthenticated JSON probe that gates traffic on database, Oban, draining and migrations, Prometheus metrics move to the main port behind a token, and a two-node :peer suite verifies the cluster in CI.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-09 |
| **Issue** | [#29](https://github.com/AimTune/converger/issues/29) |
| **Pull request** | to be opened |
| **Related** | [ADR-0001](0001-transactional-outbox-with-oban.md), [ADR-0027](0027-websocket-limits-backpressure-and-draining.md), [ADR-0011](0011-custom-trusted-proxies-plug.md), [ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md), [ADR-0021](0021-ci-quality-gates-and-lf-line-endings.md), [ADR-0022](0022-deployment-hardening.md) |

This ADR records how Converger runs as more than one node: how nodes find each other, how a load balancer or
Kubernetes decides that a node may receive traffic, where metrics are served, and how the multi-node behaviour is
tested. It amends two details of earlier ADRs: the default rate-limit backend of
[ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md) now follows `CLUSTER_STRATEGY` instead of
`DNS_CLUSTER_QUERY`, and the health endpoints and manifests listed as follow-ups in
[ADR-0022](0022-deployment-hardening.md) now exist. The operator documentation is in
[Clustering](../operations/clustering.md), [Kubernetes](../operations/kubernetes.md) and
[Observability](../operations/observability.md).

## Context and problem statement

The PRD promises horizontal scaling, and most building blocks were there: `DNSCluster` for node discovery,
`Phoenix.PubSub` (PG2 adapter) for broadcasts, Oban coordinating through Postgres, and a `:cluster` rate-limit
backend ([ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md)). But:

- **Nothing verified a two-node deployment.** WebSocket broadcasts, presence, LiveView updates and rate limits
  depend on the nodes being connected, and only in-process tests existed (`ClusterSyncTest` simulates a second
  node with a second ETS table).
- **`dns_cluster` covers one discovery mechanism** (DNS A/AAAA polling). Kubernetes headless Services happen to
  fit it, but docker compose and local development had no way to cluster, and the node naming and cookie were left
  to the operator with no guidance; the release cookie generated at build time was baked into the image.
- **Readiness only knew about draining.** [ADR-0027](0027-websocket-limits-backpressure-and-draining.md) added
  `/health/live` and `/health/ready` (served before `ForceSSL`), but readiness only reported whether the node was
  shutting down: a node whose database was unreachable or whose migrations had not run yet still received traffic.
- **Metrics on a second, unauthenticated listener** (`TelemetryMetricsPrometheus` on port 9568). It bypassed
  `TrustedProxies`, `ForceSSL` and any authentication, had to be exposed and firewalled separately, collided between
  local test runs, and pulled in `plug_cowboy`/`cowboy`/`cowlib` only for itself (with two acknowledged `cowlib`
  advisories).
- No Kubernetes manifests or PaaS examples.

## Decision drivers

- Clustering must work on Kubernetes, docker compose, Fly.io and a developer machine, chosen at runtime from
  environment variables (one image for every platform, [ADR-0010](0010-runtime-cors-and-opentelemetry-configuration.md)).
- Secure by default: no unauthenticated metrics, no well-known distribution cookie.
- Readiness must reflect what a node needs to serve requests, be cheap enough to run every few seconds, and never
  leak internals to unauthenticated callers.
- The multi-node guarantees (cross-node broadcasts, shared limits, exactly-once jobs) must be tested on real,
  separate nodes in CI, and the suite must also run on contributors' machines (including Windows).
- No new infrastructure.

## Considered options

Node discovery:

1. **libcluster with a strategy selected by `CLUSTER_STRATEGY`** (Kubernetes DNS, DNS polling, gossip, EPMD).
2. **Keep `dns_cluster`** and document DNS-based setups only.
3. **libcluster's `Kubernetes` (API) strategy** as the Kubernetes default.

Metrics:

1. **Serve `/metrics` on the main port** behind a bearer token and/or an IP allowlist; keep the separate listener
   only as an explicit opt-in.
2. **Keep the separate listener** and document that it must stay internal.
3. **Push metrics** (OTLP metrics, Prometheus remote write).

Readiness:

1. **An endpoint plug before the router** answering `/health/live` and `/health/ready` with JSON.
2. **Router routes with a controller.**
3. **TCP probes only.**

Multi-node tests:

1. **OTP `:peer` nodes controlled over stdio**, clustered among themselves, with their own database.
2. **docker compose with two containers** driven by an external script.
3. **`:peer` nodes connected to a distributed test node** (`elixir --sname ... -S mix test`) sharing the sandboxed
   test database.

### Pros and cons of the options

- **libcluster**: one library for every platform; well known; the Kubernetes DNS strategy needs no RBAC. Bad: a new
  dependency, and nodes must follow the `<basename>@<ip>` naming, which needs a release `env.sh`.
- **Keep `dns_cluster`**: no change, but no gossip/EPMD for compose and development, and still no cookie handling.
- **libcluster `Kubernetes` (API)**: discovers pods through the API server, but needs a ServiceAccount token and a
  Role to list endpoints, which widens the pods' privileges for no benefit over a headless Service.
- **Metrics on the main port**: one port to expose and protect; the IP allowlist sees the real client IP through
  `TrustedProxies`; works with one Ingress/Service; drops `plug_cowboy` and the `cowlib` advisories. Bad: a breaking
  change for existing scrapers of port 9568, and the token is sent over plain HTTP for in-cluster scrapes.
- **Separate listener**: no change for scrapers, but unauthenticated, outside every edge control, and another port.
- **Push metrics**: no inbound port, but needs a collector and changes the whole metrics pipeline (left to
  [#33](https://github.com/AimTune/converger/issues/33)).
- **Endpoint plug**: runs before `ForceSSL`, request logging and telemetry, so plain-HTTP probes to the pod IP work
  and do not flood the logs or metrics. Bad: it is not visible in the router.
- **Router routes**: conventional, but every probe is logged, measured and subject to `ForceSSL`.
- **TCP probes**: free, but do not see the database, migrations or shutdown.
- **`:peer` over stdio with a separate database**: the test node needs no distribution, peers form a real cluster
  connected by libcluster, and the SQL sandbox (which cannot span nodes) is avoided by giving the peers their own
  database with a normal pool. Runs in seconds in CI and locally, including on Windows. Bad: the peers share the
  test node's code but not its sandbox, so the suite must clean up by truncation and cannot run `async`.
- **docker compose**: closest to production, but slow, needs Docker in CI and an external driver, and is hard to run
  on contributors' machines. (A compose overlay is still shipped for manual tries.)
- **`:peer` with a distributed test node and the sandbox in shared mode**: one database, but the test node must be
  started with `--sname`, and a shared sandbox runs every query of both nodes on one connection inside a
  transaction that never commits, so Oban's job fetching and Postgres notifications do not behave as in
  production, which is exactly what the exactly-once test must observe.

## Decision

**Node discovery: libcluster, strategy chosen at runtime.** `dns_cluster` is replaced by `libcluster`.
`config/runtime.exs` maps `CLUSTER_STRATEGY` (`none`, `kubernetes_dns`, `dns`, `gossip`, `epmd`) and the `CLUSTER_*`
variables to `config :converger, Converger.Cluster, strategy:, options:`; `Converger.Cluster` turns that into one
libcluster topology and starts `Cluster.Supervisor` before `Phoenix.PubSub`. Unknown strategies and missing
required options raise at boot. `DNS_CLUSTER_QUERY` remains as an alias for `CLUSTER_STRATEGY=dns`. Any strategy
other than `none` makes `cluster` the default rate-limit backend.

**Distribution in releases: `rel/env.sh.eex`.** When clustering is enabled it sets `RELEASE_DISTRIBUTION=name` and
`RELEASE_NODE=<CLUSTER_NODE_BASENAME>@<ip>` (from `POD_IP`, `FLY_PRIVATE_IP` or `hostname -i`, switching to
`inet6_tcp` for IPv6), and `bin/converger start` refuses to boot without an explicit `RELEASE_COOKIE`, in the
spirit of the fail-fast secret checks of [ADR-0022](0022-deployment-hardening.md).

**Health: `ConvergerWeb.Plugs.Health`, first plug of the endpoint.** `GET /health/live` always answers 200.
`GET /health/ready` runs `Converger.Health.readiness/0`: `SELECT 1` with a 1 s timeout, the Oban supervisor alive,
not draining, and every migration shipped with the release present in `schema_migrations` (read directly so the
probe never waits on the migration advisory lock; cached once true). It answers 503 with short reasons; details are
only logged. The `draining` check reads `ConvergerWeb.Drain.draining?/0`, the single source of truth for the
shutdown state introduced by [ADR-0027](0027-websocket-limits-backpressure-and-draining.md): `ConvergerWeb.Drain`,
the last child of the application supervisor, flips it on SIGTERM and waits `WS_DRAIN_DELAY_MS` before the endpoint
drains its sockets (the native transports of [ADR-0035](0035-native-transports-share-signals-limits-and-draining.md)
honour the same flag). A first draft of this change had its own drain flag and shutdown child; it was dropped in favour
of ADR-0027's, so there is one flag and one delay. The `status` field keeps ADR-0027's values (`ready`,
`draining`) and adds `unavailable` for the other checks.

**Metrics: main port, secure by default.** `ConvergerWeb.Telemetry` keeps a `TelemetryMetricsPrometheus.Core`
registry; `ConvergerWeb.Plugs.Metrics` serves it at `GET /metrics`, after `TrustedProxies` and before `ForceSSL`.
Access needs `Authorization: Bearer <METRICS_TOKEN>` (constant-time comparison) or a client IP in
`METRICS_ALLOWED_IPS`; with neither configured `/metrics` answers 404. The old unauthenticated listener is started
only when `PROMETHEUS_PORT` is set (served by Bandit, so `plug_cowboy`, `cowboy`, `cowlib` and `ranch` leave the
dependency tree and the two `cowlib` advisory exceptions are removed from `mix.exs`).

**Verification: a `:peer` suite in CI.** `test/cluster/multi_node_test.exs` (tag `:cluster`, excluded by default,
own CI job) boots two nodes, clusters them with libcluster's `Epmd` strategy, and checks that an activity created
over node A's REST API reaches a raw WebSocket client on node B, that a rate-limit budget used up on node A is
enforced by node B over HTTP, and that 20 activities created on both nodes produce exactly 20 webhook deliveries with
every Oban job completed on its first attempt.

**Deployment artefacts.** `deploy/k8s` (kustomize: Deployment with startup/liveness/readiness probes and a
`preStop` sleep, Service, headless Service with `publishNotReadyAddresses`, HPA, PodDisruptionBudget, migration Job,
ServiceAccount without API token), a Helm chart skeleton in `deploy/helm/converger` with the migration as a
pre-install/pre-upgrade hook, `deploy/fly/fly.toml`, and `docker-compose.cluster.yml` (gossip).

## Consequences

### Positive

- One image clusters on Kubernetes, Fly.io, docker compose and a laptop; the cookie can no longer silently be the
  one baked into the image.
- Traffic only reaches nodes that can serve it, including during the first deploy before migrations have run and
  during shutdown; rolling updates with `maxUnavailable: 0` are safe.
- Metrics are authenticated, on the one port that is already exposed, and covered by `TrustedProxies`.
- The cross-node guarantees are tested on real nodes in CI; the issue's acceptance tests (cross-node WebSocket,
  shared rate limit, exactly-once delivery) are code.
- Fewer dependencies (`plug_cowboy`, `cowboy`, `cowboy_telemetry`, `cowlib`, `ranch`, `telemetry_metrics_prometheus`
  removed) and two fewer acknowledged advisories.

### Negative and trade-offs

- **Breaking:** scrapers of port 9568 stop getting metrics until they use the main port with a token (or set
  `PROMETHEUS_PORT`). Clustered releases need `RELEASE_COOKIE`. Both are in [Upgrades](../operations/upgrades.md).
- The readiness probe adds a `SELECT 1` per probe per pod (every 5 s in the manifests).
- During the first install on Kubernetes, pods start before the migration Job finishes; Oban logs errors about
  missing tables until it has, which is noisy but harmless.
- The plain kustomize migration Job must be deleted before applying a new image (immutable pod template); the Helm
  chart avoids this with a hook.
- The cluster suite uses a separate database that it truncates; it must not point at a database with data.
- The manifests are validated statically (kustomize, kubeconform, `helm lint`), not against a live cluster in CI.

### Follow-ups

- [#33](https://github.com/AimTune/converger/issues/33): delivery and pipeline metrics, dashboards and alert rules
  (scrape configuration now uses the main port).
- A `kind`-based CI job that applies `deploy/k8s` to a throwaway cluster.

## Implementation

- Discovery: [`lib/converger/cluster.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/cluster.ex),
  started from [`lib/converger/application.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/application.ex);
  env mapping in [`config/runtime.exs`](https://github.com/AimTune/converger/blob/main/config/runtime.exs);
  distribution in [`rel/env.sh.eex`](https://github.com/AimTune/converger/blob/main/rel/env.sh.eex).
- Health: [`lib/converger/health.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/health.ex),
  [`lib/converger/health/drain_on_shutdown.ex`](https://github.com/AimTune/converger/blob/main/lib/converger/health/drain_on_shutdown.ex),
  [`lib/converger_web/plugs/health.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/health.ex).
- Metrics: [`lib/converger_web/plugs/metrics.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/metrics.ex),
  [`lib/converger_web/telemetry.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/telemetry.ex),
  both plugs wired in [`lib/converger_web/endpoint.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/endpoint.ex).
- Tests: `test/converger/cluster_test.exs`, `test/converger_web/plugs/health_test.exs`,
  `test/converger_web/plugs/metrics_test.exs`; the two-node suite `test/cluster/multi_node_test.exs` with helpers in
  `test/support/cluster/` (`peer.ex`, `ws_client.ex`, `webhook_sink.ex`); CI job "Two-node cluster suite" in
  `.github/workflows/ci.yml`.
- Deployment: `deploy/k8s/`, `deploy/helm/converger/`, `deploy/fly/fly.toml`, `docker-compose.cluster.yml`.

## Links

- [Clustering](../operations/clustering.md), [Kubernetes](../operations/kubernetes.md),
  [Observability](../operations/observability.md), [Configuration reference](../operations/configuration.md),
  [Upgrades](../operations/upgrades.md), [Security model](../security/overview.md)
- [libcluster](https://hexdocs.pm/libcluster), [`:peer`](https://www.erlang.org/doc/apps/stdlib/peer.html)
