#!/usr/bin/env python
"""Mechanism check of the pair windows: two clients, one edit each, gap g apart, const view lag r (per_import mode),
path L = 2*lat.  Compare the simulator's 'lost edit' indicator with model.p_pair / p_pair_delete (step functions)."""
import numpy as np
import model as M
from sim import Cfg, World

lat, r = 0.05, 0.08
L = 2 * lat

def run(kind, g, first="A"):
    script = [(0.0, 0, "edit", 0), (g, 1, "edit", 0)]
    cfg = Cfg(N=2, lat=lat, r=r, lag_mode="per_import", script=script, node_kinds=[kind], H=1, seed=1)
    ev = World(cfg).run().evaluate()
    return sum(ev["lost"].values()) + ev["del_lost"]

def run_del(g):
    script = [(0.0, 0, "del", 0), (g, 1, "edit", 0)]            # A deletes, B edits the same node g later (g may be < 0)
    if g < 0:
        script = [(0.0, 1, "edit", 0), (-g, 0, "del", 0)]       # B edits first, A deletes -g later
    cfg = Cfg(N=2, lat=lat, r=r, lag_mode="per_import", script=script, node_kinds=["same"], H=1, seed=1)
    ev = World(cfg).run().evaluate()
    return sum(ev["lost"].values()) + ev["del_lost"]

gs = np.round(np.arange(0.0, 0.40, 0.0025), 4)
tot_bad = 0
for kind, mk in (("same", "lww"), ("diff", "diff"), ("list", "list")):
    sim = np.array([run(kind, g) for g in gs]); mod = M.p_pair(mk, gs, L, r, "const")
    edge = np.min(np.abs(gs[:, None] - np.array([L, L + r])[None, :]), axis=1) < 1e-9      # exact-equality ties are measure zero
    bad = gs[((sim > 0) != (mod > 0.5)) & ~edge]
    on = gs[sim > 0]
    print(f"{kind:5s}: lost for g in [{on.min():.4f}, {on.max():.4f}] ({len(on)} of {len(gs)} grid points); model window {'|g|<L+r = %.3f' % (L + r) if kind=='same' else '(L, L+r) = (%.3f, %.3f)' % (L, L + r)}; "
          f"disagreements: {len(bad)} {list(bad[:6])}")
    tot_bad += len(bad)
ds = np.round(np.arange(-0.40, 0.40, 0.005), 4)
sim = np.array([run_del(d) for d in ds]); el, dl = M.p_pair_delete(ds, L, r)
mod = (el + dl) > 0
edge = np.min(np.abs(np.abs(ds)[:, None] - np.array([L, L + r])[None, :]), axis=1) < 1e-9
bad = ds[((sim > 0) != mod) & ~edge]
print(f"del-vs-edit: lost for delta in [{ds[sim>0].min():.3f},{ds[sim>0].max():.3f}] model: edit lost in (-(L+r), L) = ({-(L+r):.3f}, {L:.3f}), delete lost in [L, L+r) = [{L:.3f},{L+r:.3f}); disagreements {len(bad)} {list(bad[:8])}")
tot_bad += len(bad)
print("PASS" if tot_bad == 0 else f"{tot_bad} boundary disagreements (inspect)")
