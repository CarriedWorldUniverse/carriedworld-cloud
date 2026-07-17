# CWB Console — pillar state + configure cwb (full spec)

**Status:** DRAFT for operator review · **Ticket:** NEX-766 · **Date:** 2026-07-17
**Companion docs:** [2026-06-12-atlas-strata-viz-design.md](2026-06-12-atlas-strata-viz-design.md) (the map + the ops seams this spec builds on) · almanac design doc (almanac repo `docs/`).

## 1. Problem

The operator's ask, verbatim: *"not really something to manage k3s, but something that shows the state of core pillars, and configure cwb"* — after finding generic k8s clients (Freelens) overwhelming. Generic tools render the whole resource model; clarity requires **curation**: a surface that knows what THIS cloud is and shows only that.

The July 2026 silent-failure week is the motivating incident class: mirror cronjobs erroring for days, porter-backup failing inside a 10/10-Ready pod, evictions piling up — none visible anywhere a human looks. The alerting layer (kwatch + Alertmanager → Discord, 2026-07-17) now pushes failures; the console is the **pull** side: one page that answers "is my cloud healthy, and what is it configured to do?"

## 2. Goals / non-goals

**Goals**
- G1 — One screen showing the live state of the core pillars and platform services, at *container* granularity where it matters (cwb-core is ten pillars in one pod; deployment-level Ready hides pillar failure).
- G2 — Surface the silent-failure classes: backup staleness, mirror-cronjob staleness, recent alerts.
- G3 — Read AND edit almanac config (`cwb/*` params) from the browser, with the same identity/audit discipline `cw config` has.
- G4 — Preserve atlas's documented invariants: `StrataService` stays read-only permanently; atlas's k8s ServiceAccount stays read-only forever.

**Non-goals (v1, explicit)**
- No k8s object browser, no pod exec, no YAML-of-everything. k3s management stays in Freelens/k9s.
- No metrics/charting (no Prometheus dependency).
- No secrets values — `SecretService` is not reachable from the console at all (list-metadata view is a possible later slice; values never).
- No ops verbs (restart/sync/upgrade) in v1 — the action-slot seam from the atlas design doc stays reserved; verbs land in a later slice via mason's existing `TriggerSync`-class RPCs, 1:1, never invented.
- No multi-tenant. One org (`cwb`), one operator.

## 3. Where it lives — and the read-only boundary, precisely

The console is a second page in **atlas**: `GET /console`, behind the existing herald-OIDC gate (`auth.Require`), served from the same `go:embed` static assets, polling a new JSON endpoint the same way the map polls `/api/state`.

The atlas design doc commits to: *"mason does, atlas sees"*, *"`StrataService` is read-only by design, permanently"*, and *"atlas's SA stays read-only"*. This spec keeps all three **literally**:

- `StrataService` (gRPC) is untouched. The console's data rides internal web endpoints (`/api/console/*`), not the mesh service.
- The k8s ServiceAccount gains only additional **read** verbs (pods, cronjobs, jobs — §5.3).
- Config writes are **not atlas acting on the cluster**. They are the *operator* acting on **almanac** (the config pillar, whose whole job is being written to), with atlas as the browser-shaped client — the identity model in §7. Cluster-state remains something atlas can only observe.

This is the boundary revision to sign off: atlas stays a pure observer of the *cluster*, and becomes a *conduit* for operator config intent to almanac. (P1: the secret the console hides is "how cloud state is gathered and how config intent reaches almanac" — pages/tiles can change freely without touching pillar code.)

## 4. Page anatomy (one screen)

