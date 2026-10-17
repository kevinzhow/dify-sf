#!/usr/bin/env python3
"""Generate the TLC configuration matrix (tla/*.cfg).  Names encode the bounds: <clients>c<ops>o_f<faults>_<profile>."""
import os
HERE = os.path.dirname(os.path.abspath(__file__)) + "/tla"

SF = """SPECIFICATION Spec
CONSTANTS
  Clients = {{{clients}}}
  Nodes = {{n1,n2,n3}}
  InitNodes = {{n1,n2}}
  Fields = {{{fields}}}
  Vals = {{v1,v2}}
  MaxOps = {ops}
  MaxFaults = {faults}
  OpKinds = {{{kinds}}}
  NoRef = NoRef
  Broken = Broken
  NoStale = {NoStale}
  NoCascade = {NoCascade}
  NoDedup = {NoDedup}
  EarlyAck = {EarlyAck}
  NoFrom = {NoFrom}
  NoResend = {NoResend}
  EqualStamp = {EqualStamp}
  NoTouch = {NoTouch}
CONSTANT Region <- RegionAll
SYMMETRY Sym
INVARIANTS {inv}
CHECK_DEADLOCK TRUE
"""
ALLINV = "Inv_P1 Inv_P2 Inv_P3 Inv_P4 Inv_P5 Inv_Acked Inv_Truth Inv_Log Inv_Recover"
K = lambda *k: ",".join(f'"{x}"' for x in k)
PROFILES = {
    "field":  (K("setField"), "f1"),                                   # 2 nodes x 1 field x 2 values = 4 ops
    "regs":   (K("setField"), "f1,f2"),                                # 2 nodes x 2 fields x 2 values = 8 ops
    "move":   (K("setField", "moveNode", "removeNode"), "f1"),         # layout LWW vs delete
    "lists":  (K("listInsert", "listRemove"), "f1"),
    "struct": (K("setField", "removeNode", "addNode", "addEdge", "setRef"), "f1"),
    "narrow": (K("setField", "removeNode", "setRef"), "f1"),
    "all":    (K("setField", "moveNode", "listInsert", "listRemove", "addNode", "removeNode", "addEdge", "setRef"), "f1,f2"),
}
def write(name, clients, ops, faults, prof, **mut):
    kinds, fields = PROFILES[prof]
    d = dict(NoStale="FALSE", NoCascade="FALSE", NoDedup="FALSE", EarlyAck="FALSE", NoFrom="FALSE", NoResend="FALSE", EqualStamp="FALSE", NoTouch="FALSE")
    d.update(mut)
    open(f"{HERE}/{name}.cfg", "w").write(SF.format(clients=",".join(f"c{i+1}" for i in range(clients)), fields=fields,
                                                    ops=ops, faults=faults, kinds=kinds, inv=ALLINV, **d))
# --- the exhaustive matrix (REPORT table) ---
MATRIX = [
    # (clients, ops per client, faults, profile) -- exhaustive TLC runs; see REPORT.md section 4
    (2, 2, 0, "narrow"), (2, 2, 0, "regs"), (2, 2, 0, "lists"), (2, 2, 0, "move"), (2, 2, 0, "struct"),
    (2, 2, 2, "field"), (2, 2, 1, "narrow"), (2, 2, 1, "lists"), (2, 2, 1, "move"),
    (3, 1, 2, "all"), (3, 2, 0, "field"), (3, 2, 1, "field"), (2, 3, 1, "field"),
]
names = []
for c, o, f, p in MATRIX:
    n = f"SF_{c}c{o}o_f{f}_{p}"; write(n, c, o, f, p); names.append(n)
# --- mutants (each must be caught) ---
write("SFmut_NoStale",   2, 1, 0, "field", NoStale="TRUE")
write("SFmut_NoCascade", 2, 2, 0, "narrow", NoCascade="TRUE")
write("SFmut_NoDedup",   2, 1, 1, "field", NoDedup="TRUE")
write("SFmut_EarlyAck",  2, 1, 1, "field", EarlyAck="TRUE")
write("SFmut_NoFrom",    2, 2, 1, "field", NoFrom="TRUE")
write("SFmut_NoResend",  2, 1, 1, "field", NoResend="TRUE")
write("SFmut_NoTouch", 2, 2, 0, "narrow", NoTouch="TRUE")
write("SFmut_EqualStamp", 2, 2, 0, "field", EqualStamp="TRUE")
# ---------------- Dify (counterexample hunting: first violation = shortest trace) ----------------
DF = """SPECIFICATION Spec
CONSTANTS
  Clients = {{{clients}}}
  Nodes = {{"n1","n2","n3"}}
  InitNodes = {{"n1","n2"}}
  Fields = {{{fields}}}
  Vals = {{{vals}}}
  MaxOps = {ops}
  MaxFaults = {faults}
  OpKinds = {{{kinds}}}
  NoRef = "none"
  Broken = "broken"
  ListMode = "{listmode}"
  ViewLag = {viewlag}
  UseVis = {vis}
  FaultKinds = {{{faultkinds}}}
  Unset = Unset
  NoInc = NoInc
  DelV = DelV
  NoOrg = NoOrg
  NoRec = NoRec
  Root = Root
CONSTANT Region <- {region}
INVARIANT {inv}
CHECK_DEADLOCK FALSE
"""
q = lambda s: ",".join('"%s"' % x for x in s.split(","))
def wd(name, clients, ops, faults, kinds, inv, fields="f1", vals="v1,v2", listmode="whole", vis="FALSE", region="RegionAll",
       faultkinds='"disc","close","crash","restart"', viewlag="TRUE"):
    open(f"{HERE}/{name}.cfg", "w").write(DF.format(clients=clients, ops=ops, faults=faults, kinds=kinds, inv=inv, fields=q(fields),
        vals=q(vals), listmode=listmode, vis=vis, region=region, faultkinds=faultkinds, viewlag=viewlag))
