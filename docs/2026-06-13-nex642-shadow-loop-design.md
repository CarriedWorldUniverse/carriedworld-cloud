# NEX-642 — shadow's autonomous work-orchestration loop (design)

**Date:** 2026-06-13
**Status:** design (operator-approved sections). Implements the shadow half of the
two-controller model in `2026-06-13-autonomous-orchestration-design.md`.

## Goal

Turn shadow from a request-response assistant into a self-running loop that drains
the generic ledger work-queue: on wake, read ground truth from ledger, decompose
ready goals, dispatch ready leaf-tasks to builders, review landed PRs, auto-merge
the green/low-risk ones, and escalate everything risky — converging
`ready tickets → dispatched/merged work` the way a Kubernetes controller converges
desired→actual.

## Decisions (operator, 2026-06-13)

- **Runtime shape = A**: a scheduled/event **Runner** drives **raw Claude Code** in
  the always-on croft pod (shadow keeps full controller capability — all MCPs,
  judgment), NOT a deployed goal-loop aspect (avoids the goal-loop harness
  fragility/re-entry bug seen this session).
- **Stateless re-invocation**: each wake is a FRESH `claude -p "<drain skill>"`.
  All work-state lives in ledger; the reasoner holds none. The "loop" is the
  Runner re-invoking a clean shadow.
