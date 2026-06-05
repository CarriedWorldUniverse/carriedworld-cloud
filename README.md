# carriedworld-cloud

The Carried World **local cloud** — the self-hosted k3s cluster on **dMon** that runs the platform (CWB) and the agent **dispatch fabric**. This repo *records* the cluster and is where we *build it out*.

## Topology (2026-06-06)
**Host: dMon** — Fedora Workstation 44, AMD + RTX 5090 Laptop GPU, tailnet `dmonextreme`. Single-node **k3s** (containerd; no registry — images are `podman build` → `k3s ctr import`).

| Layer | What runs |
|---|---|
| **Host (systemd)** | `nexus.service` — the broker (`:7888`, TLS): comms/dispatch hub + the **M1 custodian seam**. `aspect@*` always-on aspects (being retired → on-demand). |
| **k3s `cwb` ns** | CWB platform pillars: herald (identity), cairn (git), ledger, commonplace, interchange-gateway. |
| **k3s `nexus` ns** | The dispatch fabric: `dispatch-controller` (Deployment + scoped RBAC), on-demand **builder Jobs**, `nexus-builder-work` PVC. |
| **cert-manager** | TLS. |

## Dispatch model
A chat message → `@dispatch-controller` → a k8s Job runs **as the named agent** (anvil/plumb codex builders) → clones/codes/**pushes via the M1 seam** (cw + custodian, no baked secret) → real PR → exits. Design: nexus `docs/2026-06-05-k3s-work-dispatch-design.md`; epic NEX-434 (M1/M2/M3, functionally done).

## Identity & git
- Agents = herald-rooted identities; builders run as the **literal agent**, one session per name.
- **`cw setup-git`** configures pod git (creds via the custodian seam + agent `user.name/email`). github primary; **cairn** (agent-native) future. **`cw pr create`** (planned) lets the agent open its own PR, seam-brokered.
- **No raw secrets in pods** — cw brokers git/provider creds from custodian at use-time.

## Roadmap
- **Workstream 2 (active):** migrate the broker + always-on aspects from host systemd into **k3s pods** (broker → Deployment, `nexus.db` → PVC; retire always-on builders → on-demand).
- `cw pr create` — builder self-PR.
- Local fallback LLM on the 5090 (gemma-class, NVIDIA device plugin).

## Layout
- `clusters/dmon/` — the cluster manifests (namespace, storage, dispatch-controller, …) — migrating here from nexus `deploy/`.
- `docs/` — architecture + runbooks.