DIFY = []
def dc(name, *a, **k): wd(name, *a, **k); DIFY.append(name)
# violations (one run per row of the REPORT table)
dc("DF_P1_stale_view",   "1,2", 1, 0, K("setField"), "Inv_P1", fields="f1,f2")
dc("DF_P2_same_field",   "1,2", 1, 0, K("setField"), "Inv_P2")
dc("DF_P5_silent_drop",  "1,2", 1, 0, K("setField"), "Inv_P5", fields="f1,f2")
dc("DF_P1_list_whole",   "1,2", 1, 0, K("listInsert"), "Inv_P1")
dc("DF_P1_list_index",   "1,2", 2, 0, K("listInsert", "listRemove"), "Inv_P1", listmode="index")
dc("DF_P1_zombie",       "1,2", 1, 0, K("removeNode", "setField"), "Inv_P1")
dc("DF_P2_delete_edit",  "1,2", 1, 0, K("removeNode", "setField"), "Inv_P2", vals="v1")
dc("DF_P4_dangling",     "1", 2, 0, K("setRef", "removeNode"), "Inv_P4")
dc("DF_P4_dangling_edge","1,2", 1, 0, K("removeNode", "addEdge"), "Inv_P4")
dc("DF_P1_tab_crash",    "1", 1, 1, K("setField"), "Inv_P1", faultkinds='"crash"')
dc("DF_P1_disconnect",   "1", 1, 1, K("setField"), "Inv_P1", faultkinds='"disc"')
dc("DF_P1_relay_restart","1", 1, 1, K("setField"), "Inv_P1", faultkinds='"restart"')
dc("DF_P3_store_lag",    "1,2", 1, 1, K("setField"), "Inv_P3", faultkinds='"close"', region="RegionSplit")
# unconstrained shortest counterexample per property (all op kinds, 1 fault of any kind)
ALLK = K("setField", "moveNode", "listInsert", "listRemove", "addNode", "removeNode", "addEdge", "setRef")
for _p in ("P1", "P2", "P3", "P4", "P5"):
    dc(f"DF_any_{_p}", "1,2", 2, 1, ALLK, f"Inv_{_p}", fields="f1,f2")
dc("DF_cov_stale_hash", "1,2", 1, 1, K("setField"), "Cov_StaleLeaderHash", faultkinds='"close"', region="RegionSplit")
# properties that must HOLD in Dify when users do not collide (consistency with the 0/20 repro rows)
dc("DF_OK_disjoint",     "1,2", 2, 0, K("setField"), "Inv_P1 Inv_P2 Inv_P3 Inv_P5", fields="f1,f2", region="RegionSplit")
dc("DF_P1_hide_after_edit", "1,2", 1, 0, K("setField"), "Inv_P1", vals="v1", vis="TRUE")
open(HERE + "/../dify_matrix.txt", "w").write("\n".join(DIFY) + "\n")
for _n, (_c, _o, _f, _p) in {"SFlive_2c1o_f2": (2, 1, 2, "narrow"), "SFlive_2c2o_f1_field": (2, 2, 1, "field")}.items():
    write(_n, _c, _o, _f, _p)
    _p2 = f"{HERE}/{_n}.cfg"; _t = open(_p2).read()
    open(_p2, "w").write(_t.replace("SPECIFICATION Spec", "SPECIFICATION LiveSpec").replace("SYMMETRY Sym\n", "").replace("INVARIANTS " + ALLINV, "INVARIANTS Inv_P1 Inv_P2 Inv_P4 Inv_Acked Inv_Truth Inv_Log\nPROPERTY Conv"))
write("SFsim_3c4o_f2_all", 3, 4, 2, "all")
write("SFsim_3c3o_f2_struct", 3, 3, 2, "struct")
for _c in ("Rejected", "RejectDelete", "EqualAccept", "Broken", "Concurrent", "DupInFlight", "ServerCrash", "ClientCrash"):
    write(f"SFcov_{_c}", 2, 2, 1, "narrow")
    _p = f"{HERE}/SFcov_{_c}.cfg"; _t = open(_p).read()
    open(_p, "w").write(_t.replace("INVARIANTS " + ALLINV, f"INVARIANTS Cov_{_c}").replace("CHECK_DEADLOCK TRUE", "CHECK_DEADLOCK FALSE"))
open(HERE + "/../matrix.txt", "w").write("\n".join(names) + "\n")
print("\n".join(names))
