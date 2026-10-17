#!/usr/bin/env python
"""Closed-form expected EDIT-LOSS rates for Dify 1.17.1 collaborative workflow editing (mechanisms M1..M7).

Notation  (all times in seconds)
  N        users, each editing at Poisson rate lam
  L        client -> relay -> client path latency = 2*lat + L0   (lat = one-way client<->relay latency)
  r        mean view lag: remote op imported into the Loro doc -> visible in the React view (rAF + render)
  lag_lt(x) = E[exp(-x * lag)]  : const lag r -> exp(-x r);   frame-grid lag U(0,2r) -> (1-exp(-2rx))/(2rx)
  nu       rate at which ONE other user edits a given node = lam * s / H   (s = share of edits on shared 'hot' nodes,
           H = number of hot nodes; each hot-node edit picks one of the H nodes uniformly)

Per-edit loss probabilities (an edit is a 'victim'; Poisson thinning over the N-1 other users, product form):
  (a) same register (LWW):     1 - [ e^{-nu L} * lag_lt(nu) ]^{N-1}      window  L (doc-concurrent, coin flip -> L/2*2)
                                                                           + lag (later writer's view lacks it)  => W = L + r
  (b) same node, other field:  1 - lag_lt(nu)^{N-1}                       window  r  (stale-view whole-node write reverts it)
  (c) list append/append:      1 - lag_lt(nu)^{N-1}                       window  r  (stale syncList overwrites/trims it)
  (d) delete vs edit:          edit lost : zone (-(L+lag), +L) around the delete -> width 2L + r ;  delete lost (zombie): width r
  (e) persistence (second term, an ASSUMPTION-laden model, see persistence_*)
Expected losses/hour = 3600 * N * lam * per-edit loss.
Everything is first-order exact in the Poisson sense; the validation against sim.py quantifies the residual.
"""
import math
from dataclasses import dataclass, replace

import numpy as np

# workload mixes: how often do two users touch the same node, and in what way
#   s = share of a user's edits that land on the shared hot set, H = size of the hot set, w = node-kind weights
#   (same register / same node different field / list append), i.e. conditional on two edits hitting the same node
#   40% are same register, 30% different field, 30% list items.
MIXES = {
    "disjoint": dict(s=0.0, H=25, w=(0.4, 0.3, 0.3)),     # each user in own region: no shared node, ever
    "mixed":    dict(s=0.5, H=30, w=(0.4, 0.3, 0.3), p_del=0.02),   # half of all edits on a 30-node hot set (6% of the graph): P(2 edits share a node) = s^2/H = 0.83% (uniform 0.2%); 2% of hot events delete a node
    "uniform":  dict(s=1.0, H=500, w=(0.4, 0.3, 0.3), p_del=0.02),   # every edit picks one of the 500 nodes uniformly at random
}


@dataclass(frozen=True)
class Params:
    N: int = 50
    lam: float = 0.1            # edits/s/user  (1 per 10 s)
    lat: float = 0.4            # one-way client<->relay latency
    L0: float = 0.0             # relay/processing overhead added to the path
    r: float = 0.05             # mean view lag
    lag: str = "const"          # 'const' or 'uniform' (frame grid; U(0, 2r))
    s: float = 0.25
    H: int = 25
    w: tuple = (0.4, 0.3, 0.3)
    p_del: float = 0.0          # share of hot events that are node deletions
    D: float = 5.0              # save debounce
    mu: float = 1 / 1800        # leader tab exit/crash rate  (ASSUMPTION: one per 30 min)
    kappa: float = 1 / 14400    # room-wide termination rate (all tabs close / relay restart) (ASSUMPTION: one per 4 h)
    stale_first_save: bool = True

    @property
    def L(self):
        return 2 * self.lat + self.L0

    def mix(self, name):
        return replace(self, **MIXES[name])


def lag_lt(x, r, lag="const"):
    """E[exp(-x * lag)] for a lag with mean r."""
    x = np.asarray(x, dtype=float)
    if lag == "const":
        return np.exp(-x * r)
    z = 2 * r * x
    return np.where(z < 1e-9, 1.0, -np.expm1(-z) / np.where(z < 1e-9, 1.0, z))


def _nu(p):
    return p.lam * p.s * (1 - p.p_del) / p.H


def _nu_del(p):
    return p.lam * p.s * p.p_del / p.H


def x_same(p):
    """first-order exposure: expected number of other-user edits that would BEAT an edit on the same register
    (doc-concurrent partners win half the time -> L, later partners whose view lags -> lag)."""
    nu, n = _nu(p), p.N - 1
    return -n * (-nu * p.L + np.log(lag_lt(nu, p.r, p.lag)))


def P_same_first_order(p):
    """naive Poisson 'is there a beater' form 1 - exp(-x): exact only for x << 1."""
    return 1 - np.exp(-x_same(p))


def P_same(p):
    """same-register (LWW) loss probability.  A final register value only keeps the LINEAGE of edits that were made from a
    view containing their predecessor; walking back from the final value, the parent of an edit is the last edit older
    than W = L + r (anything younger is invisible to its writer).  Edits skipped per generation ~ Poisson(x), so the
    surviving lineage is a non-paralyzable dead-time process: survivors = Lam/(1+x*) -> loss = x/(1+x).
    (1 - e^-x over-counts when x ~ 1 because an edit 'beaten' by a stale writer is resurrected whenever a later writer
    that still saw it beats the stale one.)  Verified against sim.py up to x ~ 1.5."""
    x = x_same(p)
    return x / (1 + x)


def P_rev(p):
    return 1 - lag_lt(_nu(p), p.r, p.lag) ** (p.N - 1)


