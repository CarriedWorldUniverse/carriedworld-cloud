# carriedworld-cloud

The Carried World **local cloud** — the self-hosted single-node **k3s** cluster on **dMon** that runs the platform (CWB) and the agent **dispatch fabric**, plus the declarative **hosting platform** that keeps it all configured. This repo both *records* the cluster and is where we *reconcile* it.

## Topology

**Host: dMon** — Fedora Workstation 44, AMD + RTX 5090 Laptop GPU. Single-node k3s (containerd; no registry — images are `podman build` → `k3s ctr import`). The cluster joins Tailscale as its own environment via the Kubernetes operator.

| Where | What runs |
|---|---|
| **k3s `nexus` ns** | The broker (`nexus-broker`, a pod — TLS `:7888`, reachable on the tailnet as `nexus.tail41686e.ts.net` and in-cluster via CoreDNS, carrying the M1 custodian seam); `keel` (always-on gemma aspect); the `dispatch-controller` + on-demand builder Jobs. |
| **k3s `cwb` ns** | CWB platform pillars: herald (identity), cairn (git), ledger, commonplace, interchange, and `sqld` (the libSQL data layer). |
| **k3s `kube-system`** | CoreDNS (with the hosting `coredns-custom` naming), cert-manager (Let's Encrypt TLS), the Tailscale operator. |

## Hosting platform (`hosting/`)

The standing, correctly-configured host environment a service plugs into so it is automatically named, networked, and storage-attached — see `hosting/README.md`.

- `hosting/chart/` — the hosted-service convention Helm chart.
- `hosting/services/*.values.yaml` — per-service declarations rendered via the chart; plus raw manifests for bespoke services (e.g. `nexus-broker.yaml`).
- `hosting/apply.sh` — the idempotent reconcile (renders services + applies cluster config + RBAC).
- `bootstrap/hosting-reconcile-cronjob.yaml` — the periodic reconcile (every 15 min).
- `clusters/dmon/coredns-custom.yaml` — the CoreDNS naming keystone: the tailnet name resolves to the in-cluster Service, so there are no `hostAlias` hacks.

## Dispatch fabric

A chat message → `@dispatch-controller` → a k8s Job runs **as the named agent** (codex builders) → clones fresh into a clean workspace, codes, **pushes via the M1 seam** (cw + custodian, no baked secret), opens its own PR (`gh`, seam-authenticated), and exits once the work is judged complete and the PR is verified. One builder per agent at a time; briefs and jobs are reaped automatically. Design: nexus `docs/2026-06-05-k3s-work-dispatch-design.md` (epic NEX-434).

## Identity & git

- Agents are herald-rooted identities; builders run as the **literal agent**, one broker session per name.
- `cw setup-git github` configures pod git (creds brokered from the custodian seam) and authenticates `gh`; the agent opens its PR with `gh pr create`. (cairn — agent-native git — is future.)
- **No raw secrets in pods** — cw brokers git and provider creds from custodian at use-time.

## Layout

- `hosting/` — the hosting platform (chart + service declarations + reconcile).
- `clusters/dmon/` — cluster-level config (the CoreDNS naming keystone).
- `bootstrap/` — out-of-band infra applied once (the reconcile CronJob + its RBAC).
- `docs/` — design and plan documents.
