import json,glob,collections,sys
d=collections.defaultdict(dict)
for f in sorted(glob.glob('out/equiv/*.json')):
    k=f.split('/')[-1][:-5]; base,mode=k.rsplit('-',1)
    d[base][mode]=json.load(open(f))
bad=0
for base,m in sorted(d.items()):
    ref=m.get('off')
    if not ref: continue
    for mode in ('nolazy','on'):
        if mode not in m: continue
        a,b=ref['fingerprint'],m[mode]['fingerprint']
        same_draft=a['draft']==b['draft']; same_tabs=a['tabs']==b['tabs']; same_ledger=a['ledger']==b['ledger']; same_saves=a['saves']==b['saves']
        ok=same_draft and same_tabs and same_ledger
        bad+= (not ok)
        print(f"{base:28s} off vs {mode:6s} draft={same_draft} tabs={same_tabs} ledger={same_ledger}({a['ledger']} / {b['ledger']}) savetimes={same_saves}  wall off={ref['out']['wall']['totalS']}s {mode}={m[mode]['out']['wall']['totalS']}s")
print('MISMATCHES',bad)
