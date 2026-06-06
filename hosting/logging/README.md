# Logging / observability (Phase 1 — aggregation)

Centralised, bounded, AI-queryable logs for the local cloud.

- **Loki** single-binary, 30d retention (`retention_period: 720h`) + compactor, 20Gi capped PVC. Service `loki.logging.svc.cluster.local:3100`, LogQL HTTP API.
- **Alloy** DaemonSet tails every pod log via the k8s API -> Loki, labelled `namespace/pod/container/node`.
- Node-level: kubelet default container-log rotation bounds raw on-disk logs; explicit tuning deferred (needs a k3s restart).

## Rebuild
```
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update grafana
kubectl create namespace logging
helm template loki  grafana/loki  -n logging -f loki-values.yaml  | kubectl apply -n logging -f -
helm template alloy grafana/alloy -n logging -f alloy-values.yaml | kubectl apply -n logging -f -
kubectl apply -f alloy-rbac.yaml
```

## Phase 2 (next): error -> keel
Loki ruler fires on error signals -> alert->comms bridge pulls the log window + posts `@keel` (Frame / infra handler) with context -> keel triages, files a ledger issue, can dispatch a fix.
