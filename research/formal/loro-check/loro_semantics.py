#!/usr/bin/env python
"""Empirical check of the Loro map/list semantics the formal model relies on (python binding loro 1.16.2;
the Dify web app pins loro-crdt 1.15.1 (JS/WASM) -- same core). Prints one line per property: PASS/FAIL."""
import loro
from loro import LoroDoc, LoroMap, LoroList

def mk(peer):
    d = LoroDoc(); d.peer_id = peer
    return d

def nops(d): return d.len_ops

res = []
def check(name, ok, info=""):
    res.append(ok); print(("PASS " if ok else "FAIL ") + name, info)

# --- U1: set(k, v) with the value already present is a no-op (no new op)
a = LoroDoc(); a.get_map("m").insert("k", "x"); a.commit()
n0 = a.len_ops; a.get_map("m").insert("k", "x"); a.commit()
check("U1 map.set(k, same value) creates no op", a.len_ops == n0, f"ops {n0}->{a.len_ops}")
a.get_map("m").insert("k", "y"); a.commit()
check("U1b map.set(k, different value) creates an op", a.len_ops == n0 + 1)

# --- U2: concurrent set on same key: higher lamport wins; tie -> higher peer id wins
def fork_pair(setup=None):
    base = LoroDoc(); base.peer_id = 100; 
    if setup: setup(base); base.commit()
    snap = base.export(loro.ExportMode.Snapshot())
    a = LoroDoc(); a.peer_id = 1; a.import_(snap)
    b = LoroDoc(); b.peer_id = 2; b.import_(snap)
    return a, b
def sync(a, b):
    ua, ub = a.export(loro.ExportMode.Updates(loro.VersionVector())), b.export(loro.ExportMode.Updates(loro.VersionVector()))
    a.import_(ub); b.import_(ua)

a, b = fork_pair(lambda d: d.get_map("m").insert("k", "0"))
a.get_map("m").insert("k", "A"); a.commit(); b.get_map("m").insert("k", "B"); b.commit()
sync(a, b)
va, vb = a.get_deep_value()["m"]["k"], b.get_deep_value()["m"]["k"]
check("U2 equal-lamport concurrent set: higher peer id wins on both replicas", va == vb == "B", f"A(peer1)/B(peer2) -> {va},{vb}")

# lamport dominance: peer 1 does two sequential writes (lamport higher), peer 2 one concurrent write; peer1 wins despite lower id
a, b = fork_pair(lambda d: d.get_map("m").insert("k", "0"))
a.get_map("m").insert("x", 1); a.commit(); a.get_map("m").insert("k", "A2"); a.commit()
b.get_map("m").insert("k", "B"); b.commit()
sync(a, b)
va, vb = a.get_deep_value()["m"]["k"], b.get_deep_value()["m"]["k"]
check("U2b higher lamport beats higher peer id", va == vb == "A2", f"-> {va},{vb}")

# --- U3: nested containers: write into child map of a node deleted concurrently is invisible
a, b = fork_pair(lambda d: d.get_map("nodes").insert_container("n1", LoroMap()).insert("t", "0"))
a.get_map("nodes").delete("n1"); a.commit()
b.get_map("nodes").get("n1").container.insert("t", "B-edit"); b.commit()
sync(a, b)
va, vb = a.get_deep_value()["nodes"], b.get_deep_value()["nodes"]
check("U3 concurrent edit inside a node that the other peer deleted is silently dropped", va == vb == {}, f"-> {va},{vb}")

# --- U4: node re-created by stale writer (setContainer under an existing deleted key) resurrects the node
a, b = fork_pair(lambda d: d.get_map("nodes").insert_container("n1", LoroMap()).insert("t", "0"))
a.get_map("nodes").delete("n1"); a.commit(); sync(a, b)       # b has seen the delete in its CRDT doc
c = b.get_map("nodes").insert_container("n1", LoroMap())      # stale React view still shows n1 -> getNodeContainer recreates it
c.insert("t", "stale-copy"); b.commit(); sync(a, b)
va = a.get_deep_value()["nodes"]
check("U4 stale write recreates a deleted node (zombie)", va == {"n1": {"t": "stale-copy"}}, f"-> {va}")

# --- U5: concurrent list inserts at the end both survive; delete(i)+insert(i) of the same index duplicates / loses
a, b = fork_pair(lambda d: [d.get_map("m").insert_container("L", LoroList()).insert(0, "i0")])
la, lb = a.get_map("m").get("L").container, b.get_map("m").get("L").container
la.insert(1, "a"); a.commit(); lb.insert(1, "b"); b.commit(); sync(a, b)
va = a.get_deep_value()["m"]["L"]; vb = b.get_deep_value()["m"]["L"]
check("U5 concurrent appends to a LoroList both survive", sorted(va) == ["a", "b", "i0"] and va == vb, f"-> {va}")
a, b = fork_pair(lambda d: [d.get_map("m").insert_container("L", LoroList()).insert(0, "i0")])
la, lb = a.get_map("m").get("L").container, b.get_map("m").get("L").container
la.delete(0, 1); la.insert(0, "A"); a.commit(); lb.delete(0, 1); lb.insert(0, "B"); b.commit(); sync(a, b)
va = a.get_deep_value()["m"]["L"]
check("U5b both editing item 0 by delete+insert keeps BOTH values (duplicate)", sorted(va) == ["A", "B"], f"-> {va}")

# --- U6: whole-array value in a map key is LWW
a, b = fork_pair(lambda d: d.get_map("m").insert("outs", ["o0"]))
a.get_map("m").insert("outs", ["o0", "oa"]); a.commit(); b.get_map("m").insert("outs", ["o0", "ob"]); b.commit(); sync(a, b)
va = a.get_deep_value()["m"]["outs"]
check("U6 concurrent whole-value writes of an array: exactly one survives", va in (["o0", "oa"], ["o0", "ob"]), f"-> {va}")

# --- U7: update export is cumulative (a later export contains everything -> loss of an earlier message is benign)
a = LoroDoc(); a.get_map("m").insert("k", 1); a.commit(); u1 = a.export(loro.ExportMode.Updates(loro.VersionVector()))
a.get_map("m").insert("j", 2); a.commit(); u2 = a.export(loro.ExportMode.Updates(loro.VersionVector()))
c = LoroDoc(); c.import_(u2)
check("U7 export(update) with no 'from' is cumulative: u2 alone reproduces the full doc", c.get_deep_value() == a.get_deep_value())

print("ALL PASS" if all(res) else "SOME FAIL")
