#!/usr/bin/env python3
"""Reusable local-model code bench (onyx-kestrel).

Objective-first: each task asks the model for a Go solution, then the harness
compiles it against a hidden test file and runs `go test` — pass/fail is the
score, not a vibe. Re-runnable against any model list as the market churns:

    ./bench.py --base http://100.106.43.11:11434/v1 qwen3-next:80b gpt-oss:120b ...

Needs `go` on the host (the GB10 models are reached over the OpenAI-compatible
endpoint; `go test` runs locally). Quality-judged (non-objective) tasks just
capture output for human review. Add a model to the field by adding its name to
the CLI — nothing else changes.
"""
import argparse, json, os, re, subprocess, sys, tempfile, time, urllib.request

# --- tasks: each compiles `solution` (package solution) against a hidden test ---
TASKS = [
    {
        "name": "merge_intervals",
        "prompt": (
            "Write Go. Output ONLY one ```go code block, package `solution`, no main, no tests. "
            "Implement: func MergeIntervals(intervals [][]int) [][]int — merge all overlapping "
            "intervals and return them sorted by start. Adjacent-but-not-overlapping intervals "
            "are NOT merged. Handle the empty input."
        ),
        "test": '''package solution
import ("reflect";"testing")
func TestMI(t *testing.T){
  cases:=[]struct{in,want [][]int}{
    {[][]int{{1,3},{2,6},{8,10},{15,18}},[][]int{{1,6},{8,10},{15,18}}},
    {[][]int{{1,4},{4,5}},[][]int{{1,5}}},
    {[][]int{{1,4},{5,6}},[][]int{{1,4},{5,6}}},
    {[][]int{},[][]int{}},
    {[][]int{{5,7},{1,3},{2,4}},[][]int{{1,4},{5,7}}},
  }
  for i,c:=range cases{ got:=MergeIntervals(c.in); if len(got)==0&&len(c.want)==0{continue}; if !reflect.DeepEqual(got,c.want){t.Fatalf("case %d: got %v want %v",i,got,c.want)} }
}''',
        "flags": [],
    },
    {
        "name": "lru_cache",
        "prompt": (
            "Write Go. Output ONLY one ```go code block, package `solution`, no main, no tests. "
            "Implement an LRU cache:\n"
            "  func NewLRU(capacity int) *LRU\n"
            "  func (l *LRU) Get(key int) (int, bool)\n"
            "  func (l *LRU) Put(key, value int)\n"
            "Get and Put both count as 'use'. When over capacity, evict the least-recently-used key. "
            "O(1) amortized."
        ),
        "test": '''package solution
import "testing"
func TestLRU(t *testing.T){
  l:=NewLRU(2)
  l.Put(1,1); l.Put(2,2)
  if v,ok:=l.Get(1); !ok||v!=1 {t.Fatal("get1")}
  l.Put(3,3) // evicts 2
  if _,ok:=l.Get(2); ok {t.Fatal("2 should be evicted")}
  l.Put(4,4) // evicts 1 (3 and 1; 1 less recent? 1 was used by Get, then 3 put, then get2 miss, then put4 -> LRU is 1)
  if _,ok:=l.Get(1); ok {t.Fatal("1 should be evicted")}
  if v,ok:=l.Get(3); !ok||v!=3 {t.Fatal("get3")}
  if v,ok:=l.Get(4); !ok||v!=4 {t.Fatal("get4")}
}''',
        "flags": [],
    },
    {
        "name": "race_fix",
        "prompt": (
            "Write Go. Output ONLY one ```go code block, package `solution`, no main, no tests. "
            "Implement a concurrency-safe counter usable from many goroutines:\n"
            "  func NewCounter() *Counter\n"
            "  func (c *Counter) Inc()\n"
            "  func (c *Counter) Value() int\n"
            "It must be free of data races (the test runs with -race)."
        ),
        "test": '''package solution
import ("sync";"testing")
func TestCounter(t *testing.T){
  c:=NewCounter(); var wg sync.WaitGroup
  for i:=0;i<100;i++{ wg.Add(1); go func(){defer wg.Done(); for j:=0;j<100;j++{c.Inc()}}() }
  wg.Wait()
  if c.Value()!=10000 {t.Fatalf("got %d want 10000",c.Value())}
}''',
        "flags": ["-race"],
    },
]

def chat(base, model, prompt, timeout=600):
    body = json.dumps({"model": model, "temperature": 0,
                       "messages": [{"role": "user", "content": prompt}]}).encode()
    req = urllib.request.Request(base.rstrip("/") + "/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.load(r)
    return d["choices"][0]["message"]["content"], time.time() - t0

def extract_go(text):
    m = re.findall(r"```(?:go)?\s*\n(.*?)```", text, re.DOTALL)
    return max(m, key=len).strip() if m else text.strip()

def run_task(task, code):
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "go.mod"), "w").write("module solution\n\ngo 1.22\n")
        open(os.path.join(d, "solution.go"), "w").write(code)
        open(os.path.join(d, "solution_test.go"), "w").write(task["test"])
        p = subprocess.run(["go", "test", *task["flags"], "./..."], cwd=d,
                           capture_output=True, text=True, timeout=180)
        return p.returncode == 0, (p.stdout + p.stderr).strip().splitlines()[-1:] or [""]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://100.106.43.11:11434/v1")
    ap.add_argument("models", nargs="+")
    a = ap.parse_args()
    results = {}
    for model in a.models:
        results[model] = {}
        for task in TASKS:
            try:
                out, dt = chat(a.base, model, task["prompt"])
                ok, tail = run_task(task, extract_go(out))
                results[model][task["name"]] = (ok, round(dt, 1), tail[0][:60])
            except Exception as e:
                results[model][task["name"]] = (None, 0, str(e)[:60])
            r = results[model][task["name"]]
            print(f"  {model:22} {task['name']:16} {'PASS' if r[0] else 'FAIL' if r[0] is not None else 'ERR ':4} {r[1]:6}s  {r[2]}")
    print("\n=== SCORE (objective tasks passed / total) ===")
    for model in a.models:
        passed = sum(1 for v in results[model].values() if v[0])
        print(f"  {model:22} {passed}/{len(TASKS)}  avg {round(sum(v[1] for v in results[model].values())/len(TASKS),1)}s")

if __name__ == "__main__":
    main()
