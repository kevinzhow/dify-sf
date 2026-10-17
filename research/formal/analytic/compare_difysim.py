#!/usr/bin/env python
"""Compare difysim results (full-stack Dify simulator) with the closed-form predictions of model.py.

usage: compare_difysim.py [--dir DIR | --file FILE] [--r 0.05] [--lam 0.1]

Looks (recursively, skipping node_modules/dist/src) in research/dify-sim for
  *.json  *.jsonl  *.csv  and REPORT.md (markdown tables).  Tolerant column matching; the documented schema is
  {"runs":[{"N":50,"lambda":0.1,"latency_ms":400,"mix":"mixed","edits":12000,"lost":150}, ...]}
     N          users                      lambda  edits/s/user (default --lam)
     latency_ms ONE-WAY client<->relay latency per leg (path L = 2x; use "path_ms" for the total path instead)
     mix        disjoint | mixed (40/30/30) | uniform   (anything else -> 'mixed' with a warning)
     edits      acknowledged edits           lost  edits silently lost      (or "loss_rate" as fraction / '3.2%')
     optional: r_ms (view lag), s, H (hot-set share / size), p_del
Prints predicted vs observed (collision term and collision+persistence) with Clopper-Pearson CIs.  Exit code 0 always."""
import argparse, csv, json, os, re, sys
from scipy.stats import beta
import model as M

DEFAULT_DIR = "research/dify-sim"
SKIP = {"node_modules", "dist", "src", "scripts", "shims", ".git"}
ALIASES = {
    "N": ["n", "users", "clients", "n_users", "num_users", "nusers", "n_clients"],
    "lam": ["lambda", "lam", "edit_rate", "rate_per_user", "edits_per_s_per_user"],
    "lat_ms": ["latency_ms", "latency", "lat_ms", "lat", "one_way_ms", "oneway_ms", "latency_ms", "latency_ms_oneway"],
    "path_ms": ["path_ms", "l_ms"],
    "mix": ["mix", "workload", "scenario", "profile"],
    "edits": ["edits", "n_edits", "acked", "acked_edits", "acknowledged", "total", "ops", "total_edits", "edits_total"],
    "lost": ["lost", "lost_edits", "n_lost", "losses", "silent_losses", "lost_total"],
    "rate": ["loss_rate", "loss", "lost_rate", "loss_pct", "rate", "lost_frac", "loss_rate"],
    "r_ms": ["r_ms", "view_lag_ms", "lag_ms"],
    "s": ["s", "hot_share"], "H": ["h", "hot_nodes", "hot_set"], "p_del": ["p_del", "delete_frac"],
}


def norm_key(k):
    k = re.sub(r"\s+", "_", re.sub(r"[^a-z0-9_ %]", "", str(k).strip().lower())).strip("_")
    for canon, al in ALIASES.items():
        if k in al or k == canon.lower():
            return canon
    return None


def num(x):
    if x is None:
        return None
    if isinstance(x, (int, float)):
        return float(x)
    m = re.search(r"-?\d+(?:[.,]\d+)?(?:e-?\d+)?", str(x).replace(",", ""))
    if not m:
        return None
    v = float(m.group(0))
    return v / 100 if "%" in str(x) else v


def canon_row(d):
    out = {}
    for k, v in d.items():
        c = norm_key(k)
        if c and c not in out:
            out[c] = v
    return out


def adapt_storm(o):
    """best-effort adapter for difysim 'storm' json: {"out":{"cfg":{users,mix,durationS},"edits":{performed,..},
    "lostDisjointEdits":{lost,silentOverwritten},"sameValue":{lost},"diffValue":{silentOverwrites,lostOther}}}.
    FIELD MEANINGS ARE GUESSED from the names - verify against difysim's own report."""
    out = o.get("out") if isinstance(o.get("out"), dict) else None
    if not out or "cfg" not in out or "edits" not in out:
        return None
    cfg, ed = out["cfg"], out["edits"]
    g = lambda *ks: sum(num((out.get(k) or {}).get(f)) or 0 for k, f in ks)
    lost = g(("lostDisjointEdits", "lost"), ("lostDisjointEdits", "silentOverwritten"), ("sameValue", "lost"),
             ("diffValue", "silentOverwrites"), ("diffValue", "lostOther"))
    n_users, dur, perf = num(cfg.get("users")), num(cfg.get("durationS")), num(ed.get("performed"))
    row = {"N": n_users, "mix": cfg.get("mix"), "edits": perf, "lost": lost}
    if dur and n_users and perf:
        row["lambda"] = perf / (dur * n_users)
    for k in ("latencyMs", "latency_ms", "rttMs"):
        if k in cfg:
            row["latency_ms"] = cfg[k]
    return row


def rows_from_obj(o):
    ad = adapt_storm(o) if isinstance(o, dict) else None
    if ad:
        return [ad]
    if isinstance(o, dict):
        for key in ("runs", "results", "rows", "data", "cells"):
            if key in o and isinstance(o[key], list):
                return [r for r in o[key] if isinstance(r, dict)]
        if any(norm_key(k) for k in o):
            return [o]
    if isinstance(o, list):
        return [r for r in o if isinstance(r, dict)]
    return []


def parse_md_tables(text):
    rows, lines, i = [], text.splitlines(), 0
    while i < len(lines) - 1:
        if "|" in lines[i] and re.match(r"^\s*\|?\s*:?-{2,}", lines[i + 1].replace("|", "", 1)) or \
           ("|" in lines[i] and set(lines[i + 1].strip().replace("|", "").replace(" ", "")) <= set("-:")):
            head = [c.strip() for c in lines[i].strip().strip("|").split("|")]
            j = i + 2
            while j < len(lines) and "|" in lines[j]:
                cells = [c.strip() for c in lines[j].strip().strip("|").split("|")]
                if len(cells) == len(head):
                    rows.append(dict(zip(head, cells)))
                j += 1
            i = j
        else:
            i += 1
    return rows


