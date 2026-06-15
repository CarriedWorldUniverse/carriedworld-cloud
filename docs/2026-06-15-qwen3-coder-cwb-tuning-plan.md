# qwen3-coder CWB Tuning — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `tools/model-tune/` pipeline that LoRA-tunes `qwen3-coder:30b` on our Go CWB codebase for builder-fluency, and serve the result as a separate ollama tag for A/B against the stock base.

**Architecture:** A five-stage offline pipeline — extract our-authored Go + commit pairs → build SFT chat JSONL (real + LLM-synthesized) → bf16 LoRA train on the GB10 → merge + GGUF + ollama tag → eval (no-regression bench + CWB-style judged tasks). Pure-logic stages are TDD'd with pytest; GPU/integration stages are validated by explicit runs with asserted output.

**Tech Stack:** Python 3.12, pytest; PyTorch cu130-aarch64 + transformers + PEFT + TRL + datasets (on the GB10); llama.cpp (GGUF convert/quantize); ollama; the existing `tools/model-bench/bench.py` harness.

**Spec:** `carriedworld-cloud/docs/2026-06-15-qwen3-coder-cwb-tuning-design.md`

---

## Run locations (important)

| Stage | Where it runs | Why |
|---|---|---|
| Tasks 2–3 (extract, dataset) | a checkout host with the repos (`/home/operator/src`) | needs the Go repos; CPU-only |
| Tasks 1, 4, 5 (env, train, merge/export) | **GB10 / robo-dog** `ssh jacinta@100.92.111.3` | the only box with enough memory for a 30B + the GPU |
| Task 6 (eval) | any host that can reach the gateway `http://100.91.185.71:4000` | hits models over the OpenAI API |

Datasets built in Tasks 2–3 are copied to the GB10 with `scp dataset/*.jsonl jacinta@100.92.111.3:~/model-tune/dataset/` before Task 4.

All work happens on a branch off `carriedworld-cloud` main: `feature/model-tune-qwen3-coder`. Commit after each task.

## File structure

```
tools/model-tune/
  README.md              # how to run the pipeline end-to-end
  dev_standards.txt      # the SFT system prompt (distilled code-style standards)
  extract_corpus.py      # Stage ①: our-authored Go funcs + commit pairs  → corpus/*.jsonl
  build_dataset.py       # Stage ②: SFT chat JSONL (real + synthesized)    → dataset/*.jsonl
  llm_client.py          # tiny OpenAI-compatible client (used by build_dataset + eval)
  setup_gb10_env.sh      # Stage ③ prep: create the cu130-aarch64 venv on the GB10
  smoke_train.py         # Task 1: 1-step LoRA train to validate the stack
  train_lora.py          # Stage ③: the real bf16 LoRA run
  merge_and_export.py    # Stage ④: merge adapter → GGUF → ollama tag
  eval_cwb.py            # Stage ⑤: CWB-style judged eval, base vs tuned
  tests/
    test_extract_corpus.py
    test_build_dataset.py
    test_eval_cwb.py
```

`tools/model-bench/bench.py` is reused unchanged for the no-regression check (run it pointed at both ollama tags).

---

## Task 1: Validate the cu130-aarch64 training stack (smoke train)

**This is first because it is the biggest unknown** — if PyTorch + PEFT + TRL don't run on the GB10's aarch64 / Blackwell sm_121, the whole approach changes. Runs on the GB10.

**Files:**
- Create: `tools/model-tune/setup_gb10_env.sh`
- Create: `tools/model-tune/smoke_train.py`

- [ ] **Step 1: Write the env bootstrap script**

`tools/model-tune/setup_gb10_env.sh`:
```bash
#!/usr/bin/env bash
# Stand up the LoRA training venv on the GB10 (aarch64, CUDA 13.0).
# Primary path: pip cu130 wheels. If torch.cuda is False after this, fall back to
# the NGC PyTorch ARM container (see README "Fallback").
set -euo pipefail
cd "$HOME/model-tune"
python3 -m venv .venv
. .venv/bin/activate
pip install --upgrade pip
# cu130 aarch64 (sbsa) wheels:
pip install torch --index-url https://download.pytorch.org/whl/cu130
pip install "transformers>=4.46" "peft>=0.13" "trl>=0.12" "datasets>=3.0" "accelerate>=1.0"
python -c "import torch; print('torch', torch.__version__, 'cuda', torch.cuda.is_available(), torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'NO-CUDA')"
```

- [ ] **Step 2: Run the env bootstrap and verify CUDA is visible**

