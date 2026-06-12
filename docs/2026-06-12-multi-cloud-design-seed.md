# Multi-cloud CWB — design seed

**Date:** 2026-06-12 (late, post-atlas)
**Status:** direction agreed with operator; seed for a proper brainstorm when a
real second machine exists. Nothing here is build-now.

## The one-line model

**CWB's brain stays singular; its hands distribute.** The platform is the OS,
not the cluster it currently lives on. Remote clouds are compute, not new
brains.

## Distribution doctrine

- **Never distributes** (one instance, central, the source of truth):
  herald (identity), almanac (declarations), custodian (secrets), cairn
  (history), ledger (work), commonplace (knowledge), atlas (the map).
- **Distributes per CLOUD** (= per cluster; k8s distributes within a cluster,
  so one mason drives one cluster regardless of node count): **mason** — the
  reconciler must stand next to the cluster API it drives. Eventually porter
  (local-state backup per cloud).
- **Connective tissue**: interchange — the transversal boundary layer remote
  hands reach home through. (Per the 2026-06-12 discussion: interchange is
  conceptually transversal but physically stays in the core cluster until
  there is a second cluster to span; its liftability invariants — stateless,
  config-from-env, mesh-never-routes-through-it, one-directional trust — are
  guarded now.)

## The shape

```
                ┌─ CENTRAL CWB ───────────────────────────┐
                │ herald almanac custodian cairn ledger    │
                │ commonplace atlas                        │
                │ almanac: clouds/<name>/apps/...          │
                │ [interchange — the door]                 │
                └──────────▲──────────────▲────────────────┘
                     pull  │              │ pull (outbound only)
                ┌──────────┴────┐   ┌─────┴─────────┐
                │ cloud A       │   │ cloud B        │
                │ k3s + mason   │   │ k3s + mason    │
                └───────────────┘   └────────────────┘
```

## Principles

1. **One mason concept, N instances.** Same binary; per-cloud knobs: cloud
   name, almanac declaration prefix (`clouds/<name>/apps/`), local
   kubeconfig. The reconcile loop is unchanged — it already polls
   declarations and drives a local cluster.
2. **Pull, never push.** Remote masons dial home through interchange —
   outbound-only (NAT/firewall/tailnet friendly); no inbound access to remote
   machines, ever. Link down ⇒ the cloud keeps reconciling last-fetched
   declarations: autonomous degradation, not death.
3. **Machines are herald citizens.** Each remote mason = an agent identity in
   herald, `responsible_human` = the operator. Cloud enrollment IS the
   herald-rooted bootstrap flow (derive-by-name from an authenticated human):
   `cw cloud add <name>` mints the agent, seeds the declaration prefix, emits
   a join bundle. The first real rows in the carriedworld org's agent table
   are likely machines, not aspects.
4. **Secrets are brokered, never copied.** Remote workloads get theirs from
   central custodian through the edge at deploy/run time; nothing parked on
   remote disks.
5. **Images are location-blind already** — GHCR digest pins pull anywhere;
   the supply chain needs no change.
6. **The map grows regions, not concepts.** atlas adds one collector per
   cloud (each mason's ListApps + a thin status-home report) and the
   namespace-region SVG layout (2026-06-12 decision) gains a region per
   cloud.

## Real work when this activates (the deltas)

- mason's source dial: in-mesh almanac mTLS → edge dial with herald agent
  identity (the cw-app M1 transport seam already proved this path).
- `cw cloud add/ls/rm` enrollment verbs (+ the join bundle format).
- atlas multi-cloud collection + per-cloud map regions.
- interchange isolation step (own namespace + NetworkPolicies + own tailnet
  identity) — the rehearsal for any later physical split.

## Remote consumers (workload → core), not just mason → core

**The org is location-blind: everything that isn't the core reaches the core
through the door, with a herald identity. There is no second path.**

- A new box with a new consumer of an existing org needs exactly two things:
  a network route to the door (the box/cluster joins the tailnet — pods do
  NOT individually run tailscale; cluster DNS / hostAlias maps the edge name)
  and an enrolled identity (an agent in the org, responsible_human = the
  operator, via the join-bundle flow). Nothing else changes anywhere.
- Consumption is identical to local consumers: gateway prefix + herald bearer
  (the atlas strata route is the template).
- **Outpost** (the nexus design concept) = the per-cloud doorway home. In v1
  the tailnet membership IS the outpost. A dedicated relay component (single
  egress, connection reuse, token caching, cloud-scoped credential custody)
  is a legitimate later OPTIMIZATION, not architecture — addable without
  model change because everything already funnels through one logical door.
- **The core never dials a consumer.** Remote pods reach out: poll, or hold
  outbound websockets (the aspect↔broker pattern). Genuine core→consumer
  push, if ever needed, arrives via interchange's inbound-webhook respec —
  through the door's machinery, never a hole punched toward a remote box.

## How mason talks home: the lobby and the loading dock

Mason goes **through interchange, always** — never direct (the mTLS mesh is
intra-core trust fabric and never spans sites), never via a core-side relay
(relays/outposts are remote-side egress plumbing; mason needs none and may
itself host outpost duties for its cloud later). It dials home as its herald
AGENT identity and reads its declaration prefix.

The refinement: interchange grows two door CLASSES, not two boundaries —
- **the lobby**: humans + app consumers (bearer tokens, REST, browser
  sessions);
- **the loading dock**: platform machine traffic (masons, porters — agent
  identity, long-lived streams, machine scopes, its own rate/QoS so
  reconcilers are never starved by app traffic).
One wall, two doors, one audit log.

**Status inverts at the boundary**: central atlas dials local mason today
(in-mesh read) — forbidden toward remote clouds (core never dials a
consumer). Remote masons PUSH status home through the dock (strata-ingest
write or almanac status keys); atlas reads the aggregate. Reads become
reports at the boundary.

## Fit with existing direction

Matches the hosting direction (portable k8s-native; flat-rate k3s boxes —
Hetzner/Catalyst/Oracle-free — as remote clouds; AI stays home on dMon) and
the cluster-tailnet plan (each cloud joins the tailnet as its own
environment). Supersedes nothing; activates the "future: inter-cluster"
clauses already on record.
