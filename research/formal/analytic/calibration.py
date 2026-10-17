#!/usr/bin/env python
"""Calibrate the pair-collision model against the real-browser repro (repro/logs/*.jsonl).

The repro fires two UI actions 'simultaneously' with asyncio.gather; the recorded edit times t are the END of each UI
action, not the commit instant, so the true commit-time difference is  G = (tA - tB) - delta + eps  with an unknown
systematic offset delta (title action vs desc action take different time) and jitter eps ~ N(0, sigma).  We fit
(L0, r, delta) by maximum likelihood over all two-user scenarios and report profile intervals - honestly wide (n=20 each).
   L0 : relay/processing path latency with NO injected delay      r : view lag      delta : action-end offset
usage: calibration.py [--sigma 0.03] [--logs DIR]"""
import argparse, glob, json, math, os
import numpy as np
from scipy.stats import beta, binom
import model as M

HERE = os.path.dirname(os.path.abspath(__file__))
LOGS = os.path.join(HERE, "..", "..", "repro", "logs")

# scenario -> (kind, injected one-way latency per leg (s) [L = 2*lat + L0], extra view lag (s), loss label)
SCN = {
    "S1N":       dict(kind="diff", lat=0.0, extra_r=0.0,  label="title(A) vs desc(B), same node"),
    "S1N-quiet": dict(kind="diff", lat=0.0, extra_r=0.0,  label="same as S1N (quiet machine re-run)"),
    "S1NR":      dict(kind="diff", lat=0.0, extra_r=0.25, label="S1N + 250 ms rAF delay"),
    "S1NL":      dict(kind="diff", lat=0.4, extra_r=0.0,  label="S1N + 400 ms latency each leg"),
    "S2":        dict(kind="lww",  lat=0.0, extra_r=0.0,  label="same title register"),
    "S2L":       dict(kind="lww",  lat=0.4, extra_r=0.0,  label="same title register + 400 ms"),
    "S2O":       dict(kind="lww",  lat=0.0, extra_r=0.0,  label="add output var (same `outputs` value)"),
    "S2OL":      dict(kind="lww",  lat=0.4, extra_r=0.0,  label="S2O + 400 ms"),
    "S2OM":      dict(kind="lww",  lat=0.0, extra_r=0.0,  label="S2O, B starts 0.8 s later"),
    "S2OS":      dict(kind="lww",  lat=0.0, extra_r=0.0,  label="S2O, B starts 3 s later"),
}


def clopper_pearson(k, n, a=0.05):
    lo = 0.0 if k == 0 else beta.ppf(a / 2, k, n - k + 1)
    hi = 1.0 if k == n else beta.ppf(1 - a / 2, k + 1, n - k)
    return lo, hi


def load(logdir):
    out = {}
    for name in SCN:
        f = os.path.join(logdir, name + ".jsonl")
        if not os.path.exists(f):
            continue
        recs = [json.loads(l) for l in open(f) if l.strip()]
        recs = [r for r in recs if "HARNESS_ERROR" not in r.get("verdict", []) and len(r.get("edits", [])) >= 2]
        rows = []
        for r in recs:
            t = {e["by"]: e["t"] for e in r["edits"]}
            e_sorted = sorted(r["edits"], key=lambda e: e["t"])
            if name in ("S2", "S2L"):
                w = r["server_final"]["titles"]["c1"]
                first_wins = w == e_sorted[0]["value"]
                lost = "LWW_ONE_EDIT_DROPPED" in r["verdict"]
            elif name.startswith("S2O"):
                outs = r.get("server_outputs") or []
                first_wins = (("o" + e_sorted[0]["by"].lower()) in outs) and (("o" + e_sorted[1]["by"].lower()) not in outs)
                lost = "LOST_EDIT" in r["verdict"]
            else:
                first_wins = None
                lost = "LOST_EDIT" in r["verdict"]
            rows.append(dict(s=t["A"] - t["B"], lost=lost, first_wins=first_wins))
        out[name] = rows
    return out


