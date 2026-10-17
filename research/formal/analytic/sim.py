#!/usr/bin/env python
"""Mechanism-level Monte-Carlo simulator of the Dify 1.17.1 collaborative-editor data path.

Independent of model.py (no formula is used here).  It implements M1..M5 of the brief literally:
  * every client has a Loro-like doc (map keys = LWW registers ordered by (lamport, peer); skip-if-equal set;
    nodes map with delete/re-create; list container as an RGA sequence with tombstones),
  * a React-Flow-like VIEW per client that is refreshed from the doc only after a lag (rAF + render),
  * every local edit = write the WHOLE node from the view into the doc (populateNodeContainer / syncList by index),
  * every commit sends the CUMULATIVE update (version vector) through a relay with per-leg latency.
The same Client/World code runs on two doc backends: ToyDoc (this file) and LoroBackendDoc (real python loro 1.16.2),
which is what validate_vs_loro.py compares.

Loss accounting (toy backend only): an acknowledged edit is LOST iff its effect is absent from the converged final
state and no later write made from a view that CONTAINED it superseded it (provenance chains / delete 'seen' sets).
"""
import heapq
import math
import random
from dataclasses import dataclass, field

import numpy as np

LIST_KEY = "L"


# ------------------------------------------------------------------------------------------------ toy CRDT doc

class FugueList:
    """Sequence CRDT with tombstones, Fugue-style tree (what Loro's LoroList uses): a new element is the right child of
    its left origin, or - if that already has right children - the left child of its right origin; siblings ordered by
    (peer, lamport)."""

    def __init__(self):
        self.rch, self.lch = {}, {}
        self.vals, self.tomb = {}, set()
        self._seq = None

    def insert(self, eid, parent, side, val):
        self.vals[eid] = val
        d = self.rch if side == "R" else self.lch
        sib = d.setdefault(parent, [])
        sib.append(eid)
        sib.sort(key=lambda e: (e[1], e[0]))
        self._seq = None

    def seq(self):
        if self._seq is None:
            out, stack = [], [("visit", None)]           # None = root sentinel
            while stack:
                act, e = stack.pop()
                if act == "emit":
                    out.append(e)
                    continue
                # in-order: left children, node, right children  (push reversed)
                for c in reversed(self.rch.get(e, [])):
                    stack.append(("visit", c))
                if e is not None:
                    stack.append(("emit", e))
                for c in reversed(self.lch.get(e, [])):
                    stack.append(("visit", c))
            self._seq = out
        return self._seq

    def visible(self):
        return [e for e in self.seq() if e not in self.tomb]

    def origins_for_insert(self, i):
        """local insert at visible index i -> (parent, side)"""
        vis = self.visible()
        seq = self.seq()
        left = vis[i - 1] if i > 0 else None
        if not self.rch.get(left):
            return left, "R"
        pos = (seq.index(left) + 1) if left is not None else 0
        return seq[pos], "L"                              # right origin = element right after left origin (incl. tombstones)


class Store:
    """Global immutable op log (peer -> list of ops) shared by all toy docs; messages carry only version vectors."""

    def __init__(self, n):
        self.ops = [[] for _ in range(n)]
        self.cid_node = {}


