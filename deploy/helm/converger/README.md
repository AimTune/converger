# Converger Helm chart

Runs [Converger](https://converger.aimtune.dev) on Kubernetes as a libcluster cluster (Kubernetes DNS strategy over
a headless Service), with readiness-gated rolling updates, a pre-install/pre-upgrade migration hook, an HPA and a
PodDisruptionBudget. Optional: Ingress, Prometheus Operator `PodMonitor`, `NetworkPolicy`, a chart-managed Secret.

Full guide: [Kubernetes](https://converger.aimtune.dev/operations/kubernetes).

## Install

The chart is published as an OCI artifact with every `v*` release, versioned like the application:

```sh
kubectl create namespace converger
kubectl -n converger create secret generic converger-env \
  --from-literal=DATABASE_URL='ecto://USER:PASS@HOST/converger' \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')" \
  --from-literal=CLOAK_KEY="$(openssl rand -base64 32)" \
  --from-literal=RELEASE_COOKIE="$(openssl rand -base64 48 | tr -d '\n')" \
  --from-literal=METRICS_TOKEN="$(openssl rand -hex 32)"

helm install converger oci://ghcr.io/aimtune/charts/converger --version <version> \
  -n converger \
  --set env.PHX_HOST=converger.example.com

helm test converger -n converger
```

From a checkout: `helm install converger deploy/helm/converger ...`.

## Values

| Value | Default | Meaning |
| --- | --- | --- |
| `image.repository` | `ghcr.io/aimtune/converger` | Image |
| `image.tag` / `image.digest` | chart `appVersion` / empty | A digest wins over the tag |
| `existingSecret` | `converger-env` | Secret with `DATABASE_URL`, `SECRET_KEY_BASE`, `CLOAK_KEY`, `RELEASE_COOKIE`, optional `METRICS_TOKEN` |
| `secret.create` | `false` | Render the Secret from `secret.*` instead (values end up in the release; a pre-install hook when migrations are on) |
| `env` | `PHX_HOST`, `TRUSTED_PROXIES`, `FORCE_SSL`, `POOL_SIZE`, `METRICS_ALLOWED_IPS` | Non-secret settings, rendered into the ConfigMap |
| `extraEnv`, `extraEnvFrom` | `[]` | More env entries / sources (for example `MAILGUN_API_KEY` from another Secret) |
| `cluster.strategy` | `kubernetes_dns` | `none` runs independent nodes (one replica only) |
| `cluster.nodeBasename` | `converger` | Nodes are named `<basename>@<pod IP>` |
| `cluster.distributionPort` | `9100` | Fixed Erlang distribution port (`CLUSTER_DIST_PORT`); `null` for a random one |
| `replicaCount` | `2` | Used when autoscaling is off |
| `autoscaling.*` | on, 2 to 10, 70 % CPU | HPA; scales down one pod a minute |
| `podDisruptionBudget.*` | on, `minAvailable: 1` | PDB |
| `migrations.*` | on, `backoffLimit: 3`, `activeDeadlineSeconds: 600` | `/app/bin/migrate` as a `pre-install,pre-upgrade` hook |
| `serviceAccount.*` | created, no API token | Annotate it for cloud IAM (IRSA, Workload Identity) |
| `service.*` | `ClusterIP`, port 80 | Service in front of `:4000` |
| `ingress.*` | off | Raise your controller's proxy timeouts for WebSockets |
| `metrics.podMonitor.*` | off | Scrapes every pod's `/metrics` with `METRICS_TOKEN` |
| `networkPolicy.*` | off | HTTP from `httpFrom` (all when empty); EPMD and distribution between Converger pods |
| `podSecurityContext`, `securityContext` | non-root 65534, `RuntimeDefault`, no capabilities | |
| `resources` | 250m / 512Mi requests, 1Gi limit | |
| `terminationGracePeriodSeconds`, `preStopSleepSeconds` | `95`, `5` | Covers the WebSocket drain budget |
| `defaultTopologySpread` | `true` | Soft spread over nodes and zones, unless `topologySpreadConstraints` is set |
| `podAnnotations`, `podLabels`, `priorityClassName`, `nodeSelector`, `tolerations`, `affinity` | empty | |
| `tests.image` | `busybox:1.37` | `helm test` pod that GETs `/health/ready` |

`values.schema.json` validates the values on `install`, `upgrade`, `lint` and `template`.

## Upgrades

`helm upgrade` runs the migration Job with the new image first; the Deployment rolls only when it succeeds, and new
pods stay unready until their migrations are applied. Every pod drains its WebSockets on shutdown, so keep
`terminationGracePeriodSeconds` above the drain budget when you change the drain settings.

## Development

```sh
helm lint --strict deploy/helm/converger -f deploy/helm/converger/ci/full-values.yaml
helm template converger deploy/helm/converger -f deploy/helm/converger/ci/full-values.yaml | kubeconform -strict -summary
```

CI (`.github/workflows/deploy.yml`) runs both for every file in `ci/` and for `deploy/k8s`.