```bash
scp tools/model-tune/setup_gb10_env.sh jacinta@100.92.111.3:~/model-tune/
ssh jacinta@100.92.111.3 'cd ~/model-tune && bash setup_gb10_env.sh'
```
Expected last line: `torch 2.x.x+cu130 cuda True NVIDIA GB10`.
If `cuda False`: stop, switch to the NGC container fallback documented in README Step (Task 7), and re-run this step inside the container.

- [ ] **Step 3: Write the smoke-train script (tiny model, full stack exercise)**

`tools/model-tune/smoke_train.py`:
```python
#!/usr/bin/env python3
"""Prove the training stack end-to-end on the GB10 with a tiny model:
load -> attach LoRA -> one forward/backward/optimizer step on the GPU.
Exits 0 with a finite loss, non-zero otherwise. Uses a small Qwen to keep it fast."""
import sys, torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import LoraConfig, get_peft_model

MODEL = "Qwen/Qwen2.5-0.5B-Instruct"  # tiny; same family tooling as the 30B target

def main():
    assert torch.cuda.is_available(), "CUDA not available on the GB10"
    tok = AutoTokenizer.from_pretrained(MODEL)
    model = AutoModelForCausalLM.from_pretrained(MODEL, torch_dtype=torch.bfloat16).to("cuda")
    model = get_peft_model(model, LoraConfig(
        r=8, lora_alpha=16, lora_dropout=0.0,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj"]))
    model.train()
    batch = tok(["func Add(a, b int) int { return a + b }"], return_tensors="pt").to("cuda")
    batch["labels"] = batch["input_ids"].clone()
    opt = torch.optim.AdamW(model.parameters(), lr=1e-4)
    loss = model(**batch).loss
    loss.backward(); opt.step(); opt.zero_grad()
    assert torch.isfinite(loss), f"non-finite loss {loss}"
    print(f"SMOKE-OK loss={loss.item():.4f}")

if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the smoke train and verify it passes**

```bash
scp tools/model-tune/smoke_train.py jacinta@100.92.111.3:~/model-tune/
ssh jacinta@100.92.111.3 'cd ~/model-tune && .venv/bin/python smoke_train.py'
```
Expected: a line `SMOKE-OK loss=<finite-number>` and exit 0. This proves transformers + PEFT + autograd + AdamW all run on the GB10 GPU. If it fails, capture the traceback — this gates everything downstream.

- [ ] **Step 5: Commit**

```bash
git add tools/model-tune/setup_gb10_env.sh tools/model-tune/smoke_train.py
git commit -m "feat(model-tune): GB10 cu130-aarch64 training-stack smoke test"
```

---

## Task 2: Corpus extraction

Walk our-authored Go and emit (a) top-level functions for synthesis and (b) commit pairs. Pure logic — TDD. Runs on the checkout host.

**Files:**
- Create: `tools/model-tune/extract_corpus.py`
- Test: `tools/model-tune/tests/test_extract_corpus.py`

- [ ] **Step 1: Write the failing test**

`tools/model-tune/tests/test_extract_corpus.py`:
```python
from tools.model_tune.extract_corpus import is_ours, top_level_funcs

def test_is_ours_excludes_generated_vendor_and_cairn():
    assert is_ours("herald/internal/identity/roles.go")
    assert not is_ours("herald/internal/foo.pb.go")        # generated
    assert not is_ours("nexus/vendor/x/y.go")              # vendored
    assert not is_ours("cairn/server/web.go")              # upstream repo
    assert is_ours("cw/internal/cli/tenant/tenant_test.go")  # keep tests (our test style)

def test_top_level_funcs_extracts_whole_func_bodies():
    src = (
        "package x\n\n"
        "func Add(a, b int) int {\n\treturn a + b\n}\n\n"
        "func Sub(a, b int) int {\n\tif a > b {\n\t\treturn a - b\n\t}\n\treturn b - a\n}\n"
    )
    funcs = top_level_funcs(src)
    names = {f["name"] for f in funcs}
    assert names == {"Add", "Sub"}
    add = next(f for f in funcs if f["name"] == "Add")
    assert add["code"].strip().endswith("}")
    assert "return a + b" in add["code"]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /home/operator/src && python -m pytest carriedworld-cloud/tools/model-tune/tests/test_extract_corpus.py -v`
(Add `carriedworld-cloud` to `sys.path` via a `conftest.py` — see Step 3.)
Expected: FAIL with `ModuleNotFoundError: tools.model_tune.extract_corpus`.

- [ ] **Step 3: Write the implementation**

`tools/model-tune/tests/conftest.py`:
```python
import sys, os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..")))
# makes `carriedworld-cloud/` importable as the package root: tools.model_tune.*
```
Note: rename the dir reference for import — Python packages can't have hyphens. Add empty `__init__.py` to `tools/`, `tools/model-tune/` is imported via a symlink-free path; to keep it simple, the scripts are run as files (`python extract_corpus.py`) and tests import by file path. Replace the test import lines with:
```python
import importlib.util, pathlib
def _load(name):
    p = pathlib.Path(__file__).parent.parent / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
