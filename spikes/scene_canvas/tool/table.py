import json,glob,sys
rows=[]
for f in sorted(glob.glob('' + (sys.argv[1] if len(sys.argv) > 1 else '/tmp/scene_canvas') + '/full-*.log')):
    s=[l for l in open(f) if l.startswith('SUMMARY ')]
    if not s: print('NO SUMMARY', f); continue
    d=json.loads(s[0][8:])
    for p in d['phases']:
        print(f"{f.split('full-')[1][:-4]:12s} {d['mode']:8s} {d['nodes']:5d} {p['phase']:6s} fps {p['fps']:6.1f} int p50 {p['interval_p50']:5.1f} p99 {p['interval_p99']:5.1f} max {p['interval_max']:5.1f} >9.6 {p['over_9_6ms']:3d}/{p['frames']:3d} build p99 {p['build_p99']:4.1f} raster p99 {p['raster_p99']:4.1f}")
    print(f"{f.split('full-')[1][:-4]:12s} {d['mode']:8s} {d['nodes']:5d} load {d['loadMs']} ms, sharpen {d['sharpenMs']} ms (worst build {d['sharpenWorstBuildMs']}), rss {d['rssMb']} MB max {d['maxRssMb']}")
