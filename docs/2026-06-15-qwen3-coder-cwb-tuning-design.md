# qwen3-coder CWB Tuning — Design

**Status:** Draft for review · **Date:** 2026-06-15 · **Author:** shadow
**Goal:** LoRA-tune `qwen3-coder:30b` into a code model fluent in *how we build the personal cloud* — our practices, conventions, and the dispatch→implement workflow — and serve it back through the local model stack for A/B against the stock base.

---

## 1. Context & motivation

The onyx-kestrel bench picked `qwen3-coder:30b` as the local `code` lane (3/3 objective Go tasks @ ~9s; live in the LiteLLM gateway). With the base chosen, the high-ROI next step is tuning it to *our actual work* — the lever that adds capability for GPU-hours instead of dollars, given there is no 2nd DGX coming.

This is the **first round**: an experiment to prove tuning moves the needle, not a production pipeline.

## 2. Objective — what "tuned" means

The objective is **not API-knowledge injection**. Exact-API correctness is handled elsewhere in the pipeline:

- **Opus does the decomposition** — the frontier model breaks work into tasks and carries the architecture + relevant API context into each brief.
- **CI/CD (lint + test)** enforces correctness downstream — wrong API usage is caught and iterated against.

So the tuned `qwen3-coder` is the **builder inside our environment**. Tuning should make it fluent in:

- our **conventions & idioms** — error handling, file layout, naming, test/conformance style;
- the **dispatch-brief → implementation workflow** (single-ticket PRs, rebase, no dead code, CI-green-before-review — the dispatch dev-standards);
- the **contours of how the system fits** (herald auth, interchange gateway, the pillars, dispatch/runner) as expressed in our code.

This makes **LoRA the right tool**: it is strong at style/behaviour/workflow adaptation and weak at fact-injection — and we have deliberately put facts on CI + Opus, not the model.

## 3. Scope

**In scope (round one):**
- Cloud-first: the Go CWB codebase only.
- A single bf16-LoRA training run (recipe may iterate a couple of times).
- Eval against an extended bench + a hands-on read.
- Serving the result as a *separate* ollama tag for A/B.

