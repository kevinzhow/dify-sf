#!/usr/bin/env python3
"""Readable view of a TLC counterexample.
 usage: trace_summary.py <tlc.log> [--model dify|sf] [--raw] [--vars a,b]
TLC prints states in TLA+ value syntax; this script parses it (records, functions, sets, tuples, strings) and prints,
per state, the action and the compact variables that CHANGED.  `--model dify` / `sf` selects the compact projections."""
import re, sys

# ---------------------------------------------------------------- TLA+ value parser
class P:
    def __init__(s, t): s.t = t; s.i = 0
    def ws(s):
        while s.i < len(s.t) and s.t[s.i].isspace(): s.i += 1
    def peek(s, k): return s.t.startswith(k, s.i)
    def eat(s, k):
        s.ws()
        assert s.peek(k), (k, s.t[s.i:s.i+60])
        s.i += len(k)
    def value(s):
        v = s.atom()
        s.ws()
        # function  a :> 1 @@ b :> 2   (only at atom level inside parens)
        return v
    def atom(s):
        s.ws(); t = s.t
        if s.peek("<<"):
            s.i += 2; out = []
            s.ws()
            while not s.peek(">>"):
                out.append(s.expr()); s.ws()
                if s.peek(","): s.i += 1; s.ws()
            s.i += 2; return ("tup", out)
        if s.peek("{"):
            s.i += 1; out = []; s.ws()
            while not s.peek("}"):
                out.append(s.expr()); s.ws()
                if s.peek(","): s.i += 1; s.ws()
            s.i += 1; return ("set", out)
        if s.peek("["):
            s.i += 1; d = {}; s.ws()
            while not s.peek("]"):
                m = re.compile(r'("[^"]*"|\w+)\s*\|->').match(t, s.i)
                assert m, t[s.i:s.i+80]
                s.i = m.end(); k = m.group(1).strip('"'); d[k] = s.expr(); s.ws()
                if s.peek(","): s.i += 1; s.ws()
            s.i += 1; return ("rec", d)
        if s.peek("("):
            s.i += 1; s.ws()
            f = {}
            while not s.peek(")"):
                k = s.atom(); s.ws(); s.eat(":>"); v = s.atom(); s.ws()
                f[key(k)] = v
                if s.peek("@@"): s.i += 2; s.ws()
            s.i += 1; return ("fun", f)
        if s.peek('"'):
            j = t.index('"', s.i + 1); v = t[s.i+1:j]; s.i = j + 1; return ("str", v)
        m = re.compile(r"-?\d+|[A-Za-z_][\w!]*").match(t, s.i)
        assert m, t[s.i:s.i+60]
        s.i = m.end(); w = m.group(0)
        return ("int", int(w)) if re.match(r"-?\d+$", w) else ("id", w)
    def expr(s):
        v = s.atom(); s.ws()
        if s.peek(":>"):      # bare function without parens (inside sets rarely)
            s.i += 2; return ("fun1", (v, s.atom()))
        return v

def key(k): return fmt(k)

def fmt(v, depth=0):
    t, x = v
    if t in ("int", "id"): return str(x)
    if t == "str": return x
    if t == "tup": return "<<" + ",".join(fmt(e) for e in x) + ">>"
    if t == "set": return "{" + ",".join(sorted(fmt(e) for e in x)) + "}"
    if t == "rec": return "[" + ",".join(f"{k}:{fmt(e)}" for k, e in x.items()) + "]"
    if t == "fun": return "(" + ",".join(f"{k}:{fmt(e)}" for k, e in x.items()) + ")"
    return str(v)

def drop(v, names):
    t, x = v
    if t == "rec": return (t, {k: drop(e, names) for k, e in x.items() if k not in names})
    if t == "fun": return (t, {k: drop(e, names) for k, e in x.items()})
    if t in ("set", "tup"): return (t, [drop(e, names) for e in x])
    return v

# ---------------------------------------------------------------- TLC log parsing
def parse_log(path):
    txt = open(path, errors="replace").read()
    m = re.search(r"Error: (Invariant \S+ is violated|Deadlock reached|[^\n]*)", txt)
    head = m.group(0) if m else "(no error)"
    blocks = re.split(r"\nState (\d+): <", txt)
    states = []
    for i in range(1, len(blocks), 2):
        n = int(blocks[i]); body = blocks[i + 1]
        act, _, rest = body.partition(">\n")
        act = re.sub(r" line \d+.*", "", act).strip()
        rest = re.split(r"\n\n|\n\d+ states generated|\nFinished|\nThe depth|\nProgress", rest)[0]
        vars_ = {}
        for vm in re.finditer(r"/\\ (\w+) = (.*?)(?=\n/\\ \w+ = |\Z)", rest, re.S):
            vars_[vm.group(1)] = vm.group(2)
        states.append((n, act, vars_))
    return head, states