class ToyDoc:
    backend = "toy"

    def __init__(self, peer, store, n):
        self.peer, self.store = peer, store
        self.vv = np.zeros(n, dtype=np.int64)
        self.lam = 0
        self.nodes = {}   # nid -> (lam, peer, cid|None)      LWW register in the nodes map (None = tombstone)
        self.cont = {}    # cid -> (regs{key:(lam,peer,val)}, lists{key:(seq,tomb,vals)})
        self.pending = 0

    # --- op application (idempotent, commutative except RGA which is made order-independent by lamport sorting)
    def _apply(self, op):
        lam, peer, kind, a = op
        ts = (lam, peer)
        if kind == "N":
            nid, cid = a
            cur = self.nodes.get(nid)
            if cur is None or ts > cur[:2]:
                self.nodes[nid] = (lam, peer, cid)
            if cid is not None:
                self.cont.setdefault(cid, ({}, {LIST_KEY: FugueList()}))
        elif kind == "R":
            cid, key, val = a
            regs = self.cont.setdefault(cid, ({}, {LIST_KEY: FugueList()}))[0]
            cur = regs.get(key)
            if cur is None or ts > cur[:2]:
                regs[key] = (lam, peer, val)
        elif kind == "I":
            cid, key, eid, parent, side, val = a
            self.cont.setdefault(cid, ({}, {LIST_KEY: FugueList()}))[1][key].insert(eid, parent, side, val)
        elif kind == "D":
            cid, key, eid = a
            self.cont[cid][1][key].tomb.add(eid)

    def _emit(self, kind, *a):
        self.lam += 1
        op = (self.lam, self.peer, kind, a)
        self.store.ops[self.peer].append(op)
        self.vv[self.peer] += 1
        self._apply(op)
        self.pending += 1
        return (self.lam, self.peer)

    # --- reads
    def node_cid(self, nid):
        cur = self.nodes.get(nid)
        return cur[2] if cur else None

    def get_regs(self, cid):
        return {k: v[2] for k, v in self.cont[cid][0].items() if v[2] is not None and k != LIST_KEY}

    def list_ids(self, cid, key=LIST_KEY):
        return self.cont[cid][1][key].visible()

    def list_vals(self, cid, key=LIST_KEY):
        L = self.cont[cid][1][key]
        return [L.vals[e] for e in L.visible()]

    def snapshot_node(self, nid):
        cid = self.node_cid(nid)
        return None if cid is None else (self.get_regs(cid), {LIST_KEY: self.list_vals(cid)})

    # --- local writes
    def new_node(self, nid):
        cid = (self.lam + 1, self.peer)
        self.store.cid_node[cid] = nid
        self._emit("N", nid, cid)
        self._emit("R", cid, LIST_KEY, "list")       # creating the child list container is one more op (lamport parity with Loro)
        return cid

    def del_node(self, nid):
        if self.node_cid(nid) is None:
            return None
        return self._emit("N", nid, None)

    def set_reg(self, cid, key, val):
        self._emit("R", cid, key, val)

    def del_reg(self, cid, key):
        self._emit("R", cid, key, None)

    def list_delete(self, cid, key, i):
        self._emit("D", cid, key, self.list_ids(cid, key)[i])

    def list_insert(self, cid, key, i, val):
        parent, side = self.cont[cid][1][key].origins_for_insert(i)
        self._emit("I", cid, key, (self.lam + 1, self.peer), parent, side, val)

    # --- sync
    def commit(self):
        if not self.pending:
            return None
        self.pending = 0
        return self.vv.copy()                      # cumulative update message (M7)

    def import_(self, msg):
        idx = np.nonzero(msg > self.vv)[0]
        if len(idx) == 0:
            return None
        ops = []
        for p in idx:
            ops.extend(self.store.ops[p][self.vv[p]:msg[p]])
            self.vv[p] = msg[p]
        ops.sort(key=lambda o: (o[0], o[1]))
        dirty = set()
        for op in ops:
            self._apply(op)
            self.lam = max(self.lam, op[0])
            a = op[3]
            dirty.add(a[0] if op[2] == "N" else self.store.cid_node[a[0]])
        return dirty

    def canonical(self):
        out = {}
        for nid, (_, _, cid) in self.nodes.items():
            if cid is not None:
                regs = self.get_regs(cid)
                regs[LIST_KEY] = self.list_vals(cid)
                out[nid] = regs
        return out


