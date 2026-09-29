# croft & workspace architecture (separate consumer, on the cloud, builder-capable)

> **Status:** architecture (operator-resolved 2026-06-12). How the operator's workspace (croft) lives within the cloud, its relationship to CWB, its access, and the layering that generalizes to Strata.

## The layering (what lives where)

```
  HOST  (dMonextreme — a Linux box; k3s runs ON it)
   │   ← the BACKUP BUILDER: ssh to the host, run claude-code. Below the cloud,
   │     so it survives the cloud being down — the escape hatch that resurrects it.
   │     (Tonight's proof: external builder fixed dMon's kernel because it was below k3s.)
   └─ k3s  =  "the cloud"  (the infra/substrate everything runs on)
        ├─ CWB  =  "the personal cloud"  — the platform substrate / primitives:
        │     herald (identity/org) · ledger (work) · commonplace (knowledge) ·
        │     cairn (git) · custodian (secrets) · almanac (config) · interchange (the boundary/exchange)
        │
        └─ CONSUMERS of CWB (peers — each org-scoped, each reaching CWB through interchange):
              ├─ nexus   ← the agent runtime (broker + aspects + dispatch) — an APP on the cloud
              └─ croft   ← the operator workspace — another app on the cloud
```

The key distinctions the model rests on:
- **CWB *is* the personal cloud.** The pillars + interchange are the substrate — the cloud primitives (IAM = herald, data = ledger/commonplace, secrets = custodian, params = almanac, git = cairn, gateway/exchange = interchange). Everything else *runs on* it.
- **nexus is a consumer, not infrastructure.** The agent runtime is an **application on the cloud** — it consumes herald (org identity), ledger, almanac, custodian through interchange, exactly as croft does. It is *not* part of CWB.
- **croft and nexus are peers.** Both are org-scoped consumers of CWB, each reaching it through interchange. croft is its own namespace; nexus is its own (the "nexus cluster", separate).
- **The survivor is the host, not croft.** You can always `ssh dmonextreme` (below k3s) and build from there, so croft is *free to just be a good workspace* — it needn't survive cloud-down. (Replicating croft's toolchain onto the host so the backup feels identical is a nice-to-have, not load-bearing.)

## What croft is

A self-contained operator workspace container:
- **Identity:** runs as **operator** on the nexus network (the `NEXUS_TOKEN` → `sub:"operator"` credential) — so shadow/comms/TUI inside it act as the operator *without colliding with anyone already registered* (agora, aspects). A clean operator seat.
- **Builder-capable:** a ServiceAccount with cluster rights sufficient to **redeploy/rebuild pods, including itself** (verified: delete-pods any-ns, update-own-deploy, self-delete, deploy-into-nexus — all yes). croft operates and rebuilds the cloud from a workspace on it; the host remains the cold-start floor beneath that.
- **Persistent:** a PVC carries `$HOME` — repos, dotfiles, and shadow's copied memory + session history (continuity, so the orchestrator runs from here).
- **Separate:** its own namespace, distinct from `nexus`/`cwb`. A consumer, isolated.

## Access — two directions, not one (this is the load-bearing distinction)

croft sits **outside** CWB's infrastructure, so its access and CWB's access are separate concerns. Do not conflate them:

| Direction | Path | Rationale |
|---|---|---|
| **operator → croft** (reach the workspace) | croft's **own** ingress — SSH now, web later | croft is a separate consumer, not a CWB service. It is entitled to its own front door, the way any external client has its own connectivity. nexus/interchange are **not** in this path. |
| **croft → CWB** (consume *org access*) | **through interchange**, authenticating as a **herald org identity** | croft consumes CWB for **org access** — a herald-rooted org identity (the custodian-key-model org-derived identity, not the static NEXUS_TOKEN long-term). |
| **croft → nexus + agents** (the org's runtime) | the operator connection arrives at nexus **via interchange** (the consumer/boundary side), *not* the aspect side | nexus (the org's broker) + the agents are **org-scoped resources behind CWB org access**. croft reaches them *because* it holds org access — and its broker connection comes through the boundary, distinct from how aspects attach. |

**herald is the front; nexus + agents are the org runtime behind it.** What croft gets from CWB is *org access* (a herald org identity); the broker and aspects are reached as a consequence of org membership, not as separate raw endpoints. This is the Strata isolation seam: org A's workspace consumes org A's access and reaches only org A's runtime.

### croft → nexus is peer-to-peer through the exchange

nexus and croft are both consumers of CWB. interchange is the **org's exchange**: it admits consumers (org identity) and relays *between* them. So:
- **nexus's internal mesh** (broker ↔ aspects, cluster DNS) is *nexus's own internals* — an implementation detail of the agent-runtime app, not a CWB or croft concern. Other consumers never touch the aspect mesh.
- **croft reaches nexus through interchange** — `croft → interchange → nexus` is one org-consumer being relayed to another (the consumer nexus exposes for the agent service), org-identity-gated at the boundary. Mirrors herald's dual-faced shape (humans via one face, internal via another).

Interim vs target: today croft connects to the broker's `/connect` WS directly with the `NEXUS_TOKEN` — the convenient interim (it reaches nexus's own endpoint, bypassing the exchange). The **target is reaching nexus via interchange** as a peer org-consumer (org-identity-gated), which is the laters work, not a v1 blocker.

**The single-front-door discipline governs CWB, not croft.** "Everything behind interchange, no per-pod identities, internal = cluster DNS" applies to CWB's *own services* (the pillars, the broker) — they hide behind the boundary. croft is *not* one of those services; it lives outside that infrastructure. So croft having its own access surface is correct, not a violation. (Earlier framing had croft *inside* nexus and proposed an `interchange → nexus → croft` route — that was the wrong side of the boundary. nexus never routes *into* croft.)

- **SSH — now.** Terminal / mosh / code-remote. Working today, on croft's own ingress.
- **Web — later.** A web-based console (code-server / web terminal) so a browser is enough — also croft's own ingress, not a CWB surface.
- **The cold-start floor stays the host** (`ssh dmonextreme`, below k3s) regardless of croft's access — independent of everything above.

## Strata generalization

A **Strata instance = CWB (the personal cloud) + its consumer apps.** CWB is the substrate (identity, data, secrets, config, git, the exchange); the apps that run on it are peers — **nexus** (the agent runtime), **croft** (the operator workspace), and whatever else you build — each org-scoped, each reaching CWB through interchange. The product shape: *"your private cloud (CWB) is the primitives; the agent runtime and your workspaces are apps you run on it."* This is a far sharper story than "nexus is the platform": nexus is just the first, most important consumer; croft is the second. The host-below-k3s remains the universal cold-start floor.

## Status / sequence

- **Now:** croft live (separate ns, operator identity, build-capable incl. self, SSH on its own ingress, persistent + shadow memory). croft → CWB already flows as a consumer (operator auth to the broker).
- **Next (laters, ordered):** web console surface (croft's own ingress) → harden croft's own access (identity, session policy) → generalize to multi-tenant: many workspace-consumers, each reaching the one CWB through interchange (Strata).

## Open questions

- croft's *own* access hardening: what gates its SSH/web ingress long-term (the operator credential it already holds; herald-rooted later), and session TTL on long-lived terminals (mosh resumes for days).
- The croft → CWB consumer path: croft authenticates to interchange as operator — confirm that's the same boundary the external pillars are reached through, and the identity is herald-rooted as that matures.
- Multi-tenant: how nexus/CWB scopes which consumer-workspace may reach which org's resources (the Strata isolation seam).