```
┌─ CWB Console ────────────────────────────────────────────────┐
│ PILLARS (cwb-core)        PLATFORM                NODES      │
│ ┌───────┐┌───────┐ …     ┌─────────┐┌────────┐   dmon ✓ 25%  │
│ │almanac││cairn  │       │cairn-rd ││nexus-  │   robo ✓ 61%  │
│ │  UP   ││  UP   │       │  UP     ││control │              │
│ └───────┘└───────┘       └─────────┘└────────┘              │
│ BACKUPS  last pass 04:49Z ✓ · 10 sources · next 10:49Z       │
│ MIRRORS  github-mirror ✓ 2h ago · replica-mirror ✓ 41m ago   │
│ ALERTS   [00:58] default/alert-smoke-crashloop Error …       │
├──────────────────────────────────────────────────────────────┤
│ CONFIG (almanac cwb/*)                          [filter___]  │
│ cwb/porter/backup/sources                v9  porter  07-16   │
│ cwb/nexus/provider-bindings/keel         v3  shadow  07-06   │
│   → click: view YAML · edit → diff preview → apply (v+1)     │
└──────────────────────────────────────────────────────────────┘
```

Tile = name, status chip (UP / DEGRADED / DOWN / STALE), restarts-24h, image tag. Click = detail drawer (recent container state, last termination reason, image digest). Nothing else. Status colors follow the existing map's `NodeStatus` scale.

## 5. Read half — data model and collector extensions