ec = _load("extract_corpus")
is_ours, top_level_funcs = ec.is_ours, ec.top_level_funcs
```
(Apply the same `_load` pattern in the other test files. This avoids the hyphen-in-package problem.)

`tools/model-tune/extract_corpus.py`:
```python
#!/usr/bin/env python3
"""Stage ①: extract our-authored Go functions + commit pairs.
Outputs corpus/funcs.jsonl ({repo,path,name,code}) and corpus/real_pairs.jsonl
({brief,diff}). Run from the directory holding the repo checkouts."""
import argparse, json, os, re, subprocess

EXCLUDE_REPOS = {"cairn"}  # upstream git-hosting tree, not our style

def is_ours(path: str) -> bool:
    p = path.replace("\\", "/")
    if p.split("/", 1)[0] in EXCLUDE_REPOS:
        return False
    if "/vendor/" in p or p.startswith("vendor/"):
        return False
    if p.endswith(".pb.go") or p.endswith(".gen.go") or "_generated" in p:
        return False
    return p.endswith(".go")

def top_level_funcs(src: str):
    """Return [{name, code}] for top-level `func` decls via brace matching."""
    out = []
    for m in re.finditer(r"(?m)^func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)\s*\(", src):
        name = m.group(1)
        brace = src.find("{", m.end() - 1)
        if brace == -1:
            continue
        depth, i = 0, brace
        while i < len(src):
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
                if depth == 0:
                    out.append({"name": name, "code": src[m.start():i + 1]})
                    break
            i += 1
    return out

def iter_go_files(roots):
    for root in roots:
        for dirpath, _, files in os.walk(root):
            for f in files:
                full = os.path.join(dirpath, f)
                rel = os.path.relpath(full, ".")
                if is_ours(rel):
                    yield rel, full

def real_pairs(repo):
    """(commit subject+body, .go diff) for substantive commits in `repo`."""
    shas = subprocess.run(["git", "-C", repo, "log", "--no-merges", "--format=%H"],
                          capture_output=True, text=True).stdout.split()
    for sha in shas:
        msg = subprocess.run(["git", "-C", repo, "log", "-1", "--format=%s%n%n%b", sha],
                             capture_output=True, text=True).stdout.strip()
        diff = subprocess.run(["git", "-C", repo, "show", sha, "--", "*.go"],
                              capture_output=True, text=True).stdout
        if len(diff) < 80 or len(diff) > 16000:  # skip trivial / huge
            continue
        yield {"brief": msg, "diff": diff}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repos", nargs="+", required=True)
    ap.add_argument("--out", default="corpus")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "funcs.jsonl"), "w") as fh:
        for rel, full in iter_go_files(a.repos):
            src = open(full, errors="ignore").read()
            repo = rel.split("/", 1)[0]
            for fn in top_level_funcs(src):
                if 60 <= len(fn["code"]) <= 4000:  # train-worthy size band
                    fh.write(json.dumps({"repo": repo, "path": rel, **fn}) + "\n")
    with open(os.path.join(a.out, "real_pairs.jsonl"), "w") as fh:
        for repo in a.repos:
            if os.path.isdir(os.path.join(repo, ".git")):
                for pair in real_pairs(repo):
                    fh.write(json.dumps(pair) + "\n")

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/operator/src && python -m pytest carriedworld-cloud/tools/model-tune/tests/test_extract_corpus.py -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the extractor for real and sanity-check counts**

```bash
cd /home/operator/src
python carriedworld-cloud/tools/model-tune/extract_corpus.py \
  --repos nexus herald cw cwb-conformance interchange ledger commonplace custodian atlas mason porter cwb-client almanac lynxai \
  --out carriedworld-cloud/tools/model-tune/corpus
wc -l carriedworld-cloud/tools/model-tune/corpus/*.jsonl
```
Expected: `funcs.jsonl` in the low-thousands of lines; `real_pairs.jsonl` a few hundred. (cairn deliberately omitted from `--repos`.)

- [ ] **Step 6: Commit**

```bash
git add tools/model-tune/extract_corpus.py tools/model-tune/tests/test_extract_corpus.py tools/model-tune/tests/conftest.py
git commit -m "feat(model-tune): corpus extraction (our-authored Go funcs + commit pairs)"
```
(Do not commit `corpus/` — add `tools/model-tune/corpus/` and `tools/model-tune/dataset/` to `tools/model-tune/.gitignore`.)

