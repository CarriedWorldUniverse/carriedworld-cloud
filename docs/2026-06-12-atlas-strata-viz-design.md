# atlas — the live map of Strata (design)

**Date:** 2026-06-12
**Status:** approved (operator, this date)
**Scope:** v1 read layer, ops-shaped. Write verbs are v2 (seams designed here, built later).

## What and why

atlas is Strata's **human-web gateway**: a live, browser-reachable map of the
running cloud. It animates the shape in `ARCHITECTURE.md` — every pillar and
app lit by real state: up/degraded/down/dormant, the version actually running,
ready counts, what connects to what, and the backup clock.

The first job is **comprehension** — the operator can already operate the
cloud through the AI and `cw`, but cannot *see* it. The map closes that gap.
It is also, deliberately, the **entrance to the control plane**: the place an
operator will configure, deploy, upgrade, and remove services and apps. v1
ships no write verbs, but every structural decision below assumes they are
coming.

Boundary statement: **mason does, atlas sees.** atlas is a pure observer —
nothing depends on it, it holds no write authority, and killing it leaves the
cloud unaffected.

## Decisions (settled with the operator)

| Question | Decision |
|---|---|
| Access | Browser over the tailnet, always-on (`atlas.tail41686e.ts.net`) |
| Liveness | Polling, ~10s collector loop + ~10s page refresh |
| Coverage | The whole ARCHITECTURE.md diagram: pillars + apps + cross-cutting + backup clock + edges |
| Auth | herald OIDC login (the existing HTTP-OIDC face); fail closed |
| API status | First-class: `StrataService` in cwb-proto, gRPC-over-mTLS, REST via the edge |
| Writes | v1 read-only with ops seams; v2 buttons forward existing platform verbs |
| Name | atlas |

## Architecture

```
browser (tailnet) ──HTTPS──> atlas.tail41686e.ts.net   [tailscale k8s operator,
                              │                          broker/sqld pattern]
                              ├─ OIDC login ↔ herald (HTTP-OIDC face)
                              ├─ map page (static, go:embed)
                              └─ /api/state (session cookie) ← collector cache
atlas collectors (every ~10s, in-cluster):
   k8s API        — deployments/pods in cwb · nexus · croft (read-only RBAC)
   mason :8086    — AppService.ListApps → sync phase        (gRPC-mTLS)
   porter (new)   — BackupStatusService.GetBackupStatus     (gRPC-mTLS)
mesh consumers:   StrataService gRPC-mTLS; REST via edge grpc-gateway
                  (cw / MCP consume the same state later, for free)
```

One collector loop folds all sources into a single in-memory `CloudState`
snapshot (mutex-guarded). Page and gRPC consumers read the same cache;
requests never trigger collection.

## The API (cwb-proto)

```proto
service StrataService {
  rpc GetCloudState(GetCloudStateRequest) returns (GetCloudStateResponse);
}
message GetCloudStateResponse {
  repeated Node nodes = 1;
  repeated Edge edges = 2;
  BackupStatus backup = 3;
  google.protobuf.Timestamp observed_at = 4;
}
message Node {
  string id = 1;                // "herald", "nexus-broker", "croft"
  NodeKind kind = 2;            // PILLAR | APP | CROSS_CUTTING | INFRA
  string namespace = 3;
  NodeStatus status = 4;        // UP | DEGRADED | DOWN | DORMANT
  string version = 5;           // image tag, e.g. "sha-947a05e"
  string image_digest = 6;
  int32 ready = 7;
  int32 desired = 8;
  google.protobuf.Timestamp since = 9;
  string detail = 10;           // mason phase for managed apps, e.g. "Synced 1/1"
}
message Edge { string from = 1; string to = 2; EdgeKind kind = 3; }
```

Deliberate choices:

- **`DORMANT` is a first-class status.** The aspect roster policy keeps
  anvil/harrow at 0/0 on purpose; the map shows desired=0 as grey ("benched"),
  never red. Derivation: desired=0 → DORMANT; 0<ready<desired → DEGRADED;
  ready=0, desired>0 → DOWN; ready=desired → UP.
- **Edges are static topology, annotated.** The known shape from
  ARCHITECTURE.md is encoded in atlas as fixed data. Edges say what *should*
  connect; node lamps say what is *alive*. Live traffic discovery is a
  different, larger project and out of scope.
- **`StrataService` is read-only by design, permanently.** Write RPCs belong
  to mason/almanac. The comprehension surface and the operation surfaces stay
  separate APIs.

## Collectors

1. **k8s** — list deployments + pods in cwb/nexus/croft via in-cluster
   ServiceAccount. RBAC: one ClusterRole (`get`/`list` on deployments, pods,
   namespaces) bound by three namespace RoleBindings — atlas physically cannot
   mutate the cluster. Yields status, ready/desired, image tag+digest, age.
   The croft statefulset is on the map: the operator can see where the AI
   lives.
2. **mason** — existing `AppService.ListApps`, gRPC-mTLS in-mesh. Yields sync
   phase per managed app → `Node.detail`. Unmanaged nodes have no detail
   string.
