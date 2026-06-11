# croft & workspace architecture (separate consumer, on the cloud, builder-capable)

> **Status:** architecture (operator-resolved 2026-06-12). How the operator's workspace (croft) lives within the cloud, its relationship to CWB, its access, and the layering that generalizes to Strata.

## The three layers (what lives where)

```
  HOST  (dMonextreme — a Linux box; k3s runs ON it)
   │   ← the BACKUP BUILDER: ssh to the host, run claude-code. Below the cloud,
   │     so it survives the cloud being down — the escape hatch that resurrects it.
   │     (Tonight's proof: external builder fixed dMon's kernel because it was below k3s.)
   └─ k3s  =  "the cloud"  (the infra/substrate everything runs on)
        ├─ CWB  =  "the personal cloud"   (nexus + pillars + interchange + dispatch)
        │     └─ interchange = the one front door to the personal cloud
        └─ croft  (its own namespace)     ← a SEPARATE workspace container, NOT part of CWB
```

The key distinctions the model rests on:
- **croft is *on* the cloud, not *in* the personal cloud.** It runs on the same k3s box (co-located infra) but it is its own namespace and a **consumer** of CWB — it reaches nexus/the pillars *through interchange*, as the operator identity, the way any consumer would. It is not a nexus internal component.
- **The survivor is the host, not croft.** Because you can always `ssh dmonextreme` (below k3s) and build from there, croft is *free to just be a good workspace* — it doesn't have to survive cloud-down. (Replicating croft's toolchain onto the host so the backup feels identical is a nice-to-have, not load-bearing.)

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
| **croft → nexus + agents** (the org's runtime) | *behind* the org access — a consequence of being an admitted org member | nexus (the org's broker) and the agents (aspects) are **org-scoped resources behind CWB org access**. croft reaches them *because* it holds org access, not via a direct raw line. |

**herald is the front; nexus + agents are the org runtime behind it.** What croft gets from CWB is *org access* (a herald org identity); the broker and aspects are reached as a consequence of org membership, not as separate raw endpoints. This is the Strata isolation seam: org A's workspace consumes org A's access and reaches only org A's runtime.

**The single-front-door discipline governs CWB, not croft.** "Everything behind interchange, no per-pod identities, internal = cluster DNS" applies to CWB's *own services* (the pillars, the broker) — they hide behind the boundary. croft is *not* one of those services; it lives outside that infrastructure. So croft having its own access surface is correct, not a violation. (Earlier framing had croft *inside* nexus and proposed an `interchange → nexus → croft` route — that was the wrong side of the boundary. nexus never routes *into* croft.)

- **SSH — now.** Terminal / mosh / code-remote. Working today, on croft's own ingress.
- **Web — later.** A web-based console (code-server / web terminal) so a browser is enough — also croft's own ingress, not a CWB surface.
- **The cold-start floor stays the host** (`ssh dmonextreme`, below k3s) regardless of croft's access — independent of everything above.

## Strata generalization

croft is the **first workspace-container primitive**. A Strata instance = the CWB personal cloud **+ zero-or-more workspace containers** (croft-shaped) — each a *consumer* sitting outside CWB, with its own access surface, reaching the shared personal cloud through interchange as its identity. The product shape: "your private cloud (CWB, one front door) plus your workspaces (yours to reach, theirs to consume it)." The host-below-k3s remains the universal cold-start floor.

## Status / sequence

- **Now:** croft live (separate ns, operator identity, build-capable incl. self, SSH on its own ingress, persistent + shadow memory). croft → CWB already flows as a consumer (operator auth to the broker).
- **Next (laters, ordered):** web console surface (croft's own ingress) → harden croft's own access (identity, session policy) → generalize to multi-tenant: many workspace-consumers, each reaching the one CWB through interchange (Strata).

## Open questions

- croft's *own* access hardening: what gates its SSH/web ingress long-term (the operator credential it already holds; herald-rooted later), and session TTL on long-lived terminals (mosh resumes for days).
- The croft → CWB consumer path: croft authenticates to interchange as operator — confirm that's the same boundary the external pillars are reached through, and the identity is herald-rooted as that matures.
- Multi-tenant: how nexus/CWB scopes which consumer-workspace may reach which org's resources (the Strata isolation seam).