# ------------------------------------------------------------------------------------------------ real Loro backend
class LoroBackendDoc:
    """Same interface on top of python loro (used only by validate_vs_loro.py)."""
    backend = "loro"

    def __init__(self, peer, store=None, n=None):
        import loro
        self.loro = loro
        self.d = loro.LoroDoc()
        self.d.peer_id = peer + 1
        self.nodes = self.d.get_map("nodes")
        self.pending = False
        self.cid_nid = {}

    def node_cid(self, nid):
        v = self.nodes.get(str(nid))
        return None if v is None else v.container

    def get_regs(self, cid):
        return {k: v for k, v in cid.get_deep_value().items() if k != LIST_KEY}

    def _list(self, cid, key):
        return cid.get(key).container

    def list_vals(self, cid, key=LIST_KEY):
        return list(self._list(cid, key).get_deep_value())

    def snapshot_node(self, nid):
        cid = self.node_cid(nid)
        return None if cid is None else (self.get_regs(cid), {LIST_KEY: self.list_vals(cid)})

    def new_node(self, nid):
        cid = self.nodes.insert_container(str(nid), self.loro.LoroMap())
        cid.insert_container(LIST_KEY, self.loro.LoroList())
        self.pending = True
        return cid

    def del_node(self, nid):
        if self.node_cid(nid) is None:
            return None
        self.nodes.delete(str(nid))
        self.pending = True
        return True

    def set_reg(self, cid, key, val):
        cid.insert(key, val)
        self.pending = True

    def del_reg(self, cid, key):
        cid.delete(key)
        self.pending = True

    def list_delete(self, cid, key, i):
        self._list(cid, key).delete(i, 1)
        self.pending = True

    def list_insert(self, cid, key, i, val):
        self._list(cid, key).insert(i, val)
        self.pending = True

    def commit(self):
        self.d.commit()
        if not self.pending:
            return None
        self.pending = False
        return self.d.export(self.loro.ExportMode.Updates(self.loro.VersionVector()))   # cumulative (M7)

    def import_(self, msg):
        before = str(self.d.oplog_vv)
        self.d.import_(msg)
        return None if str(self.d.oplog_vv) == before else {None}   # None = "anything changed" (view refreshes wholesale)

    def canonical(self):
        return {int(k): v for k, v in self.nodes.get_deep_value().items()}


# ------------------------------------------------------------------------------------------------ client logic
class Client:
    """React view + the Dify write path (syncNodes -> getNodeContainer -> populateNodeContainer -> syncList)."""

    def __init__(self, idx, doc):
        self.idx, self.doc = idx, doc
        self.view = {}          # nid -> (regs, lists)       == React-Flow nodes
        self.dirty = set()      # nids whose doc state changed through imports since the last view refresh
        self.dirty_all = False
        self.refresh_pending = None

    def refresh_view(self):
        """rAF callback: view := doc (what nodesMap.subscribe(import) -> setNodes does)."""
        if self.dirty_all:
            self.view = {nid: s for nid in self.doc.canonical() if (s := self.doc.snapshot_node(nid))}
        else:
            for nid in self.dirty:
                s = self.doc.snapshot_node(nid)
                if s is None:
                    self.view.pop(nid, None)
                else:
                    self.view[nid] = s
        self.dirty, self.dirty_all = set(), False

    def populate(self, nid, regs, lists):
        d = self.doc
        cid = d.node_cid(nid)
        if cid is None:                                   # getNodeContainer: recreate container (zombie / first write)
            cid = d.new_node(nid)
        cur = d.get_regs(cid)
        for k in sorted(set(regs) | set(cur)):            # container.set(key, v): skipped when equal (U1)
            if regs.get(k) != cur.get(k):
                if k in regs:
                    d.set_reg(cid, k, regs[k])
                else:
                    d.del_reg(cid, k)
        for k, target in lists.items():                   # syncList: index-wise diff against the DOC list
            current = d.list_vals(cid, k)
            m = min(len(current), len(target))
            for i in range(m):
                if current[i] != target[i]:
                    d.list_delete(cid, k, i)
                    d.list_insert(cid, k, i, target[i])
            if len(current) > len(target):
                for _ in range(len(current) - len(target)):
                    d.list_delete(cid, k, len(target))
            else:
                for i in range(len(current), len(target)):
                    d.list_insert(cid, k, i, target[i])


# ------------------------------------------------------------------------------------------------ world / DES
@dataclass
class Cfg:
    N: int = 10
    lam: float = 0.1            # edits / s / user (ALL edits; only the hot fraction s is simulated, private ones never interact)
    lat: float = 0.05           # one-way client<->relay latency (s); path L = 2*lat + L0
    L0: float = 0.0             # extra relay/processing delay (s)
    jitter: float = 0.0         # mean of an exponential extra delay per leg (0 = constant)
    r: float = 0.05             # MEAN view lag (s)
    lag_mode: str = "frame"     # 'frame': refresh on a per-client frame grid with period 2r (lag ~ U(0,2r), coalesced)
                                # 'per_import': every import schedules its own callback at +r (harness rAF-delay stress)
    s: float = 1.0              # fraction of edits that go to the hot set
    H: int = 10                 # hot nodes
    w: tuple = (0.4, 0.3, 0.3)  # node kinds: same register / different fields / list append
    p_del: float = 0.0          # fraction of hot events that delete a node (and create a replacement)
    T: float = 300.0
    seed: int = 1
    backend: str = "toy"
    script: list = None         # optional [(t, client, 'edit'|'del', node_index)] replaces the Poisson generator
    node_kinds: list = None     # optional explicit kind per initial node


