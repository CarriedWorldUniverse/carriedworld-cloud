# agentfunnel build — system-prompt-control via the tuned local builder — Design

**Status:** Draft for review · **Date:** 2026-06-16 · **Author:** shadow
**Goal:** Stand up the tuned local model (`code-cwb`) as an agentfunnel builder and use it to build agentfunnel's first ecosystem extension — **per-aspect system-prompt mode control** (append vs replace) — closing the dogfood loop where the local builder builds the tooling that makes itself a better builder.

**Spec for:** the implementation plan that follows. Tech: nexus (Go — funnel + bridle `claudecode` provider + broker provider-binding), LiteLLM gateway, claude-code CLI, ollama (`qwen3-coder-cwb` Q4, live).

---

## 1. Context & motivation

The onyx-kestrel tune produced `code-cwb` (qwen3-coder + CWB LoRA), now served via ollama + the gateway. Its eval verdict: it emits terse, code-only, our-style output (the dev-standard "output only the code, no commentary" is baked into the weights). The next step the operator wants is the **dogfood loop**: run `code-cwb` as an agentfunnel builder and have it build the extension agentfunnel needs for proper local-building — starting with **system-prompt control**.

This is also the first concrete slice of the broader "own the agentfunnel ecosystem" direction (rent the engine — claude-code — own the extensibility layer).

## 2. Key facts established (from exploration)

- agentfunnel runs builders as `claude -p` (claude-code headless) via the **bridle `claudecode` provider**; the funnel composes a `SystemPrompt` (persona, from NEXUS.md/SOUL.md/PRIMER.md) and has a `SystemPromptFn` for per-turn swapping.
- Per-aspect provider/model is a **runtime binding** in the broker store (set via `nexus aspect set --via` / `PUT /api/admin/aspects/{name}/provider-binding`). Provider env (`ANTHROPIC_BASE_URL`/`OPENAI_BASE_URL`) is injected per-aspect; the code already contemplates *"a DeepSeek-via-Anthropic-shape credential"* (claude pointed at a non-Anthropic backend).
- **claude-code supports full system-prompt replacement** (`--system-prompt` / `--system-prompt-file`) AND append (`--append-system-prompt`). Replacement strips claude-code's base **tool-use/agentic-workflow guidance** (the model still receives tool *schemas* via the API, but loses the how-to-drive-the-loop coaching). `code-cwb` was tuned for **single-shot brief→code, not agentic tool-use** — so replacement is risky for it; **append is the safe bootstrap.**

## 3. Scope

**In scope:**
- ① Anthropic-shim so claude-code can target `code-cwb`.
- ② `code-cwb` builder bootstrap (append-mode, interim).
- ③ A throwaway **warmup** build — go/no-go on whether `code-cwb` can drive the agentic loop at all.
- ④ The **per-aspect prompt-mode extension** (append|replace), built by `code-cwb` if ③ passes.
- ⑤ shadow review of the builder's PR + end-to-end validation.

**Out of scope (deferred):**
- A crafted tool-aware full-replace prompt for the local lane (local stays `append` until that exists; `replace` mode is built + available, just not adopted for local yet).
- Promoting `code-cwb` to a standing builder in the roster.
- Any graphical UI (CLI/agent-first).
- Broader ecosystem extensions (plugins/skills/MCP) beyond system-prompt control.

## 4. Architecture & who builds what

The wiring that *enables* the dogfood is built by shadow/Opus (a builder cannot bootstrap its own harness — chicken-and-egg). The **extension** is built by `code-cwb`.

### ① Anthropic-shim — *shadow builds*
LiteLLM exposes an Anthropic `/v1/messages` endpoint; claude-code is pointed at it via `ANTHROPIC_BASE_URL` with claude-code's model set to `code-cwb` (so LiteLLM routes `code-cwb` → ollama `qwen3-coder-cwb`) and a dummy `ANTHROPIC_API_KEY`. The plan **validates tool-use translation early** (claude-code is tool-heavy; the Anthropic→OpenAI tools mapping must hold). Fallback: a purpose-built claude-code→OpenAI proxy (e.g. claude-code-router) if LiteLLM's translation is inadequate.

