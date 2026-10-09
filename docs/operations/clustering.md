---
title: Clustering
description: Running several Converger nodes as one Erlang cluster with libcluster (Kubernetes DNS, DNS polling, gossip, EPMD), what is shared between nodes, the release distribution variables, and the two-node test suite.
sidebar_position: 6
---

Converger scales horizontally: every node runs the same release, serves HTTP and WebSockets, and executes Oban
jobs. Postgres is the shared state. On top of that the nodes form an **Erlang cluster** so that in-memory,
real-time state reaches every node. This page explains how nodes find each other, what the cluster is used for,
and how it is tested. The decision is recorded in
[ADR-0037](../adr/0037-libcluster-clustering-health-endpoints-and-metrics-on-the-main-port.md); Kubernetes
specifics are on the [Kubernetes](kubernetes.md) page.

## What needs the cluster

| Feature | Shared through | Without a cluster (N independent nodes) |
| --- | --- | --- |
| WebSocket broadcasts (`new_activity` and other conversation events) | `Phoenix.PubSub` (PG2 adapter over distribution) | A client only sees activities created on the node it is connected to |
| Presence (`ConvergerWeb.SocketPresence`) | Phoenix Presence CRDT over PubSub | Presence lists are per node |
| Admin LiveView updates (channel health, dashboard) | PubSub | Only events from the same node appear live |
| Rate limits (`RATE_LIMIT_BACKEND=cluster`) | Counter deltas over PubSub ([Rate limiting](rate-limiting.md)) | Every node counts alone: up to N times the limit |
| Tenant rate-limit override cache invalidation | PubSub | Stale overrides for up to 30 s on other nodes |
| Oban jobs (deliveries, cron) | **Postgres** (`SKIP LOCKED`, leader election in the `oban_peers` table) | Works without a cluster: each job runs exactly once |
| Broadway pipeline (`Converger.Pipeline.Broadway`, not the default) | Nothing: each node processes what it pushed itself | Same; retries go through Oban |

Oban needs no distribution, so deliveries are exactly-once even across a netsplit. Everything in the PubSub column
degrades to per-node behaviour while nodes are disconnected and recovers when they reconnect.

## Choosing a strategy

