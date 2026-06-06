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


## Phase 2 — error->keel alerting (DEPLOYED 2026-06-07, validated end-to-end)

Live automatic pipeline: **Loki ruler** (loki-rules.yaml: LogErrorBurst, >20 error lines/5m/pod for 5m) -> **Alertmanager** (alertmanager.yaml, routes all -> webhook) -> **loki-alert-bridge** (nexus ns; pulls the Loki log window, posts @keel with context) -> **keel** triages (has kubectl read-only cluster access + the full-tools image).

Files:
- loki-values.yaml: rulerConfig (alertmanager_url + local rules) + singleBinary.extraVolumes mounting the loki-alerting-rules ConfigMap at /rules/fake (tenant "fake", auth disabled).
- loki-rules.yaml: the LogErrorBurst alerting rule (ConfigMap). Tune threshold/regex here.
- alertmanager.yaml: prom/alertmanager:v0.27.0 + config (webhook -> loki-alert-bridge.nexus.svc.cluster.local:8080/alertmanager) + ClusterIP svc.
- bridge deploy + observer identity: ../services/loki-alert-bridge.values.yaml; image build: nexus repo deploy/loki-alert-bridge/.
- keel cluster access: ../services/keel-rbac.yaml (read-only, all ns, no secrets) + kubectl in the nexus-builder image.

Apply:
  kubectl apply -f logging/alertmanager.yaml -f logging/loki-rules.yaml
  helm template loki grafana/loki -n logging -f logging/loki-values.yaml | kubectl apply -n logging -f -
