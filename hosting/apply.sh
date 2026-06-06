#!/usr/bin/env bash
# Reconcile the hosting platform: cluster config (coredns), raw manifests
# (per-service RBAC + bespoke multi-container services like the broker), and
# the common-case services rendered via the convention chart. Idempotent —
# safe to run repeatedly (CI on merge + the periodic CronJob both call this).
#
#   KUBECTL / HELM env vars override the binaries (e.g. KUBECTL="sudo kubectl").
set -euo pipefail
cd "$(dirname "$0")/.."            # repo root

KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"
CHART="hosting/chart"

echo "== cluster config (clusters/dmon) =="
$KUBECTL apply -f clusters/dmon/

echo "== raw manifests (rbac + bespoke services) =="
for f in hosting/services/*.yaml; do
  case "$f" in *.values.yaml) continue ;; esac
  [ -e "$f" ] || continue
  echo "-- $(basename "$f") --"
  $KUBECTL apply -f "$f"
done

echo "== convention-chart services =="
for f in hosting/services/*.values.yaml; do
  [ -e "$f" ] || continue
  name="$(basename "$f" .values.yaml)"
  echo "-- $name --"
  $HELM template "$name" "$CHART" -f "$f" | $KUBECTL apply -f -
done

echo "== reconcile complete =="