class Fit:
    def __init__(self, data, sigma):
        self.data, self.sigma = data, sigma
        self.z = np.linspace(-3, 3, 25)
        self.wz = np.exp(-self.z ** 2 / 2); self.wz /= self.wz.sum()

    def p_scn(self, name, L0, r, delta):
        c = SCN[name]
        L = 2 * c["lat"] + L0
        s = np.array([x["s"] for x in self.data[name]])
        off = delta if c["kind"] == "diff" else 0.0           # same action on both sides -> offsets cancel
        G = s[:, None] - off + self.sigma * self.z[None, :]
        p = M.p_pair(c["kind"], G, L, r + c["extra_r"], "const")
        return (p * self.wz).sum(1)                             # per-run loss probability

    def loglik(self, L0, r, delta, detail=False):
        ll, parts = 0.0, {}
        for name in self.data:
            p = self.p_scn(name, L0, r, delta)
            k = sum(x["lost"] for x in self.data[name]) if name not in ("S2", "S2L") else None
            if k is None:
                continue                                         # S2/S2L 'lost' flag is a harness labelling artefact (see report)
            # runs are independent Bernoulli with their own p_i: use the exact Poisson-binomial log-lik
            pi = np.clip(p, 1e-6, 1 - 1e-6)
            l = sum(math.log(pi[i]) if x["lost"] else math.log(1 - pi[i]) for i, x in enumerate(self.data[name]))
            ll += l; parts[name] = l
        # concurrency statistic: in the doc-concurrent zone |G|<L0 the loser is a coin flip, so 'first edit wins' ~ 0.5*P(conc)
        for name in ("S2", "S2O"):
            if name in self.data:
                s = np.array([x["s"] for x in self.data[name]])
                G = s[:, None] + self.sigma * self.z[None, :]
                pc = ((np.abs(G) < L0) * self.wz).sum(1)
                fw = np.array([x["first_wins"] for x in self.data[name]])
                pf = np.clip(0.5 * pc, 1e-6, 1 - 1e-6)
                l = float(np.sum(np.where(fw, np.log(pf), np.log(1 - pf))))
                ll += l; parts[name + ":first_wins"] = l
        return (ll, parts) if detail else ll


