# agentfunnel build — Implementation Plan

> **For agentic workers:** This is a **HYBRID plan**. **Phase A** (the enabling wiring + the warmup gate) is executed by **shadow** with `superpowers:executing-plans` — concrete, TDD-where-it-applies, task-by-task. **Phase B** (the extension) is **dispatched to the tuned model `code-cwb`** as the dogfood build — it is a *dispatch brief* (intent/constraints/DoD, per "brief intent not implementation"), NOT a step-by-step the engineer follows. Steps use `- [ ]` for tracking.

**Goal:** Stand up `code-cwb` as an agentfunnel builder and have it build agentfunnel's per-aspect system-prompt mode-control (append|replace) extension — the dogfood loop.

**Architecture:** Phase A wires claude-code → an Anthropic-shim → `code-cwb` (append-mode bootstrap) and runs a throwaway warmup that gates everything. Phase B dispatches the cross-repo extension build to `code-cwb`; shadow reviews + validates, and falls back gracefully if `code-cwb` (single-shot-tuned, not agentic-tuned) can't carry a cross-repo build.

**Tech Stack:** LiteLLM gateway (`/v1/messages` Anthropic endpoint), claude-code CLI, ollama (`qwen3-coder-cwb`), nexus (Go — `nexus/frame/funnel`, `nexus/broker` provider-binding), bridle (`github.com/CarriedWorldUniverse/bridle` — `provider/claudecode`, separate module).

**Spec:** `carriedworld-cloud/docs/2026-06-16-agentfunnel-build-design.md`

---

## Cross-repo reality (read first)

The flag selection (`--append-system-prompt` vs `--system-prompt-file`) lives in **bridle's `provider/claudecode`** — a *separate Go module*, not checked out locally. The per-aspect config + pass-through live in **nexus** (`broker` provider-binding + `frame/funnel`). So the extension spans **two repos**. This matters: a cross-repo agentic build is hard for a single-shot-tuned model. Phase B is therefore structured to (a) try it, (b) surface how far `code-cwb` gets, (c) let shadow finish/fall back without treating that as failure — the *experiment* (can the local builder build?) is the deliverable, not forcing the cross-repo change through code-cwb.

---

## PHASE A — shadow builds the wiring + the gate

### Task A1: LiteLLM Anthropic-shim + validate claude-code → code-cwb

**Files:**
- Modify: `carriedworld-cloud/hosting/services/litellm.yaml` (only if config changes are needed — recent LiteLLM exposes `/v1/messages` by default alongside `/v1/chat/completions`, routing by model name; the existing `code-cwb` lane should already be reachable as Anthropic `/v1/messages`).

- [ ] **Step 1: Confirm the gateway exposes `/v1/messages` for `code-cwb`**

Run (from a host that reaches the gateway):
```bash
echo '{"model":"code-cwb","max_tokens":32,"messages":[{"role":"user","content":"Reply with exactly: OK"}]}' | \
  ssh jacinta@100.91.185.71 'curl -s -m 120 http://localhost:4000/v1/messages -H "Content-Type: application/json" -H "anthropic-version: 2023-06-01" -H "x-api-key: dummy" -d @-' | head -c 600; echo
```
Expected: an Anthropic-shaped response (`{"type":"message","role":"assistant","content":[{"type":"text","text":"OK"}],...}`). If 404/"not found", add `litellm_settings: {pass_through_endpoints: ...}` or the anthropic-messages flag per LiteLLM docs to litellm.yaml, commit, apply, retry. If it returns a non-Anthropic shape, that's the translation gap → Step 3.

- [ ] **Step 2: Validate the full claude-code path including TOOL USE (the critical check)**

