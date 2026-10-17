import sys,json
for n in sys.argv[1:]:
    L=open(f'/tmp/scene_canvas/zb-{n}.log').read().splitlines()
    P={}
    for l in L:
        if l.startswith('PERF '): d=json.loads(l[5:]); P[d['phase']]=d
    z=[json.loads(l[9:]) for l in L if l.startswith('ZOOMBACK ')]
    if 'zoomback' not in P or not z: print(n,'MISSING'); continue
    d,e=P['zoomback'],z[0]
    w=P.get('warmup')
    ws=f" | warmup {w['overviewMs']} ms, fps {w['fps']:.0f}, p99 {w['interval_p99']:.1f}" if w else ''
    print('%-12s fps %5.1f p99 %5.1f max %5.1f build p99 %4.1f | pending max %3d, frames %3d/%3d, after zoom %4d ms%s'%(n,d['fps'],d['interval_p99'],d['interval_max'],d['build_p99'],e['maxPending'],e['framesWithPending'],e['framesSampled'],e['pendingAfterZoomMs'],ws))
