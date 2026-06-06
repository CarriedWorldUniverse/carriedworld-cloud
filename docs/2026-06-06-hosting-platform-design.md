# Local Hosting Platform — v1 Design

**Status:** design, approved 2026-06-06
**Scope:** the standing, correctly-configured k3s host environment on dMon that services plug into and are *automatically* hosted right.

## Why

The broker→pod cutover (NEX-457) worked, but landing a single dispatch took ~6 manual fixes, none of which were the task: the broker's address lived in five places defaulting to a dead host (controller `-node-ip`/`-broker-host`/`-git-cred-name`, `CW_SEAM_URL`, every keyfile's URL), each hand-patched; brief configmaps leaked; the schema drifted; creds had to be blob-copied by hand. Every one was the same gap — **there is no platform that owns topology, lifecycle, identity, and reconciliation, so each responsibility leaks out as a `kubectl patch` or a host-binary CLI.** Worse, those live patches evaporate on the next reconcile.

## Frame

The local cloud is **not** about building pods — k3s already runs pods, and the dispatch-controller already manufactures them. It is about **hosting them in the right configuration**: a service dropped into the host should be automatically named, networked, storage-attached, and identity-scoped *because the host is configured right*, not because something hand-wired it.

- **Most compute is a pod with attached storage** — so compute + GPU + block storage collapse into one primitive (a pod with `{cpu, gpu, mem, volumes}`), which is exactly what k3s is. The only things that don't fold into pod+storage are **shared services** (DB, object store), which take the other shape: a brokered connection, not a mounted volume.
- **Assemble-and-broker, not build-our-own.** Reuse k3s, CoreDNS, the Tailscale operator, cert-manager, and custodian; build only the thin glue.
- The control plane **maintains the host's configuration** (desired-state); it does not manufacture pods.

## v1 Scope

One declarative hosting layer with coherent naming, delivering three payoffs at once:
1. **Existing services reconcile** — broker/keel/sqld/dispatch described in one place, no evaporating patches.
2. **New services drop in hosted right** — declare it, it's named + reachable + storage-attached + identity-injected.
3. **Naming/DNS** — the foundation the other two stand on.

**Facets wired automatically in v1:** name + networking + block storage + **identity/secrets brokering**.

**Deferred (added later by need):** GPU scheduling (NVIDIA device plugin); brokered DB/object-store connections (services still dial sqld directly); pull-based drift-reconcile (Flux); multi-cluster.

## Approach (A — lean, assemble + reuse)

Almost everything is assembled from what's already in the cluster. The only new code is the **hosting convention** and the **identity injector**.

### Components

1. **Hosting convention** — one **Helm chart** that encodes "the right configuration." A service is declared by a values file: `name`, `image`, `storage`, `tailnet-edge?`, `identity`, `creds-needed`. It renders the Deployment/StatefulSet + Service + the four pieces below. This *is* the right configuration, written once. (Helm chosen over kustomize for the per-service values model.) *(new code)*

2. **Reconcile (lean)** — each service is a values file under `carriedworld-cloud` (alongside `clusters/dmon/`) referencing the convention chart. **CI renders + applies on merge** (`helm template | kubectl apply`) — push-style GitOps-lite. "No evaporating patches" becomes a rule the mechanism enforces: all cluster changes go through the repo. A periodic re-apply CronJob is the safety net. *(graduates to Flux/pull-reconcile later, no rework.)*

3. **Naming — the keystone.** A **CoreDNS rewrite per service** maps its tailnet name to its in-cluster Service: `nexus.tail41686e.ts.net → nexus-broker.nexus.svc.cluster.local`. An in-cluster pod resolving `nexus.tail…` lands on the ClusterIP **and the cert matches** — no `hostAlias`, no hardcoded IPs. The Tailscale operator gives the *same* name on the tailnet edge. One name, resolves identically everywhere. Delivered via the `coredns-custom` ConfigMap (k3s-native), declared in the repo.

4. **Identity injector** — an **init-container running `cw`** authenticates as the service identity, fetches its keyfile + scoped creds from **custodian** at pod startup, and writes them to a shared `emptyDir` the main container reads. Replaces today's hand-minted `aspect-keyfile-*` secrets with custodian-brokered identity. *(new glue, reuses cw + the credentials store.)*

5. **Storage** — a PVC per service, declared in the chart values (k8s-native block). Object/DB connections stay manual in v1.

### Deploy flow (hosting a service)

1. Author edits `<service>` declaration in the repo (values for the convention).
2. Merge → CI renders + applies → creates the Deployment/StatefulSet, Service (ClusterIP), the CoreDNS rewrite entry, the Tailscale exposure (if `tailnet-edge`), the PVC.
3. Pod scheduled → cw init-container fetches keyfile + scoped creds from custodian → writes to the shared volume.
4. Main container reads identity → dials dependencies **by name** (`nexus.tail…:7888`) → CoreDNS rewrite → ClusterIP, cert validates.
5. Reachable in-cluster (ClusterIP) and on the tailnet (operator) under the one name.

### Retrofit (the other half of v1)

Bring the running services under the convention one at a time, each replacing its bespoke YAML + the live patches:
- The **CoreDNS rewrite replaces every `hostAlias`**; the **cw injector replaces hand-minted `aspect-keyfile-*` secrets**; the `node-ip`/`broker-host`/`CW_SEAM_URL` patches collapse into convention values.
- **Order:** `sqld` (simplest — proves the convention) → `dispatch-controller` (the one just hand-patched — biggest payoff) → `broker` → `keel`.
- **Acceptance per service:** delete it, re-apply from the repo, it returns *identical and connected with zero manual patches*.

### Failure modes

- Bad manifest → CI fails pre-cluster (nothing half-applied).
- Missing CoreDNS rewrite → fails fast at startup with a clear DNS error, not a silent mis-route.
- Identity fetch fails (custodian down/unauthorized) → init-container fails → pod never starts half-configured.
- Live cluster patch → reverts on the next apply — the desired behavior ("declare it or it doesn't stick").
- Missed apply (push-reconcile gap) → covered by apply-on-merge + the periodic re-apply CronJob; full drift-reconcile is the Flux graduation.

### Testing

- **Render tests** — `helm template` / `kustomize build` the convention for real + sample services; assert Service, CoreDNS rewrite, init-container, PVC are correct.
- **Injector unit test** — cw init fetches + writes a keyfile given an identity; unauthorized → non-zero exit.
- **Integration** — deploy a throwaway service via the convention; assert it resolves in-cluster **and** on tailnet under one name, PVC attached, identity injected, reachable (mirrors the `tlstest` pod used during the cutover).
- **Retrofit acceptance** — migrate `dispatch-controller`, delete + re-apply, assert identical & connected, zero patches.

## Scope boundary (NOT in v1)

No GPU scheduling; no brokered DB/object connections (services dial sqld directly); no Flux/pull-reconcile (CI-on-merge + periodic re-apply); single cluster (dMon).

## Open follow-ups (tracked separately)

- Dispatch resource cleanup/GC (NEX-461) — orthogonal but related lifecycle gap.
- The identity-brokering glue overlaps with the dispatch git-grant auth question (should derive from identity, not a static admin token).