3. **porter (new surface)** — porter gains a small
   `BackupStatusService.GetBackupStatus` gRPC: last sync time, source count,
   per-source ok/fail, next-due (derived from the 6h ticker). Porter already
   holds all of this in memory at the end of each pass; the change exposes
   state, it does not compute anything new. Message types land in cwb-proto.
   *(Alternative rejected: porter writing a ConfigMap that atlas reads via
   k8s — fewer moving parts but turns k8s annotations into an API and breaks
   the everything-is-proto rule.)*

**Partial failure is a display state, not an error.** mason unreachable → map
renders from k8s data, mason-derived details marked stale. k8s itself failing
→ atlas serves the last snapshot with visible staleness. A status view that
goes blank during an incident is useless precisely when it matters.

## Web layer

**Auth** — OIDC authorization-code flow (+PKCE) against herald. Herald's
HTTP-OIDC face is token-endpoint-only today (jwt-bearer/password/refresh
grants); the authorization-code flow is **new herald work that lands first**
— it is the hardening path herald's own design names, and the foundation for
every future human web surface (operator decision 2026-06-12). atlas is then
a registered OIDC client; the callback sets an HttpOnly+Secure session
cookie; no session → redirect to herald login. The herald token is retained
server-side in the session — this is the identity seam v2 writes ride on.
Failures fail closed: herald down → login page with the error, no anonymous
fallback.

**Serving** — page assets `go:embed`ed in the atlas binary (platform
pattern: one image, no runtime asset dependencies). Vanilla HTML/CSS/JS, one
fetch loop, no framework — the map is ~15 nodes and a poll.

**Rendering** — hand-built SVG mirroring the ARCHITECTURE.md layout: edge on
top, pillars row, apps row, mason/porter cross-cutting, Drive offsite. Fixed
layout is the point — the map always looks the same; only the lights change.
Layout is data in one place; a new node is one entry. (Mermaid re-rendering
rejected: unstable node positions, not clickable-by-design. Graph-layout
libraries rejected: force-directed placement destroys the fixed mental
model.)

Each node renders name, status lamp (green/amber/red/grey), version chip,
ready/desired. **Click → detail panel**: full digest, age, namespace, mason
phase — and the reserved actions region where v2 verbs will live. The porter
corner shows the backup clock: "last sync 16:03 · 9 sources ✓ · next ~22:00".

Poll loop: `fetch /api/state` every 10s → diff → CSS class transitions (lamps
fade, not blink). Hidden tab pauses polling (visibility API).

## Ops seams (designed now, built in v2)

1. **Identity pass-through** — the session already retains the operator's
   herald token. v2 adds token exchange so atlas calls mason *as the
   operator*; audit reads "croft asked, mason did". atlas's own SA stays
   read-only forever.
2. **Action slots** — the detail panel reserves an actions region per node
   kind (APP → sync/upgrade/delete; PILLAR → upgrade; INFRA → none). v1
   renders it empty.
3. **Verb pass-through, not verb invention** — v2 buttons map 1:1 to existing
   or already-planned platform verbs (`mason sync`, `cw app upgrade --to`,
   `rm`). A button that needs a missing API waits for that API to land in its
   pillar first. The UI structurally cannot do anything cw/the AI cannot.
4. **Proto room** — write RPCs will never be added to `StrataService`.

## Error handling

- **Staleness always visible**: `observed_at` renders as "as of Ns ago";
  >30s turns the banner amber. Old state is never silently shown as current.
- **Per-source degradation**: one failing collector greys out only its
  derived fields (see Collectors).
- **atlas is on its own map** — it appears as a node like any pillar, so
  atlas-degraded is visible in-band. Errors log structured (slog).
- **The page degrades loudly**: fetch failure → "lost contact with atlas Ns
  ago" banner over the last-known state; malformed payloads never
  white-screen.

## Testing

- **Status derivation** — pure function `(deploy, pods, masonPhase) →
  NodeStatus`; table-driven over every transition, DORMANT-vs-DOWN
  especially.
- **Collectors** — fake k8s clientset + in-proc gRPC fakes for mason/porter;
  partial-failure cases assert stale-marking, not errors.
- **OIDC handlers** — stub herald: no-session redirect, state-param
  rejection, cookie flags.
- **Porter change** — `GetBackupStatus` covered in porter's own suite.
- **Conformance** — atlas joins cwb-conformance with a layer asserting
  `GetCloudState` returns sane live state on dMon.
- **Page** — golden-file test on rendered-SVG-for-state; no browser test
  framework in v1.

## Deployment

- New repo `atlas` (pillar pattern); proto PR to cwb-proto; GHCR image via
  the BLOCK-style release workflow; **digest-pinned manifest committed to
  carriedworld-cloud before apply** (the 15-min reconciler reverts anything
  uncommitted).
- RBAC manifests alongside (SA + ClusterRole + 3 RoleBindings).
- Tailnet exposure via the tailscale k8s operator → `atlas.tail41686e.ts.net`.
- One-time herald OIDC client registration (herald admin).
- The porter PR ships independently, first or last — atlas degrades
  gracefully without it, so there is no deploy-ordering constraint.

## Out of scope (v1)

- Write verbs of any kind (v2; seams above).
- Live traffic/connection discovery (edges are static topology).
- Historical state, metrics, or time-series (the map is *now*).
- Mobile-specific layout (the SVG scales; dedicated layout can come later).