def load(vars_):
    out = {}
    for k, s in vars_.items():
        try:
            p = P(s.strip()); out[k] = p.expr()
        except Exception as e:
            out[k] = ("str", "<unparsed>")
    return out

def tup_ids(v):   # compact op listing
    t, x = v
    if t == "set": return sorted(opshort(e) for e in x)
    return [fmt(v)]

def opshort(o):
    if o[0] != "rec": return fmt(o)
    d = o[1]; k = d["kind"][1]
    cl = fmt(d["id"])
    if k in ("setField", "setRef", "moveNode"): return f"{cl}:{k}({fmt(d['n'])}.{fmt(d['g'])}:={fmt(d['v'])})"
    if k in ("listInsert", "listRemove"): return f"{cl}:{k}({fmt(d['n'])},{fmt(d['it'])})"
    if k == "addEdge": return f"{cl}:addEdge{fmt(d['e'])}"
    return f"{cl}:{k}({fmt(d['n'])})"

def compact_graph(v):
    """view / Abs  ->  nodes + non-default registers + lists + edges"""
    if v[0] != "rec": return fmt(v)
    d = v[1]
    out = {}
    nodes = [fmt(e) for e in d["nodes"][1]] if "nodes" in d else []
    val = d.get("val", ("fun", {}))[1]; its = d.get("its", ("fun", {}))[1]
    for n in nodes:
        regs = []
        for g, x in val.get(n, ("fun", {}))[1].items():
            if x not in (("int", 0), ("id", "NoRef"), ("str", "v0"), ("str", "none")): regs.append(f"{g.strip(chr(34))}={fmt(x)}")
        lst = fmt(its[n]) if n in its and its[n][1] else ""
        out[n] = " ".join(regs) + (f" L={lst}" if lst else "")
    edges = fmt(d["edges"]) if "edges" in d else ""
    return f"nodes={sorted(nodes)} " + " | ".join(f"{n}[{s}]" for n, s in out.items()) + (f" edges={edges}" if edges != "{}" else "")

def project_dify(vs):
    o = {}
    for k in ("leader", "dirty", "dsave", "up", "conn", "trusted", "vis", "hash", "fl", "phase"):
        if k in vs: o[k] = fmt(vs[k])
    if "view" in vs and vs["view"][0] == "tup":
        for i, g in enumerate(vs["view"][1]): o[f"view[{i+1}]"] = compact_graph(g)
    if "store" in vs and vs["store"][0] == "rec":
        o["store"] = f"hash={fmt(vs['store'][1]['hash'])} " + compact_graph(vs["store"][1]["g"])
    if "issued" in vs: o["issued"] = ", ".join(tup_ids(vs["issued"]))
    if "net" in vs: o["net"] = f"{len(vs['net'][1])} msgs to " + str(sorted(fmt(m[1]['to']) for m in vs['net'][1]))
    return o

def project_sf(vs):
    o = {}
    for k in ("seen", "high", "sess", "conn", "sopen", "hasSt", "fl", "phase", "dur"):
        if k in vs: o[k] = fmt(vs[k])
    if "log" in vs:
        o["log"] = " ; ".join(f"#{i+1} {fmt(e[1]['c'])}/{fmt(e[1]['cs'])}@base{fmt(e[1]['base'])} {opshort(e[1]['op'])}" for i, e in enumerate(vs["log"][1]))
    if "sd" in vs: o["server"] = compact_graph(vs["sd"])
    if "outbox" in vs and vs["outbox"][0] == "fun":
        for c, ob in vs["outbox"][1].items():
            o[f"outbox[{c}]"] = " ; ".join(f"cs{fmt(e[1]['cs'])}@base{fmt(e[1]['base'])}:{fmt(e[1]['out'])} {opshort(e[1]['op'])}" for e in ob[1])
    if "toS" in vs: o["toS"] = " ; ".join(sorted(f"{fmt(m[1]['c'])}/cs{fmt(m[1]['cs'])}@{fmt(m[1]['base'])} {opshort(m[1]['op'])}" for m in vs["toS"][1]))
    for k in ("acked", "notified"):
        if k in vs: o[k] = ", ".join(tup_ids(vs[k]))
    if "ovw" in vs: o["ovw"] = ", ".join(f"{opshort(p[1][0])} overwritten-by {opshort(p[1][1])}" for p in vs["ovw"][1])
    return o

def main():
    path = sys.argv[1]
    model = sys.argv[sys.argv.index("--model") + 1] if "--model" in sys.argv else ("dify" if "Dify_" in path or "/Dify" in path and "SF" not in path else "sf")
    head, states = parse_log(path)
    print(head)
    prev = {}
    for n, act, vs in states:
        pv = load(vs)
        proj = (project_dify if model == "dify" else project_sf)(pv)
        print(f"--- State {n}: {act}")
        for k, v in proj.items():
            if prev.get(k) != v: print(f"    {k} = {v}")
        prev = proj
    print(f"[{len(states)} states]")

if __name__ == "__main__": main()
