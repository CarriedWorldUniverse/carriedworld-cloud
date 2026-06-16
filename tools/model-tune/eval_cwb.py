#!/usr/bin/env python3
"""Stage ⑤: CWB-style eval — baseline now, tuned later, compared directly.
Each task is a brief; the model implements it; a judge scores adherence 1-5;
the generated code is SAVED to eval-results/<model>.json so stock vs tuned can be
diffed by eye (the real signal — the judge score is a rough secondary number)."""
import argparse, json, os, re
from llm_client import chat, DEFAULT_BASE

TASKS = [
    {"name": "must_env",
     "brief": "Implement func MustEnv(key string) string that returns the env var or panics "
              "with a wrapped error message naming the key. Idiomatic Go, no dead code."},
    {"name": "health_handler",
     "brief": "Implement an http.HandlerFunc HealthHandler that writes {\"status\":\"ok\"} as JSON "
              "with the right content-type. Include a table-driven test."},
    {"name": "parse_scopes",
     "brief": "Implement func ParseScopes(raw string) ([]string, error) that splits a comma-separated "
              "scope string, trims spaces, rejects empties with a wrapped error, dedups. Fail closed."},
]
JUDGE = ("You are a strict CarriedWorld Go reviewer. Score 1-5 how well this matches our standards "
         "(focused scope, idiomatic Go, errors wrapped with %w, tests where expected, no dead code). "
         "End with a line exactly 'SCORE: N'.\n\nTASK:\n{brief}\n\nCODE:\n{code}")

def parse_judge_score(text):
    m = re.search(r"SCORE:\s*(\d+)", text)
    if not m:
        return None
    return max(1, min(5, int(m.group(1))))

def eval_model(model, base, judge_model):
    results = []
    for task in TASKS:
        code = chat([{"role": "user", "content": task["brief"]}], model=model, base=base)
        verdict = chat([{"role": "user", "content": JUDGE.format(brief=task["brief"], code=code)}],
                       model=judge_model, base=base, temperature=0)
        score = parse_judge_score(verdict)
        results.append({"task": task["name"], "score": score, "code": code})
        print(f"  {model:14} {task['name']:16} score={score}")
    valid = [r["score"] for r in results if r["score"]]
    return (sum(valid) / len(valid) if valid else 0.0), results

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=DEFAULT_BASE)
    ap.add_argument("--judge", default="control")
    ap.add_argument("--out", default="eval-results")
    ap.add_argument("models", nargs="+")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    print("=== CWB-style adherence (avg 1-5); generated code saved per model ===")
    for m in a.models:
        avg, results = eval_model(m, a.base, a.judge)
        safe = m.replace("/", "_").replace(":", "_")
        with open(os.path.join(a.out, f"{safe}.json"), "w") as fh:
            json.dump({"model": m, "avg": avg, "results": results}, fh, indent=2)
        print(f"{m:14} avg {avg:.2f}  -> {a.out}/{safe}.json")

if __name__ == "__main__":
    main()
