#!/usr/bin/env python3
"""Cheap, compiler-free guard for mutants.py: every mutant's `old` text must occur EXACTLY once in
its file. Zero means the source moved under the list (the mutant would be skipped, silently
shrinking the guard); two or more means the mutant is ambiguous. Port of bp-dex check_targets.py.

  python3 .github/scripts/check_targets.py
"""
import os, sys

here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(here, "mutants.py")).read()
ns = {}
exec(src.split("def run(")[0], ns)

bad = 0
for i, m in enumerate(ns["M"], 1):
    n = open(m["f"]).read().count(m["old"])
    if n != 1:
        bad += 1
        print(f"[{i}] {m['nome']}: target found {n} times in {m['f']} (need exactly 1)")
    if m["old"] == m["new"]:
        bad += 1
        print(f"[{i}] {m['nome']}: old == new, the mutant changes nothing")
if bad:
    sys.exit(1)
print(f"{len(ns['M'])} mutant targets, each found exactly once.")