Node discovery uses [libcluster](https://hexdocs.pm/libcluster). `CLUSTER_STRATEGY` selects the topology
(`Converger.Cluster` builds it at boot; an unknown strategy or a missing required option raises, so a
misconfigured release fails instead of running unclustered):

| `CLUSTER_STRATEGY` | libcluster strategy | Platform | Required settings |
| --- | --- | --- | --- |
| `none` (default) | none | single node, development, test | none |
| `kubernetes_dns` | `Cluster.Strategy.Kubernetes.DNS` | Kubernetes with a headless Service | `CLUSTER_SERVICE` |
| `dns` | `Cluster.Strategy.DNSPoll` | Fly.io (`<app>.internal`), ECS/Consul service discovery, any DNS name listing the node IPs | `CLUSTER_DNS_QUERY` |
| `gossip` | `Cluster.Strategy.Gossip` | docker compose, VMs on one L2 network | `CLUSTER_GOSSIP_SECRET` (recommended) |
| `epmd` | `Cluster.Strategy.Epmd` with `CLUSTER_HOSTS`, else `Cluster.Strategy.LocalEpmd` | development, fixed hosts | `CLUSTER_HOSTS` (optional) |

`kubernetes_dns` needs no Kubernetes API access (no RBAC): it only resolves the headless Service. Every variable is
listed in the [Configuration reference](configuration.md#clustering).

`DNS_CLUSTER_QUERY`, the setting of the former `dns_cluster` dependency, still works: when `CLUSTER_STRATEGY` is
unset it implies `CLUSTER_STRATEGY=dns` with that query.

## Erlang distribution in releases

All strategies connect nodes named `<basename>@<ip>` that share a cookie. `rel/env.sh.eex`, sourced by
`bin/converger` before every command, sets this up when `CLUSTER_STRATEGY` is not `none` (any value already in the
environment wins):

| Variable | Set to | Notes |
| --- | --- | --- |
| `RELEASE_COOKIE` | **you must set it** | The same random secret on every node, from your secret store (`openssl rand -base64 48`). `bin/converger start` refuses to boot while clustering is enabled and it is unset: the cookie generated at build time is baked into the image and identical for everyone who has the image. |
| `RELEASE_DISTRIBUTION` | `name` | Long names, required for `name@ip`. |
| `RELEASE_NODE` | `${CLUSTER_NODE_BASENAME:-converger}@<ip>` | `<ip>` is `POD_IP` (Kubernetes downward API), else `FLY_PRIVATE_IP`, else the first address of `hostname -i`. For an IPv6 address, `-proto_dist inet6_tcp` is added to `ERL_AFLAGS`. |
| `CLUSTER_DIST_PORT` | optional | A fixed distribution port for the server (`start`/`daemon` only; `rpc` and `remote` keep a random one). The Helm chart sets `9100`. |

The distribution listens on EPMD (port 4369) and a dynamic port (or `CLUSTER_DIST_PORT`). Nodes must reach each other on both; on
Kubernetes and docker compose pod-to-pod / container-to-container traffic is open by default. Anyone who can reach
those ports **and** knows the cookie can run code on the node: keep them on the private network and treat the
cookie like `SECRET_KEY_BASE`. `bin/migrate` (`eval`) does not start the distribution and needs no cookie.

The rate-limit backend follows clustering: with a strategy other than `none`, `RATE_LIMIT_BACKEND` defaults to
`cluster`.

## Running a cluster

**Kubernetes:** `kubectl apply -k deploy/k8s` or the Helm chart in `deploy/helm/converger`, see
[Kubernetes](kubernetes.md).

**docker compose:** `docker-compose.cluster.yml` adds a second app service and turns on the gossip strategy for
both:

```sh
# .env additionally needs RELEASE_COOKIE and CLUSTER_GOSSIP_SECRET (see .env.example)
docker compose -f docker-compose.yml -f docker-compose.cluster.yml up -d --build
# node A on http://localhost:4000, node B on http://localhost:4001
docker compose exec app /app/bin/converger rpc 'IO.inspect(Node.list())'
```

**Fly.io:** `deploy/fly/fly.toml` uses `CLUSTER_STRATEGY=dns` with `CLUSTER_DNS_QUERY=<app>.internal`; the node
address comes from `FLY_PRIVATE_IP` (IPv6), migrations run as the `release_command`, and the HTTP service check
uses `/health/ready`. Set `RELEASE_COOKIE` with `fly secrets set`.

**Local development**, two nodes on one machine:

```sh
CLUSTER_STRATEGY=epmd iex --sname a -S mix phx.server
PORT=4001 CLUSTER_STRATEGY=epmd iex --sname b -S mix phx.server
```

With no `CLUSTER_HOSTS`, the `epmd` strategy connects every node registered in the local EPMD. `Node.list()` in
either shell shows the other node.

## Verifying a cluster

On a running release:

```sh
bin/converger rpc 'IO.inspect(Node.list())'                     # connected nodes
bin/converger rpc 'IO.inspect(Converger.RateLimit.backend())'    # :cluster
curl -s http://<pod-ip>:4000/health/ready                         # {"status":"ready",...}
```

libcluster logs `[libcluster:converger] connected to :"converger@10.0.1.12"` when a node joins and
`unable to connect to ...` when it cannot reach one (wrong cookie, blocked port, wrong basename).

## The two-node test suite

`test/cluster/multi_node_test.exs` boots two Converger nodes with OTP's `:peer` and checks the guarantees above
end to end:

- an activity created over node A's REST API arrives at a WebSocket client connected to node B (a real WebSocket
  over TCP, `test/support/cluster/ws_client.ex`);
- the HTTP rate limit is shared: after node A has used up a client's budget, node B answers `429`;
- with both nodes running the Oban queues, 20 activities created on both nodes produce exactly 20 webhook
  deliveries (counted by a local HTTP sink) and every delivery job completes on its first attempt;
- both nodes report ready on `/health/ready`.

The peers form a real Erlang cluster (long names on `127.0.0.1`, connected by libcluster's `Epmd` strategy) while
the test node controls them over stdio, so the test node itself does not need to be distributed. Because SQL
sandbox transactions cannot span nodes, the peers use a separate database, `<test database>_cluster`, with a
normal connection pool: the suite creates and migrates it with `Converger.Release` and truncates it before the
run.

The suite is tagged `:cluster` and excluded by default (it starts two extra VMs and takes about 30 s):

```sh
mix test --only cluster
```

CI runs it in the "Two-node cluster suite" job (`.github/workflows/ci.yml`).
