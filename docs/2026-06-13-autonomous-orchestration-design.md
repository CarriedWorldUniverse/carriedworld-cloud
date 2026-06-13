# Autonomous orchestration — shadow (work) + keel (ops)

**Date:** 2026-06-13
**Status:** direction decided (operator). The consequential reframe: the
platform's missing piece was never a dispatcher — it was AGENCY OVER TIME. The
whole system still requires the operator at the keyboard to trigger every flow;
each flow goes deep, but initiation is 100% manual. This closes that.

Both agents are CARRIEDWORLD-org consumers (not CWB pillars), owned-AIs with
responsible_human = croft.

## Steady state (minimal)

- **shadow = autonomous orchestrator of WORK.** A goal-loop: wake on events +
  heartbeat → read ground truth (jira ready queue, open PRs, CI status, the
  dispatch queue, builder pool) → advance: queue ready tickets, dispatch via
  the pull pipeline, review PRs, merge green low-risk ones, backfill the queue
  from the backlog when idle-with-budget, escalate blockers. Budget-governed:
  runs while tokens available, winds down when low. You become the STEERER
  (goals, escalations, approvals), not the trigger.
- **keel = autonomous SYSTEM ENGINEER.** A goal-loop over the ops plane:
  ingest (loki-alert-bridge already in nexus ns + pod logs + the escalated
  dispatch events from NEX-640 + pillar health) → CLASSIFY (severity;
  category: transient/config/code-bug/security/capacity; known vs novel) →
  RESPOND (auto-remediate known/transient; FILE A TICKET for recurring/code
  issues; ESCALATE critical/novel/security to the operator). The platform's
  immune system.
- **worker pool** (anvil/plumb + specialists harrow/maren/forge) = enabled at
  need; pulled by the pipeline; scale-from-zero. No always-on cost.
- **operator (croft)** = steerer.

## The closed loop (why keel-as-syseng is the keystone)

keel detects an ops problem → files a ticket → it lands in shadow's work queue
→ the pipeline ships the fix. Ops detection feeds work execution. The NEX-640
escalated dispatch errors finally have a consumer: keel. Two autonomous brains
(shadow = hands/work, keel = senses/ops) + a worker pool + a human who is
pinged only on guardrail-hits and critical/novel/security events.

## Prerequisite: the trust floor (non-negotiable)

An unattended loop CANNOT run on an opaque system — it acts on phantom state
(the 2026-06-13 dispatch incident: a builder "ok" that didn't run, survivable
only because a human was at the keyboard). The transparency/AAA work is the
floor autonomy stands on. BUT we don't block on full NEX-640: the dispatch
skill's verify-gate is the INTERIM floor — an autonomous shadow that runs the
skill confirms acceptance before believing anything. Loop starts on the skill;
simplifies as the system gets honest.

## Guardrails (the autonomy boundary — operator-set)

Autonomous WITHOUT the operator: queue-fill, dispatch, review, merge of GREEN
LOW-RISK PRs, backlog grooming, known-issue remediation (keel).
HARD-STOP + escalate to operator: destructive ops, cross-cutting / central-
policy changes, identity/auth changes, spend/outward-facing actions, scope
changes, novel/security ops events. Enforced as GATES, not conventions.

## Runtime shape — TWO PLANES, kept distinct (operator 2026-06-13)

**croft stays the operator's control plane** — your pod, your identity, your
interactive seat; it NEVER hosts an autonomous loop (that would be your
workspace acting without you). **The live loop runs in the SHADOW POD** (the
deployed shadow-aspect, already running). Shadow's real, distinct home — not a
vestige of croft.

Identity consequence: the autonomous loop acts AS shadow (owned-AI,
responsible_human=croft), NOT as croft. Audit reads "shadow, owned by croft,
did X"; "croft did X" is reserved for what the operator actually did. The
human identity is never the one acting unattended. (Refines the earlier
"shadow acts as croft" shorthand.)

Remaining sub-question (decided at flip-time, NEX-642): HOW it loops inside
the shadow pod — raw-CC-on-a-wake-loop (keep controller-grade capability) vs
the agentfunnel goal-loop harness (uniform with maren/keel, watch the
re-entry bug). Either way: in the shadow pod, not croft.

