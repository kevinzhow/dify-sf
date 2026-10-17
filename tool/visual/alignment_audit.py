#!/usr/bin/env python3
# From raft-flutter (tool/alignment-audit.py, same author), used unchanged.
"""Horizontal alignment audit: Flutter capture vs Web capture of the same parity case.

  tool/alignment-audit.py run  --root DIR [--root DIR ...] [--cases GLOB[,GLOB]] [--out DIR]
  tool/alignment-audit.py show --root DIR --case ID --out FILE.png      # overlay of one case
  tool/alignment-audit.py overlays --out DIR                            # overlays of every flagged case in DIR/results.json
  tool/alignment-audit.py selftest

`--root` is a parity output directory (build/parity or build/parity-ext) holding
visual-testing-results/{react,android}/<case>.png + react metadata (density).
Nothing here writes into a root; results go to --out (default
.local/alignment/audit). Measures, in CSS px (device px / density):

* edge: strong VERTICAL edges (borders, field/button/card/avatar sides) = columns
  where the horizontal colour step is > EDGE_STEP and continues vertically for at
  least MIN_RUN css px (glyph stems are shorter). Segment = (x, y0, y1, polarity).
* ink: left/right start columns of ink clusters per text line band (text start
  columns: labels, row titles, badges). Long edge columns are removed first.

Each Web segment is matched to the nearest Flutter segment with the same
polarity whose y range overlaps. |dx| <= ALIGNED (AA / fractional) = aligned;
ALIGNED < |dx| <= MAX_SHIFT = OFFSET (reported); beyond = unmatched (a layout
difference, not an alignment slip). A uniform shift of all matched segments
(median dx over >= 4 matches) is treated as a crop/shell offset and subtracted,
and reported as `globalShift`.

A second pass finds intra-panel NEAR-MISS columns: two left-edge columns of one
image 1..8 css px apart that both occur >= 3 times (the "search at 16, rows at
12" pattern). It is reported for Web and for Flutter; a near miss that Web also
has is Web's own geometry, not a Flutter slip.
"""
import argparse
import fnmatch
import json
import pathlib
import sys

import numpy as np
from PIL import Image

EDGE_STEP = 40       # per-channel step across a column boundary (0..255)
MIN_RUN = 18.0       # css px of vertical continuity for an edge segment
RUN_GAP = 1          # device px of tolerated gap
ALIGNED = 0.75       # css px: AA / fractional-px noise
MAX_SHIFT = 12.0     # css px: beyond this it is a layout difference
INK_DIFF = 90        # distance from the band background to count as ink
INK_GAP = 10.0       # css px of blank between two ink clusters in a band
TEXT_ALIGNED = 1.5   # css px: glyph side bearing / rasteriser tolerance
Y_SLACK = 3.0        # css px of vertical slack when pairing segments


def load(path):
    im = Image.open(path)
    if im.mode in ('RGBA', 'LA'):
        bg = Image.new('RGBA', im.size, (255, 255, 255, 255))
        im = Image.alpha_composite(bg, im.convert('RGBA'))
    return np.asarray(im.convert('RGB'), dtype=np.int16)


def vertical_segments(img, density):
    """[(x_css, y0_css, y1_css, polarity)] long vertical edges. x is the boundary
    between device columns x-1 and x."""
    h, w, _ = img.shape
    step = np.abs(img[:, 1:, :] - img[:, :-1, :]).max(axis=2)  # h x (w-1)
    lum = img.mean(axis=2)
    sign = np.sign(lum[:, 1:] - lum[:, :-1])
    mask = step > EDGE_STEP
    min_run = int(round(MIN_RUN * density))
    segs = []
    for x in range(w - 1):
        col = mask[:, x]
        if col.sum() < min_run:
            continue
        ys = np.flatnonzero(col)
        start = prev = ys[0]
        for y in list(ys[1:]) + [None]:
            if y is None or y - prev > RUN_GAP + 1:
                if prev - start + 1 >= min_run:
                    s = sign[start:prev + 1, x]
                    pol = int(np.sign(s.sum())) or 1
                    segs.append((round((x + 1) / density, 3), round(start / density, 2),
                                 round((prev + 1) / density, 2), pol))
                if y is not None:
                    start = y
            if y is not None:
                prev = y
    return merge_segments(segs)


