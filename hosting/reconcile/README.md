# reconcile (NEX-816) — GitOps-lite drift safety net

Three incidents landed this: a 3-week-stale image ran in prod while its fix
sat merged; a security hot-patch lived only in the deployed copy, never in
the repo; a `kubectl`-applied zombie deployment ran a pre-fix image for a
week, evicting every 8 minutes. In every case live and repo state drifted
apart silently. `reconcile.sh` makes the repo the source of truth, on a
timer, and **alerts before it acts** so a human sees what is about to change.

## What it does

`reconcile.sh`:

1. `git pull --ff-only` in the checkout it runs from.
2. Renders the same manifest sources `hosting/apply.sh` does (cluster config,
   raw per-service manifests, chart-rendered `*.values.yaml` services).
3. `kubectl diff`s each one. `kubectl diff` exits `0` for no drift, `1` when
   drift exists, and `>1` on an actual error — these are different things and
   getting them mixed up is the classic bug here; the script tells them
   apart.
4. If there is drift anywhere: POSTs a compact summary to Discord **before**
   applying anything. If the alert fails to send, it refuses to apply blind
   and exits nonzero instead.
5. `kubectl apply --server-side` everything that isn't in the skip-list.
6. No drift anywhere -> exits `0` silently, no alert, no apply.

Any `git`/`kubectl`/`curl` failure alerts and exits nonzero. Reconcile never
partially applies: it fails before the apply phase starts, and each apply
call failing mid-loop also aborts immediately.

## Provisioning the webhook file

The Discord webhook URL is **never** hardcoded or logged. `reconcile.sh`
reads it from a file, path given by `RECONCILE_WEBHOOK_FILE` (default
`/etc/carriedworld/discord_webhook`). Provision it out of band:

```sh
# systemd host:
install -o carriedworld-reconcile -m 0400 /dev/stdin /etc/carriedworld/discord_webhook <<< "$WEBHOOK_URL"

# k3s CronJob:
kubectl create secret generic reconcile-discord-webhook -n nexus \
  --from-literal=webhook=<the webhook URL>
```

If the file is missing or unreadable, reconcile logs a warning and still
proceeds (drift is still applied) — this is a deliberate choice so a
misconfigured alert channel does not become a second drift-safety failure;
it does mean a broken webhook file fails *silently* on the alerting side, so
treat "reconcile logs are clean but I never see Discord messages" as its own
incident.

## Timer vs CronJob — pick one

Two equivalent triggers are provided; run **one**, not both:

- **systemd** (`reconcile.service` + `reconcile.timer`) — for running
  reconcile directly on the host that has kubectl/helm access (e.g. dMon).
  `systemctl enable --now reconcile.timer`. Every 15 minutes
  (`RandomizedDelaySec=90`, `Persistent=true` so a missed run while the host
  was down fires on the next boot).
- **k3s CronJob** (`reconcile-cronjob.yaml`) — for running reconcile as a job
  inside the cluster (matches the existing
  `../../bootstrap/hosting-reconcile-cronjob.yaml` shape, but diff-first and
  alerting). If you adopt this one, retire the older
  `bootstrap/hosting-reconcile-cronjob.yaml` (it applies with no diff and no
  alert) so there is only one periodic reconciler running.

Both invoke the same `reconcile.sh`.

## Skip-list

`RECONCILE_SKIP_FILE` optionally points at a file listing manifest-source
basenames to exclude from diff+apply entirely (see `skip-list.example`).
Empty/unset by default — nothing is skipped.

## Diff-only mode (run this first)

Set `RECONCILE_DIFF_ONLY=1` and reconcile does everything except write: it
pulls, diffs, and sends the Discord alert (prefixed `DIFF-ONLY:`), then exits
without applying. This is the safe way to run a first cycle on a cluster whose
repo has not been the source of truth for a while — you get to read exactly
what WOULD change, and prove the alert path works, before anything is applied.
It is also the honest way to answer "what has drifted?" at any time.

    RECONCILE_DIFF_ONLY=1 RECONCILE_WEBHOOK_FILE=/etc/carriedworld/discord_webhook \
      bash hosting/reconcile/reconcile.sh

Drop the variable (or set it empty) to arm the apply.

## Field ownership (`--force-conflicts`)

The apply runs `kubectl apply --server-side --force-conflicts`. Server-side
apply tracks which manager owns each field; a `kubectl set image`, a
`kubectl edit`, or an apply from a laptop takes ownership of what it touched
and a plain server-side apply then REFUSES to overwrite it. Since reconcile's
whole contract is that the repo wins, it forces the conflict and takes the
field back — that is the same statement as "hand edits get reverted", just at
field granularity rather than object granularity.

This is safe precisely because the diff and the Discord alert happen BEFORE
the apply: nothing is force-overwritten without having been reported first.
If you need a field to stay under someone else's control, skip-list its
manifest rather than weakening this flag.

## Break-glass

Reconcile is **repo -> live only**. Any hand edit made directly against the
live cluster (`kubectl edit`, `kubectl apply` from a laptop, a manual
patch to "just fix it for now") **will be reverted** the next time reconcile
runs — that is the entire point, and it is by design, not a bug. If you need
to make a live change stick, put it in the repo first.

If reconcile itself is misbehaving (flapping, applying something wrong,
alert storm) or you need to freeze live state while you investigate:

- **systemd**: `systemctl stop reconcile.timer` (stops future runs; an
  in-flight run finishes). `systemctl disable reconcile.timer` to also
  survive a reboot.
- **k3s CronJob**: `kubectl patch cronjob hosting-reconcile -n nexus -p
  '{"spec":{"suspend":true}}'` (suspends future runs without deleting the
  CronJob/RBAC). Resume with `"suspend":false`.

Re-enable once the underlying issue (a bad manifest, a broken webhook, a
kubectl/RBAC problem) is fixed in the repo.

## Digest bump on image publish

`.github/workflows/digest-bump.yml` + `bump-digest.sh` + `images.txt`: when
an image is published, bump its digest-pinned reference in the manifest that
declares it and open a PR (never a direct push to main — Fable reviews
first, same as every other change here). Adding a new image to track is one
line in `images.txt`.

## Tests

`tests/reconcile-tests.sh` drives `reconcile.sh` with fake `kubectl` /
`helm` / `curl` / `git` on `PATH` — no cluster, no network, no real webhook —
through the no-diff / diff-exists / kubectl-error / missing-webhook-file
scenarios, asserting both which calls happened and their order (webhook
POST before apply). Run it directly: `bash hosting/reconcile/tests/reconcile-tests.sh`.
