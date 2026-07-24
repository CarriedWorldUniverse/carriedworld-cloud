#!/usr/bin/env bash
# Exercises hosting/reconcile/reconcile.sh with fake kubectl/helm/curl/git on
# PATH -- no cluster, no network, no real webhook. Each fake records its
# invocations (argv, one per line) to a shared log file so assertions can
# check both *that* a call happened and the *order* calls happened in.
#
# Scenarios (see NEX-816):
#   i.   no drift            -> apply not called, exit 0, no webhook POST
#   ii.  drift exists        -> webhook POST happens BEFORE apply (order
#                                asserted from the log), apply gets
#                                --server-side
#   iii. kubectl diff errors -> nonzero exit, alert sent, apply NOT called
#   iv.  missing webhook file -> reconcile still applies, but warns
set -euo pipefail

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reconcile_dir="$(cd "$tests_dir/.." && pwd)"
reconcile_sh="$reconcile_dir/reconcile.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail() {
  echo "FAIL: $1" >&2
  echo "--- call log ---" >&2
  cat "$log_file" >&2 2>/dev/null || true
  exit 1
}

# --- fake binaries ----------------------------------------------------------
# KUBECTL_DIFF_RC / KUBECTL_APPLY_RC / CURL_RC / GIT_RC are read by the fakes
# via env vars threaded through by run_case, so each scenario can script a
# distinct exit code without touching PATH between cases.

fake_bin_dir="$work_dir/fakebin"
mkdir -p "$fake_bin_dir"

cat >"$fake_bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$RECONCILE_TEST_LOG"
if [ "$1" = "diff" ]; then
  exit "${KUBECTL_DIFF_RC:-0}"
elif [ "$1" = "apply" ]; then
  exit "${KUBECTL_APPLY_RC:-0}"
fi
exit 0
EOF

cat >"$fake_bin_dir/helm" <<'EOF'
#!/usr/bin/env bash
echo "helm $*" >> "$RECONCILE_TEST_LOG"
echo "# fake rendered manifest for $2"
exit 0
EOF

cat >"$fake_bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$RECONCILE_TEST_LOG"
# Record the -d payload so a test can assert on its SIZE (Discord caps the
# content field at 2000 chars and 400s anything larger -- verified live).
prev=""
for a in "$@"; do
  if [ "$prev" = "-d" ] && [ -n "${RECONCILE_TEST_PAYLOAD:-}" ]; then
    printf '%s' "$a" > "$RECONCILE_TEST_PAYLOAD"
  fi
  prev="$a"
done
exit "${CURL_RC:-0}"
EOF

cat >"$fake_bin_dir/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "$RECONCILE_TEST_LOG"
exit "${GIT_RC:-0}"
EOF