class World:
    def __init__(self, cfg):
        self.cfg = cfg
        self.rng = random.Random(cfg.seed)
        N = cfg.N
        self.store = Store(N)
        mk = (lambda i: ToyDoc(i, self.store, N)) if cfg.backend == "toy" else (lambda i: LoroBackendDoc(i))
        self.clients = [Client(i, mk(i)) for i in range(N)]
        self.heap, self.seq, self.t = [], 0, 0.0
        self.kind_of, self.next_nid = {}, 0
        self.edits, self.par, self.deletes = {}, {0: None}, {}
        self.next_eid = 1
        self.n_msgs = 0
        # --- initial graph: H hot nodes, kinds assigned by weights (deterministic proportions), created by client 0
        kinds = cfg.node_kinds or self._assign_kinds()
        c0 = self.clients[0]
        for kd in kinds:
            nid = self._new_nid(kd)
            c0.populate(nid, *self._fresh_node(kd))
        msg = c0.doc.commit()
        for c in self.clients[1:]:
            c.doc.import_(msg)
        for c in self.clients:
            c.dirty_all = True
            c.refresh_view()
        self.seed_msg = msg

    # ---------------------------------------------------------------- helpers
    def _assign_kinds(self):
        H, w = self.cfg.H, self.cfg.w
        names = ["same", "diff", "list"]
        counts = [int(round(H * x)) for x in w]
        counts[0] += H - sum(counts)
        return [n for n, c in zip(names, counts) for _ in range(c)]

    def _new_nid(self, kind):
        nid = self.next_nid
        self.next_nid += 1
        self.kind_of[nid] = kind
        return nid

    @staticmethod
    def _fresh_node(kind):
        return ({"T": 0} if kind == "same" else {}), {LIST_KEY: []}

    def push(self, t, kind, *args):
        self.seq += 1
        heapq.heappush(self.heap, (t, self.seq, kind, args))

    def leg(self):
        c = self.cfg
        return c.lat + (self.rng.expovariate(1 / c.jitter) if c.jitter > 0 else 0.0)

    # ---------------------------------------------------------------- local actions
    def do_edit(self, ci, t, pick):
        c = self.clients[ci]
        ids = sorted(c.view)
        nid = ids[pick % len(ids)]
        kind = self.kind_of[nid]
        regs, lists = c.view[nid]
        regs, lists = dict(regs), {k: list(v) for k, v in lists.items()}
        eid = self.next_eid
        self.next_eid += 1
        if kind == "list":
            key = LIST_KEY
            lists[LIST_KEY] = lists[LIST_KEY] + [eid]
        else:
            key = "T" if kind == "same" else f"f{ci}"
            self.par[eid] = regs.get(key)
            regs[key] = eid
        self.edits[eid] = (t, ci, nid, kind, key)
        c.view[nid] = (regs, lists)
        c.populate(nid, regs, lists)
        self.after_commit(ci, t)

    def seen_set(self, regs, lists):
        seen = set()
        for v in regs.values():
            while v is not None and v not in seen:
                seen.add(v)
                v = self.par.get(v)
        seen.update(lists.get(LIST_KEY, []))
        return seen

    def do_delete(self, ci, t, pick):
        c = self.clients[ci]
        ids = sorted(c.view)
        nid = ids[pick % len(ids)]
        kind = self.kind_of[nid]
        regs, lists = c.view.pop(nid)
        seen = self.seen_set(regs, lists)
        ts = c.doc.del_node(nid)
        if ts is None:                     # already deleted in this doc: nothing written
            c.doc.commit()
            return
        self.deletes[ts] = (nid, ci, t, seen)
        nn = self._new_nid(kind)           # replacement node (keeps the hot set size constant)
        fr = self._fresh_node(kind)
        c.view[nn] = (dict(fr[0]), {k: list(v) for k, v in fr[1].items()})
        c.populate(nn, *fr)
        self.after_commit(ci, t)

    def after_commit(self, ci, t):
        msg = self.clients[ci].doc.commit()
        if msg is None:
            return
        self.n_msgs += 1
        L0 = self.cfg.L0
        for j in range(self.cfg.N):
            if j != ci:
                self.push(t + self.leg() + self.leg() + L0, "deliver", j, msg)

    def on_deliver(self, j, t, msg):
        c = self.clients[j]
        dirty = c.doc.import_(msg)
        if dirty is None:
            return
        if None in dirty:
            c.dirty_all = True
        c.dirty |= dirty
        r = self.cfg.r
        if self.cfg.lag_mode == "frame":
            P = 2 * r
            if c.refresh_pending is None:
                phase = (j * 0.6180339887) % 1.0 * P                       # per-client frame phase
                nxt = t + ((phase - t) % P)
                c.refresh_pending = nxt
                self.push(nxt, "refresh", j)
        else:
            self.push(t + r, "refresh", j)

    # ---------------------------------------------------------------- run
    def run(self):
        cfg = self.cfg
        if cfg.script is not None:
            for (t, ci, what, pick) in cfg.script:
                self.push(t, what, ci, pick)
        else:
            rate = cfg.N * cfg.lam * cfg.s
            if rate > 0:
                self.push(self.rng.expovariate(rate), "gen")
        while self.heap:
            t, _, kind, a = heapq.heappop(self.heap)
            self.t = t
            if kind == "gen":
                if t > cfg.T:
                    continue
                ci = self.rng.randrange(cfg.N)
                what = "del" if self.rng.random() < cfg.p_del else "edit"
                self.push(t, what, ci, self.rng.randrange(1 << 30))
                self.push(t + self.rng.expovariate(cfg.N * cfg.lam * cfg.s), "gen")
            elif kind == "edit":
                self.do_edit(a[0], t, a[1])
            elif kind == "del":
                self.do_delete(a[0], t, a[1])
            elif kind == "deliver":
                self.on_deliver(a[0], t, a[1])
            elif kind == "refresh":
                c = self.clients[a[0]]
                c.refresh_pending = None
                c.refresh_view()
        return self

    # ---------------------------------------------------------------- evaluation (toy backend)
    def converged(self):
        ref = self.clients[0].doc.canonical()
        return all(c.doc.canonical() == ref for c in self.clients[1:])

    def _survives_in(self, doc, cid, kind, key, eid):
        """is edit eid part of container cid's current content (register lineage / list items)?"""
        if cid not in doc.cont:
            return False
        if kind == "list":
            return eid in doc.list_vals(cid)
        reg = doc.cont[cid][0].get(key)
        v = reg[2] if reg else None
        while v is not None:
            if v == eid:
                return True
            v = self.par.get(v)
        return False

    def evaluate(self):
        """Count silently lost edits in the converged final state of client 0.
        alive node  : lost iff the edit is not in the winning container's content (register lineage / list items)
        deleted node: if the edit had already vanished from every container -> lost under its own kind (it was lost
                      before the delete); else lost 'by delete' iff the deleter's view had not seen it."""
        doc = self.clients[0].doc
        cids_of = {}
        for cid, nid in self.store.cid_node.items():
            cids_of.setdefault(nid, []).append(cid)
        lost = {"same": 0, "diff": 0, "list": 0, "delete": 0}
        tot = {"same": 0, "diff": 0, "list": 0}
        for eid, (t, ci, nid, kind, key) in self.edits.items():
            tot[kind] += 1
            cur = doc.nodes.get(nid)
            if cur is not None and cur[2] is not None:
                if not self._survives_in(doc, cur[2], kind, key, eid):
                    lost[kind] += 1
            else:
                alive_somewhere = any(self._survives_in(doc, cid, kind, key, eid) for cid in cids_of.get(nid, []))
                if not alive_somewhere:
                    lost[kind] += 1
                else:
                    seen = self.deletes.get(cur[:2] if cur else None, (None, None, None, set()))[3]
                    if eid not in seen:
                        lost["delete"] += 1
        d_lost = sum(1 for ts, (nid, ci, t, seen) in self.deletes.items()
                     if (doc.nodes.get(nid) or (0, 0, None))[2] is not None)
        return {"n_edits": len(self.edits), "n_del": len(self.deletes), "tot": tot, "lost": lost,
                "del_lost": d_lost, "msgs": self.n_msgs}


