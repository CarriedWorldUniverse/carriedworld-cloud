#!/usr/bin/env python3
"""Stage ②: build SFT chat JSONL from corpus/funcs.jsonl (+ real_pairs.jsonl).
Synthesized briefs come from an OpenAI-compatible model (default: local gateway
`control` lane for speed; pass --model/--base to use a stronger one)."""
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

def synth_brief(func, chat_fn=default_chat, model="control", base=DEFAULT_BASE):
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
    ap.add_argument("--model", default="control")
    ap.add_argument("--base", default=DEFAULT_BASE)
    ap.add_argument("--max-synth", type=int, default=400)
    ap.add_argument("--max-real", type=int, default=200)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    system = open(os.path.join(os.path.dirname(__file__), "dev_standards.txt")).read().strip()

    funcs = [json.loads(l) for l in open(os.path.join(a.corpus, "funcs.jsonl"))]
    random.Random(0).shuffle(funcs)
    examples = []
    for i, fn in enumerate(funcs[:a.max_synth]):
        try:
            examples.append(to_example(system, synth_brief(fn, model=a.model, base=a.base), fn["code"]))
        except Exception as e:
            print("synth skip:", e)
        if (i + 1) % 25 == 0:
            print(f"  synthesized {i + 1}/{min(a.max_synth, len(funcs))}")
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
