#!/usr/bin/env python
"""Replay random 2-3 user schedules through (a) the toy CRDT doc of sim.py and (b) REAL Loro (python loro 1.16.2)
with the identical Client/populate/syncList/view-refresh/relay code (sim.World, only the doc backend differs) and
check that the converged final states are identical.  usage: validate_vs_loro.py [n_schedules=400]"""
import random, sys
from sim import Cfg, World

def schedule(rng):
    N = rng.choice([2, 3])
    n_ev = rng.randint(4, 14)
    span = rng.choice([0.3, 1.0, 3.0])
    script = []
    for _ in range(n_ev):
        what = "del" if rng.random() < 0.12 else "edit"
        script.append((rng.uniform(0, span), rng.randrange(N), what, rng.randrange(1 << 20)))
    return Cfg(N=N, H=rng.choice([2, 3, 4]), lat=rng.choice([0.005, 0.05, 0.2]), jitter=rng.choice([0.0, 0.03]),
               r=rng.choice([0.01, 0.05, 0.15]), lag_mode=rng.choice(["frame", "per_import"]),
               script=script, seed=rng.randrange(1 << 30), w=rng.choice([(0.4, 0.3, 0.3), (0.34, 0.33, 0.33), (1, 0, 0), (0, 0, 1)]))

def main(n):
    rng = random.Random(2024)
    bad, tot_ops, conv_bad, interesting = [], 0, 0, 0
    for i in range(n):
        cfg = schedule(rng)
        cfg.backend = "toy"; wt = World(cfg).run()
        cfg.backend = "loro"; wl = World(cfg).run()
        st, sl = wt.clients[0].doc.canonical(), wl.clients[0].doc.canonical()
        ok_t, ok_l = wt.converged(), wl.converged()
        conv_bad += (not ok_t) + (not ok_l)
        ev = wt.evaluate()
        interesting += sum(ev["lost"].values()) + ev["del_lost"] > 0
        tot_ops += sum(len(o) for o in wt.store.ops)
        if st != sl:
            bad.append((i, cfg, st, sl))
    print(f"schedules={n}  toy ops={tot_ops}  schedules with >=1 silent loss={interesting}")
    print(f"non-converged replicas: {conv_bad}")
    print(f"final-state mismatches toy vs real Loro: {len(bad)} / {n}")
    for i, cfg, st, sl in bad[:3]:
        print(" mismatch", i, "N", cfg.N, "script", sorted(cfg.script), "\n  toy ", st, "\n  loro", sl)
    print("PASS" if not bad and not conv_bad else "FAIL")
    return 0 if not bad and not conv_bad else 1

if __name__ == "__main__":
    sys.exit(main(int(sys.argv[1]) if len(sys.argv) > 1 else 400))
