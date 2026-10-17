import json, sys, glob
def load(files):
    out=[]
    for f in files:
        for l in open(f):
            r=json.loads(l)
            if 'frames' in r: out.append(r)
    return out
def isbin(f): return f['ev']=='graph_event' and 'bin' in f
def analyse(r):
    t0=r['t_ready']; F=r['frames']
    ca=[f['t'] for f in F['A'] if f['d']=='up_in' and isbin(f) and f['t']>=t0]
    cb=[f['t'] for f in F['B'] if f['d']=='up_in' and isbin(f) and f['t']>=t0]
    if not ca or not cb: return None
    # arrival (browser receive time = down_out) of the other's first graph_update binary
    aa=[f['t'] for f in F['A'] if f['d']=='down_out' and f['ev']=='graph_update' and 'bin' in f and f['t']>=t0]
    ab=[f['t'] for f in F['B'] if f['d']=='down_out' and f['ev']=='graph_update' and 'bin' in f and f['t']>=t0]
    n={x['id']:x['data'] for x in r['draft_after']['graph']['nodes']}
    i=r['i']
    sc=r['scenario']
    if sc=='s1n':
        tl=n['c1']['title']==f'A-title-{i}'; dl=n['c1']['desc']==f'B-desc-{i}'
        lost = None if (tl and dl) else ('B_desc_lost' if tl else 'A_title_lost' if dl else 'both')
    elif sc=='s2o':
        o=n['c2']['outputs']; oa='oa' in o; ob='ob' in o
        lost = None if (oa and ob) else ('B_lost' if oa else 'A_lost' if ob else 'both')
    return dict(i=i, ca=ca[0], cb=cb[0], ca2=ca[1:2], cb2=cb[1:2], arr_at_A=aa[0] if aa else None, arr_at_B=ab[0] if ab else None, lost=lost, gap=r.get('gap'), agap=r.get('agap'))
if __name__=='__main__':
    sc=sys.argv[1]
    rows=[]
    for r in load(sys.argv[2:]):
        a=analyse(r)
        if a: rows.append(a)
    t=lambda x:x
    print('i  | A-commit minus B-commit(ms) | margin_A (A commit - arrival of B update at A) | margin_B | lost')
    for a in sorted(rows,key=lambda a:(a['ca']-a['cb'])):
        mA=(a['ca']-a['arr_at_A'])*1000 if a['arr_at_A'] else None
        mB=(a['cb']-a['arr_at_B'])*1000 if a['arr_at_B'] else None
        print(f"{a['i']:3d} | {(a['ca']-a['cb'])*1000:8.0f} | {mA if mA is None else round(mA):>8} | {mB if mB is None else round(mB):>8} | {a['lost']}")
