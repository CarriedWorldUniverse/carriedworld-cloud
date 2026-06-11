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

## Access (ssh now, web later, interchange as the target route)

croft has **two front doors to the workspace itself** (distinct from CWB's one front door):
- **SSH — now.** Terminal / mosh / code-remote. Working today.
- **Web — later.** A web-based console (code-server / web terminal) so a browser is enough. Deferred.

**The route those doors *should* take** is through the cloud's boundary — **interchange → nexus → croft** — so the personal cloud has exactly one external surface and croft has none of its own (the `cluster-tailnet-environment` discipline: tailscale = external edge only; internal = cluster DNS). The interim uses what already exists (host as jump / the current path); we converge on the boundary route later, since the host-SSH backup means there's no urgency forcing it.

### Target access mechanism (when interchange is the genuine sole ingress)

interchange already is a boundary gateway with an **E2E relay**. Workspace access rides it as an authenticated session stream:
1. **operator → interchange (public).** Authenticate as operator (herald-rooted long-term); interchange decides *which workspace this identity may reach*.
2. **interchange → nexus (in-cluster).** nexus applies routing/policy (identity → permitted workspace; the seam that becomes Strata multi-tenancy) and dials croft over cluster DNS.
3. **nexus → croft.** Session terminates as the operator's shell; bytes relay back out the same chain.

Transport lean: **SSH-over-relay** — keeps stock `ssh`/mosh/VS-Code-remote, reuses croft's sshd; the new piece is an identity-gated stream-relay on interchange + nexus's inward dial. (Alternatives: PTY/websocket terminal, or a brokered tunnel.) Bypass-resistance test: kill every other path (no host SSH, no per-pod identity) and the operator still has croft *because interchange relays it*. Session open/close audited to ledger.

## Strata generalization

croft is the **first workspace-container primitive**. A Strata instance = the CWB personal cloud **+ zero-or-more workspace containers** (croft-shaped) for its operator/users, all on shared infra, the cloud reached through its one door, each workspace identity-gated and nexus-routed. Build the access pattern once for croft and every tenant inherits "your private cloud has exactly one front door, and it knows who you are." The host-below-k3s remains the universal cold-start floor.

## Status / sequence

- **Now:** croft live (separate ns, operator identity, build-capable incl. self, SSH, persistent + shadow memory). Interim access path.
- **Next (laters, ordered):** web console surface → the interchange SSH-over-relay route (remove bypasses, interchange becomes the genuine sole ingress) → generalize nexus's identity→workspace policy to org-scoped multi-tenant (Strata).

## Open questions

- Does interchange's E2E-relay primitive carry a raw TCP/SSH stream, or is it message-framed (→ needs a stream mode)?
- Client side: a `cw ssh croft` / `ProxyCommand` wrapper so stock `ssh` drives the interchange route.
- Re-auth / session-TTL on long-lived terminals (mosh resumes for days) without dropping the session.
