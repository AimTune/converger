---
title: Kubernetes
description: Deploying a clustered Converger on Kubernetes with the kustomize manifests in deploy/k8s or the published Helm chart, with probes, migrations, clustering, autoscaling, disruption budget and metrics scraping.
sidebar_position: 7
---

The repository ships two ways to run Converger on Kubernetes:

- `deploy/k8s/`: plain manifests for `kubectl apply -k deploy/k8s`;
- `deploy/helm/converger/`: a Helm chart with the same resources, the migration as a hook and optional Ingress,
  PodMonitor and NetworkPolicy, published to `oci://ghcr.io/aimtune/charts/converger` with every release.

Both run a [clustered](clustering.md) Deployment whose pods only receive traffic once
[`GET /health/ready`](observability.md#health-endpoints) passes. The design is recorded in
[ADR-0037](../adr/0037-libcluster-clustering-health-endpoints-and-metrics-on-the-main-port.md).

## What `deploy/k8s` contains

| File | Resource | Purpose |
| --- | --- | --- |
| `deployment.yaml` | `Deployment converger` | 2 replicas, rolling update with `maxUnavailable: 0`, probes, `preStop` sleep, `POD_IP` from the downward API, non-root, all capabilities dropped |
| `service.yaml` | `Service converger` | ClusterIP on port 80 to the `http` port (4000); only ready pods are endpoints. Put your Ingress / LoadBalancer in front of it. |
| `service-headless.yaml` | `Service converger-headless` | `clusterIP: None`, `publishNotReadyAddresses: true`: the DNS name libcluster resolves to find every pod |
| `hpa.yaml` | `HorizontalPodAutoscaler` | 2 to 10 replicas at 70% CPU (needs metrics-server); scales in one pod per minute |
| `pdb.yaml` | `PodDisruptionBudget` | `minAvailable: 1` for node drains and cluster upgrades |
| `migrate-job.yaml` | `Job converger-migrate` | Runs `/app/bin/migrate` once |
| `configmap.yaml` | `ConfigMap converger-config` | Non-secret settings: `PHX_HOST`, `TRUSTED_PROXIES`, `CLUSTER_STRATEGY=kubernetes_dns`, `CLUSTER_SERVICE=converger-headless`, ... |
| `serviceaccount.yaml` | `ServiceAccount converger` | No API token mounted: the `kubernetes_dns` strategy needs no RBAC |
| `kustomization.yaml` | | Lists the resources and pins the image (`images:`) |

## Install

1. Create the secret (never commit it). `RELEASE_COOKIE` is required because the pods cluster:

   ```sh
   kubectl create secret generic converger-env \
     --from-literal=DATABASE_URL='ecto://USER:PASS@postgres.example.internal/converger' \
     --from-literal=SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')" \
     --from-literal=CLOAK_KEY="$(openssl rand -base64 32)" \
     --from-literal=RELEASE_COOKIE="$(openssl rand -base64 48 | tr -d '\n')" \
     --from-literal=METRICS_TOKEN="$(openssl rand -hex 32)"
   ```

2. Set `PHX_HOST`, `TRUSTED_PROXIES` (your ingress controller's addresses) and the image tag, preferably in an
   overlay that references `deploy/k8s` as a base.
3. Apply:

   ```sh
   kubectl apply -k deploy/k8s
   kubectl rollout status deploy/converger
   kubectl exec deploy/converger -- /app/bin/converger rpc 'IO.inspect(Node.list())'
   ```

On the first apply the migration Job and the pods start together. Until the Job has finished, `/health/ready`
answers `503 migrations pending: N`, so the pods are not added to the Service and get no traffic (Oban may log
errors about missing tables during that time; the pods recover once the schema exists). This is the readiness
gating; no init container or ordering is needed.

### Upgrades

A Job's pod template is immutable, so for each new image:

```sh
kubectl delete job converger-migrate --ignore-not-found   # or wait for ttlSecondsAfterFinished (10 min)
kubectl apply -k deploy/k8s                                # new image tag in kustomization.yaml
```

New pods only become ready once their own migrations are applied, and `maxUnavailable: 0` keeps the old pods
serving until then. Migrations must follow the expand/contract rules in
[Migrations and maintenance windows](migrations.md), since old and new pods run side by side. With Helm or
Argo CD, run the migration as a pre-upgrade / PreSync hook instead (the chart does).

## Probes and shutdown

| Probe | Endpoint | Settings | Why |
| --- | --- | --- | --- |
| startup | `/health/live` | every 2 s, up to 120 s | covers VM boot; liveness only starts afterwards |
| liveness | `/health/live` | every 10 s, 6 failures | restarts a hung VM; never fails because of the database |
| readiness | `/health/ready` | every 5 s, 2 failures | removes the pod from the Service when the database is unreachable, Oban is down, migrations are pending or the pod is draining |

The probes hit the pod IP over plain HTTP. `/health/*` is served before `ForceSSL`, so no
`FORCE_SSL_EXCLUDE_PATHS` entry is needed.

Shutdown: Kubernetes removes a terminating pod from the Service endpoints and runs the `preStop` hook
(`sleep 5`, time for kube-proxy and the ingress to stop routing to it) before sending SIGTERM. The release then
marks itself draining (`ConvergerWeb.Drain`: readiness answers `503 draining` and new sockets are refused), waits
`WS_DRAIN_DELAY_MS` (5 s), then closes its native and Phoenix WebSockets in batches and lets Oban finish running
jobs; see [WebSocket limits and draining](websocket-limits.md#draining-on-shutdown), which budgets 60 s with the
defaults and up to 90 s for nodes holding many of both socket kinds. `terminationGracePeriodSeconds: 95` covers the
preStop sleep plus that budget; raise it together with the drain settings. A job that is still running when the pod is killed
is rescued by Oban's Lifeline plugin ([chaos testing](../chaos.md)).

## Clustering

`CLUSTER_STRATEGY=kubernetes_dns` with `CLUSTER_SERVICE=converger-headless`: libcluster resolves the headless
Service every 5 s and connects to `converger@<pod IP>`. `rel/env.sh.eex` names each node `converger@$POD_IP`
(`POD_IP` comes from the downward API in `deployment.yaml`). The headless Service publishes not-ready pods, so a
starting pod joins the cluster (PubSub, rate-limit sync) before it receives traffic. The Helm chart sets the fully
qualified Service name (`<release>-converger-headless.<namespace>.svc.cluster.local`).

If a NetworkPolicy restricts pod traffic, allow pod-to-pod TCP on 4369 (EPMD) and the distribution port. Pin
the distribution port with `CLUSTER_DIST_PORT` (the Helm chart sets `9100` and, with `networkPolicy.enabled`, renders
that policy). Do not pin it through `ERL_AFLAGS`: that also applies to `bin/converger rpc`, whose second node would
then fail to bind the same port.

## Metrics

Scrape every pod (not the Service) at `:4000/metrics` with the bearer token from the Secret, for example with the
Prometheus Operator:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: converger
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: converger
      app.kubernetes.io/component: server
  podMetricsEndpoints:
    - port: http
      path: /metrics
      bearerTokenSecret:
        name: converger-env
        key: METRICS_TOKEN
```

Or set `METRICS_ALLOWED_IPS` in the ConfigMap to the Prometheus pods' range and drop the token. See
[Observability](observability.md#prometheus-endpoint). The Helm chart renders this `PodMonitor` with
`metrics.podMonitor.enabled=true`.

## Helm chart

`deploy/helm/converger` renders the same resources as `deploy/k8s`, runs the migration as a
`pre-install,pre-upgrade` hook (so upgrades need no manual Job cleanup), and adds optional Ingress, Prometheus
Operator `PodMonitor`, `NetworkPolicy` and a chart-managed Secret. Every `v*` release publishes it to GHCR as an
OCI artifact, with the chart `version` and `appVersion` both set to the release version.

```sh
helm install converger oci://ghcr.io/aimtune/charts/converger --version <version> \
  -n converger \
  --set env.PHX_HOST=converger.example.com

helm test converger -n converger    # GET /health/ready through the Service
```

From a checkout, use `deploy/helm/converger` instead of the OCI reference. The Secret (`converger-env` by default)
is the same one as in [Install](#install).

| Value | Default | Meaning |
| --- | --- | --- |
| `image.repository`, `image.tag`, `image.digest` | `ghcr.io/aimtune/converger`, chart `appVersion`, empty | Image to run; a digest wins over the tag |
| `existingSecret` | `converger-env` | Secret with `DATABASE_URL`, `SECRET_KEY_BASE`, `CLOAK_KEY`, `RELEASE_COOKIE`, optional `METRICS_TOKEN` |
| `secret.create`, `secret.*` | `false` | Render that Secret from values instead. The values then live in the Helm release; with migrations on, the Secret is a hook (created before the migration Job, kept on uninstall). Prefer `existingSecret` in production. |
| `env` | `PHX_HOST`, `TRUSTED_PROXIES`, `FORCE_SSL`, `POOL_SIZE`, `METRICS_ALLOWED_IPS` | Non-secret settings, rendered into the ConfigMap ([Configuration](configuration.md)) |
| `extraEnv`, `extraEnvFrom` | `[]` | More env entries or sources, for example `MAILGUN_API_KEY` from another Secret |
| `cluster.strategy` | `kubernetes_dns` | `none` for a single, unclustered replica (no headless Service) |
| `cluster.nodeBasename` | `converger` | Nodes are `<basename>@<pod IP>` |
| `cluster.distributionPort` | `9100` | `CLUSTER_DIST_PORT`; `null` leaves the port random |
| `replicaCount` | `2` | Used when autoscaling is off |
| `autoscaling.*` | on, 2 to 10 replicas, 70 % CPU, optional memory target | HPA, scaling in one pod a minute |
| `podDisruptionBudget.*` | on, `minAvailable: 1` | PDB |
| `migrations.*` | on, `backoffLimit: 3`, `activeDeadlineSeconds: 600` | `/app/bin/migrate` hook with the new image |
| `serviceAccount.*` | created, no API token | Annotate it for cloud IAM (IRSA, Workload Identity). The migration hook only uses it when `create: false` (the chart's own account does not exist yet during `pre-install`). |
| `service.*` | `ClusterIP`, port 80 | Service to the `http` port (4000) |
| `ingress.*` | off | Ingress to the Service; raise the controller's proxy timeouts for WebSockets |
| `metrics.podMonitor.*` | off, 30 s | Scrapes every pod's `/metrics` with `METRICS_TOKEN` from the Secret (needs the Prometheus Operator CRDs) |
| `networkPolicy.enabled`, `networkPolicy.httpFrom` | off, `[]` | Allows HTTP from `httpFrom` (everyone when empty) and EPMD plus the distribution port between Converger pods |
| `defaultTopologySpread`, `topologySpreadConstraints` | `true`, `[]` | Soft spread over nodes and zones unless constraints are given |
| `terminationGracePeriodSeconds`, `preStopSleepSeconds` | `95`, `5` | See [Probes and shutdown](#probes-and-shutdown) |
| `podSecurityContext`, `securityContext`, `resources`, `podAnnotations`, `podLabels`, `priorityClassName`, `nodeSelector`, `tolerations`, `affinity` | non-root, 250m/512Mi | The usual pod settings |

`values.schema.json` rejects unknown strategies, bad digests and wrongly typed values on `install`, `upgrade`,
`lint` and `template`. The chart's own [README](https://github.com/AimTune/converger/tree/main/deploy/helm/converger)
lists the same values.

## Validation

The `Deploy manifests` workflow (`.github/workflows/deploy.yml`) runs on every change under `deploy/`: it renders
`kubectl kustomize deploy/k8s` and checks it with [kubeconform](https://github.com/yannh/kubeconform) (`-strict`,
Kubernetes 1.31), then runs `helm lint --strict` and `helm template | kubeconform` (with the CRD catalog for the
`PodMonitor`) for every values file in `deploy/helm/converger/ci/` (defaults, every option on, single node). On a
`v*` tag it then packages the chart and pushes it to `oci://ghcr.io/aimtune/charts`. Nothing is exercised against a
live cluster in CI; the cluster behaviour itself is covered by the
[two-node test suite](clustering.md#the-two-node-test-suite).
