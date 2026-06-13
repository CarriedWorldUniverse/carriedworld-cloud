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

## Runtime shape (implementation choice, to settle)

shadow wants BOTH max capability (raw Claude Code + MCPs, controller-shaped —
its current shape) AND autonomy (a wake-loop). Options: (a) raw-CC in the
always-on croft pod driven by a scheduled wake-loop (loop/schedule primitives)
— keeps capability, gains autonomy; (b) deployed goal-loop aspect under
agentfunnel (proven by maren posting art unattended, keel always-on) — uniform
with the harness but possibly less capable than raw CC. Lean (a) for shadow's
capability; keel fits (b) cleanly. Watch the goal-loop re-entry bug
(false "more work to do" on empty inbox) for whichever harness.

## Supersedes / relates

- NEX-176 (keel takes over DISPATCH) — OBSOLETE premise: the pull pipeline
  self-routes, so there's no dispatcher-agent role; keel becomes the system
  engineer instead.
- NEX-640 (first-class dispatch + escalated events) — its escalation consumer
  is keel; its honest-200 is shadow's trust floor.
- Pull-pipeline (queue + worker pool) — the routing layer both sit above.
- The "solo dev → team manager" ideal, finally realized.