**Out of scope (deferred):**
- WakeStone (C#/Unity) — a *separate* adapter later, once its corpus is available; not mixed into this run.
- A production/repeatable pipeline (scheduled re-tunes, data refresh, versioned adapter releases) — only if round one clearly moves the needle.
- API-knowledge injection / continued-pretraining / RAG.
- Promoting the tuned model to the live `code` lane — that is a separate decision after eval.

## 4. Architecture

A small, mostly-offline pipeline of five standalone stages, each producing an artifact the next consumes. Lives in **`carriedworld-cloud/tools/model-tune/`** (alongside `tools/model-bench/`): scripts + configs + README. Training executes on **robo-dog (GB10)** over ssh; artifacts land on the GB10 NVMe.

```
repos + jira ──▶ ① corpus ──▶ ② dataset (JSONL) ──▶ ③ LoRA adapter
                                                          │
                              ⑤ eval (base vs tuned) ◀── ④ merged GGUF in ollama
```

### Stage ① — Corpus extract
- **Responsibility:** gather the raw training material, filtered to *our-authored* code.
- **Inputs:** the local CWB Go repos (~212k LOC gross); the ~70–80 NEX-tagged commits; jira ticket bodies (via the jira MCP / API).
- **Filtering (important):** exclude cairn's upstream git-hosting tree, `vendor/`, and generated `*.pb.go`. These would teach upstream/generated boilerplate, not our style.
- **Outputs:** (a) a tree of our-authored Go files; (b) a list of `(ticket-key, ticket-body, commit-diff)` triples for the NEX-tagged commits.

### Stage ② — Dataset build
- **Responsibility:** emit SFT examples in chat format.
- **Format per example:** `system` = the dispatch dev-standards (our practices, verbatim from `reference_dev_standards`); `user` = a task/brief; `assistant` = our actual implementation.
- **Two sources:**
  - **Real pairs** — `ticket-body → diff/files-changed` from the Stage ① triples.
  - **Synthesized pairs** — for our functions/files, a *strong model (Opus)* writes the "implement this" brief; the **real code is the gold target**. This scales volume past the ~70–80 real tickets while preserving the brief→our-build behaviour. Synthesis quality matters, so the generator is the frontier model (one-time cost).
- **Outputs:** `train.jsonl` + `val.jsonl` (held-out split; val never seen in training).

### Stage ③ — Train
- **Responsibility:** produce the LoRA adapter.
- **Method:** **bf16 LoRA** (no 4-bit). The GB10's 128 GB unified memory holds the 30B in bf16 with room for LoRA + optimizer + activations, so we avoid 4-bit/bitsandbytes entirely — sidestepping the worst aarch64/Blackwell risk.
- **Base:** the **HF safetensors** `Qwen/Qwen3-Coder-30B-A3B-Instruct` (~60 GB) — the served GGUF cannot be trained on. Must match the variant we serve.
- **Stack:** PyTorch **cu130 / aarch64** + PEFT + TRL + datasets, stood up on the GB10. The very first implementation task validates the stack with a 1-step smoke train before any real run. Fallback: the NGC PyTorch ARM container, or torchtune.
- **Config (starting point, may iterate):** LoRA on attention + MLP projections; modest rank (≈16–32); a few epochs; packed sequences. Kept light to avoid small-data overfitting.
- **Outputs:** a LoRA adapter on the GB10 NVMe.

### Stage ④ — Merge + serve
- **Responsibility:** make the tuned model servable for A/B.
- **Steps:** merge adapter → base; convert to **GGUF** at the **same quant** we serve `qwen3-coder` at; load into ollama as a **separate tag** (e.g. `qwen3-coder-cwb`); add a gateway lane for it.
- **Constraint:** the live `code` lane stays on stock `qwen3-coder` — no disruption until eval convinces us.

### Stage ⑤ — Eval
- **Responsibility:** decide whether tuning moved the needle.
- **Extends `bench.py`** with three checks, base vs tuned:
  - **(a) No-regression:** the existing objective Go tasks must still pass **3/3** (catastrophic-forgetting guard).
  - **(b) CWB-style tasks:** new "implement-from-brief" tasks, judged for our conventions/structure (does it build the way we build?).
  - **(c) Hands-on read:** a sample for the operator's judgment.

## 5. Data flow

`repos + jira` → `corpus tree + NEX triples` → `train/val JSONL` → `LoRA adapter` → `merged GGUF (ollama tag qwen3-coder-cwb)` → `eval comparison report`.

## 6. Hardware decisions

- **Training must be on the GB10.** The dMon RTX 5090 is a 24 GB Laptop GPU — too small for a 30B (needs ~30–40 GB+). The GB10's 128 GB is the only place this fits.
- **bf16, not 4-bit** — enabled by the 128 GB; removes the bitsandbytes/aarch64 dependency.
- **Serving contention:** the GB10 currently serves the `code` lane via ollama; a training run pauses or scales-down serving for its duration. Acceptable for an experiment (the lane is new and A/B-only). Scale ollama back up after the run.
- **CUDA 13.0 + driver 580** already present on the GB10; Python 3.12. No torch yet — Stage ③ installs it.

## 7. Success criteria

Round one **"moves the needle"** when the tuned model produces **visibly more our-style output on the CWB-style tasks without regressing correctness** (still 3/3 on the objective tasks) and the operator's hands-on read agrees. That outcome justifies considering a production pipeline; absence of lift ends the experiment cheaply (or motivates a data/recipe iteration).

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| cu130-aarch64 / Blackwell (sm_121) training stack may not "just work" | First implementation task is a 1-step smoke train; fallback to NGC PyTorch ARM container / torchtune |
| Modest data volume → modest lift | Synthesize pairs from our code to scale; calibrate expectations (style/idiom shift, not a capability leap); iterate the recipe |
| Synthesis quality | Use the frontier model (Opus) as the brief generator; spot-check a sample |
| Small-data overfitting / catastrophic forgetting | Modest LoRA rank + few epochs + held-out val + the no-regression bench gate |
| MoE GGUF conversion of the merged model | Validate the convert+quantize path on the merged model before relying on it; keep the base tag intact |
| Training disrupts the live code lane | Separate ollama tag for the tuned model; schedule the run; restore serving after |

## 9. Open decisions (carried into the plan)

- Exact LoRA target modules for the A3B MoE (attention-only vs include router/shared) — settled during the smoke-train task.
- Final synthesized-pair count and the real:synth ratio — tuned to the validated stack throughput.
- The specific CWB-style eval tasks — drafted alongside the bench extension.