def P_edit_deleted(p):
    nd, n = _nu_del(p), p.N - 1
    return 1 - (np.exp(-nd * 2 * p.L) * lag_lt(nd, p.r, p.lag)) ** n


def P_delete_zombie(p):
    return 1 - lag_lt(_nu(p), p.r, p.lag) ** (p.N - 1)


# --------------------------------------------------------------------------- persistence (second term, M6)
def t_durable(p):
    """expected time an edit stays NON-durable (no failures).  The leader saves its whole VIEW, so ANY debounce fire in the
    room (not only the author's) makes every edit already visible to the leader durable.
      visibility at the leader : (1-1/N)(L + r)             (author = follower; leader's own edits are immediate)
      then the first save      : min(Exp(f_o), T_own)  ->  (1 - exp(-f_o T_own)) / f_o
    f_o = (N-1) lam e^{-lam D} = rate of fires by the other users (a fire = a burst of one user ends and D elapsed),
    T_own = (e^{lam D}-1)/lam = expected own trailing-debounce time (restarts on every further own edit)."""
    lam, D, N = p.lam, p.D, p.N
    t_own = (math.exp(lam * D) - 1) / lam
    f_o = (N - 1) * lam * math.exp(-lam * D)
    wait = t_own if f_o * t_own < 1e-9 else (1 - math.exp(-f_o * t_own)) / f_o
    return (1 - 1 / N) * (p.L + p.r) + wait


def persistence_per_edit(p):
    """P(edit never becomes durable) = room-end/relay-restart rate kappa * time spent non-durable  (+ hand-off extension).
    hand-off extension: with prob mu*T the leader exits while the edit is pending; the new leader's first save fails
    (stale unique_hash, no retry), so durability waits for one more save: extra ~ 1/f (f = N lam e^{-lam D})."""
    T = t_durable(p)
    f = p.N * p.lam * math.exp(-p.lam * p.D)
    extra = (1 / f) if p.stale_first_save else 0.0
    return p.kappa * (T + p.mu * T * extra), p.kappa * T, p.kappa * p.mu * T * extra


# --------------------------------------------------------------------------- aggregation
def breakdown(p):
    """per-edit loss probabilities by mechanism (fractions of ALL acknowledged edits)."""
    w_same, w_diff, w_list = p.w
    live = p.s * (1 - p.p_del)
    out = {
        "a_lww": live * w_same * float(P_same(p)),
        "b_revert": live * w_diff * float(P_rev(p)),
        "c_list": live * w_list * float(P_rev(p)),
        "d_delete": p.s * ((1 - p.p_del) * float(P_edit_deleted(p)) + p.p_del * float(P_delete_zombie(p))),
        "e_persist": persistence_per_edit(p)[0],
    }
    out["total"] = sum(out.values())
    out["collisions"] = out["total"] - out["e_persist"]
    return out


def per_hour(p):
    bd = breakdown(p)
    return {k: v * p.N * p.lam * 3600 for k, v in bd.items()}


def kind_rates(p):
    """loss probability of an edit that LANDS on a hot node of a given kind (what sim.py measures per kind)."""
    return {"same": float(P_same(p)), "diff": float(P_rev(p)), "list": float(P_rev(p))}


# --------------------------------------------------------------------------- two-user pair (what the repro measures)
def stale_hit(g, L, r, lag="const"):
    """P(later writer's view still lacks the earlier edit) for an edit g seconds after the other one, g > L."""
    g = np.asarray(g, dtype=float)
    x = g - L
    if lag == "const":
        return np.where((x >= 0) & (x < r), 1.0, 0.0)
    return np.where(x < 0, 0.0, np.clip(1 - x / (2 * r), 0, 1))


def p_pair(kind, G, L, r, lag="const"):
    """Probability that a pair of edits whose COMMIT-time difference is G (array or scalar, seconds, sign irrelevant)
    ends with one silently lost edit.
      kind 'lww'  : same register       : |G| < L (doc-concurrent) or stale window  -> W = L + r
      kind 'diff' : same node/other field / 'list' : |G| in (L, L+r) only (concurrent merges are fine)
    Average over a gap distribution by passing samples and taking the mean."""
    a = np.abs(np.asarray(G, dtype=float))
    stale = stale_hit(a, L, r, lag)
    if kind == "lww":
        return np.where(a < L, 1.0, stale)
    if kind in ("diff", "list"):
        return np.where(a < L, 0.0, stale)
    raise ValueError(kind)


def p_pair_uniform_gap(kind, spread, L, r):
    """closed form for G ~ Uniform(-spread/2, spread/2) (spread >= 2(L+r)):  window/spread."""
    w = {"lww": 2 * (L + r), "diff": 2 * r, "list": 2 * r}[kind]
    return min(1.0, w / spread)


def p_pair_delete(delta, L, r, lag="const"):
    """pair (A deletes at 0, B edits at delta): returns (P(edit lost), P(delete lost)) for lag const."""
    d = np.asarray(delta, dtype=float)
    edit_lost = ((d > -(L + r)) & (d < L)).astype(float)
    del_lost = ((d >= L) & (d < L + r)).astype(float)
    return edit_lost, del_lost


if __name__ == "__main__":
    for mix in MIXES:
        for lat in (0.05, 0.4, 2.0):
            for N in (10, 50, 100):
                p = Params(N=N, lat=lat).mix(mix)
                bd = breakdown(p)
                print(f"{mix:9s} lat={lat:4.2f} N={N:3d}  loss/edit={bd['total']:.3e}  coll={bd['collisions']:.3e}"
                      f"  persist={bd['e_persist']:.2e}  /hour={per_hour(p)['total']:.2f}")
