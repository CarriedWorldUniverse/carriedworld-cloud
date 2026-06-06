# nexus broker → pod + embedded-AI removal — Implementation Plan

> **For agentic workers:** execute phase-by-phase. This is an **infra + code migration**, so tasks are bigger than the usual 2–5-min unit and lean on commands + verification rather than TDD code. **Gates** between phases are hard — do not proceed past a gate until its verify passes. Each phase is independently revertible (keep the host broker running until Phase 5).

**Goal:** move the nexus broker from host systemd into a k3s pod, put its data on the brokered `sqld` layer, and decouple the in-process Frame into **keel** — a standalone always-on agentfunnel pod on gemma. End state: a pure broker pod + a keel pod + `sqld`, no host `nexus.service`, no in-process funnel, no per-user host accounts.

**Architecture:** broker (routing/dispatch/admin-API, in a pod) ⇄ `sqld` (brokered SQLite-compatible data) ⇄ keel (standing gemma funnel pod) + on-demand dispatch agents. Agents/shadow read data via brokered `sqld` connections; admin ops via the admin API.

**Tech stack:** k3s on dMon, `sqld` (libSQL), the nexus Go binary, agentfunnel, the gemma Ollama endpoint (`gemma-ollama.nexus.svc:11434`), cw/custodian for connection brokering.

**Design ref:** `docs/2026-06-06-embedded-ai-removal-design.md`. Related: NEX-454 (data layer), `project_dispatch_native_architecture`.

---

## Phase 0 — `sqld` data layer + migrate `nexus.db`

**Gate to pass:** `sqld` serving `nexus.db`'s data; a throwaway client reads a known row.

- [ ] **0.1 Stand up `sqld`** in the `cwb` namespace — a Deployment + Service + a PVC for its data. Image: `ghcr.io/tursodatabase/libsql-server` (pin a tag). `sqld` exposes the libSQL/HTTP protocol on `:8080`. **VERIFY** the pod is Running and `/health` responds.
- [ ] **0.2 Load `nexus.db` into `sqld`.** libSQL is SQLite-compatible, so the simplest path is to **seed `sqld`'s data dir with a copy of `nexus.db`** (stop-the-world copy: `systemctl stop nexus` on the host briefly, copy `/var/lib/nexus/nexus.db` into the `sqld` PVC, start `sqld`). **VERIFY** `sqld` returns the aspect rows (`SELECT name FROM aspects`).
- [ ] **0.3 (Thin brokering, optional this phase)** wire a custodian-issued, scoped `sqld` DSN per consumer (the `cw` credential pattern, kind=db). If deferring, use a direct in-cluster DSN env for now and add custodian brokering in a follow-up. **Decision point:** broker-now vs direct-DSN-now (see Risks).

---

## Phase 1 — broker container + pod (still with the Frame in-process)

**Gate to pass:** the broker pod is up, reads/writes `sqld`, and **all aspects reconnect**; a real task + conformance run pass against the pod broker. The host broker is now redundant (but keep it stopped, not deleted).

- [ ] **1.1 Broker image.** Dockerfile: the prebuilt `nexus` binary + CA/TLS material; entrypoint `nexus` with flags pointing at the mounted config. Build → `podman build` → `k3s ctr import` (the established dMon image flow).
- [ ] **1.2 Repoint the broker at `sqld`.** Change the broker's DB open path from the local SQLite file to the `sqld` DSN (env `NEXUS_DB_DSN` or equivalent). **This is the one code touch in this phase** — find where `nexus.db` is opened (`nexus/storage`/the broker main) and switch the driver/DSN to libSQL. Migrations run against `sqld` on boot. **VERIFY** locally: broker boots against `sqld`, migrations idempotent.
- [ ] **1.3 Broker Deployment + exposure.** Deployment (the keyfile + TLS as Secrets, the aspect-dir `/var/lib/nexus/aspects` as a PVC or migrated, the `sqld` DSN env). Service: the aspects connect to `wss://…:7888`, so expose the broker on the node/tailnet (LoadBalancer or NodePort) **and** in-cluster DNS. **Critically:** the existing aspect keyfiles embed the broker URL (`dmonextreme…:7888`) — keep that reachable (the node IP/tailnet) so keyfiles validate without re-minting.
- [ ] **1.4 Cutover.** Stop the host `nexus.service`; apply the broker pod. **VERIFY:** `kubectl get pods` broker Running; every expected aspect re-registers; run one real dispatch (e.g. `!dispatch`-style JSON brief to a builder) end-to-end; run the conformance suite (NEX-403) green against the pod broker.

---

## Phase 2 — admin/DB inventory + admin-API coverage

**Gate to pass:** every in-process DB/admin call the Frame makes has a network equivalent (admin API endpoint or brokered `sqld` read), with no in-process-only dependency left.