def fit(data, sigma):
    F = Fit(data, sigma)
    L0s = np.arange(0.0, 0.151, 0.005); rs = np.arange(0.005, 0.301, 0.005); ds = np.arange(-0.2, 0.7, 0.02)
    grid = np.empty((len(L0s), len(rs), len(ds)))
    for i, L0 in enumerate(L0s):
        for j, r in enumerate(rs):
            for k, d in enumerate(ds):
                grid[i, j, k] = F.loglik(L0, r, d)
    return F, L0s, rs, ds, grid


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sigma", type=float, default=0.03)
    ap.add_argument("--logs", default=LOGS)
    a = ap.parse_args()
    data = load(a.logs)
    if not data:
        print("no repro logs found in", a.logs); return
    F, L0s, rs, ds, grid = fit(data, a.sigma)
    i, j, k = np.unravel_index(np.argmax(grid), grid.shape)
    best = grid[i, j, k]
    L0b, rb, db = L0s[i], rs[j], ds[k]
    prof_r = grid.max(axis=(0, 2)); prof_L0 = grid.max(axis=(1, 2)); prof_d = grid.max(axis=(0, 1))
    ci = lambda prof, xs: (xs[prof >= best - 1.92].min(), xs[prof >= best - 1.92].max())
    print(f"=== max-likelihood fit (sigma_eps={a.sigma}):  L0={L0b*1000:.0f} ms   r={rb*1000:.0f} ms   delta={db*1000:.0f} ms   logL={best:.2f}")
    print(f"    95% profile-likelihood ranges:  r in [{ci(prof_r, rs)[0]*1000:.0f}, {ci(prof_r, rs)[1]*1000:.0f}] ms;"
          f"  L0 in [{ci(prof_L0, L0s)[0]*1000:.0f}, {ci(prof_L0, L0s)[1]*1000:.0f}] ms;  delta in [{ci(prof_d, ds)[0]*1000:.0f}, {ci(prof_d, ds)[1]*1000:.0f}] ms")
    print("    (n=20 per scenario => ranges are wide; delta and r are only jointly constrained)\n")

    print(f"{'scenario':10s} {'kind':5s} {'n':>3s} {'obs k':>5s} {'rate':>6s} {'CP 95% CI':>14s} | {'model p':>7s} {'E[k]':>5s} {'P(|k-E|>=obs)':>13s}  verdict")
    flags = []
    for name in SCN:
        if name not in data:
            continue
        rows = data[name]; n = len(rows); kobs = sum(x["lost"] for x in rows)
        p = F.p_scn(name, L0b, rb, db); pm = p.mean(); Ek = p.sum()
        lo, hi = clopper_pearson(kobs, n)
        # two-sided exact-ish p-value using the binomial with the mean p (Poisson-binomial ~ binomial here)
        pv = min(1.0, 2 * min(binom.cdf(kobs, n, pm), binom.sf(kobs - 1, n, pm)))
        ok = "consistent" if pv > 0.05 else "INCONSISTENT"
        if name in ("S2", "S2L"):
            ok = "harness flag not informative (see below)"
        print(f"{name:10s} {SCN[name]['kind']:5s} {n:3d} {kobs:5d} {kobs/n:6.0%} [{lo:5.0%},{hi:5.0%}] | {pm:7.2f} {Ek:5.1f} {pv:13.3f}  {ok}")
        if ok == "INCONSISTENT":
            flags.append(name)
    print()
    for name in ("S2", "S2L", "S2O"):
        if name in data:
            fw = [x["first_wins"] for x in data[name]]
            k, n = sum(fw), len(fw); lo, hi = clopper_pearson(k, n)
            ll, parts = F.loglik(L0b, rb, db, detail=True)
            s = np.array([x["s"] for x in data[name]]); G = s[:, None] + a.sigma * F.z[None, :]
            Lx = 2 * SCN[name]["lat"] + L0b
            pc = ((np.abs(G) < Lx) * F.wz).sum(1).mean()
            print(f"{name}: 'first (earlier) edit wins' in {k}/{n} runs ({k/n:.0%}, CP [{lo:.0%},{hi:.0%}]);  if every pair were separated (later edit saw the earlier one) this"
                  f" would be 0%; doc-concurrent coin-flip zone gives 50% x P(|G|<L) -> model {0.5*pc:.0%}  (=> P(|G|<L) ~ {min(1,2*k/n):.0%} observed)")
    print("\nNOTES")
    print(" * S2 (no latency): harness flagged 0/20 because the loser's own tab already showed the winner when the ack was read (acked=False),")
    print("   not because nothing was dropped: in every run exactly ONE of two different titles survived; the later-in-time edit lost in")
    print("   the 'first wins' runs above, i.e. real LWW drops that the harness labelled OK.  S2L (400 ms) shows the same drops flagged 20/20.")
    print(" * S1NL 0/20 is predicted by the model (window moved to |G| in (L, L+r) = (0.8, 0.8+r) while observed gaps are 0.15-0.4 s);")
    print(f"   but 0/20 vs the no-latency rate (4/40 pooled S1N+quiet = 10 pct) is only weak evidence: P(0/20 | p=0.10) = {0.9 ** 20:.2f}.")
    print(" * S2O/S2OL: 39/39 lost, and S2OM (gap ~0.6 s) / S2OS 0/40 => window (L0+r) between max observed lost gap and 0.56 s.")
    if flags:
        print(" * INCONSISTENT with the fitted model:", ", ".join(flags))
    # sensitivity to sigma and the S1N-only estimate of r under the 'uniform gap spread' rule P ~ 2r / spread
    s = np.array([x["s"] for sc in ("S1N", "S1N-quiet") for x in data.get(sc, [])])
    kk = sum(x["lost"] for sc in ("S1N", "S1N-quiet") for x in data.get(sc, []))
    if len(s):
        spread = s.max() - s.min()
        print(f"\nrule-of-thumb check: pooled S1N+quiet loss {kk}/{len(s)} = {kk/len(s):.0%}; gap spread {spread:.2f} s  ->  r ~ P*spread/2 = {kk/len(s)*spread/2*1000:.0f} ms (crude)")
    np.save(os.path.join(HERE, "results", "calib_grid.npy"), grid)
    json.dump(dict(L0=L0b, r=rb, delta=db, sigma=a.sigma, logL=best, r_range=ci(prof_r, rs), L0_range=ci(prof_L0, L0s)),
              open(os.path.join(HERE, "results", "calibration.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