def merge_segments(segs):
    """Collapse the same edge seen in adjacent columns (soft AA edge) into one."""
    segs = sorted(segs, key=lambda s: (s[3], s[1], s[0]))
    out = []
    for s in segs:
        for i, o in enumerate(out):
            if (o[3] == s[3] and abs(o[0] - s[0]) <= 0.5 and min(o[2], s[2]) - max(o[1], s[1]) > 0.5 * min(o[2] - o[1], s[2] - s[1])):
                out[i] = (o[0], min(o[1], s[1]), max(o[2], s[2]), o[3])
                break
        else:
            out.append(s)
    return sorted(out, key=lambda s: (s[1], s[0]))


def _runs_mask(mask, min_run):
    """Pixels of `mask` that belong to a vertical run >= min_run (gap-tolerant)."""
    h, w = mask.shape
    out = np.zeros_like(mask)
    for x in range(w):
        col = mask[:, x]
        if col.sum() < min_run:
            continue
        ys = np.flatnonzero(col)
        start = prev = ys[0]
        for y in list(ys[1:]) + [None]:
            if y is None or y - prev > RUN_GAP + 1:
                if prev - start + 1 >= min_run:
                    out[start:prev + 1, x] = True
                if y is not None:
                    start = y
            if y is not None:
                prev = y
    return out


def ink_mask(img, density):
    """Edge pixels that are neither part of a long vertical nor a long horizontal
    run: glyph strokes, small icons, badge corners."""
    h, w, _ = img.shape
    gx = np.zeros((h, w), bool)
    gy = np.zeros((h, w), bool)
    gx[:, 1:] = np.abs(img[:, 1:, :] - img[:, :-1, :]).max(axis=2) > EDGE_STEP
    gy[1:, :] = np.abs(img[1:, :, :] - img[:-1, :, :]).max(axis=2) > EDGE_STEP
    min_run = int(round(MIN_RUN * density))
    longv = _runs_mask(gx, min_run)
    longh = _runs_mask(gy.T, min_run).T
    long = longv | longh
    k = max(1, int(round(density)))
    # dilate by k px each way
    dil = long.copy()
    for dy in range(-k, k + 1):
        for dx in range(-k, k + 1):
            dil |= np.roll(np.roll(long, dy, 0), dx, 1)
    return (gx | gy) & ~dil


def ink_clusters(img, density, edges):
    """[(x0_css, x1_css, y0_css, y1_css)] ink clusters per line band."""
    h, w, _ = img.shape
    diff = ink_mask(img, density)
    rows = diff.any(axis=1)
    bands, start = [], None
    for y in range(h + 1):
        on = y < h and rows[y]
        if on and start is None:
            start = y
        if not on and start is not None:
            bands.append((start, y))
            start = None
    out = []
    gap = int(round(INK_GAP * density))
    for y0, y1 in bands:
        hh = (y1 - y0) / density
        if hh < 5 or hh > 48:  # not a text line (rule, block, whole illustration)
            continue
        cols = diff[y0:y1].any(axis=0)
        xs = np.flatnonzero(cols)
        if xs.size == 0:
            continue
        s = p = xs[0]
        for x in list(xs[1:]) + [None]:
            if x is None or x - p > gap:
                out.append((s / density, (p + 1) / density, y0 / density, y1 / density))
                if x is not None:
                    s = x
            if x is not None:
                p = x
    return out


def overlap(a0, a1, b0, b1):
    return min(a1, b1) - max(a0, b0)


def match(web, flt, key_x, y_of, polarity=None, min_ov=0.4):
    """For each web item the nearest flutter item (same polarity, y overlap)."""
    res = []
    for w in web:
        wy0, wy1 = y_of(w)
        best = None
        for f in flt:
            if polarity and polarity(w) != polarity(f):
                continue
            fy0, fy1 = y_of(f)
            ov = overlap(wy0 - Y_SLACK, wy1 + Y_SLACK, fy0, fy1)
            if ov < min_ov * min(wy1 - wy0, fy1 - fy0):
                continue
            d = key_x(f) - key_x(w)
            if best is None or abs(d) < abs(best[0]):
                best = (d, f)
        res.append((w, best))
    return res


