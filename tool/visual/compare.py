"""Visual comparison: the same Dify workflow file in Dify Web (the specification) and in our web build.

  tool/visual/.venv/bin/python tool/visual/compare.py [--cases tool/visual/cases.json] [--only ID,...] [--out DIR]

Needs, while it runs (start them only for the run):
  * a local Dify 1.17.1 at $DIFY_URL (default http://localhost) and an account: $DIFY_EMAIL, $DIFY_PASSWORD
  * the dify-sf server at $DIFYSF_URL (default http://127.0.0.1:18080)
  * our web build: app/build/web (flutter build web --profile), served by this script; $OURS_QUERY adds query
    parameters to its URL (canvas=widgets: the widget renderer)

For each case: the workflow file (with the case's viewport written into it) is imported into Dify and into dify-sf;
both editors are opened in the same Chromium at the same window size; the same region of each canvas (relative to
the canvas's top-left corner) is captured. Results go to DIR/visual-testing-results/{react,android}/<case>.png (the
layout alignment_audit.py reads; react = Dify, android = ours) plus a pixel-difference summary in DIR/report.md.
"""
import argparse, base64, functools, http.server, json, os, pathlib, re, threading, time
import numpy as np
import requests
from PIL import Image, ImageChops
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[2]
DIFY = os.environ.get('DIFY_URL', 'http://localhost')
SF = os.environ.get('DIFYSF_URL', 'http://127.0.0.1:18080')
# Extra query parameters for our app, e.g. canvas=widgets (the widget renderer instead of Flutter Scene).
EXTRA = os.environ.get('OURS_QUERY', '')
# Device pixel ratio of both browsers: 2, the acceptance screen's (mibook).
DSF = float(os.environ.get('VISUAL_DSF', '2'))


def dify_session():
    s = requests.Session()
    pw = base64.b64encode(os.environ['DIFY_PASSWORD'].encode()).decode()
    r = s.post(f'{DIFY}/console/api/login', json={'email': os.environ['DIFY_EMAIL'], 'password': pw, 'remember_me': True, 'language': 'en-US'})
    r.raise_for_status()
    csrf = s.cookies.get('csrf_token')
    if csrf:
        s.headers['X-CSRF-Token'] = csrf
    return s


def with_viewport(yaml_text, x, y, zoom):
    """Sets workflow.graph.viewport in the file (Dify opens a workflow at the stored viewport)."""
    vp = f'viewport:\n      x: {x}\n      y: {y}\n      zoom: {zoom}\n'
    existing = r'^    viewport:\n(?:      .*(?:\n|$)){3}'
    if re.search(existing, yaml_text, re.M):
        return re.sub(existing, '    ' + vp, yaml_text, count=1, flags=re.M)
    return re.sub(r'^  graph:\n', '  graph:\n    ' + vp, yaml_text, count=1, flags=re.M)


def dify_import(s, text):
    r = s.post(f'{DIFY}/console/api/apps/imports', json={'mode': 'yaml-content', 'yaml_content': text})
    r.raise_for_status()
    body = r.json()
    if body.get('status') == 'pending':
        body = s.post(f'{DIFY}/console/api/apps/imports/{body["id"]}/confirm').json()
    return body['app_id']


def sf_import(text):
    r = requests.post(f'{SF}/v1/docs/import', data=text.encode(), headers={'Content-Type': 'application/x-yaml'})
    r.raise_for_status()
    return r.json()['id']


def serve(directory):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=directory)
    handler.log_message = lambda *a: None
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f'http://127.0.0.1:{server.server_address[1]}'


def capture_dify(browser, s, app_id, case, out):
    ctx = browser.new_context(viewport={'width': case['window'][0], 'height': case['window'][1]}, device_scale_factor=DSF)
    ctx.add_cookies([{'name': c.name, 'value': c.value, 'url': DIFY} for c in s.cookies])
    page = ctx.new_page()
    page.goto(f'{DIFY}/app/{app_id}/workflow')
    page.wait_for_selector('.react-flow__node', timeout=60000)
    page.wait_for_timeout(1500)  # icons, fonts, fit
    box = page.locator('.react-flow').bounding_box()
    # Dify fits the view on load: read the viewport it actually shows, and open ours at the same one.
    t = page.evaluate("getComputedStyle(document.querySelector('.react-flow__viewport')).transform")
    m = [float(v) for v in re.findall(r'-?[\d.]+(?:e-?\d+)?', t)]
    viewport = (m[4], m[5], m[0]) if len(m) == 6 else tuple(case['viewport'])
    shot(page, box, case, out)
    # Where Dify draws text (every non-empty text node in the canvas), relative to the captured region.
    rects = page.evaluate(TEXT_RECTS)
    ox, oy = box['x'] + case['region'][0], box['y'] + case['region'][1]
    out.with_suffix('.text.json').write_text(
        json.dumps([[(r[0] - ox) * DSF, (r[1] - oy) * DSF, (r[2] - ox) * DSF, (r[3] - oy) * DSF] for r in rects]))
    ctx.close()
    return box, viewport


TEXT_RECTS = """() => {
  const out = [];
  const root = document.querySelector('.react-flow');
  const walk = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let n = walk.nextNode(); n; n = walk.nextNode()) {
    if (!n.textContent.trim()) continue;
    const range = document.createRange();
    range.selectNodeContents(n);
    for (const r of range.getClientRects()) if (r.width > 0 && r.height > 0) out.push([r.left, r.top, r.right, r.bottom]);
  }
  return out;
}"""


