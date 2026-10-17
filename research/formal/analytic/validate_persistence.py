#!/usr/bin/env python
"""Persistence term: debounce/leader-save/hand-off/room-end DES (sim.sim_persistence) vs model.persistence_per_edit.
Churn rates are INFLATED here (room end every ~10-30 min, leader exit every 1-5 min) only to get statistics; the formula is linear in them."""
import sys
from multiprocessing import Pool
import model as M
from sim import sim_persistence

CASES = [dict(N=20, lam=0.1, L=0.8, mu=1/300, kappa=1/600), dict(N=5, lam=0.3, L=0.1, mu=1/200, kappa=1/400),
         dict(N=50, lam=0.05, L=4.0, mu=1/300, kappa=1/500), dict(N=3, lam=0.02, L=0.1, mu=1/300, kappa=1/1000),
         dict(N=2, lam=0.05, L=0.1, mu=1/100, kappa=1/800), dict(N=10, lam=0.1, L=0.8, mu=1/60, kappa=1/2000)]

def f(a):
    kw, s, T = a
    return sim_persistence(T=T, seed=s, **kw)

if __name__ == "__main__":
    T = float(sys.argv[1]) if len(sys.argv) > 1 else 4e5
    print(f"{'case':58s} {'sim':>9s} {'model':>9s} {'rel.err':>8s}   at-risk(sim/model)")
    with Pool(8) as pool:
        for kw in CASES:
            res = pool.map(f, [(kw, s, T) for s in range(8)])
            e = sum(r["edits"] for r in res); l = sum(r["lost"] for r in res); ar = sum(r["at_risk"] for r in res)
            p = M.Params(N=kw["N"], lam=kw["lam"], lat=kw["L"] / 2, r=0.05, mu=kw["mu"], kappa=kw["kappa"])
            tot = M.persistence_per_edit(p)[0]
            print(f"{str(kw):58s} {l/e:9.5f} {tot:9.5f} {tot/(l/e)-1:+8.1%}   {ar/e:.4f}/{kw['mu']*M.t_durable(p):.4f}  (+-{l**.5/e:.5f})")