def median_shift(pairs):
    ds = [b[0] for _, b in pairs if b is not None and abs(b[0]) <= MAX_SHIFT]
    if len(ds) < 4:
        return 0.0
    m = float(np.median(ds))
    return m if abs(m) >= 1.0 and sum(1 for d in ds if abs(d - m) <= ALIGNED) >= 0.6 * len(ds) else 0.0


def near_miss(xs):
    """Pairs of left-edge columns 1..8 css px apart, both with >= 3 members."""
    if not xs:
        return []
    xs = sorted(round(x) for x in xs)
    cols = {}
    for x in xs:
        cols[x] = cols.get(x, 0) + 1
    keys = sorted(k for k, n in cols.items() if n >= 3)
    out = []
    for i, a in enumerate(keys):
        for b in keys[i + 1:]:
            if b - a > 8:
                break
            out.append({'a': a, 'b': b, 'na': cols[a], 'nb': cols[b]})
    return out


def analyse(react_png, flutter_png, density):
    web, flt = load(react_png), load(flutter_png)
    res = {'webSize': [round(web.shape[1] / density, 1), round(web.shape[0] / density, 1)],
           'flutterSize': [round(flt.shape[1] / density, 1), round(flt.shape[0] / density, 1)]}
    we, fe = vertical_segments(web, density), vertical_segments(flt, density)
    pairs = match(we, fe, lambda s: s[0], lambda s: (s[1], s[2]), polarity=lambda s: s[3])
    shift = median_shift(pairs)
    res['globalShift'] = round(shift, 2)
    findings, aligned, unmatched = [], 0, 0
    for w, best in pairs:
        if best is None or abs(best[0] - shift) > MAX_SHIFT:
            unmatched += 1
            continue
        d = best[0] - shift
        if abs(d) <= ALIGNED:
            aligned += 1
        else:
            findings.append({'kind': 'edge', 'side': 'left' if w[3] > 0 else 'right', 'web_x': w[0], 'flutter_x': best[1][0],
                             'delta': round(d, 2), 'y': [w[1], w[2]]})
    res['edges'] = {'web': len(we), 'flutter': len(fe), 'aligned': aligned, 'unmatched': unmatched}
    wi, fi = ink_clusters(web, density, we), ink_clusters(flt, density, fe)
    ipairs = match(wi, fi, lambda c: c[0], lambda c: (c[2], c[3]))
    ishift = shift
    ia = iu = 0
    for w, best in ipairs:
        if best is None or abs(best[0] - ishift) > MAX_SHIFT:
            iu += 1
            continue
        d = best[0] - ishift
        if abs(d) <= TEXT_ALIGNED:
            ia += 1
        else:
            findings.append({'kind': 'text', 'side': 'left', 'web_x': float(round(w[0], 2)), 'flutter_x': float(round(best[1][0], 2)),
                             'delta': float(round(d, 2)), 'y': [float(round(w[2], 1)), float(round(w[3], 1))]})
    res['ink'] = {'web': len(wi), 'flutter': len(fi), 'aligned': ia, 'unmatched': iu}
    res['findings'] = findings
    res['nearMiss'] = {'web': near_miss([s[0] for s in we if s[3] > 0] + [c[0] for c in wi]),
                       'flutter': near_miss([s[0] for s in fe if s[3] > 0] + [c[0] for c in fi])}
    return res


def case_density(root, case):
    meta = root / 'visual-testing-results/react' / f'{case}.metadata.json'
    try:
        return float(json.loads(meta.read_text())['viewport'].get('density', 1))
    except Exception:  # noqa: BLE001
        return 1.0


def cases_in(root):
    r = root / 'visual-testing-results/react'
    a = root / 'visual-testing-results/android'
    return sorted(p.name[:-4] for p in r.glob('*.png') if (a / p.name).is_file())


