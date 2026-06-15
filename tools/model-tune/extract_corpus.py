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
