#!/usr/bin/env python
"""Closed form (model.py) vs mechanism simulator (sim.py) over a parameter grid.
usage: compare_sim_model.py [--quick] [--workers 8]      -> results/simgrid.json + printed table"""
import argparse, json, math, os, time
from multiprocessing import Pool
import numpy as np
import model as M
from sim import Cfg, simulate, World

HERE = os.path.dirname(os.path.abspath(__file__))


def cells(quick):
    out = []
    target = 2500 if quick else 7000          # hot edits per run
    seeds = 2 if quick else 4
    for N in (5, 10, 25, 50):
        for lat in (0.05, 0.4, 2.0):
            for r in (0.05, 0.25):
                out.append(dict(tag="grid", N=N, lat=lat, r=r, lam=0.1, s=1.0, H=20, p_del=0.0, lag_mode="frame", target=target, seeds=seeds))
    for lam in (1 / 60, 1 / 30, 1 / 10, 1 / 3):                       # per-user rate sweep
        out.append(dict(tag="lam", N=25, lat=0.4, r=0.1, lam=lam, s=1.0, H=20, p_del=0.0, lag_mode="frame", target=target, seeds=seeds))
    for H in (5, 10, 40, 100):                                        # contention sweep
        out.append(dict(tag="H", N=20, lat=0.4, r=0.1, lam=0.1, s=1.0, H=H, p_del=0.0, lag_mode="frame", target=target, seeds=seeds))
    for pd in (0.02, 0.05, 0.1):                                      # delete vs edit
        for lat in (0.05, 0.4):
            out.append(dict(tag="del", N=10, lat=lat, r=0.1, lam=0.1, s=1.0, H=20, p_del=pd, lag_mode="frame", target=target * 2, seeds=seeds))
    for N, lat in ((50, 0.4), (50, 2.0)):                             # realistic sparse mix: s=0.25, H=25
        out.append(dict(tag="mixed", N=N, lat=lat, r=0.05, lam=0.1, s=0.25, H=25, p_del=0.0, lag_mode="frame", target=target * (2 if quick else 5), seeds=seeds))
    for N, lat in ((2, 0.05), (2, 0.4), (10, 0.4)):                   # harness-like constant per-import callback delay
        out.append(dict(tag="per_import", N=N, lat=lat, r=0.25, lam=0.1, s=1.0, H=20, p_del=0.0, lag_mode="per_import", target=target, seeds=seeds))
    return out


def run_one(args):
    c, seed = args
    hot_rate = c["N"] * c["lam"] * c["s"]
    cfg = Cfg(N=c["N"], lam=c["lam"], lat=c["lat"], r=c["r"], s=c["s"], H=c["H"], p_del=c["p_del"], lag_mode=c["lag_mode"],
              T=c["target"] / hot_rate, seed=1000 + seed)
    ev = simulate(cfg)
    assert ev["converged"], "replicas diverged"
    return ev


def model_pred(c):
    lag = "const" if c["lag_mode"] == "per_import" else "uniform"
    names = ["same", "diff", "list"]
    cnt = World._assign_kinds(type("X", (), {"cfg": Cfg(H=c["H"])})())      # realised node-kind counts (rounding at small H)
    w = tuple(names.count(k) / c["H"] for k in cnt) if False else tuple(cnt.count(k) / c["H"] for k in names)
    p = M.Params(N=c["N"], lam=c["lam"], lat=c["lat"], r=c["r"], s=c["s"], H=c["H"], p_del=c["p_del"], lag=lag, w=w)
    bd = M.breakdown(p)
    s = c["s"]
    # per hot EVENT (sim only generates hot events) -> divide model fractions of all edits by s
    return {k: bd[k] / s for k in ("a_lww", "b_revert", "c_list", "d_delete")}


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--quick", action="store_true"); ap.add_argument("--workers", type=int, default=8)
    a = ap.parse_args()
    cs = cells(a.quick)
    jobs = [(c, sd) for c in cs for sd in range(c["seeds"])]
    t0 = time.time()
    with Pool(a.workers) as pool:
        res = pool.map(run_one, jobs, chunksize=1)
    rows, i = [], 0
    for c in cs:
        evs = res[i:i + c["seeds"]]; i += c["seeds"]
        n = sum(e["n_edits"] + e["n_del"] for e in evs)
        lost = {k: sum(e["lost"][k] for e in evs) for k in ("same", "diff", "list", "delete")}
        lost["zombie"] = sum(e["del_lost"] for e in evs)
        pred = model_pred(c)
        # sim: per hot event; 'delete' mechanism = edits lost because their node ended up deleted + deletes undone (zombie)
        sim = {"a_lww": lost["same"] / n, "b_revert": lost["diff"] / n, "c_list": lost["list"] / n, "d_delete": (lost["delete"] + lost["zombie"]) / n}
        sim["total"] = sum(sim.values()); pred["total"] = sum(pred.values())
        rows.append(dict(cfg=c, n=n, lost=lost, sim=sim, model=pred))
    json.dump(rows, open(os.path.join(HERE, "results", "simgrid_quick.json" if a.quick else "simgrid.json"), "w"), indent=1)
    print(f"{len(jobs)} simulations in {time.time()-t0:.0f}s")
    print(f"{'tag':10s} {'N':>3s} {'lat':>5s} {'r':>5s} {'lam':>6s} {'H':>3s} {'pdel':>4s} | {'sim_total':>9s} {'model':>9s} {'z':>6s} | per-mech (sim/model)  a_lww  b_rev  c_list d_del")
    zs, ab, rel = [], [], []
    for R in rows:
        c, n, S, Mo = R["cfg"], R["n"], R["sim"], R["model"]
        se = math.sqrt(max(Mo["total"] * (1 - Mo["total"]) / n, 1e-12)) * 1.0
        z = (S["total"] - Mo["total"]) / se
        zs.append(z); ab.append(abs(S["total"] - Mo["total"]))
        if sum(R["lost"].values()) >= 30: rel.append(abs(S["total"] - Mo["total"]) / Mo["total"])
        mech = "  ".join(f"{S[k]:.4f}/{Mo[k]:.4f}" for k in ("a_lww", "b_revert", "c_list", "d_delete"))
        print(f"{c['tag']:10s} {c['N']:3d} {c['lat']:5.2f} {c['r']:5.2f} {c['lam']:6.3f} {c['H']:3d} {c['p_del']:4.2f} | {S['total']:9.5f} {Mo['total']:9.5f} {z:6.1f} | {mech}")
    print(f"\nmax |sim-model| (per hot event) = {max(ab):.4f};  max relative error over cells with >=30 lost events = {max(rel):.1%}; "
          f"median rel = {np.median(rel):.1%};  rms z = {np.sqrt(np.mean(np.square(zs))):.2f}; |z|>3 in {sum(abs(z)>3 for z in zs)}/{len(zs)} cells")


if __name__ == "__main__":
    main()
