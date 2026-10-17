#!/usr/bin/env python
"""Run the mechanism simulator at the plotted operating points (N in 10/25/50/100, latency 50ms/400ms/2s, mixes
mixed and uniform; lam=0.1, r=0.05) -> results/simmarkers.json.  Long (tens of minutes); chunks run in parallel.
usage: sim_markers.py [--workers 8] [--quick]"""
import argparse, json, math, os, time
from multiprocessing import Pool
import model as M
from sim import Cfg, simulate

HERE = os.path.dirname(os.path.abspath(__file__))
CHUNK = 20000


def job(a):
    pt, seed, n_hot = a
    cfg = Cfg(N=pt["N"], lam=pt["lam"], lat=pt["lat"], r=pt["r"], s=pt["s"], H=pt["H"], p_del=pt["p_del"], w=tuple(pt["w"]),
              T=n_hot / (pt["N"] * pt["lam"] * pt["s"]), seed=7000 + seed)
    ev = simulate(cfg)
    assert ev["converged"]
    return ev


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--workers", type=int, default=8); ap.add_argument("--quick", action="store_true")
    a = ap.parse_args()
    pts, jobs = [], []
    for mix in ("mixed", "uniform"):
        for lat in (0.05, 0.4, 2.0):
            for N in (10, 25, 50, 100):
                p = M.Params(N=N, lat=lat, lam=0.1, r=0.05, lag="uniform").mix(mix)
                bd = M.breakdown(p)
                rate_hot = max(bd["collisions"] / p.s, 1e-6)
                n_hot = int(min(max(400 / rate_hot, 3000), 1.0e7 / (N - 1), 4e5))
                if a.quick:
                    n_hot = min(n_hot, 20000)
                pt = dict(mix=mix, N=N, lam=0.1, lat=lat, r=0.05, s=p.s, H=p.H, p_del=p.p_del, w=list(p.w), n_hot=n_hot)
                pts.append(pt)
                k = max(1, math.ceil(n_hot / CHUNK))
                jobs += [(len(pts) - 1, (pt, sd, n_hot // k)) for sd in range(k)]
    jobs.sort(key=lambda j: -j[1][0]["N"] * j[1][2])        # longest first
    t0 = time.time()
    with Pool(a.workers) as pool:
        res = pool.map(job, [j[1] for j in jobs], chunksize=1)
    out = [dict(pt, n=0, lost={"same": 0, "diff": 0, "list": 0, "delete": 0, "zombie": 0}) for pt in pts]
    for (i, _), ev in zip(jobs, res):
        o = out[i]
        o["n"] += ev["n_edits"] + ev["n_del"]
        for k in ("same", "diff", "list", "delete"):
            o["lost"][k] += ev["lost"][k]
        o["lost"]["zombie"] += ev["del_lost"]
    json.dump(out, open(os.path.join(HERE, "results", "simmarkers.json"), "w"), indent=1)
    print(f"done in {time.time()-t0:.0f}s, {len(jobs)} chunks")
    for o in out:
        l = sum(o["lost"].values()); p = M.Params(N=o["N"], lat=o["lat"], lam=0.1, r=0.05, lag="uniform").mix(o["mix"])
        print(o["mix"], o["N"], o["lat"], "hot edits", o["n"], "lost", l, "sim/hot-event %.5f  model %.5f" % (l / o["n"], M.breakdown(p)["collisions"] / p.s))


if __name__ == "__main__":
    main()