- [ ] **2.1 Inventory.** Grep the funnel/Frame for direct DB access + admin-privileged calls it makes *because* it runs in-process (shared `*sql.DB`, the observability hub, admin helpers). Produce a table: call → purpose → network replacement (admin endpoint / `sqld` read / observability frame). *(This is the load-bearing detail the design flagged.)*
- [ ] **2.2 Fill gaps.** For any call lacking a network path, add the admin-API endpoint (mirror existing admin handlers) or confirm the `sqld` read covers it. **VERIFY** each replacement with a direct call (curl the new endpoint / query `sqld`).

---

## Phase 3 — keel as a standing gemma pod (Frame still in-process in the broker)

**Gate to pass:** keel runs as its own pod, registers, is addressable, and processes a message on gemma — *while* the broker still also runs the Frame in-process (both can't hold keel's identity; see 3.3).

- [ ] **3.1 keel cloud setup** — the same recipe harrow used: keel keyfile → `aspect-keyfile-keel` Secret (current keyfile from `/home/keel/keyfile.json` on dMon, not the stale Drive copy); provider-binding `openai`/`gemma`; the `gemma` provider credential already exists (allow keel).
- [ ] **3.2 keel Deployment** — an always-on standing pod (not a Job): the agentfunnel in long-running mode, `runtimeClassName` not needed (keel calls the gemma *service*), the keyfile Secret, `CW_SEAM_URL`, the `sqld` DSN + admin-API base for data/admin access (Phase 2 outputs).
- [ ] **3.3 Identity handoff.** keel's single session is currently held by the in-process Frame. To stand keel up as a pod **without** removing `frame.Embed()` yet, run keel's pod against a **distinct test identity** for this phase's verify, OR sequence 3.x immediately before Phase 4 so the in-process Frame stops as the pod starts. **Decision point** — recommend: fold 3.2 into Phase 4's cutover (stand keel up *as* `frame.Embed()` is removed) to avoid a two-keel conflict.

---

## Phase 4 — remove `frame.Embed()` → pure broker

**Gate to pass:** broker boots with **no** in-process funnel; keel-the-pod is the Frame; a message to keel routes to the pod and is answered on gemma; shadow reads broker data remotely via `sqld`.

- [ ] **4.1 Drop the embed.** In `nexus/cmd/nexus/main.go` `buildChatRouter()`, remove the `frame.Embed()` construction + wiring. The broker no longer builds/owns a funnel. Anything that called the in-process Frame → route via comms / admin API (from Phase 2).
- [ ] **4.2 Cutover (combined with 3.2).** Build/deploy the new broker image (no embed) **and** apply the keel pod in one step, so keel's session moves cleanly from broker-in-process → keel-pod. **VERIFY:** broker logs show no Frame; `kubectl get pods` keel Running + registered; send keel a message → answered on gemma; conformance green.
- [ ] **4.3 Frontier escalation.** Confirm keel can **dispatch** a frontier-model agent for a hard task (the cheap-baseline/premium-on-demand path) — a smoke dispatch from keel.

---

## Phase 5 — decommission host + verify end state

**Gate to pass:** nothing on dMon's host runs nexus or per-user aspect accounts; the whole platform is pods.

- [ ] **5.1 Disable host auto_spawn** for all aspects (the broker re-creates host agentfunnels otherwise) — set `auto_spawn:false` (admin path) so the turned-off host accounts stay off.
- [ ] **5.2 Remove host artifacts** — host `nexus.service` unit, per-user aspect accounts (after their cloud dispatch/standing equivalents exist). Keep keyfiles archived (Drive) but note they must carry the **current** broker URL + non-revoked version.
- [ ] **5.3 End-state verify** — broker pod + keel pod + `sqld` + on-demand dispatch; no host process; shadow-via-agora manages nexus through brokered `sqld`; a real maintenance task dispatched + completed.

---

## Risks / decisions
- **Broker exposure + keyfile URLs (Phase 1.3):** aspect keyfiles embed `dmonextreme:7888`. Keep that endpoint reachable (node/tailnet) so we don't re-mint every keyfile. If we *do* re-host the URL, plan a keyfile re-issue pass.
- **DB cutover atomicity (0.2/1.2):** the SQLite→`sqld` seed needs a brief stop-the-world. Schedule it; it's the one unavoidable broker blip.
- **`sqld` driver swap (1.2):** verify the nexus Go code's SQLite usage is libSQL-compatible (it should be — libSQL is SQLite-superset); watch for any sqlite-driver-specific pragmas.
- **Two-keel conflict (3.3/4.2):** the one-session-per-name rule means the in-process Frame and the keel pod can't both register. **Resolve by combining Phase 3.2 + Phase 4.2 into a single cutover.**
- **Brokering vs direct DSN (0.3):** custodian-brokered `sqld` connections are the target; a direct in-cluster DSN is an acceptable interim to unblock the broker migration, with brokering as a fast-follow.

## Sequencing summary
0 (`sqld`) → 1 (broker pod, Frame still embedded) → 2 (inventory/admin API) → **3+4 combined cutover** (keel pod up as `frame.Embed` removed) → 5 (decommission). Phases 0–1 deliver value alone (broker in a pod on `sqld`); 2–4 deliver the embedded-AI removal; 5 closes out the host.
