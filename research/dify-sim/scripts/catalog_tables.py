import json, collections
rows = json.load(open('out/catalog-A.json'))
def w(k, n, z=1.96):
    if n == 0: return (0, 1)
    p = k / n; d = 1 + z * z / n; c = p + z * z / (2 * n); h = z * ((p * (1 - p) / n + z * z / (4 * n * n)) ** .5)
    return (max(0, (c - h) / d), min(1, (c + h) / d))
# full per-case table
out = ['# A-tier catalog results (simulator, Dify 1.17.1 code path)', '',
       'Each cell = runs in which the metric occurred / K. M4 is reported as "collaboration-induced" (more dangling references than the serial single-user reference run of the same operations).', '',
       '| case id | title | relation | timing | K | M1 | M2 | M3 | M4(collab) | M4(inherent in op) | M5 |', '|---|---|---|---|---|---|---|---|---|---|---|']
titles = {}
import re
for r in rows:
    t = r['tags']
    base4 = r['serialBaseline']['M4']
    out.append(f"| {r['id']} | {r.get('title','')} | {t['rel']} | {t['timing']} | {r['K']} | {r['M']['M1']} | {r['M']['M2']} | {r['M']['M3']} | {r['M4_collab']} | {'yes' if base4 else '-'} | {r['M']['M5']} |")
open('CATALOG-RESULTS.md', 'w').write('\n'.join(out) + '\n')
# summary by relation x timing
agg = collections.defaultdict(lambda: collections.Counter())
for r in rows:
    key = (r['tags']['rel'], r['tags']['timing'])
    a = agg[key]; a['cases'] += 1; a['runs'] += r['K']
    for m in ('M1', 'M2', 'M3', 'M5'): a[m] += r['M'][m]
    a['M4'] += r['M4_collab']
    a['cases_with_M1'] += r['M']['M1'] > 0
    a['cases_with_M2'] += r['M']['M2'] > 0
    a['cases_with_M3'] += r['M']['M3'] > 0
print('| relation | timing | cases | runs | M1 runs (rate) | M2 runs | M3 runs | M4 runs | cases with any M1 |')
print('|---|---|---|---|---|---|---|---|---|')
for (rel, tm), a in sorted(agg.items()):
    lo, hi = w(a['M1'], a['runs'])
    print(f"| {rel} | {tm} | {a['cases']} | {a['runs']} | {a['M1']} ({a['M1']/a['runs']*100:.1f}%) | {a['M2']} | {a['M3']} | {a['M4']} | {a['cases_with_M1']}/{a['cases']} |")
tot = collections.Counter()
for r in rows:
    tot['runs'] += r['K']
    for m in ('M1', 'M2', 'M3', 'M5'): tot[m] += r['M'][m]
    tot['M4'] += r['M4_collab']
print('\nTOTAL', dict(tot), 'cases', len(rows))
