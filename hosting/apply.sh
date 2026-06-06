#!/usr/bin/env bash
# Reconcile the hosting platform: render every hosted service via the
# convention chart and apply it, plus cluster-level config (coredns) and
# per-service RBAC. Idempotent — safe to run repeatedly (CI on merge + the
# periodic CronJob both call this). Exits non-zero on any apply failure.
#
#   KUBECTL / HELM env vars override the binaries (e.g. KUBECTL="sudo kubectl").
set -euo pipefail
cd "$(dirname "$0")/.."            # repo root

KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"
CHART="hosting/chart"

echo "== cluster config (clusters/dmon) =="
$KUBECTL apply -f clusters/dmon/

echo "== per-service RBAC =="
for f in hosting/services/*-rbac.yaml; do
  [ -e "$f" ] || continue
  echo "-- $(basename "$f") --"
  $KUBECTL apply -f "$f"
done

echo "== hosted services =="
for f in hosting/services/*.values.yaml; do
  [ -e "$f" ] || continue
  name="$(basename "$f" .values.yaml)"
  echo "-- $name --"
  $HELM template "$name" "$CHART" -f "$f" | $KUBECTL apply -f -
done

echo "== reconcile complete =="
