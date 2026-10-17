import json, sys, statistics, bisect
def stats(files):
    lat_raf=[]; lat_dom=[]; per_run=[]
    for f in files:
        for l in open(f):
            r=json.loads(l)
            if 'probe' not in r: continue
            for tab in 'AB':
                p=r['probe'][tab]; origin=p['origin']
                t_ready_pg = r['t_ready']*1000 - origin   # page-relative ms of readiness
                raf=sorted(p['raf']); mut=[m for m in p['mut']]
                lats=[]
                for t,n in p['msgs']:
                    if t < t_ready_pg or n < 1000: continue    # graph_update binaries (>= 1 KB) after ready
                    k=bisect.bisect_right(raf,t)
                    if k<len(raf) and raf[k]-t<2000:
                        lats.append(raf[k]-t)
                        lat_raf.append(raf[k]-t)
                    # DOM change carrying a title/value update after the message
                    for mt in mut:
                        if mt[0]>=t and mt[0]-t<2000 and mt[1]=='attributes':
                            lat_dom.append(mt[0]-t); break
                if lats: per_run.append((r['i'],tab,statistics.median(lats)))
    return lat_raf,lat_dom,per_run
if __name__=='__main__':
    a,b,c=stats(sys.argv[1:])
    q=lambda x,p: sorted(x)[min(len(x)-1,int(p*len(x)))] if x else None
    print('graph_update msg -> next rAF callback ms: n=%d p10=%.0f p50=%.0f p90=%.0f p99=%.0f max=%.0f'%(len(a),q(a,.1),q(a,.5),q(a,.9),q(a,.99),max(a)))
    if b: print('graph_update msg -> DOM attribute mutation ms: n=%d p50=%.0f p90=%.0f'%(len(b),q(b,.5),q(b,.9)))

    if len(sys.argv)>1 and False: pass
    import os
    out=os.environ.get('RAFDIST_OUT')
    if out: json.dump([round(x,2) for x in a], open(out,'w'))