- **Dogfood on ledger alongside Jira**: 642 builds the loop reading/writing
  LEDGER; work enters as operator-filed goals → shadow decomposes into ledger
  sub-issues → drains. Jira stays as-is (human truth); NO jira→ledger cutover in
  642 (that's a later decision).
- **Merge autonomy = auto-merge green + low-risk; escalate the rest**: shadow
  auto-merges a builder PR only when CI-green AND single-ticket AND clean review
  AND not cross-cutting; anything cross-cutting/deploy/proto/auth/scope/CI-red/
  review-flagged/doubtful → leave open + escalate. Deploys ALWAYS escalate.

## Architecture — controller-reconciler with a stateless reasoner

Three parts with clean boundaries:

1. **The Runner** — small, persistent, stateful; "WHEN to wake + don't double-drain."
2. **The Drain Skill** — re-invokable, stateless; "WHAT to do this wake" (the reasoner).
3. **The Gates** — explicit autonomy rules inside the skill.

Ledger is the only durable state. The Runner is testable without the reasoner; the
skill is testable by invoking against a seeded ledger.

The loop adopts Kubernetes-controller semantics (not the library — the semantics):
**level-triggered** (each drain re-reads the ready-set; a dropped/dup wake can't
corrupt — the next drain re-derives truth), **one drain in flight + pending-bit**
(coalescing workqueue), **heartbeat resync backstop** (eventual-correctness even if
an event is lost).

## Components

### ① The Runner (croft-resident)

A lightweight always-on process in the croft pod, co-located with `claude`.

- **Heartbeat (v1):** every ~10–15 min, enqueue a drain. This alone makes the loop
  correct (level-triggered polling of truth) — just less responsive.
- **Event subscription (v2, additive):** subscribe to ledger `status_changed`
  events → enqueue a drain for responsiveness. Deferred so v1 ships without
  depending on a ledger event stream existing yet.
- **Coalescing workqueue:** one drain in flight + a pending-bit (small local state
  file). Idle+trigger→drain; draining+trigger→set pending; finish→if pending,
  re-drain. N bursts collapse to one follow-up. The bit carries no data.
- **Invocation:** runs `claude -p "<drain-skill prompt>"` with shadow's keyfile +
  MCPs locally in croft; captures exit code + output to a log.
- **Resilience:** crash → k8s/supervision restarts it; no work lost (state in
  ledger, heartbeat re-derives). Holds NO work-state — only the pending-bit.
- Reuses the nexus scheduler (NEX-304) for the heartbeat IF it's built; otherwise a
  self-contained croft timer.

### ② The Drain Skill (`.agents/skills/orchestrate/`)

Loaded by the fresh shadow each wake. Stateless logic:

1. **Snapshot** the ledger ready-set (`ListReady` — skill/category/dependency-aware,
   complete as of NEX-645/646). The snapshot is the drain boundary.
2. Per ready unit, classify and act:
   - **goal/epic (decompose candidate)** → decompose: create child leaf-issues with
     `skills` + `definition_of_done` + `parent_key`, mark ready; transition the goal
     → active. (Children are picked up the NEXT drain — snapshot boundary; the
     decompose status-change + heartbeat triggers it promptly.)
   - **leaf task** → dispatch to a builder (dispatch skill, verify-acceptance gate)
     → **immediately transition the unit → claimed/dispatched** so it leaves the
     ready-set (the double-dispatch guard).
3. For dispatched units whose PR has landed → **review** → gate check (§③).
4. **Transition ledger states** as it goes (claimed→dispatched→in-review→done).
   *Interim:* shadow does these transitions itself in the drain; **NEX-655 later
   automates this actual-state half** (dispatch engine → ledger), after which the
   skill just reads the state. This is 642's one forward-dependency — carried
   manually until 655.
5. **Exit** when the snapshot is handled OR a rate-limit/error is hit (the next
   heartbeat re-derives and resumes).

Stateless: re-derives everything from ledger each wake.

### ③ The Gates (explicit rules in the skill)

- **Autonomous:** decompose · dispatch · review · auto-merge (green + single-ticket +
  low-risk + clean-review + not-cross-cutting) · groom (reprioritize, close-merged).
- **STOP + escalate + park:** cross-cutting · deploy · proto/contract change · auth/
  identity · scope change · CI-red · review-found blocking issue · any doubt.
- **Escalation:** a distinct ERROR-level log event + an operator comms ping; the unit
  is left parked (not retried until the operator acts → status change → next drain
  resumes). Deploys ALWAYS escalate.

### ④ Budget / cadence (under subscriptions)

No `$`/token budget — agents run on subscriptions, so the limiter is rate-limit
windows + wall-clock (see `feedback_subscriptions_not_api_keys`). The **heartbeat
cadence + coalescing + level-triggered-resume IS the governor**: handle the full
snapshot per wake; if a rate-limit/error hits mid-drain, exit partial and let the
next heartbeat continue. No token accounting.

## Data flow

1. Operator files a **goal** as a ledger issue (ready, assigned to shadow's orchestration).
2. Runner heartbeat/event → coalesce → `claude -p <drain>`.
3. Shadow snapshots the ready-set, sees the goal.
4. Goal is a decompose candidate → shadow **decomposes** into ready child leaf-issues;
   goal → active. (Children handled next drain.)
5. Next drain: children are ready leaves → **dispatch each** → immediately transition
   child → claimed/dispatched (leaves ready-set).
6. Builders → PRs (653/654 track acceptance/stall).
7. Drain sees a dispatched unit's PR landed → **review** → gate: green+single-ticket+
   low-risk+clean+not-cross-cutting → **auto-merge** → child → done; else → **escalate
   + park**.
8. All children done → goal → done (or in-review for operator). Loop idles until next
   goal/event.

## Error handling & idempotency

- **Dropped wake** → heartbeat resync re-derives. **Burst/dup wakes** → coalescing
  (one drain + pending-bit) + level-triggered re-read → no double-drain, no
  double-dispatch.
- **Drain crash / rate-limit mid-drain** → partial progress is durable (each
  dispatch/transition commits as it happens); next heartbeat re-derives the remaining
  ready-set and continues. No corruption.
- **Double-dispatch trap** (the headline risk) → mitigated by *claimed units leave the
  ready-set*. Interim (pre-655): the drain transitions a unit to claimed/dispatched
  itself, immediately on dispatch.
- **Builder stall/fail** (654 idle-kill / 657 timeout→failed) → run marked failed →
  unit returns to ready/failed → shadow **redispatches-with-feedback** or **escalates
  after N retries**.
- **Review finds a problem** → PR left open + redispatch-with-feedback, or escalate if
  unresolvable.
- **Escalation** → distinct ERROR log + operator comms ping + unit parked.
- **Runner crash** → supervised restart; state in ledger; heartbeat re-derives.

Idempotency rests on three legs: **level-triggered re-read**, **claimed-leaves-ready-set**,
**atomic `ClaimIssue`**. Re-running any drain converges to the same state.

## Testing / dogfood plan

- **Runner unit tests:** coalescing (idle+trigger→drain; draining+trigger→pending;
  finish→re-drain; N bursts→one follow-up), heartbeat fires, invocation captures
  exit/output, pending-bit persists across restart.
- **Drain skill, seeded-ledger tests:** against a ledger seeded with known issues,
  assert the skill (a) dispatches a ready leaf and transitions it claimed, (b) does
  NOT re-dispatch a claimed unit on the next drain, (c) decomposes a goal into
  children, (d) auto-merges a green/low-risk PR, (e) escalates a cross-cutting/red PR
  and parks it. (Drive the skill in a test harness or via scripted `claude -p` runs.)
- **End-to-end dogfood (the acceptance bar):** operator files ONE real goal as a
  ledger issue; the loop decomposes → dispatches → builds → reviews → auto-merges the
  low-risk children and escalates anything risky, with shadow never in the loop except
  on escalations. Verify via ledger state + the merged PRs + the escalation log.

## Scope, dependencies, decomposition

**In scope (642):** the Runner (v1 heartbeat), the drain skill (decompose/dispatch/
review/auto-merge/escalate + interim ledger transitions), the gates, croft deploy of
the Runner.

**Out of scope / deferred:** ledger event subscription (Runner v2); NEX-655 (dispatch
engine → ledger lifecycle — 642 carries the transitions manually until then); the
jira→ledger cutover (NEX-665-style, later); the assignee rename (NEX-665).

**Depends on:** the generic ledger queue (NEX-645/646 — DONE: skill/category/
dependency-aware ready-set, create-with-skills); the dispatch engine honest-ack +
stall (653/654 — LIVE); the dispatch skill (verify-acceptance gate).

**Build order (buildable units, each its own PR):**
1. **Runner** (croft-resident heartbeat + coalescing workqueue + `claude -p`
   invocation + supervision) — nexus/croft.
2. **Drain skill** (`.agents/skills/orchestrate/`) — the stateless drain logic + gates.
3. **Wire + dogfood** — deploy the Runner to croft, file a test goal, run the e2e bar.
4. (later) Runner v2 ledger-event subscription; fold in 655's actual-state once built.

## Relates

- `2026-06-13-autonomous-orchestration-design.md` — the two-controller model this
  implements the shadow half of.
- NEX-655 (dispatch engine → ledger lifecycle) — automates the actual-state half 642
  carries manually.
- NEX-304 (nexus scheduler) — heartbeat source if built.
- `feedback_subscriptions_not_api_keys`, `feedback_one_ticket_at_a_time`,
  `project_dispatch_native_architecture`.