def simulate(cfg: Cfg):
    w = World(cfg).run()
    ev = w.evaluate()
    ev["converged"] = w.converged()
    return ev


def rates(ev):
    """Per-event loss rates from one evaluation dict."""
    n = ev["n_edits"] + ev["n_del"]
    lost = sum(ev["lost"].values()) + ev["del_lost"]
    return lost / max(n, 1)


# ------------------------------------------------------------------------------------------------ persistence DES (M6)
def sim_persistence(N=20, lam=0.1, L=0.8, r=0.05, D=5.0, mu=1 / 600, kappa=1 / 1800, T=2e5, seed=1, stale_first_save=True):
    """Debounced leader-save pipeline.  Returns (edits, lost_permanently, at_risk_edits).
    * every local edit restarts that client's trailing debounce(D); on fire: leader saves its view; a follower
      sends sync_request, the leader imports (+L), refreshes (+r) and saves;
    * leader exit (rate mu): leader's timers/pending save die; random other client becomes leader; its FIRST save
      fails (stale unique_hash) and is not retried; the departed tab is replaced by a fresh one;
    * room end (rate kappa): every tab closes/relay restarts -> every non-durable edit is lost for good."""
    rng = random.Random(seed)
    ev, seq = [], 0

    def push(t, k, *a):
        nonlocal seq
        seq += 1
        heapq.heappush(ev, (t, seq, k, a))

    push(rng.expovariate(N * lam), "edit")
    push(rng.expovariate(mu), "exit")
    push(rng.expovariate(kappa), "end")
    leader, epoch, stale = 0, 0, False
    edits = []                 # [t, author, durable?]
    live = []                  # indices of non-durable edits
    gen = [0] * N              # debounce generation per client (lazy cancel)
    n_edits = lost = at_risk = 0
    at_risk_set = set()
    while ev:
        t, _, k, a = heapq.heappop(ev)
        if t > T:
            break
        if k == "edit":
            u = rng.randrange(N)
            edits.append([t, u, False])
            live.append(len(edits) - 1)
            n_edits += 1
            gen[u] += 1
            push(t + D, "fire", u, gen[u], epoch)
            push(t + rng.expovariate(N * lam), "edit")
        elif k == "fire":
            u, g, ep = a
            if g != gen[u] or ep != epoch:
                continue
            if u == leader:
                push(t, "save", epoch)
            else:
                push(t + L + r, "save", epoch)       # sync_request -> import -> rAF refresh -> save
        elif k == "save":
            if a[0] != epoch:
                continue
            if stale:
                stale = False                        # first save after hand-off fails; hash refreshed; no retry
                continue
            keep = []
            for i in live:
                te, au, _ = edits[i]
                arrive = te if au == leader else te + L + r      # author's edit visible in the leader's VIEW
                if arrive <= t:
                    edits[i][2] = True
                else:
                    keep.append(i)
            live = keep
        elif k == "exit":
            epoch += 1
            stale = stale_first_save
            cand = [x for x in range(N) if x != leader]
            old = leader
            leader = rng.choice(cand)
            gen[old] += 1                            # departed tab replaced by a fresh one: its timer died
            at_risk_set.update(live)
            push(t + rng.expovariate(mu), "exit")
        elif k == "end":
            lost += len(live)
            live = []
            epoch += 1
            stale = False
            leader = rng.randrange(N)
            gen = [g + 1 for g in gen]
            push(t + rng.expovariate(kappa), "end")
    return {"edits": n_edits, "lost": lost, "at_risk": len(at_risk_set)}


if __name__ == "__main__":
    cfg = Cfg(N=10, lat=0.4, r=0.05, T=300)
    ev = simulate(cfg)
    print(ev, "rate/hot-event", rates(ev))