---

## Task 3: Dataset build (SFT chat JSONL)

Turn the corpus into chat-format SFT examples. Pure logic + an LLM call (mocked in tests). Runs on the checkout host.

**Files:**
- Create: `tools/model-tune/dev_standards.txt`
- Create: `tools/model-tune/llm_client.py`
- Create: `tools/model-tune/build_dataset.py`
- Test: `tools/model-tune/tests/test_build_dataset.py`

- [ ] **Step 1: Write the SFT system prompt**

`tools/model-tune/dev_standards.txt` (distilled, code-relevant subset of the dispatch dev-standards):
```
You are a CarriedWorld (CWB) builder. Write Go that matches our standards:
- Scope: make one focused change; do not add unrelated helpers or refactors.
- Tests: new code paths get tests — especially HTTP handlers, gRPC/WS handlers, and DB writes.
- No dead code: never introduce helpers, types, or fields with zero callers.
- Errors: wrap with context (fmt.Errorf("...: %w", err)); fail closed on auth/security paths.
- Style: idiomatic Go, small focused files, clear names; match the surrounding package.
- Output only the code requested, no commentary.
```

- [ ] **Step 2: Write the LLM client (used by synthesis + eval)**

`tools/model-tune/llm_client.py`:
```python
#!/usr/bin/env python3
"""Minimal OpenAI-compatible chat client. Defaults to the local gateway."""
import json, urllib.request

DEFAULT_BASE = "http://100.91.185.71:4000/v1"  # LiteLLM gateway (dMon tailnet)

def chat(messages, model, base=DEFAULT_BASE, temperature=0.2, timeout=600, api_key="ollama"):
    body = json.dumps({"model": model, "temperature": temperature, "messages": messages}).encode()
    req = urllib.request.Request(base.rstrip("/") + "/chat/completions", data=body,
                                 headers={"Content-Type": "application/json",
                                          "Authorization": f"Bearer {api_key}"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)["choices"][0]["message"]["content"]
```

- [ ] **Step 3: Write the failing test**

`tools/model-tune/tests/test_build_dataset.py`:
```python
import json, pathlib, importlib.util
def _load(name):
    p = pathlib.Path(__file__).parent.parent / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
bd = _load("build_dataset")

def test_to_example_builds_chat_triple():
    ex = bd.to_example("system std", "implement Add", "func Add(a,b int) int { return a+b }")
    assert ex["messages"][0] == {"role": "system", "content": "system std"}
    assert ex["messages"][1]["role"] == "user" and "implement Add" in ex["messages"][1]["content"]
    assert ex["messages"][2]["role"] == "assistant" and "func Add" in ex["messages"][2]["content"]

def test_synth_brief_uses_injected_client():
    calls = {}
    def fake_chat(messages, model, **kw):
        calls["model"] = model
        return "Implement a function that adds two ints."
    brief = bd.synth_brief({"name": "Add", "code": "func Add(a,b int) int { return a+b }"},
                           chat_fn=fake_chat, model="code")
    assert "adds two ints" in brief
    assert calls["model"] == "code"

def test_split_is_deterministic_and_disjoint():
    items = [{"messages": [{"role": "user", "content": str(i)}]} for i in range(100)]
    tr, va = bd.split(items, val_frac=0.1, seed=0)
    assert len(va) == 10 and len(tr) == 90
    seen = {json.dumps(x) for x in tr}
    assert all(json.dumps(x) not in seen for x in va)
```

- [ ] **Step 4: Run it to verify it fails**

Run: `cd /home/operator/src && python -m pytest carriedworld-cloud/tools/model-tune/tests/test_build_dataset.py -v`
Expected: FAIL with `module ... has no attribute 'to_example'`.

- [ ] **Step 5: Write the implementation**