### 5.1 What exists (reuse as-is)
- `collect.Loop` cache + 10s poll + partial-failure semantics (k8s error → keep last snapshot; mason error → mark stale; porter error → nil summary). The console endpoint reads the same loop products; no second poller.
- Porter strip: `BackupStatusService.GetBackupStatus` already returns `last_success/last_attempt/last_error/next_due` + per-source name/size of the last successful pass. **v1 renders pass-level staleness** (red when `now > next_due + interval`, i.e. ≥2 intervals stale). Per-source last-sweep timestamps would need porter-side persistence — deliberately deferred (porter's in-memory `Holder` restarting to "no pass yet" is acceptable and visible as UNKNOWN, not lying-green).
- Mason phases (`ListApps`) continue to decorate APP tiles exactly as they decorate map nodes.

### 5.2 New collector capability A — per-container pillar facts
The ten pillars live in ONE deployment (`cwb/cwb-core`); listing deployments cannot see a pillar failing (July proof: porter-backup down for days inside a Ready 10/10 pod). Extend the k8s collector to read the cwb-core **pod** (label-selected, current replica) and extract per-container: `ready`, `restartCount`, `lastState.terminated{reason, finishedAt}`, image tag. New struct `ContainerFacts`; keyed `cwb/cwb-core/<container>`.

Tile status derivation (pure function, unit-tested):
- `DOWN` — container not ready and last termination < 10m ago, or restartCount rising across the last N polls.
- `DEGRADED` — ready but restartCount > 0 in 24h.
- `STALE` — collector failed this poll (inherits the loop's existing stale semantics).
- else `UP`.

### 5.3 New collector capability B — cronjob staleness
Read CronJobs + their most recent Jobs in namespaces `cwb`, `nexus`, `croft` (the mirror pair, drain-seeder, transcript-ingest). Per cronjob: `lastSuccessfulTime`, `lastScheduleTime`, schedule string, and DERIVED `overdueBy` (now − expected-next-success). Tile red when overdue ≥ 2 schedule periods — this is exactly the tile that would have caught the 14-hour-silent mirror failures.

RBAC delta (read-only, additive): `pods` (get/list), `cronjobs`, `jobs` (get/list) in the three namespaces. The SA gains no write verb of any kind (G4).

### 5.4 Alert feed
v1: atlas polls **Alertmanager's HTTP API** (`GET alertmanager.logging.svc:9093/api/v2/alerts`) for active alerts — zero new infrastructure, in-cluster HTTP, shows "what is firing right now". Alert *history* stays in Discord (already pushed). A kwatch-event mirror or Loki query is explicitly out of scope until the active-alerts tile proves insufficient.

### 5.5 Console state endpoint
`GET /api/console/state` (auth-gated) returns one JSON document: `{pillars[], platform[], nodes[], backup, cronjobs[], alerts[], observedAt}` — protojson style, camelCase, `Cache-Control: no-store`, client polls at the map's cadence. The page is dependency-free static JS like `map.js` (P5: the accident is already solved there; copy the pattern, no framework).

## 6. Config half — almanac params in the browser

Read path (slice 2): `ListConfig(prefix="cwb/")` → table of `path · version · writer · updated_at` (requires adding `writer` to `ConfigItem` proto — the column already exists in `config_items`; one-field proto addition, backward-compatible). Click → `GetConfig` → read-only YAML/value view.

Write path (slice 3):
1. Edit in a plain textarea; client renders a **unified diff preview** (old vs new) before enabling Apply.
2. Apply calls `SetConfig`. **Almanac gains optional `expected_version` on `SetConfigRequest`**: when set and ≠ current, reject with `FAILED_PRECONDITION` (compare-and-set). This closes the lost-update race between two writers (console + `cw config`, or two tabs) — P4: the invariant at this seam is *"a write lands on the version the writer reviewed"*, and it must be enforced server-side, not by the UI.
3. On success the row shows the new version; `config_history` + `audit_log` record writer/when exactly as they do for `cw config` (no new audit machinery — the pillar already does this).

History view (slice 3b, small): almanac gains `ListConfigHistory(path, limit)` reading the existing `config_history` table — the table has no RPC today. Console renders version-over-version diffs.

Guardrails: params only (`ConfigService`); `SecretService` is never dialed by atlas — the client simply isn't constructed (P2: wrong path unrepresentable, not just forbidden). Value size cap mirrors almanac's own. Rendered values/paths are control-character-escaped (the cairn #130 lesson: anything echoed into a terminal or DOM gets sanitized at the print seam).

## 7. Identity & authz for writes — the one real design decision

Almanac authenticates via mTLS-gated metadata (`cwb-subject` / `cwb-org` / `cwb-scopes`), trusting in-mesh peers to assert them. Two candidate paths for console writes:

**(a) Token pass-through (doc-purist).** Atlas forwards the operator's retained herald access token; an interchange/edge hop validates it and injects the metadata. Truest to the atlas design doc's "identity pass-through" seam — but there is no gRPC edge in front of almanac today; this path requires new interchange machinery before slice 3 can land.

**(b) Session-derived assertion (platform precedent) — RECOMMENDED.** Atlas dials almanac in-mesh (its existing client mTLS identity) and asserts `cwb-subject=<operator sub from the live herald web session>`, `cwb-org=cwb`, `cwb-scopes=config:read config:write`. This is **exactly how `cw config` works today** (in-mesh client self-asserts metadata over mTLS); atlas is at least as trustworthy an asserter as a CLI on croft. Constraints that keep it honest:
  - Metadata is derived ONLY from a live, herald-authenticated web session — no session, no client call, no ambient service identity fallback.
  - Atlas's asserted scopes are hard-capped at `config:read config:write` in code (never `secret:*`, never `admin:write`, never `almanac:purge`) — the cap is a constant, not config.
  - `audit_log.actor` therefore records the *operator's* herald subject, not "atlas".

Path (a) remains the stated end-state when interchange gains a gRPC edge; (b) does not foreclose it (the almanac call site is one function).

**CSRF:** writes are `POST` with a custom header token bound to the session (SameSite=Lax cookies already; the header requirement defeats cross-site form posts). **No CORS relaxation.**

## 8. Failure honesty (the anti-lying rules)

Every strip renders its own collector's health: a tile derived from a failed poll says STALE/UNKNOWN, never green (the loop's partial-failure semantics already model this — the console must not flatten them). The July lesson generalized: **absence of data must be visually distinct from healthy data.** Acceptance criteria below enforce it.

## 9. Slices, with observable acceptance criteria

Criteria follow `docs/network/OBSERVABLE-CRITERIA.md` — checkable from artifact + evidence, not narrative.

**Slice 1 — `/console` read page: pillar tiles + platform tiles + node capsule + backup/mirror strips.**
- AC1: with the cluster healthy, `/console` renders ≥10 pillar tiles all UP; `kubectl -n cwb exec` killing porter-backup's process flips ONLY that tile from UP within 2 poll intervals (screenshot pair + the JSON from `/api/console/state` showing the container's restartCount increment).
- AC2: suspending `cairn-replica-mirror` for 2+ schedule periods turns its mirror chip red/overdue (JSON shows `overdueBy > 0`); resuming turns it green after next success.
- AC3: stopping the porter status server renders the backup strip UNKNOWN (not green, not absent) — JSON `backup: null` + UI state screenshot.
- AC4: unauthenticated `GET /console` → 302 to `/login`; unauthenticated `GET /api/console/state` → 401 (curl transcript).
- AC5: atlas's ServiceAccount diff shows only added read verbs (pods/cronjobs/jobs get/list) — `kubectl auth can-i` transcript proving create/patch/delete all remain "no".

**Slice 2 — config read.**
- AC6: `/console` lists every `cwb/*` param with version+writer+updated_at matching `cw config list` output run the same minute (side-by-side transcript).
- AC7: no request to `SecretService` appears in almanac logs during a full console session exercising every read view (log excerpt).

**Slice 3 — config write.**
- AC8: editing `cwb/console/smoke-param` through the UI bumps its version by exactly 1, and `config_history` + `audit_log` rows show `actor = <operator herald sub>` (not `atlas`) — sqlite excerpt.
- AC9: two concurrent editors: second Apply on a stale version returns the FAILED_PRECONDITION path rendered as a conflict banner, and the param's stored value is the FIRST writer's (sqlite + screenshot).
- AC10: replaying a captured Apply POST without the session cookie AND without the CSRF header fails 401/403 (curl transcript).

**Slice 3b — history RPC + version diffs.** AC11: history view for a param with ≥3 writes shows all versions with writers; diff between v(n-1)→v(n) matches `sqlite3` extraction of those rows.

**Slice 4 (later, separate sign-off) — ops verbs via mason action slots; cedar-harbor doc-reader panel as sibling page.**

## 10. Open decisions for the operator

1. **§7 identity path**: (b) session-derived assertion now (recommended), or wait for (a) token pass-through via interchange before any write ships?
2. **Alert feed source**: Alertmanager active-alerts only in v1 (recommended) — acceptable that history lives in Discord?
3. **Backup granularity**: pass-level staleness v1 (recommended) vs. adding per-source last-sweep persistence to porter first?
4. **Placement confirmation**: console as an atlas page (recommended, this spec) vs. a separate tiny service (costs a 5th always-on thing; only worth it if the atlas boundary revision in §3 is unacceptable).

## 11. Lean-design self-review

- **P1 ✓** — the console hides "how state is gathered / how config intent reaches almanac"; pillar code and `cw` remain untouched by page changes. The seam that's *likely to change* (tile set, layout) is isolated in static assets.
- **P2 ✓** — SecretService client never constructed; scope cap is a code constant; `StrataService` untouched — wrong shortcuts unrepresentable, not just discouraged.
- **P3 ✓** — tile status is a pure nameable state machine (UP/DEGRADED/DOWN/STALE/UNKNOWN) derived in one function; collector lifecycle reuses the loop's existing states.
- **P4 ✓** — the seam invariant "a write lands on the version the writer reviewed" is enforced server-side (`expected_version`); AC9 asserts it.
- **P5 ✓** — accident (polling page, JSON endpoint, OIDC gate) copied from the map, built once; no framework; essence (which twelve things matter and when to call them unhealthy) is where the effort goes.
- **Over-application check**: no speculative multi-tenant hooks, no plugin system, no config-schema DSL (forms for known params were CUT from v1); the only new proto surface is three small, immediately-consumed additions (`writer` field, `expected_version`, `ListConfigHistory`).
