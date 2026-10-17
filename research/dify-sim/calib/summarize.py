import json, sys, math, glob, os
OK = {'s1n': 'TD', 's2o': 'oa+ob', 's2os': 'oa+ob'}
def load(f):
    rows = []
    for l in open(f):
        if l.startswith('{'): rows.append(json.loads(l))
    return rows
def summ(f, scen):
    rows = load(f)
    if not rows: return None
    n = len(rows); ok = OK.get(scen)
    realloss = sum(1 for r in rows if ok and r['real'] != ok)
    predloss = sum(1 - r['dist'].get(ok, 0) / sum(r['dist'].values()) for r in rows) if ok else None
    ll = sum(math.log(max(r['pReal'], 0.01)) for r in rows) / n
    brier = None
    dec = [r for r in rows if r['pReal'] >= 0.9 or r['pReal'] <= 0.1]
    dec_ok = sum(1 for r in dec if r['pReal'] >= 0.9)
    mass = sum(r['pReal'] for r in rows) / n
    beq = [r['byteEq'] for r in rows if r['byteEq'] is not None]
    # modal agreement
    modal = sum(1 for r in rows if max(r['dist'], key=r['dist'].get) == r['real'])
    return dict(file=os.path.basename(f), n=n, real_loss=f'{realloss}/{n}' if ok else '-', pred_loss=(f'{predloss:.1f}/{n} ({predloss/n*100:.0f}%)' if ok else '-'), modal_agree=f'{modal}/{n}', mean_p_real=round(mass, 2), mean_loglik=round(ll, 2),
                decisive=f'{dec_ok}/{len(dec)}', byte_equal=f'{sum(1 for b in beq if b)}/{len(beq)}')
if __name__ == '__main__':
    for f in sorted(glob.glob('out/calib-*.txt')):
        base = os.path.basename(f)
        scen = base.split('-')[1].split('_')[0]
        s = summ(f, scen)
        if s: print(s)
