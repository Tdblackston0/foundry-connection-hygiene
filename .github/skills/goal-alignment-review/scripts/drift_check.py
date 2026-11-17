#!/usr/bin/env python3
"""
Mechanical first-pass drift check. Heuristic only — the agent still writes the verdict.

Compares the repo against GOAL.md and prints:
  - terms that appear in source/outputs but never in GOAL.md (candidate scope creep)
  - GOAL.md success-criterion terms that never appear in outputs (candidate gaps)
  - artifact count vs. success-criterion count (pattern 9)
  - disclaimer density in human-readable outputs (pattern 1)
  - status/disposition vocabularies with > 4 values (pattern 1)

Usage:
  python drift_check.py [--root .] [--goal GOAL.md] [--outputs reports]
"""
import argparse
import collections
import json
import pathlib
import re
import sys

SRC_EXT = {".ps1", ".psm1", ".py", ".ts", ".js", ".cs", ".bicep", ".tf", ".yaml", ".yml"}
OUT_EXT = {".md", ".csv", ".json", ".txt"}
CAUTION = re.compile(
    r"\b(not verified|unknown|investigate|interpret carefully|manual review|"
    r"not proof|never use|review hint|not authorization|cannot be assumed|caveat|"
    r"is not unused|not that usage|requires .* review|read-only)\b",
    re.I,
)
STOP = set("the a an and or of to in for on with by is are be this that from as at it its into not no yes".split())


def words(text: str) -> collections.Counter:
    toks = re.findall(r"[A-Za-z][A-Za-z0-9_\-]{3,}", text)
    return collections.Counter(t.lower() for t in toks if t.lower() not in STOP)


def read(p: pathlib.Path) -> str:
    try:
        return p.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""


def section(goal: str, heading: str) -> str:
    m = re.search(rf"^##\s+{re.escape(heading)}.*?$(.*?)(?=^##\s|\Z)", goal, re.S | re.M)
    return m.group(1) if m else ""


def status_vocab(paths):
    """Find CSV/JSON columns that look like status/disposition and count distinct values."""
    found = {}
    for p in paths:
        if p.suffix == ".csv":
            lines = read(p).splitlines()
            if len(lines) < 2:
                continue
            hdr = [h.strip().strip('"') for h in lines[0].split(",")]
            for i, h in enumerate(hdr):
                if re.search(r"status|disposition|verdict|state|class", h, re.I):
                    vals = set()
                    for ln in lines[1:]:
                        cells = ln.split(",")
                        if i < len(cells):
                            vals.add(cells[i].strip().strip('"'))
                    found[f"{p.name}:{h}"] = vals
        elif p.suffix == ".json":
            try:
                data = json.loads(read(p))
            except Exception:
                continue
            def walk(o, path=""):
                if isinstance(o, dict):
                    for k, v in o.items():
                        walk(v, f"{path}.{k}" if path else k)
                elif isinstance(o, list):
                    for item in o:
                        if isinstance(item, dict):
                            for k, v in item.items():
                                if isinstance(v, str) and re.search(r"status|disposition|verdict|state", k, re.I):
                                    found.setdefault(f"{p.name}:{path}[].{k}", set()).add(v)
                        walk(item, path)
            walk(data)
    return {k: v for k, v in found.items() if len(v) > 4}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--goal", default="GOAL.md")
    ap.add_argument("--outputs", default="reports")
    a = ap.parse_args()

    root = pathlib.Path(a.root)
    goal_path = root / a.goal
    if not goal_path.exists():
        print(f"FAIL: {goal_path} not found. Run Capture mode first.")
        sys.exit(2)
    goal = read(goal_path)
    goal_words = words(goal)
    criteria = [ln for ln in section(goal, "Success criteria").splitlines() if re.match(r"\s*\d+\.", ln)]
    nongoals = section(goal, "Non-goals")

    src = [p for p in root.rglob("*") if p.suffix in SRC_EXT and ".github" not in p.parts and ".git" not in p.parts]
    out_dir = root / a.outputs
    outs = [p for p in out_dir.rglob("*") if p.suffix in OUT_EXT] if out_dir.exists() else []

    src_words = collections.Counter()
    for p in src:
        src_words.update(words(read(p)))
    out_text = "\n".join(read(p) for p in outs)

    print(f"GOAL.md: {len(criteria)} success criteria, {len(nongoals.strip().splitlines())} non-goal lines")
    print(f"Source files: {len(src)}   Output artifacts: {len(outs)}")
    print()

    # Pattern 9: output multiplication
    if criteria and len(outs) > 2 * len(criteria):
        print(f"[P9 output multiplication] {len(outs)} artifacts for {len(criteria)} criteria. Target: 1 machine + 1 human file.")

    # Pattern 3/7: terms in source never in GOAL.md
    novel = [(w, c) for w, c in src_words.most_common(400) if w not in goal_words and c >= 5]
    novel = [x for x in novel if not re.match(r"^(function|param|return|string|object|write|null|true|false|foreach|where|select|invoke|import|export|const|class|public|private|static|async|await)$", x[0])]
    if novel:
        print("[P3/P7 candidate scope] frequent source terms absent from GOAL.md (top 15):")
        print("   " + ", ".join(f"{w}({c})" for w, c in novel[:15]))

    # Non-goal terms present in source
    ng_words = words(nongoals)
    hits = [w for w in ng_words if src_words.get(w, 0) >= 3 and len(w) > 4]
    if hits:
        print(f"[Non-goal leakage] non-goal terms found in source: {', '.join(sorted(hits)[:10])}")

    # Pattern 5: criteria terms missing from outputs
    if outs:
        ow = words(out_text)
        for c in criteria:
            key = [w for w in words(c) if len(w) > 5][:4]
            missing = [w for w in key if w not in ow]
            if key and len(missing) == len(key):
                print(f"[P5 candidate gap] criterion with no matching output terms: {c.strip()[:80]}")

    # Pattern 1: caution density
    if outs:
        human = "\n".join(read(p) for p in outs if p.suffix in {".md", ".txt"})
        lines = [l for l in human.splitlines() if l.strip()]
        caut = sum(1 for l in lines if CAUTION.search(l))
        if lines and caut / len(lines) > 0.15:
            print(f"[P1 caution creep] {caut}/{len(lines)} human-readable lines are caveats ({caut/len(lines):.0%}).")

    # Pattern 1: status vocab
    for k, v in status_vocab(outs).items():
        print(f"[P1 status sprawl] {k} has {len(v)} values: {sorted(v)}")

    print("\nHeuristics only. Write the verdict using references/review-template.md.")


if __name__ == "__main__":
    main()