def find_files(d):
    out = []
    for root, dirs, files in os.walk(d):
        dirs[:] = [x for x in dirs if x not in SKIP]
        for f in files:
            if f.endswith((".json", ".jsonl", ".csv")) or f.lower() in ("report.md",) or (f.endswith(".md") and "result" in f.lower()):
                out.append(os.path.join(root, f))
    return sorted(out)


def load_rows(path):
    try:
        txt = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return []
    if path.endswith(".json"):
        try:
            return rows_from_obj(json.loads(txt))
        except json.JSONDecodeError:
            return []
    if path.endswith(".jsonl"):
        out = []
        for l in txt.splitlines():
            try:
                out += rows_from_obj(json.loads(l))
            except json.JSONDecodeError:
                pass
        return out
    if path.endswith(".csv"):
        return list(csv.DictReader(txt.splitlines()))
    return parse_md_tables(txt)


def cp(k, n, a=0.05):
    lo = 0.0 if k == 0 else beta.ppf(a / 2, k, n - k + 1)
    hi = 1.0 if k == n else beta.ppf(1 - a / 2, k + 1, n - k)
    return lo, hi


def mix_name(v):
    s = str(v or "").lower()
    if any(t in s for t in ("disjoint", "own", "region", "separate")):
        return "disjoint"
    if any(t in s for t in ("uniform", "random", "500")):
        return "uniform"
    if any(t in s for t in ("40", "mixed", "hot", "collab")):
        return "mixed"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=DEFAULT_DIR)
    ap.add_argument("--file")
    ap.add_argument("--r", type=float, default=0.05, help="mean view lag (s) when not in the data")
    ap.add_argument("--lam", type=float, default=0.1, help="edits/s/user when not in the data")
    ap.add_argument("--lat-ms", type=float, default=25.0, help="one-way latency (ms) when the data has none")
    a = ap.parse_args()
    files = [a.file] if a.file else (find_files(a.dir) if os.path.isdir(a.dir) else [])
    runs = []
    for f in files:
        for raw in load_rows(f):
            c = canon_row(raw)
            if "N" in c and ("edits" in c or "rate" in c) and ("lost" in c or "rate" in c):
                c["_file"] = os.path.relpath(f, a.dir) if not a.file else f
                runs.append(c)
    if not runs:
        print(f"difysim results not found yet (searched {len(files)} candidate file(s) under {a.file or a.dir}; "
              f"need tables/JSON with N, latency and loss columns - see the schema in this file's docstring).")
        return 0
    print(f"{len(runs)} run(s) parsed from {len({r['_file'] for r in runs})} file(s)\n")
    hdr = (f"{'file':24s} {'N':>4s} {'lam':>6s} {'lat_ms':>6s} {'mix':>9s} {'edits':>8s} {'lost':>6s} {'obs':>8s} {'CP95':>17s} | "
           f"{'pred(coll)':>10s} {'pred(+persist)':>14s}  {'z(coll)':>7s}  covered")
    print(hdr)
    for c in runs:
        N = int(num(c["N"]))
        lam = num(c.get("lam")) or a.lam
        lat = num(c.get("lat_ms"))
        if lat is not None:
            lat /= 1000.0
        elif c.get("path_ms") is not None:
            lat = num(c["path_ms"]) / 2000.0
        else:
            lat = a.lat_ms / 1000.0
        r = (num(c.get("r_ms")) / 1000.0) if c.get("r_ms") is not None else a.r
        mx = mix_name(c.get("mix"))
        note = ""
        if mx is None:
            mx, note = "mixed", " (mix unknown -> 'mixed')"
        kw = {}
        for k in ("s", "H", "p_del"):
            if c.get(k) is not None:
                kw[k] = num(c[k]) if k != "H" else int(num(c[k]))
        p = M.Params(N=N, lam=lam, lat=lat, r=r).mix(mx)
        if kw:
            from dataclasses import replace
            p = replace(p, **kw)
        bd = M.breakdown(p)
        edits, lost = num(c.get("edits")), num(c.get("lost"))
        if edits is None or lost is None:
            rate = num(c.get("rate"))
            if rate is None:
                continue
            rate = rate / 100 if rate > 1 else rate
            obs, ci, edits_s, lost_s, z = rate, ("", ""), "-", "-", float("nan")
        else:
            edits, lost = int(edits), int(round(lost))
            obs = lost / max(edits, 1)
            ci = cp(lost, edits)
            edits_s, lost_s = str(edits), str(lost)
            pc = bd["collisions"]
            se = (max(pc, 1.0 / max(edits, 1)) * (1 - pc) / max(edits, 1)) ** 0.5
            z = (obs - pc) / se
        cov = ""
        if ci[0] != "":
            cov = "yes" if ci[0] <= bd["collisions"] <= ci[1] else ("yes(+persist)" if ci[0] <= bd["total"] <= ci[1] else "NO")
            cis = f"[{ci[0]:.4f},{ci[1]:.4f}]"
        else:
            cis = "-"
        print(f"{c['_file'][-24:]:24s} {N:4d} {lam:6.3f} {lat*1000:6.0f} {mx:>9s} {edits_s:>8s} {lost_s:>6s} {obs:8.4f} {cis:>17s} | "
              f"{bd['collisions']:10.4f} {bd['total']:14.4f}  {z:7.1f}  {cov}{note}")
    print("\nNOTE pred(coll) = (a)-(d) collision mechanisms only; pred(+persist) adds the (e) persistence term (assumption-laden).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
