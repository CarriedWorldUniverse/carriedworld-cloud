#!/usr/bin/env bash
# Diff-first, alert-before-apply reconcile. This is the drift-safety loop
# behind NEX-816: three incidents (a 3-week-stale image running in prod, a
# security hot-patch that only ever lived in the deployed copy, and a
# kubectl-applied zombie deployment evicting every 8 minutes for a week) all
# came from live and repo state silently drifting apart. This script makes
# the repo the source of truth, on a timer, and alerts BEFORE it acts so a
# human sees what is about to change.
#
# Flow: git pull --ff-only -> render every manifest source the same way
# hosting/apply.sh does -> `kubectl diff` each one (0 = no drift, 1 = drift,
# >1 = kubectl error -- these are NOT the same thing, mixing them up is the
# classic bug here) -> if any drift was found, POST a summary to Discord
# *before* applying anything -> `kubectl apply --server-side` everything not
# in the skip-list. Any git/kubectl/curl failure alerts and exits nonzero;
# reconcile never partially applies.
#
# Env overrides:
#   RECONCILE_WEBHOOK_FILE  file holding the Discord webhook URL (never a
#                           literal URL in this repo). Default:
#                           /etc/carriedworld/discord_webhook
#   RECONCILE_SKIP_FILE     optional file listing manifest sources to skip,
#                           one basename per line (# comments, blank lines
#                           ignored). Default: none configured (nothing
#                           skipped). See hosting/reconcile/README.md.
#   RECONCILE_DIFF_ONLY     if set to a non-empty value, report drift and send
#                           the alert but NEVER apply -- the safe way to run a
#                           first cycle (or to answer "what would change?")
#                           without writing to the cluster
#   RECONCILE_NO_PULL       if set to a non-empty value, skip the git pull
#                           step (used by the test harness; real deployments
#                           should leave this unset).
#   KUBECTL / HELM / GIT / CURL  override the binaries invoked, same
#                           convention as hosting/apply.sh (e.g. for test
#                           fakes, or KUBECTL="sudo kubectl").
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"
GIT="${GIT:-git}"
CURL="${CURL:-curl}"
CHART="hosting/chart"
WEBHOOK_FILE="${RECONCILE_WEBHOOK_FILE:-/etc/carriedworld/discord_webhook}"
SKIP_FILE="${RECONCILE_SKIP_FILE:-}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

json_escape() {
  # Pure-bash JSON string escaping -- no external interpreter dependency.
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

alert() {
  # Post a plain-text summary to Discord. Never echoes the webhook URL.
  local msg="$1"
  if [ ! -r "$WEBHOOK_FILE" ]; then
    echo "reconcile: WARNING: webhook file not readable ($WEBHOOK_FILE) -- skipping Discord alert" >&2
    return 0
  fi
  local url payload
  url="$(<"$WEBHOOK_FILE")"
  payload="{\"content\":\"$(json_escape "$msg")\"}"
  if ! "$CURL" -fsS -X POST -H 'Content-Type: application/json' -d "$payload" "$url" >/dev/null; then
    echo "reconcile: WARNING: failed to POST Discord alert" >&2
    return 1
  fi
  return 0
}

fail() {
  local msg="$1"
  echo "reconcile: ERROR: $msg" >&2
  alert "reconcile FAILED: $msg" || true
  exit 1
}

is_skipped() {
  # $1 = a name to test (basename of the manifest source) against the
  # skip-list file, if configured.
  local name="$1"
  [ -n "$SKIP_FILE" ] || return 1
  [ -r "$SKIP_FILE" ] || return 1
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -n "$line" ] || continue
    [ "$line" = "$name" ] && return 0
  done <"$SKIP_FILE"
  return 1
}

# ---------------------------------------------------------------------------
# 1. bring the checkout up to date
# ---------------------------------------------------------------------------

if [ -n "${RECONCILE_NO_PULL:-}" ]; then
  echo "reconcile: RECONCILE_NO_PULL set -- skipping git pull"
else
  echo "== git pull --ff-only =="
  if ! "$GIT" pull --ff-only; then
    fail "git pull --ff-only failed"
  fi
fi

# ---------------------------------------------------------------------------
# 2. assemble the manifest sources (same three phases as hosting/apply.sh)
#    each entry is "label|path-to-diff-and-apply"
# ---------------------------------------------------------------------------

targets=()

targets+=("clusters/dmon|clusters/dmon")

for f in hosting/services/*.yaml; do
  case "$f" in *.values.yaml) continue ;; esac
  [ -e "$f" ] || continue
  targets+=("$(basename "$f")|$f")
done

for f in hosting/services/*.values.yaml; do
  [ -e "$f" ] || continue
  name="$(basename "$f" .values.yaml)"
  rendered="$tmp_dir/${name}.rendered.yaml"
  if ! "$HELM" template "$name" "$CHART" -f "$f" >"$rendered" 2>"$tmp_dir/${name}.helm.err"; then
    fail "helm template failed for $name ($(cat "$tmp_dir/${name}.helm.err" 2>/dev/null))"
  fi
  targets+=("$(basename "$f")|$rendered")
done

# ---------------------------------------------------------------------------
# 3. diff every target -- 0 = no drift, 1 = drift, >1 = kubectl error
# ---------------------------------------------------------------------------

echo "== kubectl diff =="
drift_found=0
diff_summary=""
apply_list=()

for target in "${targets[@]}"; do
  label="${target%%|*}"
  path="${target#*|}"

  if is_skipped "$label"; then
    echo "-- $label -- skipped (skip-list)"
    continue
  fi

  apply_list+=("$target")

  set +e
  diff_out="$("$KUBECTL" diff -f "$path" 2>"$tmp_dir/diff.err")"
  rc=$?
  set -e

  if [ "$rc" -gt 1 ]; then
    fail "kubectl diff failed for $label (exit $rc): $(cat "$tmp_dir/diff.err" 2>/dev/null)"
  elif [ "$rc" -eq 1 ]; then
    echo "-- $label -- drift detected"
    drift_found=1
    diff_summary="${diff_summary}${label}:
${diff_out}

"
  else
    echo "-- $label -- no drift"
  fi
done

# ---------------------------------------------------------------------------
# 4. alert BEFORE applying, if there is drift to apply
# ---------------------------------------------------------------------------

if [ "$drift_found" -eq 1 ]; then
  if [ -n "${RECONCILE_DIFF_ONLY:-}" ]; then
    verb="DIFF-ONLY: drift detected, NOT applying (RECONCILE_DIFF_ONLY set)."
  else
    verb="drift detected, applying now."
  fi
  summary="carriedworld-cloud reconcile: ${verb}

$(printf '%s' "$diff_summary" | head -c 3500)"
  if ! alert "$summary"; then
    fail "drift detected but the Discord alert failed to send -- refusing to apply blind"
  fi
else
  echo "== no drift -- nothing to apply =="
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. apply
# ---------------------------------------------------------------------------

if [ -n "${RECONCILE_DIFF_ONLY:-}" ]; then
  echo "== DIFF-ONLY mode: drift reported and alerted, apply skipped =="
  exit 0
fi

echo "== kubectl apply --server-side =="
for target in "${apply_list[@]}"; do
  label="${target%%|*}"
  path="${target#*|}"
  echo "-- $label --"
  if ! "$KUBECTL" apply --server-side -f "$path"; then
    fail "kubectl apply --server-side failed for $label"
  fi
done

echo "== reconcile complete =="