chmod +x "$fake_bin_dir"/*

log_file=""

run_case() {
  # run_case <name> <expected_exit> [env=val ...]
  local name="$1" expected_exit="$2"
  shift 2
  log_file="$work_dir/${name}.log"
  : >"$log_file"
  rm -f "$work_dir/curl-payload.txt"

  set +e
  env -i \
    PATH="$fake_bin_dir:/usr/bin:/bin" \
    RECONCILE_TEST_LOG="$log_file" \
    RECONCILE_TEST_PAYLOAD="$work_dir/curl-payload.txt" \
    RECONCILE_NO_PULL=1 \
    "$@" \
    bash "$reconcile_sh" >"$work_dir/${name}.out" 2>"$work_dir/${name}.err"
  actual_exit=$?
  set -e

  echo "=== case: $name (exit $actual_exit, expected $expected_exit) ==="
  cat "$work_dir/${name}.out" "$work_dir/${name}.err"

  if [ "$actual_exit" -ne "$expected_exit" ]; then
    fail "$name: expected exit $expected_exit, got $actual_exit"
  fi
}

called() {
  # called <log> <pattern>
  grep -Fq "$2" "$1"
}

not_called() {
  ! grep -Fq "$2" "$1"
}

order_before() {
  # order_before <log> <first> <second> -- asserts the first line matching
  # <first> appears before the first line matching <second>.
  local log="$1" first="$2" second="$3"
  local first_ln second_ln
  first_ln="$(grep -Fn "$first" "$log" | head -1 | cut -d: -f1)"
  second_ln="$(grep -Fn "$second" "$log" | head -1 | cut -d: -f1)"
  [ -n "$first_ln" ] || fail "order_before: '$first' never appeared in log"
  [ -n "$second_ln" ] || fail "order_before: '$second' never appeared in log"
  [ "$first_ln" -lt "$second_ln" ] || fail "order_before: expected '$first' (line $first_ln) before '$second' (line $second_ln)"
}

# --- webhook file fixtures ---------------------------------------------------

webhook_file="$work_dir/discord_webhook"
printf 'https://discord.example.invalid/webhook/fake-not-real\n' >"$webhook_file"

missing_webhook_file="$work_dir/no-such-webhook"

# --- (i) no diff -------------------------------------------------------------

run_case "no-diff" 0 \
  KUBECTL_DIFF_RC=0 \
  RECONCILE_WEBHOOK_FILE="$webhook_file"

not_called "$log_file" "kubectl apply" || fail "no-diff: apply must not be called"
not_called "$log_file" "curl " || fail "no-diff: webhook must not be POSTed"
echo "PASS: no-diff"

# --- (ii) diff exists ---------------------------------------------------------

run_case "diff-exists" 0 \
  KUBECTL_DIFF_RC=1 \
  RECONCILE_WEBHOOK_FILE="$webhook_file"

called "$log_file" "curl " || fail "diff-exists: webhook must be POSTed"
called "$log_file" "kubectl apply --server-side" || fail "diff-exists: apply must be called with --server-side"
order_before "$log_file" "curl " "kubectl apply --server-side"
echo "PASS: diff-exists (webhook before apply, --server-side used)"

# --- (iii) kubectl diff errors -------------------------------------------------

run_case "diff-error" 1 \
  KUBECTL_DIFF_RC=2 \
  RECONCILE_WEBHOOK_FILE="$webhook_file"

called "$log_file" "curl " || fail "diff-error: alert must still be sent on failure"
not_called "$log_file" "kubectl apply" || fail "diff-error: apply must NOT be called after a kubectl diff error"
echo "PASS: diff-error (alerted, apply skipped, nonzero exit)"

# --- (iv) missing webhook file --------------------------------------------------

run_case "missing-webhook" 0 \
  KUBECTL_DIFF_RC=1 \
  RECONCILE_WEBHOOK_FILE="$missing_webhook_file"

not_called "$log_file" "curl " || fail "missing-webhook: no webhook file means no curl call possible"
grep -q "WARNING: webhook file not readable" "$work_dir/missing-webhook.err" || fail "missing-webhook: must warn"
called "$log_file" "kubectl apply --server-side" || fail "missing-webhook: reconcile must still apply (documented choice, see README)"
echo "PASS: missing-webhook (warns, still applies)"

# --- (v) diff-only mode ---------------------------------------------------------
# The safe first-cycle / "what would change?" mode: drift is found and ALERTED,
# but the cluster is never written to.

run_case "diff-only" 0 \
  KUBECTL_DIFF_RC=1 \
  RECONCILE_DIFF_ONLY=1 \
  RECONCILE_WEBHOOK_FILE="$webhook_file"

called "$log_file" "curl " || fail "diff-only: the alert must still be sent"
not_called "$log_file" "kubectl apply" || fail "diff-only: apply must NEVER be called in diff-only mode"
grep -q "DIFF-ONLY" "$work_dir/diff-only.out" || fail "diff-only: run must announce diff-only mode"
echo "PASS: diff-only (alerted, apply never called)"

# --- (vi) oversized alert payload ----------------------------------------------
# Discord rejects content >2000 chars with HTTP 400 (verified live 2026-07-24).
# A huge diff must still produce a SENDABLE alert, not a 400 that makes
# reconcile refuse to apply.

run_case "big-diff" 0 \
  KUBECTL_DIFF_RC=1 \
  KUBECTL_DIFF_BYTES=9000 \
  RECONCILE_WEBHOOK_FILE="$webhook_file"

called "$log_file" "curl " || fail "big-diff: alert must still be sent"
[ -s "$work_dir/curl-payload.txt" ] || fail "big-diff: no curl payload captured -- the assertion below would pass vacuously"
payload_len=$(wc -c <"$work_dir/curl-payload.txt")
[ "$payload_len" -gt 200 ] || fail "big-diff: payload suspiciously small (${payload_len}) -- the diff body should be present"
[ "$payload_len" -lt 2100 ] || fail "big-diff: payload is ${payload_len} bytes -- Discord caps content at 2000"
echo "PASS: big-diff (payload capped to ${payload_len} bytes, alert sent)"

echo
echo "all reconcile scenarios passed"
