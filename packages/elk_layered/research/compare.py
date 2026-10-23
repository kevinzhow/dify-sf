"""Compare node positions after the translation Dify removes in normaliseBounds."""
import json
import math
import sys
from collections import defaultdict
from pathlib import Path

root = Path(__file__).parent
oracle = {x['id']:x for x in json.loads((root/'elkjs.json').read_text())}
actual_file = sys.argv[1] if len(sys.argv)>1 else 'dart.json'
dart = {x['id']:x for x in json.loads((root/actual_file).read_text())}

def normalize(nodes):
    if not nodes:
        return {}
    minx = min(n['x'] for n in nodes)
    miny = min(n['y'] for n in nodes)
    return {n['id']:{**n,'x':n['x']-minx,'y':n['y']-miny} for n in nodes}

results = []
for key, ref in oracle.items():
    actual = dart[key]
    record = {'id': key}
    if 'error' in ref or 'error' in actual:
        record.update(reference_error=ref.get('error'), dart_error=actual.get('error'))
        results.append(record)
        continue
    r, a = normalize(ref['nodes']), normalize(actual['nodes'])
    deltas = {k:max(abs(r[k][f]-a[k][f]) for f in ('x','y','width','height')) for k in r}
    distances = {k:math.hypot(r[k]['x']-a[k]['x'],r[k]['y']-a[k]['y']) for k in r}
    record.update(exact=all(d<=1e-9 for d in deltas.values()), nodes=len(r),
                  matching_nodes=sum(d<=1e-9 for d in deltas.values()),
                  max_coordinate_delta=max(deltas.values(), default=0),
                  mean_node_distance=sum(distances.values())/max(1,len(r)),
                  width_reference=max((n['x']+n['width'] for n in r.values()),default=0),
                  width_dart=max((n['x']+n['width'] for n in a.values()),default=0),
                  height_reference=max((n['y']+n['height'] for n in r.values()),default=0),
                  height_dart=max((n['y']+n['height'] for n in a.values()),default=0))
    results.append(record)
    if key=='basic/root/diamond':
        (root/f'diamond-{Path(actual_file).stem}.json').write_text(json.dumps({'reference':r,'dart':a},indent=2)+'\n')
summary = {}
for prefix in ('all','sample','basic','random'):
    subset = results if prefix=='all' else [r for r in results if r['id'].startswith(prefix+'/')]
    valid = [r for r in subset if 'exact' in r]
    summary[prefix] = {'graphs':len(subset), 'valid':len(valid),
                       'exact':sum(r['exact'] for r in valid),
                       'nodes':sum(r['nodes'] for r in valid),
                       'matching_nodes':sum(r['matching_nodes'] for r in valid),
                       'max_coordinate_delta':max((r['max_coordinate_delta'] for r in valid),default=0),
                       'mean_node_distance':sum(r['mean_node_distance']*r['nodes'] for r in valid)/max(1,sum(r['nodes'] for r in valid))}
output_file = 'comparison.json' if actual_file == 'dart.json' else f'comparison-{Path(actual_file).stem}.json'
(root/output_file).write_text(json.dumps({'summary':summary,'graphs':results},indent=2)+'\n')
print(json.dumps(summary,indent=2))
print('Errors:',[(r['id'],r.get('reference_error'),r.get('dart_error')) for r in results if 'exact' not in r])
print('Basic:',json.dumps([r for r in results if r['id'].startswith('basic/')],indent=2))