### ② code-cwb builder bootstrap — *shadow builds*
A builder aspect bound to provider `claude-code`, with a credential supplying `ANTHROPIC_BASE_URL`=the shim + dummy key + model `code-cwb`, and the **dev-standards injected via `--append-system-prompt`** (through the funnel's existing SystemPrompt/append path). This is the interim prompt mechanism the extension later generalizes.

### ③ Warmup — *code-cwb attempts; go/no-go* — *shadow sets up + judges*
Dispatch `code-cwb` (as the builder) a small, throwaway task in a scratch target (e.g. "add `func MustEnv(key string) string` + a table-driven test to a throwaway package"). Purpose: test whether a single-shot-tuned model can drive claude-code's agentic loop (read files, call tools, edit, iterate) **at all**.
- **Pass** → proceed to ④.
- **Fail** → stop and record the finding: `code-cwb` is a *single-shot codegen lane* (use it as Opus-decomposes→code-cwb-emits-each-function), and the agentic builder role stays with a frontier model. This is a legitimate, valuable outcome — not a failure of the effort.

### ④ The extension — *code-cwb builds (if ③ passes)*
**Per-aspect `prompt_mode` (`append` | `replace`):**
- **Storage:** a new per-aspect field alongside the existing provider-binding (same broker store + admin-endpoint/CLI pattern as provider/model). Default `append` (preserves today's behavior).
- **Honored where claude-code is launched:** the funnel/bridle `claudecode` provider reads `prompt_mode` and passes claude-code **`--append-system-prompt <content>`** (append) or **`--system-prompt-file <path>`** (replace, content written to a temp file). Content is the funnel's existing composed `SystemPrompt`.
- **Likely spans** the funnel's claude-code-launch path + bridle's `claudecode` provider. If bridle is a separate repo, the change is cross-repo — the plan confirms bridle's location first (it raises the bar for code-cwb's first agentic build, which is part of the test).

### ⑤ Review + validate — *shadow*
Standard single-ticket-PR review (shadow as reviewer). Validate end-to-end (below).

## 5. Data flow

`aspect prompt_mode (store)` → broker injects into the funnel → funnel/bridle `claudecode` provider selects the flag → `claude -p --append-system-prompt|--system-prompt-file <SystemPrompt>` → (for the local lane) `ANTHROPIC_BASE_URL` shim → LiteLLM `/v1/messages` → ollama `qwen3-coder-cwb`.

## 6. Success criteria

- **③ warmup:** `code-cwb` produces a correct change applied via the agentic loop — *or* a clear no-go finding (recorded; reshapes how code-cwb is used).
- **④ extension:** an aspect with `prompt_mode=replace` demonstrably launches `claude -p` with `--system-prompt-file`; `prompt_mode=append` with `--append-system-prompt`; default unchanged behavior preserved. PR reviewed + merged. The build was authored by `code-cwb` (the dogfood is real, not shadow-ghostwritten).

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| code-cwb can't drive the agentic loop (single-shot-tuned) | ③ warmup is the explicit gate; a no-go is a valid finding (code-cwb = single-shot lane) |
| LiteLLM `/v1/messages` tool-translation inadequate for claude-code | Validate early; fall back to a purpose-built claude-code→OpenAI proxy |
| Extension is cross-repo (funnel + separate bridle) | Confirm bridle's location first; if cross-repo, consider it part of ③'s difficulty signal — may scope the build to the funnel side first |
| Full-replace strips tool guidance → broken builder | Local lane stays `append`; `replace` mode is built + available but not adopted for local until a tool-aware full prompt is crafted (out of scope here) |
| code-cwb's terseness-overshoot (drops fences/imports) hurts agentic edits | The warmup surfaces this directly; tool-use is structured (the model edits via tools, not fenced blocks), so it may be a non-issue — the warmup tells us |

## 8. Open questions (resolved in the plan)

- bridle's exact location (in-nexus vs separate repo) and how its `claudecode` provider currently passes the system prompt flag.
- LiteLLM `/v1/messages` config specifics + the model-name mapping claude-code↔`code-cwb`.
- Whether claude-code on the shim needs any auth/header coaxing beyond a dummy key.
