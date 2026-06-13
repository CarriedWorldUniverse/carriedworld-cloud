# NEX-642 Shadow Autonomous Loop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up shadow's autonomous work-orchestration loop — a croft-resident Runner that wakes on a heartbeat, coalesces triggers, and re-invokes a fresh `claude -p` running the `orchestrate` drain skill against the ledger queue.

**Architecture:** Kubernetes-controller-reconciler semantics with a stateless reasoner. A small Go **Runner** (croft pod) holds the only loop state (a coalescing pending-bit) and shells out to `claude -p`. The **orchestrate skill** (markdown loaded by the fresh shadow) is the stateless drain logic: snapshot ledger ready-set → decompose / dispatch / review / auto-merge-or-escalate, with all work-state in ledger.

**Tech Stack:** Go (Runner, in the `nexus` repo, `runtime/cmd/shadow-runner/`); Claude Code CLI (`claude -p`); a Claude Code skill (`.agents/skills/orchestrate/SKILL.md`); ledger via the nexus-jira-style ledger MCP / `cw` (shadow's existing tools); k8s Deployment in the `croft`/`nexus` namespace.

**Spec:** `carriedworld-cloud/docs/2026-06-13-nex642-shadow-loop-design.md`

---

## File Structure

**Runner (nexus repo):**
- Create: `runtime/dispatch/shadowrunner/workqueue.go` — the coalescing workqueue (one-drain-in-flight + pending-bit), pure logic, no I/O. The testable core.
- Create: `runtime/dispatch/shadowrunner/workqueue_test.go` — coalescing tests.
- Create: `runtime/dispatch/shadowrunner/runner.go` — the loop: heartbeat ticker + workqueue + drain invocation (an injectable `drainFn` so the loop is testable without `claude`).
- Create: `runtime/dispatch/shadowrunner/runner_test.go` — loop tests with a fake drainFn + fake clock.
- Create: `runtime/cmd/shadow-runner/main.go` — wires the real drainFn (`exec` of `claude -p`), flags/env, signal handling.
- Create: `deploy/shadow-runner/Dockerfile` + `deploy/shadow-runner/build.sh` — image build (mirrors `deploy/broker/build.sh`).
- Create: `deploy/shadow-runner/deployment.yaml` — k8s Deployment (croft-adjacent; mounts shadow keyfile + claude).

**Drain skill (nexus repo):**
- Create: `.agents/skills/orchestrate/SKILL.md` — the stateless drain logic + gates (markdown).

**Pending-bit persistence:** a file at `$CW_RUNNER_STATE_DIR/pending` (default `/var/lib/shadow-runner/`), so a Runner restart mid-pending re-drains.

---

## Task 1: Coalescing workqueue (the testable core)

**Files:**
- Create: `runtime/dispatch/shadowrunner/workqueue.go`
- Test: `runtime/dispatch/shadowrunner/workqueue_test.go`

The workqueue models exactly the spec's coalescing semantics: idle+trigger→run; running+trigger→set pending; finish→if pending, run again. No timers, no I/O — a state machine over `{idle, running, runningPending}` so it's trivially testable.

- [ ] **Step 1: Write the failing test**

```go
package shadowrunner

import "testing"

func TestWorkqueue_IdleTriggerRuns(t *testing.T) {
	q := NewWorkqueue()
	if !q.Trigger() { // returns true = caller should start a drain now
		t.Fatal("idle+trigger should signal a drain")
	}
}

func TestWorkqueue_TriggerWhileRunningSetsPending(t *testing.T) {
	q := NewWorkqueue()
	q.Trigger()              // idle -> running (drain starts)
	if q.Trigger() {         // running+trigger -> pending, NOT a new drain
		t.Fatal("trigger while running must not start a 2nd drain")
	}
	if !q.Done() {           // finish: pending was set -> should re-drain
		t.Fatal("Done with pending should signal re-drain")
	}
	if q.Done() {            // finish again: no pending -> idle, no re-drain
		t.Fatal("Done with no pending should not re-drain")
	}
}

func TestWorkqueue_BurstCollapsesToOne(t *testing.T) {
	q := NewWorkqueue()
	q.Trigger()                 // -> running
	for i := 0; i < 5; i++ {    // 5 mid-drain triggers
		q.Trigger()
	}
	if !q.Done() {              // one follow-up drain
		t.Fatal("burst should collapse to exactly one follow-up")
	}
	if q.Done() {               // and no more
		t.Fatal("no second follow-up")
	}
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd <repo> && go test ./runtime/dispatch/shadowrunner/ -run TestWorkqueue -v`
Expected: FAIL — `undefined: NewWorkqueue`.

- [ ] **Step 3: Implement the minimal workqueue**

```go
// Package shadowrunner implements the coalescing trigger loop that drives
// shadow's stateless orchestrate drain (NEX-642). The workqueue here holds
// the ONLY loop state: one drain in flight + a pending bit. Pure logic so the
// coalescing semantics are unit-tested without timers or claude.
package shadowrunner

import "sync"

type wqState int

const (
	wqIdle wqState = iota
	wqRunning
	wqRunningPending
)

// Workqueue is the level-triggered coalescing workqueue: N triggers during a
// drain collapse to exactly one follow-up drain; a dropped trigger can't strand
// work because the next drain re-reads ledger truth (see the design's
// level-triggered semantics).
type Workqueue struct {
	mu    sync.Mutex
	state wqState
}

func NewWorkqueue() *Workqueue { return &Workqueue{state: wqIdle} }

// Trigger records a wake. Returns true iff the caller should START a drain now
// (i.e. we were idle). While a drain runs, it only sets the pending bit.
func (q *Workqueue) Trigger() bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	switch q.state {
	case wqIdle:
		q.state = wqRunning
		return true
	case wqRunning:
		q.state = wqRunningPending
		return false
	default: // wqRunningPending
		return false
	}
}

// Done marks the current drain finished. Returns true iff a follow-up drain
// should start immediately (a trigger arrived mid-drain).
func (q *Workqueue) Done() bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.state == wqRunningPending {
		q.state = wqRunning
		return true
	}
	q.state = wqIdle
	return false
}

// Pending reports whether a follow-up is queued (for persistence on restart).
func (q *Workqueue) Pending() bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.state == wqRunningPending
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `go test ./runtime/dispatch/shadowrunner/ -run TestWorkqueue -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add runtime/dispatch/shadowrunner/workqueue.go runtime/dispatch/shadowrunner/workqueue_test.go
git commit -m "feat(shadow-runner): NEX-642 coalescing workqueue"
```

---

## Task 2: The Runner loop (heartbeat + drain invocation, injectable)

**Files:**
- Create: `runtime/dispatch/shadowrunner/runner.go`
- Test: `runtime/dispatch/shadowrunner/runner_test.go`

The loop owns a heartbeat ticker and the workqueue, and calls an injected `DrainFunc` (so tests use a fake; `main.go` injects the real `claude -p` exec). One drain at a time is guaranteed by the workqueue. A `Trigger()` method lets an external event source (Runner v2) also poke it.

- [ ] **Step 1: Write the failing test**

```go
package shadowrunner

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

func TestRunner_HeartbeatDrains(t *testing.T) {
	var drains int32
	r := New(Config{Heartbeat: 5 * time.Millisecond}, func(context.Context) error {
		atomic.AddInt32(&drains, 1)
		return nil
	})
	ctx, cancel := context.WithCancel(context.Background())
	go r.Run(ctx)
	time.Sleep(40 * time.Millisecond)
	cancel()
	if atomic.LoadInt32(&drains) == 0 {
		t.Fatal("heartbeat should have triggered at least one drain")
	}
}

func TestRunner_NoConcurrentDrains(t *testing.T) {
	var inFlight, maxSeen int32
	r := New(Config{Heartbeat: time.Millisecond}, func(context.Context) error {
		n := atomic.AddInt32(&inFlight, 1)
		if n > atomic.LoadInt32(&maxSeen) {
			atomic.StoreInt32(&maxSeen, n)
		}
		time.Sleep(10 * time.Millisecond) // slow drain; ticks pile up
		atomic.AddInt32(&inFlight, -1)
		return nil
	})
	ctx, cancel := context.WithCancel(context.Background())
	go r.Run(ctx)
	time.Sleep(60 * time.Millisecond)
	cancel()
	if atomic.LoadInt32(&maxSeen) > 1 {
		t.Fatalf("drains overlapped: maxSeen=%d, want 1", maxSeen)
	}
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `go test ./runtime/dispatch/shadowrunner/ -run TestRunner -v`
Expected: FAIL — `undefined: New` / `Config`.

- [ ] **Step 3: Implement the loop**

```go
package shadowrunner

import (
	"context"
	"log/slog"
	"time"
)

// DrainFunc runs one drain (in production: invoke `claude -p <orchestrate>`).
// Returning an error is logged but NOT fatal — the next heartbeat re-derives
// ledger truth (level-triggered), so a failed/partial drain self-heals.
type DrainFunc func(context.Context) error

type Config struct {
	Heartbeat time.Duration // unconditional resync drain interval
	Log       *slog.Logger
}

type Runner struct {
	cfg   Config
	q     *Workqueue
	drain DrainFunc
	wake  chan struct{} // external triggers (event source, v2)
}

func New(cfg Config, drain DrainFunc) *Runner {
	if cfg.Heartbeat <= 0 {
		cfg.Heartbeat = 12 * time.Minute
	}
	if cfg.Log == nil {
		cfg.Log = slog.Default()
	}
	return &Runner{cfg: cfg, q: NewWorkqueue(), drain: drain, wake: make(chan struct{}, 1)}
}

// Trigger pokes the loop from an external event source (non-blocking).
func (r *Runner) Trigger() {
	select {
	case r.wake <- struct{}{}:
	default:
	}
}

func (r *Runner) Run(ctx context.Context) {
	t := time.NewTicker(r.cfg.Heartbeat)
	defer t.Stop()
	r.cfg.Log.Info("shadow-runner: started", "heartbeat", r.cfg.Heartbeat)
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			r.onTrigger(ctx)
		case <-r.wake:
			r.onTrigger(ctx)
		}
	}
}

// onTrigger applies coalescing: only the idle->running transition runs a drain
// (synchronously); triggers during a drain set the pending bit and the same
// goroutine re-drains on completion until pending clears.
func (r *Runner) onTrigger(ctx context.Context) {
	if !r.q.Trigger() {
		return // a drain is already running; pending bit set
	}
	for {
		if err := r.drain(ctx); err != nil {
			r.cfg.Log.Error("shadow-runner: drain error (will resync next wake)", "err", err)
		}
		if !r.q.Done() {
			return
		}
		r.cfg.Log.Info("shadow-runner: pending trigger — re-draining")
	}
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `go test ./runtime/dispatch/shadowrunner/ -v`
Expected: PASS (workqueue + runner tests). May take a few seconds (timing tests).

- [ ] **Step 5: Commit**

```bash
git add runtime/dispatch/shadowrunner/runner.go runtime/dispatch/shadowrunner/runner_test.go
git commit -m "feat(shadow-runner): NEX-642 heartbeat loop with coalescing + injectable drain"
```

---

## Task 3: main.go — real `claude -p` drain + pending-bit persistence + signals

**Files:**
- Create: `runtime/cmd/shadow-runner/main.go`
- Test: `runtime/cmd/shadow-runner/main_test.go`

`main.go` injects the real drain: exec `claude -p` with the orchestrate prompt, inheriting the croft env (keyfile, MCPs). It restores the pending-bit from disk on start (so a restart mid-pending re-drains) and persists it on each transition. SIGTERM cancels the context (graceful).

- [ ] **Step 1: Write the failing test (pending-bit persistence)**

```go
package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPendingFile_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "pending")
	if pendingExists(p) {
		t.Fatal("fresh dir: no pending")
	}
	if err := setPending(p, true); err != nil {
		t.Fatal(err)
	}
	if !pendingExists(p) {
		t.Fatal("pending should exist after set true")
	}
	if err := setPending(p, false); err != nil {
		t.Fatal(err)
	}
	if pendingExists(p) {
		t.Fatal("pending should be cleared")
	}
	_ = os.RemoveAll(dir)
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `go test ./runtime/cmd/shadow-runner/ -v`
Expected: FAIL — `undefined: pendingExists`.

- [ ] **Step 3: Implement main.go**

```go
// Command shadow-runner drives shadow's autonomous orchestrate loop (NEX-642):
// a heartbeat-coalescing Runner that re-invokes a fresh `claude -p` running the
// orchestrate drain skill. Stateless reasoner; all work-state lives in ledger.
package main

import (
	"context"
	"flag"
	"log/slog"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/CarriedWorldUniverse/nexus/runtime/dispatch/shadowrunner"
)

func pendingExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func setPending(path string, on bool) error {
	if on {
		return os.WriteFile(path, []byte("1"), 0o644)
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func main() {
	heartbeat := flag.Duration("heartbeat", 12*time.Minute, "unconditional resync drain interval")
	claudeBin := flag.String("claude", "claude", "path to the claude CLI")
	prompt := flag.String("prompt", "Use the orchestrate skill to drain the ledger work queue: read the ready set, decompose ready goals, dispatch ready leaf tasks, review landed PRs, auto-merge green low-risk ones, escalate the rest. Then exit.", "drain prompt")
	stateDir := flag.String("state-dir", envOr("CW_RUNNER_STATE_DIR", "/var/lib/shadow-runner"), "pending-bit dir")
	timeout := flag.Duration("drain-timeout", 30*time.Minute, "max wall-clock per drain")
	flag.Parse()

	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	_ = os.MkdirAll(*stateDir, 0o755)
	pendingPath := filepath.Join(*stateDir, "pending")

	drain := func(ctx context.Context) error {
		dctx, cancel := context.WithTimeout(ctx, *timeout)
		defer cancel()
		cmd := exec.CommandContext(dctx, *claudeBin, "-p", *prompt)
		cmd.Stdout = os.Stdout // captured by the pod log
		cmd.Stderr = os.Stderr
		log.Info("shadow-runner: invoking claude drain")
		err := cmd.Run()
		log.Info("shadow-runner: drain finished", "err", err)
		return err
	}

	r := shadowrunner.New(shadowrunner.Config{Heartbeat: *heartbeat, Log: log}, drain)

	// Restore pending across restart: if we died mid-pending, re-drain now.
	if pendingExists(pendingPath) {
		log.Info("shadow-runner: pending bit found on start — triggering drain")
		r.Trigger()
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	r.Run(ctx)
	log.Info("shadow-runner: stopped")
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
```

NOTE on the pending-bit wiring: Task 2's `Runner` persists nothing; `main.go` owns the file. For v1, the in-memory workqueue + restore-on-start above is sufficient (a restart that loses an in-flight pending just means the next heartbeat re-drains within `heartbeat` — acceptable, level-triggered). Full per-transition persistence is a v1.1 nicety; do NOT over-build it now (YAGNI). The test above covers the file helpers used by restore-on-start.

- [ ] **Step 4: Run tests + build, verify pass**

Run: `go test ./runtime/cmd/shadow-runner/ -v && go build ./runtime/cmd/shadow-runner/`
Expected: PASS + clean build.

- [ ] **Step 5: Commit**

```bash
git add runtime/cmd/shadow-runner/
git commit -m "feat(shadow-runner): NEX-642 main — claude -p drain + pending restore + SIGTERM"
```

---

## Task 4: The orchestrate drain skill

**Files:**
- Create: `.agents/skills/orchestrate/SKILL.md`

This is the stateless reasoning logic the fresh `claude -p` shadow runs each wake. It is MARKDOWN (instructions), not unit-tested Go; its correctness is proven by the dogfood e2e in Task 5. Keep it tight and imperative.

- [ ] **Step 1: Write the skill**

Create `.agents/skills/orchestrate/SKILL.md` with this content:

````markdown
---
name: orchestrate
description: Drain the ledger work queue once — decompose ready goals, dispatch ready leaf tasks, review landed PRs, auto-merge green/low-risk, escalate the rest. Stateless; all state in ledger.
---

# orchestrate — one drain of shadow's autonomous loop (NEX-642)

You are shadow, woken to drain the ledger work queue ONCE, then exit. You hold no
memory of prior drains — **all state is in ledger**. Re-read truth; never assume.

## Procedure

1. **Snapshot the ready set.** Call ledger ListReady for shadow's orchestration
   queue. This set is already skill/category/dependency-aware (no blocked, no
   missing-DoR, no already-claimed units). Treat the snapshot as fixed for this
   drain; newly-created/changed issues are handled next drain.

2. **For each ready unit, classify and act (one unit at a time):**
   - **Goal / epic (no dispatchable leaf children yet)** → DECOMPOSE: break it into
     leaf sub-issues, each created in ledger with `parent_key` set, a clear
     `summary`, a `definition_of_done`, and `skills` tags for routing. Transition
     the goal to `In Progress`. Do NOT dispatch the children this drain — they
     enter the ready set and are picked up next wake.
   - **Leaf task (ready, dispatchable)** → DISPATCH to a builder via the dispatch
     skill (`!dispatch <builder>%<provider> repo=<r> ticket=<ledger-key> …`),
     using its `skills` to pick the builder. VERIFY ACCEPTANCE (broker log
     `builder job created` + `Submit returned err=<nil>` + pod Running — NOT the
     send_chat "ok"). On confirmed acceptance, **immediately transition the unit
     to `In Progress`** (claimed) so it leaves the ready set — THIS is the
     double-dispatch guard. If acceptance fails → escalate (see Gates).

3. **Reconcile dispatched units** (those already `In Progress` with a builder run):
   check whether their PR has landed (gh / the run record). If a PR is up →
   REVIEW it. (Interim until NEX-655: you track run→PR state yourself by checking
   the broker run log / gh; once 655 lands, read the lifecycle from ledger.)

4. **Review → merge-or-escalate (the Gates):**
   - **AUTO-MERGE** only when ALL hold: CI green · single-ticket scope · your
     review found no blocking issue · NOT cross-cutting (no deploy, proto/contract,
     auth/identity, multi-repo, or scope change). Then squash-merge, delete branch,
     transition the ledger unit to `Done`.
   - **ESCALATE + PARK** otherwise (cross-cutting / deploy / proto / auth / scope /
     CI-red / review-found issue / ANY doubt): leave the PR open, transition the
     unit to `Blocked`, log a distinct line `orchestrate: ESCALATION <key> <reason>`,
     and ping the operator (comms). Do NOT merge. Do NOT retry — it waits for the
     operator. **Deploys ALWAYS escalate.**
   - **Builder failed/stalled** (run failed/stalled per 653/654): transition the
     unit back to ready and redispatch-with-feedback ONCE; on a second failure,
     escalate.

5. **Groom (cheap, optional):** close ledger units whose PRs already merged;
   nothing else.

6. **Exit** when the snapshot is handled, OR if you hit a rate-limit / repeated
   error (stop cleanly — the next heartbeat resumes; partial progress is durable in
   ledger). Report a one-line summary of what you did this drain.

## Hard rules
- One ticket per builder; builders run in parallel; never bundle tickets in a dispatch.
- Transition-on-dispatch is mandatory (the double-dispatch guard).
- When in doubt about a merge, ESCALATE — never merge on uncertainty.
- You are stateless: if something isn't in ledger/git/the run log, it didn't happen.
````

- [ ] **Step 2: Sanity-check the skill loads**

Run (in croft, manually): `claude -p "Use the orchestrate skill to list (don't act) what's in the ledger ready set right now, then exit."`
Expected: shadow invokes the skill, calls ledger ListReady, reports the set, exits. (Read-only probe — no dispatch.)

- [ ] **Step 3: Commit**

```bash
git add .agents/skills/orchestrate/SKILL.md
git commit -m "feat(orchestrate): NEX-642 stateless drain skill + gates"
```

---

## Task 5: Image, deploy to croft, and dogfood e2e

**Files:**
- Create: `deploy/shadow-runner/Dockerfile`
- Create: `deploy/shadow-runner/build.sh`
- Create: `deploy/shadow-runner/deployment.yaml`

- [ ] **Step 1: Dockerfile** (mirror `deploy/broker/Dockerfile` — minimal base + the binary + the claude CLI available; the Runner shells to `claude`, so the image/pod must have claude + shadow's keyfile + MCP config, same as the croft environment)

```dockerfile
# Built on the host, binary COPY'd in (see deploy/broker/Dockerfile pattern).
FROM debian:stable-slim
RUN apt-get update && apt-get install -y ca-certificates git && rm -rf /var/lib/apt/lists/*
COPY shadow-runner /usr/local/bin/shadow-runner
# claude CLI + shadow keyfile + .mcp.json are provided by the croft image/mounts,
# not baked here — the Runner reuses the croft execution environment.
ENTRYPOINT ["/usr/local/bin/shadow-runner"]
```

- [ ] **Step 2: build.sh** (mirror `deploy/broker/build.sh`: host `go build` → `podman build` → `k3s ctr images import`)

```bash
#!/usr/bin/env bash
set -euo pipefail
NEXUS_SRC="${NEXUS_SRC:-/usr/local/src/nexus}"
IMG="localhost/shadow-runner:${TAG:-dev}"
CTX="$(mktemp -d)"
( cd "$NEXUS_SRC" && go build -o "${CTX}/shadow-runner" ./runtime/cmd/shadow-runner )
cp "$(dirname "$0")/Dockerfile" "${CTX}/Dockerfile"
( cd "$CTX" && podman build -t "$IMG" . )
podman save "$IMG" | sudo k3s ctr images import -
rm -rf "$CTX"
echo "==> done: ${IMG}"
```

- [ ] **Step 3: deployment.yaml** — single-replica Deployment in the croft/nexus namespace, mounting shadow's keyfile + claude env (copy the volume/env setup from the existing croft/aspect deployment so `claude -p` has identity + MCPs). `args: ["-heartbeat=12m"]`. `restartPolicy` via Deployment (supervised restart).

(Author this by copying the croft pod's spec for the claude environment; the only new bits are the `shadow-runner` image + the `-heartbeat` arg + a `state-dir` emptyDir/PVC for the pending bit.)

- [ ] **Step 4: Build + deploy (cross-cutting — get operator nod first)**

```bash
# On dMon, from /usr/local/src/nexus on main:
sudo NEXUS_SRC=/usr/local/src/nexus bash deploy/shadow-runner/build.sh
# commit deployment.yaml to carriedworld-cloud manifests if GitOps-managed, then:
sudo kubectl apply -f deploy/shadow-runner/deployment.yaml
sudo kubectl -n <ns> rollout status deploy/shadow-runner
```

Expected: Runner pod Running; logs show `shadow-runner: started heartbeat=12m`.

- [ ] **Step 5: Dogfood e2e (the acceptance bar)**

1. Operator (or shadow, manually) files ONE real goal as a ledger issue: a small,
   decomposable goal with a clear DoD, assigned to shadow's orchestration queue,
   status ready.
2. Wait for a heartbeat (≤12m) or `Trigger()` the Runner.
3. Observe across drains (via ledger state + broker log + gh):
   - drain 1: goal decomposed into ≥1 ready leaf child(ren);
   - drain 2: child dispatched, transitioned In Progress (verify it is NOT
     re-dispatched on the following drain — the double-dispatch guard);
   - builder produces a PR; a later drain reviews it;
   - a green/low-risk child → auto-merged → Done; a cross-cutting one → escalated
     + parked + operator pinged.
4. Verify shadow was never manually in the loop except to act on an escalation.

- [ ] **Step 6: Commit**

```bash
git add deploy/shadow-runner/
git commit -m "feat(shadow-runner): NEX-642 image + croft deployment + dogfood runbook"
```

---

## Self-review notes (gaps deliberately deferred — YAGNI, not omissions)
- **Ledger event subscription** (Runner v2) — not in this plan; heartbeat-only v1 is
  correct (level-triggered), just less responsive. Add when a ledger event stream exists.
- **655 actual-state reconciliation** — the orchestrate skill tracks run→PR→ledger
  state itself (Task 4 step 3/4) until 655 automates it; the skill notes the seam.
- **Per-transition pending persistence** — restore-on-start only (Task 3 note); a lost
  in-flight pending self-heals within one heartbeat.
- **deployment.yaml exact volumes/env** — authored by copying the live croft pod spec at
  build time (the claude identity/MCP setup is environment-specific; don't invent it).
