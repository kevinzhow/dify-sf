#!/usr/bin/env python
"""Aggregate logs/*.jsonl -> table of verdict counts per scenario(+tag). usage: summarize.py [logs_dir]"""
import glob, json, os, sys, collections
d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
rows = []
for f in sorted([x for x in glob.glob(os.path.join(d, "*.jsonl")) if "harness_errors" not in x]):
    name = os.path.basename(f)[:-6]
    if name == "api_tests":
        continue
    recs = [json.loads(l) for l in open(f) if l.strip()]
    c = collections.Counter("+".join(r.get("verdict", ["?"])) for r in recs)
    n = len(recs)
    bad = n - c.get("OK", 0) - c.get("HARNESS_ERROR", 0)
    valid = n - c.get("HARNESS_ERROR", 0)
    rows.append((name, n, valid, bad, dict(c)))
print(f'{"scenario":14} {"runs":>4} {"valid":>5} {"not-OK":>6} {"rate":>6}  verdicts')
for name, n, valid, bad, c in rows:
    print(f'{name:14} {n:4d} {valid:5d} {bad:6d} {100*bad/max(valid,1):5.0f}%  {c}')
