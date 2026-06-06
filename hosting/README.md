# Hosting Platform

This directory contains the hosted-service declarations and the shared chart used
to render them into cluster resources.

- `chart/` is the hosted-service convention Helm chart.
- `services/*.values.yaml` are per-service declarations rendered through that
  chart.
- `services/` may also contain raw manifests for bespoke services, such as
  `nexus-broker.yaml`.
- `apply.sh` is the idempotent reconcile entrypoint. It renders services and
  applies cluster config and RBAC.
- `../bootstrap/hosting-reconcile-cronjob.yaml` runs the periodic reconcile.
- `../clusters/dmon/coredns-custom.yaml` is the CoreDNS naming keystone for the
  platform.