`tools/model-tune/build_dataset.py`:
```python
#!/usr/bin/env python3
"""Stage ②: build SFT chat JSONL from corpus/funcs.jsonl (+ real_pairs.jsonl).
Synthesized briefs come from an OpenAI-compatible model (default: local gateway
`code` lane; pass --model/--base to use a stronger one if available)."""
import argparse, json, os, random
from llm_client import chat as default_chat, DEFAULT_BASE

SYNTH_PROMPT = ("Given this Go function, write a one-paragraph task brief that an engineer "
                "could follow to produce it — describe the behavior and the signature, but "
                "DO NOT include the implementation. Function:\n\n```go\n{code}\n```")

def to_example(system, user, assistant):
    return {"messages": [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
        {"role": "assistant", "content": assistant}]}

def synth_brief(func, chat_fn=default_chat, model="code", base=DEFAULT_BASE):
    msg = [{"role": "user", "content": SYNTH_PROMPT.format(code=func["code"])}]
    return chat_fn(msg, model=model, base=base).strip()

def split(items, val_frac=0.1, seed=0):
    items = list(items)
    random.Random(seed).shuffle(items)
    n = max(1, int(len(items) * val_frac))
    return items[n:], items[:n]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default="corpus")
    ap.add_argument("--out", default="dataset")
    ap.add_argument("--model", default="code")
    ap.add_argument("--base", default=DEFAULT_BASE)
    ap.add_argument("--max-synth", type=int, default=800)
    ap.add_argument("--max-real", type=int, default=200)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    system = open(os.path.join(os.path.dirname(__file__), "dev_standards.txt")).read().strip()

    funcs = [json.loads(l) for l in open(os.path.join(a.corpus, "funcs.jsonl"))]
    random.Random(0).shuffle(funcs)
    examples = []
    for fn in funcs[:a.max_synth]:
        try:
            examples.append(to_example(system, synth_brief(fn, model=a.model, base=a.base), fn["code"]))
        except Exception as e:
            print("synth skip:", e)
    rp_path = os.path.join(a.corpus, "real_pairs.jsonl")
    if os.path.exists(rp_path):
        for line in list(open(rp_path))[:a.max_real]:
            p = json.loads(line)
            examples.append(to_example(system, p["brief"], p["diff"]))

    tr, va = split(examples, val_frac=0.1, seed=0)
    for name, rows in (("train", tr), ("val", va)):
        with open(os.path.join(a.out, f"{name}.jsonl"), "w") as fh:
            for r in rows:
                fh.write(json.dumps(r) + "\n")
    print(f"train={len(tr)} val={len(va)}")

if __name__ == "__main__":
    main()
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd /home/operator/src && python -m pytest carriedworld-cloud/tools/model-tune/tests/test_build_dataset.py -v`
Expected: PASS (3 tests).

- [ ] **Step 7: Build the real dataset and copy it to the GB10**

```bash
cd /home/operator/src/carriedworld-cloud/tools/model-tune
python build_dataset.py --model code --max-synth 800 --max-real 200
head -1 dataset/train.jsonl | python -m json.tool | head -20   # eyeball one example
ssh jacinta@100.92.111.3 'mkdir -p ~/model-tune/dataset'
scp dataset/train.jsonl dataset/val.jsonl jacinta@100.92.111.3:~/model-tune/dataset/
```
Expected: a `train=… val=…` count printed; one example shows system=dev-standards, user=brief, assistant=Go code.

- [ ] **Step 8: Commit**

```bash
git add tools/model-tune/dev_standards.txt tools/model-tune/llm_client.py tools/model-tune/build_dataset.py tools/model-tune/tests/test_build_dataset.py
git commit -m "feat(model-tune): SFT dataset build (synthesized + real chat pairs)"
```

---

## Task 4: LoRA training run

bf16 LoRA on the GB10 against the real base. Runs on the GB10. No unit test — validated by a tiny-subset run (loss must drop), then the full run.

**Files:**
- Create: `tools/model-tune/train_lora.py`

- [ ] **Step 1: Write the training script**

