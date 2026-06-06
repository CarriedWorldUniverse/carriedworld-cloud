# Removing the Embedded AI from nexus — Design

**Status:** design (brainstormed 2026-06-06, operator-approved direction). Next: implementation plan.

**Goal:** stop the broker booting an in-process funnel. nexus becomes a **pure message/dispatch hub**. The Frame's role moves to **keel** — a standalone, always-on agentfunnel pod on the local gemma. AI is no longer embedded in the broker; it's an addressable agent (keel) plus on-demand dispatched agents.

---

## Background — what the "embedded AI" actually is

The map of the nexus codebase (2026-06-06) confirmed the embedded AI is **not** a tangle of broker-side AI logic. It is **one thing**: the **Frame** — an in-process `*funnel.Funnel` instance the broker boots via `frame.Embed()` in `buildChatRouter()` (`nexus/cmd/nexus/main.go` ~L1650). It runs in the broker's goroutine, shares the broker's DB + observability hub **in-process**, and holds an **admin-privileged aspect identity**. The Frame **is keel**.

The funnel's AI behaviours — judge / CheapModelFilter, summariser (compaction), rewriter (haiku distiller), auto-recall, the main turn — are **functions of the funnel**. They run wherever the funnel runs. They are **not** separate broker AI to dispatch one-by-one (the earlier "dispatch the judge / chat.retract / hot-path latency" framing was solving a non-problem). **We relocate the whole funnel; the AI functions move with it, unchanged.**

Every dispatched builder/agent already runs as an **out-of-process agentfunnel** talking to the broker over comms — so the out-of-process path already exists and is proven (harrow ran this way on gemma, 2026-06-06).

---

## Architecture

- **Broker:** drop `frame.Embed()`. The broker no longer constructs or runs a funnel. It is routing + dispatch + the data/admin API. Genuinely dumb and reliable.
- **keel:** a standalone agentfunnel, **always-on** (a standing k8s Deployment pod), `provider = gemma` (the cheap warm core). Its funnel (judge/summarise/recall/main-turn) runs **in keel's pod, unchanged** from how it runs in the broker goroutine today.
- **Addressing:** keel registers and is addressed via the normal comms path (like the dispatched agents) — just always-on instead of on-demand.
- **Escalation:** keel **dispatches to a frontier model** for hard Frame tasks. Cheap baseline, premium on-demand.

---

## keel ⇄ shadow division of labour (operator, 2026-06-06)

The brokered remote DB access (NEX-454) changes who does what:

- **keel-on-gemma = the always-on cheap WATCHER / baseline.** Watching the network, light routing/triage, "is this worth acting on / waking shadow," cheap background tasks. Always available, free (local model).
- **shadow (Opus, via agora) = the active manager.** With a **brokered remote DB connection**, shadow reads the cloud's data directly and **manages/diagnoses nexus remotely**, dispatching long-running maintenance itself — *without* handing off to keel as the local-data intermediary. The shadow→keel hand-off for data-driven work largely disappears.
- **Heavy / long work = dispatch.** keel or shadow spins up a skill-scoped agent on the right provider.

So: keel = warm cheap presence; shadow = active premium manager with full remote data access; dispatch = the heavy lifting.

---

## The data + admin seam — the only real coupling to break

The in-process Frame enjoyed three things an out-of-process keel loses: **direct DB access, admin privileges, and the in-process observability hub.** Each has a clean replacement:

1. **Direct DB → the brokered DB connection (NEX-454).** Out-of-process keel **and** remote shadow read the broker's data through a **custodian-brokered `sqld` connection**, not in-process. This is the unification: the data-layer direction *is* how decoupled agents read the broker's data. The embedded-AI removal and NEX-454 are the same seam.
2. **Admin operations → the admin API.** Whatever the Frame did with in-process admin privileges goes through the admin REST API the agentfunnels already use. **Inventory the Frame's admin/DB calls** and map each to an endpoint (expose new ones where missing).
3. **Observability → the observability frames.** keel reports turns via the same `observe.*` frames the dispatched agents already emit, not the shared in-process hub.

---

## Components / files

- `nexus/cmd/nexus/main.go` (`buildChatRouter` ~L1650) — remove `frame.Embed()`; broker stops constructing/running the Frame funnel.
- The Frame's in-process DB/admin usage → routed to (1) the brokered `sqld` connection and (2) the admin API.
- **keel deployment** (`carriedworld-cloud/clusters/dmon/`) — a standing pod: `provider=gemma` binding, the keel keyfile Secret, always-on, `runtimeClassName: nvidia` not needed (keel calls the gemma *service*, doesn't host a model). Addressable.
- Any remaining in-process callers of the Frame → via comms / the admin API.

---

## Data flow

- A message addressed to keel → broker routes it over comms to keel's pod → keel's funnel processes it (LLM call to the gemma endpoint) → responds over comms. Identical to the dispatched-agent path, just always-on.
- keel / shadow read broker data → via the brokered `sqld` connection.

---

## Testing

- Broker boots with **no in-process funnel** (`frame.Embed` removed); aspects still register + route; admin API serves the Frame's old operations.
- keel runs as a standing pod, registers, is addressable, processes messages on gemma.
- keel **and** remote shadow read nexus data through the brokered connection.
- The Frame's former admin/DB operations succeed through the API path.

---

## Risks / open questions

- **The admin/DB call inventory is the load-bearing implementation detail** — the exact in-process DB/admin calls the Frame makes today, to map to the brokered connection + admin endpoints. A focused pass before the plan.
- **Ordering vs the data layer:** the clean version needs the brokered `sqld` connection (NEX-454) first (at least `nexus.db` reachable as a brokered connection). Alternative: decouple first with keel reaching data via the admin API as an interim, `sqld` later. Decide in the plan.
- **keel-on-gemma capability:** fine for the watcher/baseline; hard Frame work escalates by dispatch to a frontier model.
- **keel's specific watcher responsibilities** (routing rules, triage thresholds, what wakes shadow) — a spec/plan detail, intentionally left open here.

---

## Sequence (toward the implementation plan)

1. **Prereq:** the brokered DB layer (NEX-454 / `sqld`) — at minimum `nexus.db` reachable as a brokered connection.
2. **Inventory** the Frame's in-process DB/admin calls → map to the brokered connection + admin API (add endpoints where missing).
3. **Stand keel up** as an always-on gemma pod (keyfile, `openai`/gemma binding, Deployment) — addressable.
4. **Remove `frame.Embed()`** from the broker; route the Frame's role to keel; broker becomes pure.
5. **Verify** the end state: pure broker, keel as the standing Frame on gemma, shadow managing remotely through brokered data, heavy work dispatched.

---

*Pairs with [project_dispatch_native_architecture] (the platform going dispatch-native) and NEX-454 (the brokered data layer). The broker→pod migration (workstream 2) and this removal are best done together — both are "get the funnel and the data out of the broker process."*
