# Sovereign data node (robo-dog / atom-gb10)

Captured from the live cluster after cairn + herald + ledger were relocated onto
the robo-dog GB10 node (`cwb/gpu: atom-gb10`) with persistent state on the node's
`/data/sovereign` disk. These manifests were originally applied live-only; this
directory makes them reproducible.

## What's here
- `ledger-rd.yaml` — ledger Deployment (arm64 `ghcr.io/.../ledger:main`) + its per-pod Service `ledger-rd`.
- `herald-rd.yaml` — herald Deployment + Service `herald-rd`.
- `cairn-rd.yaml` — cairn Deployment (HTTP 8100 / gRPC 8102 / SSH 2222). No `cairn-rd` Service exists in the cluster; the flipped `cairn` + `cairn-ssh` services target `app=cairn-rd` directly.
- `services-flipped.yaml` — the four pre-existing stable services (`ledger`, `herald`, `cairn`, `cairn-ssh`) whose selectors were CUT OVER to `app=*-rd`. Captured to document the cutover.
- `cairn-github-mirror.yaml` — the `cairn-mirror-script` ConfigMap (mirror.sh) + the `cairn-github-mirror` CronJob (every 6h at :23) that mirrors each cairn bare repo to a private `CarriedWorldUniverse/cairn-mirror-<slug>` GitHub repo.

## hostPath data layout (on the robo-dog node)
Persistent state lives on the node under `/data/sovereign/`:
- `/data/sovereign/herald`  -> mounted at `/var/lib/herald`  (herald.db)
- `/data/sovereign/ledger`  -> mounted at `/var/lib/ledger`  (ledger.db)
- `/data/sovereign/cairn`   -> mounted at `/var/lib/nexus`   (cairn.db + `repos/` bare repos)

These are `hostPath` (type: Directory) volumes; the directories must pre-exist on the node.

## Pre-existing secrets (referenced by name, NOT captured here)
These Secrets must already exist in namespace `cwb`; the manifests reference them
by name only. Secret VALUES are deliberately not stored in git.
- `cairn-mirror-pat` — GitHub PAT (key `gh_pat`) used by the mirror CronJob.
- `herald-tls`, `ledger-tls`, `cairn-client-tls` — mesh mTLS cert/key/ca (mounted at `/etc/cwb/tls`).
- `cairn-secrets` — cairn SSH host key (key `ssh_host_key`).
- `herald-secrets` — herald signing key + genesis owner password (keys `signing_key`, `genesis_owner_password`).
- `ghcr-pull` — image pull secret for `ghcr.io/carriedworlduniverse/*`.

## Design doc
See `docs/network/SOVEREIGN-DATA-NODE.md` in the nexus repo.