`tools/model-tune/train_lora.py`:
```python
#!/usr/bin/env python3
"""Stage ③: bf16 LoRA SFT of qwen3-coder on the GB10 (no quantization)."""
import argparse, torch
from datasets import load_dataset
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import LoraConfig
from trl import SFTConfig, SFTTrainer

BASE = "Qwen/Qwen3-Coder-30B-A3B-Instruct"
TARGETS = ["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="dataset")
    ap.add_argument("--out", default="adapter")
    ap.add_argument("--epochs", type=float, default=3.0)
    ap.add_argument("--max-steps", type=int, default=-1)   # set small for the tiny-subset run
    ap.add_argument("--rank", type=int, default=16)
    ap.add_argument("--seq-len", type=int, default=2048)
    a = ap.parse_args()

    tok = AutoTokenizer.from_pretrained(BASE)
    model = AutoModelForCausalLM.from_pretrained(BASE, torch_dtype=torch.bfloat16, device_map="cuda")
    model.config.use_cache = False
    ds = load_dataset("json", data_files={"train": f"{a.data}/train.jsonl",
                                          "val": f"{a.data}/val.jsonl"})
    cfg = SFTConfig(
        output_dir=a.out, num_train_epochs=a.epochs, max_steps=a.max_steps,
        per_device_train_batch_size=1, gradient_accumulation_steps=8,
        learning_rate=1e-4, lr_scheduler_type="cosine", warmup_ratio=0.03,
        bf16=True, gradient_checkpointing=True, packing=True,
        max_seq_length=a.seq_len, logging_steps=5, eval_strategy="epoch",
        save_strategy="epoch", report_to=[])
    trainer = SFTTrainer(
        model=model, args=cfg, train_dataset=ds["train"], eval_dataset=ds["val"],
        peft_config=LoraConfig(r=a.rank, lora_alpha=a.rank * 2, lora_dropout=0.05,
                               target_modules=TARGETS, task_type="CAUSAL_LM"))
    trainer.train()
    trainer.save_model(a.out)
    print("ADAPTER-SAVED", a.out)

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Pause serving so training has the GPU**

```bash
ssh jacinta@100.91.185.71 'sudo kubectl -n model-stack scale deploy/ollama --replicas=0'
```
Expected: `deployment.apps/ollama scaled`. (The `code` lane is unavailable until Task 4 Step 6 — acceptable for the experiment.)

- [ ] **Step 3: Tiny-subset validation run (loss must drop)**

```bash
ssh jacinta@100.92.111.3 'cd ~/model-tune && .venv/bin/python train_lora.py --max-steps 10 --out adapter_smoke'
```
Expected: training logs show `loss` printed every 5 steps and **decreasing** across the 10 steps; ends `ADAPTER-SAVED adapter_smoke`. This is the first time the 30B loads in bf16 — confirm it fits in the 128 GB (watch `nvidia-smi`). If OOM: drop `--seq-len` to 1024 and retry.

- [ ] **Step 4: Full training run**

```bash
ssh jacinta@100.92.111.3 'cd ~/model-tune && nohup .venv/bin/python train_lora.py --epochs 3 --out adapter > train.log 2>&1 &'
# monitor:
ssh jacinta@100.92.111.3 'tail -n 20 ~/model-tune/train.log'
```
Expected: completes with `ADAPTER-SAVED adapter`; final eval loss < initial eval loss. (Background it; it may run for a while on the bandwidth-bound GB10.)

- [ ] **Step 5: Commit the script**

```bash
git add tools/model-tune/train_lora.py
git commit -m "feat(model-tune): bf16 LoRA training script for qwen3-coder on GB10"
```

- [ ] **Step 6: Restore serving**

```bash
ssh jacinta@100.91.185.71 'sudo kubectl -n model-stack scale deploy/ollama --replicas=1 && sudo kubectl -n model-stack rollout status deploy/ollama'
```
Expected: ollama back to 1/1 (stock `code` lane serving again).

---

## Task 5: Merge + GGUF export + ollama tag

Produce a servable tuned model as a separate tag. Runs on the GB10. Validated by the tag answering a prompt.

**Files:**
- Create: `tools/model-tune/merge_and_export.py`

- [ ] **Step 1: Write the merge script**

`tools/model-tune/merge_and_export.py`:
```python
#!/usr/bin/env python3
"""Stage ④a: merge the LoRA adapter into the base and save fp16 safetensors."""
import argparse, torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import PeftModel

BASE = "Qwen/Qwen3-Coder-30B-A3B-Instruct"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--adapter", default="adapter")
    ap.add_argument("--out", default="merged")
    a = ap.parse_args()
    model = AutoModelForCausalLM.from_pretrained(BASE, torch_dtype=torch.float16, device_map="cpu")
    model = PeftModel.from_pretrained(model, a.adapter)
    model = model.merge_and_unload()
    model.save_pretrained(a.out, safe_serialization=True)
    AutoTokenizer.from_pretrained(BASE).save_pretrained(a.out)
    print("MERGED", a.out)

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run the merge**

```bash
ssh jacinta@100.92.111.3 'cd ~/model-tune && .venv/bin/python merge_and_export.py --adapter adapter --out merged'
```
Expected: `MERGED merged`; `~/model-tune/merged/` contains `*.safetensors` + tokenizer files.

- [ ] **Step 3: Convert to GGUF + quantize (llama.cpp)**

```bash
ssh jacinta@100.92.111.3 'cd ~/model-tune && \
  ([ -d llama.cpp ] || git clone https://github.com/ggml-org/llama.cpp) && \
  pip install -r llama.cpp/requirements.txt && \
  python llama.cpp/convert_hf_to_gguf.py merged --outfile cwb-f16.gguf --outtype f16 && \
  (cd llama.cpp && cmake -B build && cmake --build build --target llama-quantize -j) && \
  ./llama.cpp/build/bin/llama-quantize cwb-f16.gguf qwen3-coder-cwb-Q4_K_M.gguf Q4_K_M'
```
Expected: `qwen3-coder-cwb-Q4_K_M.gguf` produced (~18 GB, matching the served base quant). If `convert_hf_to_gguf.py` errors on the MoE arch, update llama.cpp to latest (`git -C llama.cpp pull`) — qwen3moe support is upstream.