def capture_ours(browser, base, doc, case, out, viewport):
    ctx = browser.new_context(viewport={'width': case['window'][0], 'height': case['window'][1]}, device_scale_factor=DSF)
    page = ctx.new_page()
    rect = []
    views = []
    page.on('console', lambda m: rect.append(m.text) if m.text.startswith('CANVAS_RECT') else None)
    page.on('console', lambda m: views.append(m.text) if m.text.startswith('CANVAS_VIEW') else None)
    x, y, z = viewport
    page.goto(f'{base}/?server={SF}&doc={doc}&view={x},{y},{z}&visual=1' + (f'&{EXTRA}' if EXTRA else ''))
    t0 = time.time()
    while not rect and time.time() - t0 < 60:
        page.wait_for_timeout(200)
    page.wait_for_timeout(2500)  # captures and overviews
    l, t, w, h = (float(v) for v in rect[-1].split()[1].split(','))
    box = {'x': l, 'y': t, 'width': w, 'height': h}
    shot(page, box, case, out)
    if views:
        print(f'  ours at rest: {views[-1]}')
    ctx.close()
    return box


def shot(page, box, case, out):
    ox, oy, w, h = case['region']
    page.screenshot(path=str(out), clip={'x': box['x'] + ox, 'y': box['y'] + oy, 'width': w, 'height': h})


def similarity(a, b, text_rects=()):
    """Share of pixels within 16/255: over all pixels, and over the pixels outside Dify's text boxes (the acceptance
    measure; browsers and Flutter rasterise glyphs differently, text placement is checked by alignment_audit.py)."""
    ia = np.asarray(Image.open(a).convert('RGB'), dtype=np.int16)
    ib = np.asarray(Image.open(b).convert('RGB'), dtype=np.int16)
    diff = np.abs(ia - ib).max(axis=2)
    keep = np.ones(diff.shape, bool)
    h, w = diff.shape
    for l, t, r, btm in text_rects:
        keep[max(0, int(t) - 1):min(h, int(np.ceil(btm)) + 1), max(0, int(l) - 1):min(w, int(np.ceil(r)) + 1)] = False
    same = (diff <= 16).mean()
    non_text = (diff[keep] <= 16).mean()
    heat = Image.fromarray(np.where(diff > 16, 255, np.where(keep, 0, 60)).astype(np.uint8))
    return same, non_text, heat


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cases', default=str(ROOT / 'tool/visual/cases.json'))
    ap.add_argument('--only')
    ap.add_argument('--out', default=str(ROOT / 'build/visual'))
    a = ap.parse_args()
    cases = json.loads(pathlib.Path(a.cases).read_text())
    if a.only:
        cases = [c for c in cases if c['id'] in a.only.split(',')]
    out = pathlib.Path(a.out)
    (out / 'visual-testing-results/react').mkdir(parents=True, exist_ok=True)
    (out / 'visual-testing-results/android').mkdir(parents=True, exist_ok=True)
    (out / 'diff').mkdir(exist_ok=True)
    (out / 'visual-testing-results/react/metadata.json').write_text(json.dumps({'density': DSF}))
    s = dify_session()
    server, base = serve(str(ROOT / 'app/build/web'))
    rows = []
    with sync_playwright() as p:
        browser = p.chromium.launch()
        for c in cases:
            text = with_viewport((ROOT / c['fixture']).read_text(), *c['viewport'])
            if not c.get('keepSelection'):
                # A node saved as selected opens its panel in Dify; canvas cases compare the canvas alone.
                text = re.sub(r'^(\s+)selected: true$', r'\1selected: false', text, flags=re.M)
            app_id, doc = dify_import(s, text), sf_import(text)
            web = out / 'visual-testing-results/react' / f'{c["id"]}.png'
            ours = out / 'visual-testing-results/android' / f'{c["id"]}.png'
            try:
                dbox, viewport = capture_dify(browser, s, app_id, c, web)
                obox = capture_ours(browser, base, doc, c, ours, viewport)
                print(f'{c["id"]}: Dify viewport x={viewport[0]:.3f} y={viewport[1]:.3f} zoom={viewport[2]:.4f}; '
                      f'canvas at Dify {dbox["x"]:.2f},{dbox["y"]:.2f} ours {obox["x"]:.2f},{obox["y"]:.2f}')
            finally:
                s.delete(f'{DIFY}/console/api/apps/{app_id}')
            same, non_text, heat = similarity(web, ours, json.loads(web.with_suffix('.text.json').read_text()))
            heat.save(out / 'diff' / f'{c["id"]}.png')
            rows.append((c['id'], non_text, same))
            print(f'{c["id"]}: non-text {non_text * 100:.2f}%, all {same * 100:.2f}% of pixels within 16/255')
        browser.close()
    server.shutdown()
    (out / 'report.md').write_text(
        '| case | non-text pixels within 16/255 (pass: 99.5%) | all pixels |\n|---|---|---|\n'
        + ''.join(f'| {i} | {n * 100:.2f}% | {v * 100:.2f}% |\n' for i, n, v in rows))


if __name__ == '__main__':
    main()
