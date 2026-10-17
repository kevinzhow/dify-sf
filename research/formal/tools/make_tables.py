#!/usr/bin/env python3
"""Summarise TLC logs in results/ into markdown tables (used to fill REPORT.md).  usage: make_tables.py [dify|sf|mut]"""
import re, os, sys
R = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results")
ROOT = os.path.join(R, "..")

def parse(name):
    f = os.path.join(R, name + ".log")
    if not os.path.exists(f): return None
    t = open(f, errors="replace").read()
    d = {"name": name}
    m = re.search(r"Error: Invariant (\w+) is violated", t)
    d["violated"] = m.group(1) if m else None
    d["deadlock"] = "Deadlock reached" in t
    d["ok"] = "No error has been found" in t
    m = re.findall(r"(\d+) states generated, (\d+) distinct states found, (\d+) states left on queue", t)
    if m: d["gen"], d["dist"], d["queue"] = map(int, m[-1])
    else:
        m = re.findall(r"Progress\(\d+\) at [\d\- :]+: ([\d,]+) states generated.*?([\d,]+) distinct states found.*?([\d,]+) states left", t)
        if m: d["gen"], d["dist"], d["queue"] = (int(x.replace(",", "")) for x in m[-1])
    m = re.search(r"depth of the complete state graph search is (\d+)", t)
    if m: d["depth"] = int(m.group(1))
    else:
        m = re.findall(r"Progress\((\d+)\)", t); d["depth"] = int(m[-1]) if m else None
    m = re.search(r"Finished in ([^\n]*?) at", t)
    d["time"] = m.group(1) if m else None
    d["finished"] = bool(m)
    ce = os.path.join(R, "ces", name + ".txt")
    d["trace_len"] = None
    if os.path.exists(ce):
        mm = re.search(r"\[(\d+) states\]", open(ce).read()); d["trace_len"] = int(mm.group(1)) if mm else None
    return d

def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "dify"
    if which == "dify":
        names = [l.strip() for l in open(os.path.join(ROOT, "dify_matrix.txt")) if l.strip()]
        print("| config | verdict | trace length | distinct states explored | time |\n|---|---|---|---|---|")
        for n in names:
            d = parse(n)
            if not d: print(f"| {n} | (not run) | | | |"); continue
            v = (f"VIOLATED {d['violated']}" if d["violated"] else "HOLDS (exhaustive)" if d["ok"] else "DEADLOCK" if d["deadlock"] else "partial/timeout")
            print(f"| {n} | {v} | {d['trace_len'] or '-'} | {d.get('dist', 0):,} | {d['time'] or '-'} |")
    elif which == "sf":
        names = [l.strip() for l in open(os.path.join(ROOT, "matrix.txt")) if l.strip()]
        print("| config | verdict | distinct states | depth | time |\n|---|---|---|---|---|")
        for n in names:
            d = parse(n)
            if not d: print(f"| {n} | (not run) | | | |"); continue
            v = (f"VIOLATED {d['violated']}" if d["violated"] else "DEADLOCK" if d["deadlock"] else "**HOLDS (exhaustive)**" if d["ok"] else "no violation, PARTIAL (time limit)")
            print(f"| {n} | {v} | {d.get('dist', 0):,} | {d['depth']} | {d['time'] or 'limit'} |")
    else:
        names = sorted(f[:-4] for f in os.listdir(os.path.join(ROOT, "tla")) if f.startswith("SFmut_") and f.endswith(".cfg"))
        print("| mutant | caught by | trace length |\n|---|---|---|")
        for n in names:
            d = parse(n)
            if not d: print(f"| {n} | (not run) | |"); continue
            how = d["violated"] or ("deadlock (no convergence)" if d["deadlock"] else "NOT CAUGHT")
            print(f"| {n[6:]} | {how} | {d['trace_len'] or '-'} |")
main()