- [ ] **Step 4: Create the ollama tag**

```bash
ssh jacinta@100.92.111.3 'cd ~/model-tune && printf "FROM ./qwen3-coder-cwb-Q4_K_M.gguf\n" > Modelfile && \
  ollama create qwen3-coder-cwb -f Modelfile && \
  ollama run qwen3-coder-cwb "Write a Go function ReverseString(s string) string." '
```
Expected: `ollama create` succeeds; the run prints a Go function. The tag `qwen3-coder-cwb` is now servable alongside the stock base.

- [ ] **Step 5: Commit**

```bash
git add tools/model-tune/merge_and_export.py
git commit -m "feat(model-tune): merge adapter + GGUF export + ollama tag"
```

---

## Task 6: Eval — no-regression + CWB-style, base vs tuned

Compare stock vs tuned. No-regression uses the existing `bench.py`; the CWB-style judged eval is new. Scoring logic is TDD'd; the comparison is a run.

**Files:**
- Create: `tools/model-tune/eval_cwb.py`
- Test: `tools/model-tune/tests/test_eval_cwb.py`

- [ ] **Step 1: Add the tuned tag as a gateway lane (for eval routing)**

Edit `hosting/services/litellm.yaml` ConfigMap `model_list` — add (do not change `code`):
```yaml
      - model_name: code-cwb            # tuned A/B candidate (eval only)
        litellm_params:
          model: openai/qwen3-coder-cwb
          api_base: http://100.92.111.3:11434/v1
          api_key: ollama
```
Apply + restart:
```bash
cat hosting/services/litellm.yaml | ssh jacinta@100.91.185.71 'sudo kubectl apply -f -'
ssh jacinta@100.91.185.71 'sudo kubectl -n model-stack rollout restart deploy/litellm && sudo kubectl -n model-stack rollout status deploy/litellm'
```

- [ ] **Step 2: No-regression check (existing objective bench, both lanes)**

```bash
cd /home/operator/src/carriedworld-cloud/tools/model-bench
python bench.py --base http://100.91.185.71:4000/v1 code code-cwb
```
Expected: **`code-cwb` must score 3/3**, equal to `code` (stock). A drop signals catastrophic forgetting → reduce epochs/rank in Task 4 and re-run.

- [ ] **Step 3: Write the failing test for the CWB-style judge parsing**

`tools/model-tune/tests/test_eval_cwb.py`:
```python
import pathlib, importlib.util
def _load(name):
    p = pathlib.Path(__file__).parent.parent / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, p)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
ev = _load("eval_cwb")

def test_parse_judge_score_extracts_integer_1_to_5():
    assert ev.parse_judge_score("Reasoning... SCORE: 4") == 4
    assert ev.parse_judge_score("SCORE: 5\n") == 5

def test_parse_judge_score_clamps_and_defaults():
    assert ev.parse_judge_score("no score here") is None
    assert ev.parse_judge_score("SCORE: 9") == 5     # clamp high
    assert ev.parse_judge_score("SCORE: 0") == 1     # clamp low
```

- [ ] **Step 4: Run it to verify it fails**

Run: `cd /home/operator/src && python -m pytest carriedworld-cloud/tools/model-tune/tests/test_eval_cwb.py -v`
Expected: FAIL with `module ... has no attribute 'parse_judge_score'`.

- [ ] **Step 5: Write the implementation**

