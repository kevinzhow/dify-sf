"""Formula (model.py) vs difysim mix 'formula' runs (difysim/out/formula/u{N}-l{lat}-s{seed}.json), per mechanism.

Observed, against the replicas' converged state (vsTabs): (a) same register and (b) different fields = writes not on the
final value's provenance chain (the model's own definition: vsTabs.chainLost, per class; private edits share class (b) but
cannot collide); (c) list append = list items missing (list-class M1+M2). Edits that
are in the replicas but not in the stored draft at the end are reported separately (persistence, not a formula term). Predicted: breakdown() with
the run's N, lambda, one-way latency, s=0.5, H=30, p_del=0, r = mean calibrated view lag (difysim out/rafdist_dom.json)."""
import glob, json, os, sys
from scipy.stats import beta
import model as M

SIM = os.path.expanduser('research/dify-sim')
r = sum(json.load(open(f'{SIM}/out/rafdist_dom.json'))) / len(json.load(open(f'{SIM}/out/rafdist_dom.json'))) / 1000
L0 = float(sys.argv[1]) if len(sys.argv) > 1 else 0.0

def cp(k, n):
    lo = 0.0 if k == 0 else beta.ppf(0.025, k, n - k + 1)
    hi = 1.0 if k == n else beta.ppf(0.975, k + 1, n - k)
    return lo, hi

import collections
agg = collections.OrderedDict()
for f in sorted(glob.glob(f'{SIM}/out/formula/*.json')):
    o = json.load(open(f))['out']
    c = o['cfg']; key = (c['users'], c['linkMs'][0] / 1000, c['lambda'])
    a = agg.setdefault(key, {'n': 0, 'a': 0, 'b': 0, 'c': 0, 'runs': 0, 'secs': 0, 'errors': []})
    a['n'] += o['edits']['performed']; a['runs'] += 1; a['secs'] += c['durationS']
    # collision losses are measured against the replicas' converged state (vsTabs); runs without it are skipped
    if not o.get('vsTabs'): a['runs'] -= 1; a['n'] -= o['edits']['performed']; a['secs'] -= c['durationS']; a.setdefault('skipped', 0); a['skipped'] += 1; continue
    bc = o['vsTabs']['byClass']
    g = lambda cl, m: bc.get(cl, {}).get(m, 0)
    ch = o['vsTabs'].get('chainLost')
    if ch is None: a['runs'] -= 1; a['n'] -= o['edits']['performed']; a['secs'] -= c['durationS']; continue
    # registers (a, b): the model's provenance-chain definition; lists (c): items missing from the converged state
    a['a'] += ch.get('diff-value', 0); a['b'] += ch.get('disjoint', 0); a['c'] += g('list', 'm1') + g('list', 'm2')
    dbc = o['edits']['byClass']; a.setdefault('notSaved', 0)
    a['notSaved'] += sum(dbc.get(cl, {}).get('m1', 0) + dbc.get(cl, {}).get('m2', 0) for cl in ('diff-value', 'disjoint', 'list')) - (g('diff-value', 'm1') + g('diff-value', 'm2') + g('disjoint', 'm1') + g('disjoint', 'm2') + g('list', 'm1') + g('list', 'm2'))
    a['errors'] += o['errors'][:1]
rows = []
for (N, lat, lam), a in agg.items():
    p = M.Params(N=N, lam=lam, lat=lat, r=r, s=0.5, H=30, p_del=0.0, L0=L0)
    b = M.breakdown(p)
    pred = {'a': b['a_lww'], 'b': b['b_revert'], 'c': b['c_list']}
    n = a['n']; obs = {m: a[m] for m in 'abc'}; k = sum(obs.values())
    lo, hi = cp(k, n)
    if not n: continue
    rows.append((N, lat, n, k, k / n if n else 0, lo, hi, sum(pred.values()), obs, pred, f"{a['runs']} runs/{a['secs']} s, not in draft at end {a.get('notSaved', 0)}", a['errors']))
print(f"r = {r*1000:.1f} ms (mean calibrated view lag), L0 = {L0*1000:.0f} ms")
print(f"{'N':>4} {'lat':>5} {'edits':>6} {'lost':>5} {'obs':>7} {'CP95':>17} {'pred':>7} {'obs/pred':>8}  per mechanism obs(pred count)")
for N, lat, n, k, rate, lo, hi, tp, obs, pred, Mm, err in sorted(rows):
    mech = '  '.join(f"{m}:{obs[m]}({pred[m]*n:.1f})" for m in 'abc')
    inside = 'ok' if lo <= tp <= hi else 'OUT'
    print(f"{N:>4} {lat:>5.2f} {n:>6} {k:>5} {rate:>7.4f} [{lo:.4f},{hi:.4f}] {tp:>7.4f} {rate/tp if tp else float('nan'):>8.2f}  {mech}  {inside}  {Mm}{'  ERR '+err[0][:60] if err else ''}")
