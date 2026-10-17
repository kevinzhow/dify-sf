"""Table: real-browser results (repro/logs/*.jsonl, Playwright harness, 20 runs each) vs simulator (ideal main thread / harness-calibrated)."""
import json, collections, os
REAL = 'research/real-browser/logs'
ideal = {r['id']: r for r in json.load(open('out/sseries.json'))}
cal = {r['id']: r for r in json.load(open('out/sseries-calib.json'))} if os.path.exists('out/sseries-calib.json') else {}
def wilson(k, n, z=1.96):
    if n == 0: return (0, 1)
    p = k / n; d = 1 + z * z / n; c = p + z * z / (2 * n); h = z * ((p * (1 - p) / n + z * z / (4 * n * n)) ** .5)
    return (max(0, (c - h) / d), min(1, (c + h) / d))
def cell(k, n):
    lo, hi = wilson(k, n); return f'{k}/{n} [{lo*100:.0f}-{hi*100:.0f}%]'
def sim_loss(s):  # "loss-like" = acknowledged edit missing (M1) or clients != stored draft (M3); M2 (silent LWW overwrite) tracked separately
    return max(s['M']['M1'], s['M']['M3'], s['M']['M4'])
print('| scenario | what (Dify 1.17.1) | real browsers: verdicts | real loss-like | sim, ideal main thread | sim, harness-calibrated | sim/real overlap (calibrated) | sim M2 (silent LWW overwrite) cal |')
print('|---|---|---|---|---|---|---|---|')
agree = tot = 0
for sid, s in ideal.items():
    c = cal.get(sid, s)
    f = f'{REAL}/{sid}.jsonl'
    if not os.path.exists(f):
        print(f"| {sid} | {s['doc'][:70]} | not run on real | - | {cell(sim_loss(s), s['K'])} | {cell(sim_loss(c), c['K'])} | - | {c['M']['M2']}/{c['K']} |"); continue
    recs = [r for r in map(json.loads, open(f)) if r.get('verdict') != ['HARNESS_ERROR']]
    cnt = collections.Counter('+'.join(r.get('verdict', ['?'])) for r in recs)
    n = len(recs)
    real_loss = sum(v for k, v in cnt.items() if k not in ('OK', 'OK+LWW_ONE_EDIT_DROPPED'))
    lo, hi = wilson(real_loss, n); slo, shi = wilson(sim_loss(c), c['K'])
    ok = slo <= hi and lo <= shi
    tot += 1; agree += ok
    print(f"| {sid} | {s['doc'][:70]} | {dict(cnt)} | {cell(real_loss, n)} | {cell(sim_loss(s), s['K'])} | {cell(sim_loss(c), c['K'])} | {'yes' if ok else '**NO**'} | {c['M']['M2']}/{c['K']} |")
print(f'\ncalibrated-sim vs real, scenarios with real data: {agree}/{tot} have overlapping 95% Wilson intervals')
