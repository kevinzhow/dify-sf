#!/usr/bin/env python
"""Replay the Dify counterexamples on the REAL Loro library through the miniature Dify data path (minidify.py).
Each scenario prints the abstract counterexample step list (from Dify.tla traces) and PASS if the real CRDT ends in the
violating state predicted by the model.  No network: 'delivery' = import of the sender's full update (cumulative export)."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from minidify import make_room

ok_all = True
def check(name, cond, info=""):
    global ok_all
    ok_all &= bool(cond)
    print(("PASS " if cond else "FAIL ") + name + (("  -> " + str(info)) if info else ""))

def converge(*cs):
    """deliver everything to everybody, then rAF refresh"""
    ups = [c.export_update() for c in cs]
    for c in cs:
        for u in ups:
            c.import_update(u)
    for c in cs:
        c.refresh_view()

G = lambda: {"n1": {"title": "t0", "desc": "d0", "variables": ["x0"], "outputs": {"o0": 1}},
             "n2": {"title": "u0", "desc": "e0", "variables": [], "outputs": {}}}

# ---- CE-A  same node, different fields, B's view lags its doc (S1N / S1NR) --------------------------------------
A, B, C = make_room(G())
A.edit("n1", title="A-title"); uA = A.export_update()
B.import_update(uA)                          # arrives in B's DOC now ...
B.edit("n1", desc="B-desc")                  # ... B edits before the rAF refresh: view still has title t0
converge(A, B)
d = A.data("n1")
check("CE-A stale view reverts remote field (title lost, A acked)", d["title"] == "t0" and d["desc"] == "B-desc", d)

# ... and the control: B edits BEFORE A's update reaches B's doc (network latency, S1NL) -> nothing lost
A, B, C = make_room(G())
A.edit("n1", title="A-title"); B.edit("n1", desc="B-desc")
converge(A, B)
d = A.data("n1")
check("CE-A' control: concurrent in network (doc not ahead of view) merges fine", d["title"] == "A-title" and d["desc"] == "B-desc", d)

# ---- CE-B  same field concurrent: silent LWW (S2 / S2L) ----------------------------------------------------------
A, B, C = make_room(G())
A.edit("n1", title="A-same"); B.edit("n1", title="B-same")
converge(A, B)
check("CE-B same field: one acknowledged edit silently disappears", A.data("n1")["title"] in ("A-same", "B-same") and A.data("n1") == B.data("n1"), A.data("n1")["title"])

# ---- CE-C  whole-valued list (code-node outputs object): two adds -> one survives (S2O / S2OL) -------------------
A, B, C = make_room(G())
A.edit("n1", outputs={"o0": 1, "oa": 2}); B.edit("n1", outputs={"o0": 1, "ob": 3})
converge(A, B)
o = A.data("n1")["outputs"]
check("CE-C object-valued list: concurrent adds, one lost", ("oa" in o) != ("ob" in o), o)

# ---- CE-D  index list (LoroList): remote append erased by stale-view append ----------------------------------------
A, B, C = make_room(G())
A.edit("n1", variables=["x0", "a"]); uA = A.export_update()
B.import_update(uA)
B.edit("n1", variables=["x0", "b"])          # target [x0,b] vs doc [x0,a]: index diff deletes a
converge(A, B)
v = A.data("n1")["variables"]
check("CE-D index list: stale-view append deletes the remote item", v == ["x0", "b"], v)

# ---- CE-E  index list: removal resurrected by a stale-view edit ----------------------------------------------------
g = G(); g["n1"]["variables"] = ["x0", "x1"]
A, B, C = make_room(g)
A.edit("n1", variables=["x1"]); B.import_update(A.export_update())     # A removed x0; B's view still [x0,x1]
B.edit("n1", variables=["x0", "x1b"])                                 # B edits item 1 from its stale view
converge(A, B)
v = A.data("n1")["variables"]
check("CE-E index list: removed item x0 resurrected", "x0" in v, v)

# ---- CE-F  delete vs concurrent edit: edit dropped; and zombie when the editor's view is stale ----------------------
A, B, C = make_room(G())
A.delete_node("n2"); B.edit("n2", title="B-edit")
converge(A, B)
check("CE-F delete vs concurrent edit: B's acknowledged edit silently gone", A.data("n2") is None and B.data("n2") is None)

A, B, C = make_room(G())
A.delete_node("n2"); B.import_update(A.export_update())                # B's doc knows n2 is deleted, B's view still shows it
B.edit("n2", title="B-zombie")
converge(A, B)
d = A.data("n2")
check("CE-F' zombie: deleted node re-created by a stale-view edit", d is not None and d["title"] == "B-zombie", d)

# ---- CE-G  dangling reference: no cleanup on delete (sequential, single user) ----------------------------------------
A, B, C = make_room(G())
A.edit("n1", ref="n2"); A.delete_node("n2")
converge(A, B)
d = B.data("n1")
check("CE-G reference to a deleted node stays (no marker, no cleanup)", d.get("ref") == "n2" and B.data("n2") is None, d.get("ref"))

print("ALL PASS" if ok_all else "SOME FAIL")
sys.exit(0 if ok_all else 1)