## The operating model — activated tickets (operator 2026-06-13)

You QUEUE + ACTIVATE tickets; shadow's loop works the ACTIVATED LIST in your
order. Per-ticket cycle:
```
next activated ticket → DECOMPOSE (plan / sub-tickets / dispatch briefs,
  via the spec+planning skills) → dispatch pieces to the pull pipeline
  → watch acceptance (dispatch skill verify-gate) → review PRs
  → merge green low-risk → ticket done → next
activated list empty / budget low → idle → wake when you activate more
```

- **"Activated" is the steering wheel AND the primary guardrail, one knob.**
  Shadow works ONLY activated tickets (not everything `ready`), in your order.
  Cross-cutting/destructive/identity-auth work is simply NOT activated — you
  drive it yourself in croft. Two composable layers: ACTIVATION gates WHICH
  tickets shadow may touch; the merge-green-low-risk line gates HOW FAR within
  one. Most of the safety lives in "only what I activated."
- **Decompose = shadow running the spec/planning phase** (what was done for
  atlas tonight, loop-driven instead of operator-driven). Big tickets
  decompose into sub-tickets that can themselves be activated → mildly
  recursive.
- **Classify each unit by SKILL SET needed** — the intelligent half of
  decompose. Shadow tags every dispatch unit with the skill it requires
  (go-build→anvil/plumb · research→harrow · art/3D→maren · game-AI
  training→forge · …); workers advertise skills and pull matching jobs. The
  pool is skill-scoped (the specialist-pod images ARE the skills); shadow
  classifies, the pipeline matches — cognition vs plumbing. Common case
  (generic build) load-balances across anvil/plumb; specialist case targets.
  A unit needing a skill NO active worker advertises = ESCALATE (capability
  gap), never queue an unclaimable job.
- **Shadow keeps the pipeline FED, not one-ticket-at-a-time.** Decompose A,
  dispatch its pieces, then decompose B while builders work A — every idle
  builder busy from the activated list. Serialism stays per-builder; shadow
  juggles workstreams against builder availability + budget. This is what
  "keep work flowing while tokens are available" means concretely.
- **keel→shadow handoff via activation:** keel files an ops ticket → it sits
  un-activated until the operator (or an auto-activate rule for known-safe
  classes) activates it. The activation gate is where ops-detection meets
  human judgment before work fires.

Needs: an "activated" ticket state distinct from `ready` — the explicit,
ordered, per-ticket go signal.

## LEDGER IS THE QUEUE (operator decision 2026-06-13)

There is NO separate internal building queue — that would be the nexus-specific
artifact the genericity principle forbids. Ledger (the CWB issues pillar) IS
the work queue, top to bottom; it already has the claim-based primitives:
ListReadyIssues (the ready set), ClaimIssue (atomic claim), AssignIssue,
TransitionIssue (the status machine), parent_key (decomposition = sub-issues).

Flow, one source of truth:
```
operator activates a ledger ticket → shadow reads ready/activated
  → decomposes into ledger SUB-ISSUES, each skill-classified
  → workers pull ready sub-issues (ListReadyIssues + ClaimIssue) filtered by skill
  → TransitionIssue tracks claimed → accepted → running → done
```
The NEX-640 acceptance contract = ledger status transitions. Decomposition is
visible (sub-issues under parent); claim/accept/done is visible (status). Any
org's orchestrator + workers use the same generic ledger.

Split: **ledger = generic work STATE + claim protocol** (platform pillar);
**the runner launching k8s Jobs = carriedworld's COMPUTE** (consumer-specific,
reads/claims from ledger, launches workers; does NOT own the queue). If
dispatch churn ever strains ledger → a read-cache OVER ledger, never a rival
source of truth.

Reframes NEX-644: not "build a durable queue" but "workers claim ready issues
from ledger + add skill-routing to the ready query."

## Workflows are per-consumer; CATEGORIES are the generic spine (NEX-646)

