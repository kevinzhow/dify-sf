"""Per-run joint timings of the real S2O calibration recordings: (A add, A rename, B add, B rename) in ms after
t_ready, plus the real outcome. Output: difysim/out/s2o_joint.json"""
import json, sys
base = sys.argv[1]
out = {}
for key, fn in (('lat0', 's2o_lat0.jsonl'), ('fast', 's2o_fast.jsonl')):
    rows = []
    for l in open(f'{base}/calib/data/{fn}'):
        r = json.loads(l)
        if 'frames' not in r or 'draft_after' not in r: continue
        t0 = r['t_ready']
        ge = {t: [(f['t'] - t0) * 1000 for f in r['frames'][t] if f['d'] == 'up_out' and f['ev'] == 'graph_event'] for t in 'AB'}
        if len(ge['A']) < 3 or len(ge['B']) < 3: continue
        outs = [n for n in r['draft_after']['graph']['nodes'] if n['id'] == 'c2'][0]['data'].get('outputs', {})
        rows.append({'aAdd': round(ge['A'][0], 1), 'aRen': round(ge['A'][2], 1), 'bAdd': round(ge['B'][0], 1), 'bRen': round(ge['B'][2], 1),
                     'raf': r.get('raf', 0), 'lost': not ('oa' in outs and 'ob' in outs)})
    out[key] = rows
json.dump(out, open(f'{base}/out/s2o_joint.json', 'w'), indent=1)
print({k: (len(v), sum(x['lost'] for x in v)) for k, v in out.items()})
