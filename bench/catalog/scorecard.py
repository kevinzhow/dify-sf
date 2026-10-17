"""Side-by-side scorecard of the tier-A conflict catalog: Dify 1.17.1 (simulator running Dify's own collaboration code,
CATALOG-RESULTS.md of the Dify simulator) vs dify-sf (docs/results/catalog-A-difysf.md). Same case ids on both sides.
usage: scorecard.py DIFY_RESULTS.md DIFYSF_RESULTS.md ["Dify column description"] > docs/results/scorecard-A.md"""
import re, sys

def rows(path, cols):
    out = {}
    for line in open(path, encoding='utf-8'):
        if not line.startswith('| A-'):
            continue
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        out[cells[0]] = dict(zip(cols, cells))
    return out

dify = rows(sys.argv[1], ['id', 'title', 'rel', 'timing', 'K', 'M1', 'M2', 'M3', 'M4', 'M4i', 'M5'])
ours = rows(sys.argv[2], ['id', 'title', 'runs', 'M1', 'M2', 'M3', 'M4', 'M5', 'expect', 'outcomes'])
ms = ['M1', 'M2', 'M3', 'M4', 'M5']
num = lambda x: int(x) if re.fullmatch(r'\d+', x or '') else 0
print('# Conflict catalog, tier A: Dify vs dify-sf\n')
print('Same 88 cases on both sides (ids from the shared generator). Each cell: runs in which the metric occurred / runs.')
print('M1 acknowledged edit lost; M2 silently overwritten (no notice); M3 replicas diverge; M4 dangling reference; M5 edit')
print('without any outcome. dify-sf refuses the later of two conflicting writes **with a notice** (not M2).\n')
print('Dify column: ' + (sys.argv[3] if len(sys.argv) > 3 else 'Dify 1.17.1 collaboration code in the code-level simulator (ideal main thread, K=30 per case).'))
print('dify-sf column: deterministic simulator, protocol 1.4, 20 runs per case with different network seeds.\n')
lossy_d = lossy_o = 0
by_rel = {}
lines = []
for cid, d in dify.items():
    o = ours.get(cid)
    dK = num(d['K']); oK = num(o['runs']) if o else 0
    dl = any(num(d[m]) for m in ms); ol = bool(o) and any(num(o[m]) for m in ms)
    lossy_d += dl; lossy_o += ol
    r = by_rel.setdefault(d['rel'], [0, 0, 0]); r[0] += 1; r[1] += dl; r[2] += ol
    dcell = ' / '.join(f"{m} {d[m]}" for m in ms if num(d[m])) or '0'
    ocell = (' / '.join(f"{m} {o[m]}" for m in ms if num(o[m])) or '0') if o else 'not run'
    lines.append(f"| {cid} | {d['title']} | {dcell} (of {dK}) | {ocell} (of {oK}) | {o['outcomes'] if o else ''} |")
print(f"**Cases with any loss metric: Dify {lossy_d}/{len(dify)}, dify-sf {lossy_o}/{len(dify)}.**\n")
print('| relation | cases | Dify: cases with loss | dify-sf: cases with loss |\n|---|---|---|---|')
names = {'R1': 'same field', 'R2': 'same node, different fields', 'R3': 'overlapping paths', 'R4': 'same list, different items',
         'R5': 'different nodes', 'R6': 'references', 'R7': 'structure (edges, nodes)'}
for rel in sorted(by_rel):
    n, dl, ol = by_rel[rel]
    print(f"| {rel} {names.get(rel, '')} | {n} | {dl} | {ol} |")
print('\n| case | title | Dify | dify-sf | dify-sf outcomes (count) |\n|---|---|---|---|---|')
print('\n'.join(lines))