On a host with claude-code installed (dMon or shadow's env), in a scratch dir:
```bash
mkdir -p /tmp/shim-test && cd /tmp/shim-test && echo "hello" > probe.txt
ANTHROPIC_BASE_URL=http://100.91.185.71:4000 ANTHROPIC_API_KEY=dummy \
  claude -p "Read the file probe.txt and tell me its contents using the Read tool." \
  --model code-cwb --allowedTools Read 2>&1 | tail -20
```
Expected: claude-code drives a **tool call** (Read) through the shim to `code-cwb` and reports `hello`. This proves Anthropic↔OpenAI **tool-use translation** works end-to-end. PASS → A2.

- [ ] **Step 3: Fallback if tool-translation fails**

If Step 2 shows claude-code can't make tool calls through LiteLLM (tool schema/format not translated), stand up a purpose-built claude-code→OpenAI proxy instead (e.g. `claude-code-router` or `y-router`) pointed at the `code-cwb` ollama backend, and set `ANTHROPIC_BASE_URL` to it. Re-run Step 2 against the proxy. Document which path was used in the PR.

- [ ] **Step 4: Commit any gateway change**
```bash
cd /home/operator/src/carriedworld-cloud
git add hosting/services/litellm.yaml && git commit -m "feat(model-stack): expose code-cwb via Anthropic /v1/messages for claude-code"
```
(Skip if no litellm.yaml change was needed.)

### Task A2: code-cwb builder bootstrap

**Files:** broker provider-binding store (set via `PUT /api/admin/aspects/{name}/provider-binding`) — no code change, configuration only.

- [ ] **Step 1: Pick/confirm a throwaway builder aspect name**

Use a disposable aspect (e.g. `test-keel` already exists, or mint a `cwbtest` aspect). Confirm it exists:
```bash
ssh jacinta@100.91.185.71 'curl -sk https://10.43.138.250:7888/api/admin/aspects/test-keel/provider-binding'
```
Expected: a binding JSON (or 404 → mint one with `nexus aspect mint`).

- [ ] **Step 2: Bind it to claude-code + the code-cwb shim**

The aspect needs: provider `claude-code`, model `code-cwb`, and `ANTHROPIC_BASE_URL`=the shim + dummy key in its provider env (via the credential/binding mechanism in `nexus/broker/validate_endpoint.go`). Set the binding:
```bash
echo '{"provider":"claude-code","model":"code-cwb"}' | \
  ssh jacinta@100.91.185.71 'curl -sk -X PUT https://10.43.138.250:7888/api/admin/aspects/test-keel/provider-binding -H "Content-Type: application/json" --data @-'
```
The `ANTHROPIC_BASE_URL`/dummy-key + `--append-system-prompt` of the dev-standards is set via the launch env / funnel SystemPrompt — confirm in `nexus/autospawn` childEnv + `nexus/frame/funnel` how the aspect's provider env + SystemPrompt are sourced, and set the aspect's SystemPrompt to the dev-standards block (`tools/model-tune/dev_standards.txt` content).

- [ ] **Step 3: Verify the builder runs one turn through code-cwb**

Dispatch a trivial chat ("reply OK") to the aspect and confirm it responds via `code-cwb` (check the activity/session log shows the turn completed through the shim). Expected: a completed turn, model=code-cwb in the trace.

### Task A3: WARMUP — go/no-go on agentic capability

- [ ] **Step 1: Hand code-cwb a throwaway agentic build task**

In a scratch git repo/branch, dispatch the builder aspect a small task:
> "In package `scratch`, add `func MustEnv(key string) string` that returns the env var or panics with a wrapped message naming the key. Add a table-driven test `TestMustEnv`. Run `go test ./...` and make it pass."

- [ ] **Step 2: Judge — can it drive the agentic loop?**

PASS criteria: code-cwb uses tools to read context, write the file + test, run `go test`, and iterate to green — producing a correct, applied change (not just emitting a code blob).

- [ ] **Step 3: Record the verdict (the real finding)**

- **PASS** → proceed to Phase B.
- **FAIL** (can't drive tools / loops / never converges) → **STOP Phase B.** Record in `tools/model-tune/eval-results/` + the cobalt memory: *code-cwb is a single-shot codegen lane (use as Opus-decomposes → code-cwb-emits-each-function); agentic building stays with a frontier model.* This is a legitimate outcome — the experiment answered its question. Commit the finding; the wiring (A1/A2) remains useful for the single-shot lane.

---

## PHASE B — code-cwb builds the extension (gated on A3 PASS)

### Task B1: Dispatch the extension build to code-cwb

This is a **dispatch brief** — intent, constraints, DoD. Do **not** hand code-cwb exact Go signatures (over-specifying injects bugs). Paste this brief (plus the canonical dev-standards block from `reference_dev_standards` / `nexus/docs/2026-05-17-developer-standards.md`) to the code-cwb builder:

> **Ticket: per-aspect system-prompt mode control (append|replace).**
> **Why:** agentfunnel must be able to, per aspect, either *append* our standards to claude-code's base prompt (frontier default, preserves tool guidance) or *replace* it with a custom prompt (local lane, full control). Today it only appends.
> **What:**
> - Add a per-aspect `prompt_mode` with values `append` (default) and `replace`, stored + served the same way provider/model are (the broker provider-binding: store column/field, the `GET`/`PUT /api/admin/aspects/{name}/provider-binding` surface in `nexus/broker/admin_provider_binding.go`, and the `nexus aspect set` CLI in `nexus/cmd/nexus`). Default `append` must preserve today's exact behavior.
> - Thread `prompt_mode` from the broker → `nexus/frame/funnel` (Config) → the bridle `provider/claudecode` construction site, so the launched `claude -p` gets `--append-system-prompt <SystemPrompt>` when `append`, or `--system-prompt-file <tmpfile>` (content = the same composed `SystemPrompt`) when `replace`. (bridle is `github.com/CarriedWorldUniverse/bridle`, a separate module — its `provider/claudecode` builds the `claude -p` argv; you'll touch both repos.)
> **DoD:** unit tests for the store field + the flag-selection logic; an aspect set to `replace` launches `claude -p` with `--system-prompt-file`, `append` with `--append-system-prompt`; default-unset = `append` = unchanged behavior; CI green; single-ticket PR(s) per repo; rebased on main.
> **Standards:** [paste the canonical dev-standards block].

- [ ] **Step 1:** Dispatch the brief to the code-cwb builder aspect; capture branch + PR URL(s).
- [ ] **Step 2:** Let it work; do not micro-manage. Note how far it gets (single-repo? cross-repo? converges?).

### Task B2: shadow review + validate + graceful-degrade

- [ ] **Step 1: Review the PR(s)** as shadow (standard review — correctness, scope, the `prompt_mode` default-append-preserves-behavior invariant, tests, CI green).

- [ ] **Step 2: Validate end-to-end**

Set a throwaway aspect to `replace`, launch a turn, and confirm the spawned `claude -p` argv contains `--system-prompt-file` (check the process/launch log); set it to `append`, confirm `--append-system-prompt`. Default-unset aspect: unchanged.

- [ ] **Step 3: Graceful-degrade + record the experiment outcome**

If code-cwb couldn't complete the cross-repo build (likely-plausible for a single-shot-tuned model): shadow finishes the remaining part, and record *how far code-cwb got* (which repo/files, where it stalled) in the cobalt memory + `eval-results/`. The finding (the local builder's real agentic reach on a cross-repo Go change) is the point. Merge the completed extension; restore any throwaway aspect's binding.

---

## Self-review

**Spec coverage:** ① shim → A1; ② builder bootstrap → A2; ③ warmup go/no-go → A3; ④ extension (prompt_mode append|replace, broker store + funnel + bridle claudecode, default append) → B1 brief; ⑤ shadow review + validate → B2; append-safe/replace-deferred-for-local → honored (B builds both modes; local adoption of `replace` is out of scope per the spec); the build-vs-wiring split → Phase A (shadow) vs Phase B (code-cwb); cross-repo risk → called out + B2 graceful-degrade. Covered.

**Placeholder scan:** Phase A steps have concrete commands + expected output. Phase B is intentionally a brief (not TDD steps) per "brief intent not implementation" — that's by design for a dispatched build, not a placeholder; the brief's DoD is concrete. The credential/SystemPrompt sourcing in A2 Step 2 says "confirm in autospawn/funnel how it's sourced" — that's a real read-the-code step, not a hand-wave (the mechanism exists; the exact field is read at execution).

**Consistency:** `prompt_mode` (`append`|`replace`), `code-cwb`, the shim (`/v1/messages` + ANTHROPIC_BASE_URL), and the broker provider-binding pattern are named consistently across A1–B2. `--append-system-prompt` / `--system-prompt-file` match the claude-code capability confirmed in the spec.