`tools/model-tune/eval_cwb.py`:
```python
#!/usr/bin/env python3
"""Stage ⑤: CWB-style judged eval, base vs tuned. Each task is a brief; both models
implement it; a judge scores adherence to our conventions (1-5). Prints a table."""
import argparse, re
from llm_client import chat, DEFAULT_BASE

TASKS = [
    "Implement func MustEnv(key string) string that returns the env var or panics with "
    "a wrapped error message naming the key. Idiomatic Go, no dead code.",
    "Implement an http.HandlerFunc HealthHandler that writes {\"status\":\"ok\"} as JSON "
    "with the right content-type. Include a table-driven test.",
    "Implement func ParseScopes(raw string) ([]string, error) that splits a comma-separated "
    "scope string, trims spaces, rejects empties with a wrapped error, dedups. Fail closed.",
]
JUDGE = ("You are a strict CWB Go reviewer. Score 1-5 how well this matches our standards "
         "(focused scope, idiomatic Go, wrapped errors, tests where expected, no dead code). "
         "End with a line exactly 'SCORE: N'.\n\nTASK:\n{task}\n\nCODE:\n{code}")

def parse_judge_score(text):
    m = re.search(r"SCORE:\s*(\d+)", text)
    if not m:
        return None
    return max(1, min(5, int(m.group(1))))

def eval_model(model, base, judge_model):
    scores = []
    for task in TASKS:
        code = chat([{"role": "user", "content": task}], model=model, base=base)
        verdict = chat([{"role": "user", "content": JUDGE.format(task=task, code=code)}],
                       model=judge_model, base=base, temperature=0)
        s = parse_judge_score(verdict)
        scores.append(s)
        print(f"  {model:16} task -> score {s}")
    valid = [s for s in scores if s]
    return sum(valid) / len(valid) if valid else 0.0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=DEFAULT_BASE)
    ap.add_argument("--judge", default="code")   # judge with the stock model
    ap.add_argument("models", nargs="+")          # e.g. code code-cwb
    a = ap.parse_args()
    print("=== CWB-style adherence (avg 1-5) ===")
    for m in a.models:
        avg = eval_model(m, a.base, a.judge)
        print(f"{m:16} avg {avg:.2f}")

if __name__ == "__main__":
    main()
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd /home/operator/src && python -m pytest carriedworld-cloud/tools/model-tune/tests/test_eval_cwb.py -v`
Expected: PASS (2 tests).

- [ ] **Step 7: Run the CWB-style comparison**

```bash
cd /home/operator/src/carriedworld-cloud/tools/model-tune
python eval_cwb.py --base http://100.91.185.71:4000/v1 --judge code code code-cwb
```
Expected: an avg-1-to-5 table for `code` vs `code-cwb`. Capture it for the operator's hands-on read.

- [ ] **Step 8: Commit (eval + the gateway lane)**

```bash
git add tools/model-tune/eval_cwb.py tools/model-tune/tests/test_eval_cwb.py hosting/services/litellm.yaml
git commit -m "feat(model-tune): CWB-style judged eval + code-cwb gateway lane"
```

---

## Task 7: README + results + decision

**Files:**
- Create: `tools/model-tune/README.md`

- [ ] **Step 1: Write the README**

`tools/model-tune/README.md` — document: the run-locations table; the end-to-end command sequence (Tasks 1→6); the **NGC container fallback** for Task 1 (`docker run --gpus all -v ~/model-tune:/work nvcr.io/nvidia/pytorch:25.xx-py3` then `pip install peft trl datasets` and run inside); and how to promote `qwen3-coder-cwb` to the live `code` lane *if* eval wins (repoint `code` in `litellm.yaml`).

- [ ] **Step 2: Record the eval results**

Append a "Round-one results" section to the README with the no-regression scores (Task 6 Step 2), the CWB-style table (Task 6 Step 7), and a one-line verdict: **did it move the needle?** (visibly more our-style without regressing 3/3 → yes).

- [ ] **Step 3: Commit + finish the branch**

```bash
git add tools/model-tune/README.md
git commit -m "docs(model-tune): README + round-one results and verdict"
```
Then use **superpowers:finishing-a-development-branch** to open the PR for `feature/model-tune-qwen3-coder`.

---

## Self-review

**Spec coverage:** ① corpus → Task 2; ② dataset (real+synth, dev-standards system prompt) → Task 3; ③ bf16 LoRA on GB10 (cu130-aarch64, base A3B, no 4-bit) → Tasks 1+4; ④ merge+GGUF+ollama tag → Task 5; ⑤ eval (no-regression 3/3 + CWB-style + hands-on) → Task 6; serving-pause + separate tag + restore → Task 4 Steps 2/6, Task 5/6; success criteria + decision → Task 7. The "first task validates the stack" requirement → Task 1. Covered.

**Placeholder scan:** no TBD/TODO; every code step has runnable code; deferred specifics from the spec (exact LoRA targets, synth counts) are given concrete starting values (TARGETS list, --max-synth 800) that the tiny-subset run in Task 4 Step 3 tunes.

**Type consistency:** `to_example`/`synth_brief`/`split` (Task 3) match their tests; `parse_judge_score`/`eval_model` (Task 6) match; `llm_client.chat(messages, model, base=...)` signature is used consistently by build_dataset and eval_cwb; ollama tag `qwen3-coder-cwb` and gateway lane `code-cwb` are consistent across Tasks 5–6.