ledger's workflow is hardcoded today (a Go map; fixed To Do→…→Done). Make it
CONFIGURABLE per consumer (states + transitions + DoD gates as data), with each
state mapped to a fixed platform-owned CATEGORY (draft/ready/active/in-review/
awaiting-merge/blocked/done/cancelled — refine in spec). **Shadow + workers key
off CATEGORY, never the display name** — so a consumer can name/restructure
states freely (carriedworld: preparing→ready→in-dev→code-review⇄dev→in-PR→
ready-to-merge→merged) and orchestration stays generic. claim on category:ready;
review on in-review; merge on awaiting-merge; close on done. The Jira/Linear
status-category pattern.

EVENT-DRIVEN WAKE (already half-designed in ledger): "Ready to Start" exists as
the dispatch-ready signal, and workflow.go references an orchestration-redesign
spec where the scheduler SUBSCRIBES to status_changed events rather than polling.
That is shadow's wake spine — wake on a ledger status-change event (something
became category:ready / awaiting-merge), not a poll loop. Find + fold in that
spec under NEX-642/646.

GENERICITY FIXES ledger needs first (the nexus-leak audit, NEX-645):
- `assignee_aspect` (Issue + SearchFilter) → `assignee` (generic identity).
- `ListReadyIssuesRequest.aspect` → generic: assignee + skill/capability filter.
- Issue has NO skill/label field → add one; skill-routing needs it.
- The "ready" predicate (status + Definition-of-Ready + deps-clear + assigned)
  must be a DEFINED generic condition, not a free-string `status` convention.

## Decisions (operator 2026-06-13)

- **Autonomy line = through merge of green low-risk PRs.** Autonomous without
  the operator: queue-fill/groom, dispatch, review, MERGE green low-risk PRs,
  backfill. Hard-stop + escalate: destructive, cross-cutting/central-policy,
  identity/auth, spend/outward-facing, scope, anything not green, and (keel)
  novel/security ops events.
- **Build the floor first; flip autonomy deliberately.** Do NOT put shadow on
  a live autonomous clock yet. Build the prerequisites, then turn it on as a
  conscious act. Runtime shape (raw-CC-in-croft wake-loop vs goal-loop aspect)
  is decided AT flip-time, not now.

## Build order (to autonomous shadow)

1. **Interim trust floor — DONE:** the dispatch skill verify-gate (nexus PR
   #379). Lets a future loop not be fooled by phantom "ok".
2. **Full trust floor — NEX-640:** first-class dispatch, honest 200 (=builder
   accepted), escalated error events.
3. **Pull pipeline — NEX-644:** durable queue + worker pool + self-routing
   (the routing layer; the NEX-640 acceptance contract is its state machine).
4. **Flip shadow autonomous — NEX-642:** wake-loop, the autonomy line above,
   runtime chosen deliberately here.
5. **keel system engineer — NEX-643:** parallel; consumes NEX-640 escalations,
   feeds shadow's queue.

## Dependency: real review gating needs cairn (identity-native git)

Autonomous shadow's review→merge step requires the reviewer-≠-author /
author-can't-self-merge gate to be REAL, not an honor-system convention. Today
all aspects + shadow funnel through ONE GitHub bot account (nexus-cw), so
author==reviewer==merger — GitHub's formal request-changes/approve gates don't
even fire ("can't review your own PR"), and an autonomous loop merging builder
PRs on that shared identity would be rubber-stamping itself: the accountability
is fictional. CAIRN (CWB's herald-identity-native git) is the fix — each aspect
pushes/commits/reviews AS its own herald identity (signed, per-aspect), so the
gate is enforced by construction. This is the AAA story applied to code
(authn = who pushed/reviewed; authz = who may merge; audit = signed per-aspect
history). The builders are on the GitHub path only as the explicit interim
("cairn not functional yet → cw pr once it works"); the review-gating gap
resolves at the cairn cutover. => cairn (or distinct per-aspect GitHub
identities as a stopgap) is on the CRITICAL PATH for the autonomous-review half
of NEX-642, not a nice-to-have.

## Supersedes / relates

- NEX-176 (keel takes over DISPATCH) — OBSOLETE premise: the pull pipeline
  self-routes, so there's no dispatcher-agent role; keel becomes the system
  engineer instead.
- NEX-640 (first-class dispatch + escalated events) — its escalation consumer
  is keel; its honest-200 is shadow's trust floor.
- Pull-pipeline (queue + worker pool) — the routing layer both sit above.
- The "solo dev → team manager" ideal, finally realized.