def cmd_run(args):
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    pats = args.cases.split(',') if args.cases else None
    results = {}
    for root in map(pathlib.Path, args.root):
        for case in cases_in(root):
            if pats and not any(fnmatch.fnmatch(case, p) for p in pats):
                continue
            d = case_density(root, case)
            try:
                r = analyse(root / 'visual-testing-results/react' / f'{case}.png',
                            root / 'visual-testing-results/android' / f'{case}.png', d)
            except Exception as exc:  # noqa: BLE001
                r = {'error': str(exc)}
            r['density'] = d
            r['root'] = str(root)
            results[case] = r
    (out / 'results.json').write_text(json.dumps(results, indent=1))
    n = sum(1 for r in results.values() if r.get('findings'))
    print(f'{len(results)} cases analysed, {n} with offsets; {out / "results.json"}')


def cmd_overlays(args):
    """Overlay PNG (web | flutter, offsets marked) for every case with findings."""
    out = pathlib.Path(args.out)
    res = json.loads((out / 'results.json').read_text())
    (out / 'overlays').mkdir(exist_ok=True)
    n = 0
    for case, r in res.items():
        if not r.get('findings'):
            continue
        a = argparse.Namespace(root=[r['root']], case=case, out=str(out / 'overlays' / f'{case}.png'))
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            cmd_show(a)
        n += 1
    print(f'{n} overlays in {out / "overlays"}')


def cmd_show(args):
    root = pathlib.Path(args.root[0])
    case = args.case
    d = case_density(root, case)
    rp = root / 'visual-testing-results/react' / f'{case}.png'
    fp = root / 'visual-testing-results/android' / f'{case}.png'
    r = analyse(rp, fp, d)
    web, flt = Image.open(rp).convert('RGB'), Image.open(fp).convert('RGB')
    from PIL import ImageDraw
    dw, df = ImageDraw.Draw(web), ImageDraw.Draw(flt)
    for f in r['findings']:
        col = (255, 0, 0) if f['kind'] == 'edge' else (0, 120, 255)
        y0, y1 = [int(v * d) for v in f['y']]
        dw.line([(int(f['web_x'] * d), y0), (int(f['web_x'] * d), y1)], fill=col, width=max(1, int(d)))
        df.line([(int(f['flutter_x'] * d), y0), (int(f['flutter_x'] * d), y1)], fill=col, width=max(1, int(d)))
    w = web.width + flt.width + 20
    h = max(web.height, flt.height)
    sheet = Image.new('RGB', (w, h), (200, 200, 200))
    sheet.paste(web, (0, 0))
    sheet.paste(flt, (web.width + 20, 0))
    sheet.save(args.out)
    print(json.dumps({k: r[k] for k in ('globalShift', 'edges', 'ink', 'webSize', 'flutterSize')}))
    for f in r['findings']:
        print(f)


def cmd_selftest(_):
    """A synthetic pair: the right-hand panel's rows and button are inset 4 css px
    more in the 'flutter' image."""
    import tempfile
    d = 1
    def make(row_x, btn_x):
        im = np.full((200, 320, 3), 255, np.uint8)
        im[20:60, 16:304] = 0
        im[22:58, 18:302] = 255  # search field, 2px border at 16
        im[80:100, row_x:row_x + 2] = 0  # tall row avatar edge
        im[80:130, row_x:row_x + 30] = 0
        im[150:190, btn_x:320 - btn_x] = 0
        return Image.fromarray(im)
    t = pathlib.Path(tempfile.mkdtemp())
    make(12, 12).save(t / 'a.png')
    make(16, 16).save(t / 'b.png')
    r = analyse(t / 'a.png', t / 'b.png', d)
    ds = sorted(f['delta'] for f in r['findings'] if f['kind'] == 'edge')
    assert any(abs(x - 4) < .5 for x in ds), r
    print('selftest ok', ds)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='cmd', required=True)
    for name, fn in (('run', cmd_run), ('show', cmd_show), ('overlays', cmd_overlays), ('selftest', cmd_selftest)):
        s = sub.add_parser(name)
        s.add_argument('--root', action='append', default=[])
        s.add_argument('--cases')
        s.add_argument('--case')
        s.add_argument('--out', default='.local/alignment/audit')
        s.set_defaults(fn=fn)
    a = p.parse_args()
    a.fn(a)


if __name__ == '__main__':
    sys.exit(main())
