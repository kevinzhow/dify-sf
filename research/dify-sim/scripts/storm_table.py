import json,glob,sys,collections
rows=[]
for f in sorted(glob.glob('out/storm/*.json')):
    try: d=json.load(open(f))['out']
    except Exception: continue
    rows.append(d)
rows.sort(key=lambda d:(d['cfg'].get('calibrated') or False,d['cfg'].get('focus') or 0,d['cfg']['mix'],d['cfg']['users'],d['cfg']['seed']))
print('| mix | focus | main-thread | users | seed | edits | lost disjoint | silently overwritten (disjoint) | same-value lost | diff-value silent overwrites | clients != draft | distinct client states | saves ok/409 | save p50/p99 (s) | visible p50/p99 (ms) | wall (min) |')
print('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|')
for d in rows:
    c=d['cfg']; l=d['lostDisjointEdits']; sv=d['sameValue']; dv=d['diffValue']; dg=d['divergence']; sv_=d['saves']; sl=d['saveLatencyMs']; vl=d['visibilityLatencyMs']
    f=lambda x: '-' if x is None else f'{x/1000:.1f}'
    print(f"| {c['mix']} | {c.get('focus') or 'all 500'} | {'calibrated' if c.get('calibrated') else 'ideal'} | {c['users']} | {c['seed']} | {d['edits']['performed']} (+{d['edits']['blockedByOverlay']} blocked) | {l['lost']}/{l['n']} | {l['silentOverwritten']} | {sv['lost']}/{sv['n']} | {dv['silentOverwrites']}/{dv['n']} | {dg['differFromDraft']}/{dg['liveTabs']} | {dg['distinctClientStates']} | {sv_['ok']}/{sv_['conflict409']} | {f(sl['p50'])}/{f(sl['p99'])} | {vl['p50'] and round(vl['p50'])}/{vl['p99'] and round(vl['p99'])} | {d['wall']['totalS']/60:.1f} |")
