"""Visual comparison: the same Dify workflow file in Dify Web (the specification) and in our web build.

  tool/visual/.venv/bin/python tool/visual/compare.py [--cases tool/visual/cases.json] [--only ID,...] [--out DIR]

Needs, while it runs (start them only for the run):
  * a local Dify 1.17.1 at $DIFY_URL (default http://localhost) and an account: $DIFY_EMAIL, $DIFY_PASSWORD
  * the dify-sf server at $DIFYSF_URL (default http://127.0.0.1:18080); protocol 1.8 accounts: the script signs in as
    $DIFYSF_EMAIL / $DIFYSF_PASSWORD (default visual@example.com / Visual12345), setting that owner up on a fresh
    server, and hands our app the session the way it keeps one (localStorage `dify-sf/tokens/<server>`)
  * our web build: app/build/web (flutter build web --profile), served by this script; $OURS_QUERY adds query
    parameters to its URL (canvas=widgets: the widget renderer)

For each case: the workflow file (with the case's viewport written into it) is imported into Dify and into dify-sf;
both editors are opened in the same Chromium at the same window size; the same region of each canvas (relative to
the canvas's top-left corner) is captured. Results go to DIR/visual-testing-results/{react,android}/<case>.png (the
layout alignment_audit.py reads; react = Dify, android = ours) plus a pixel-difference summary in DIR/report.md.
--reuse-dify keeps the Dify captures of an earlier run in DIR (with the viewport Dify showed) and re-shoots ours
only: Dify need not run.
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


class Browsers:
    """Chromium at a real device pixel ratio (--force-device-scale-factor), one per window size: Playwright's
    emulated ratio (`device_scale_factor`) lays CSS out at ratio 1, so 0.5 px borders become 1 CSS px (2 device
    pixels), where a 2x screen draws 1 device pixel."""

    def __init__(self, playwright):
        self.playwright, self.browsers = playwright, {}

    def context(self, width, height):
        size = (int(width), int(height))
        if size not in self.browsers:
            self.browsers[size] = self.playwright.chromium.launch(
                args=[f'--force-device-scale-factor={DSF:g}', f'--window-size={size[0]},{size[1]}'])
        return self.browsers[size].new_context(no_viewport=True)

    def close(self):
        for b in self.browsers.values():
            b.close()


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


@functools.cache
def sf_tokens():
    """An access / refresh token pair of the dify-sf server (protocol 1.8): the first owner on a fresh server."""
    email = os.environ.get('DIFYSF_EMAIL', 'visual@example.com')
    password = os.environ.get('DIFYSF_PASSWORD', 'Visual12345')
    if requests.get(f'{SF}/v1/setup').json().get('step') != 'finished':
        r = requests.post(f'{SF}/v1/setup', json={'email': email, 'name': 'Visual', 'password': password})
    else:
        r = requests.post(f'{SF}/v1/auth/login', json={'email': email, 'password': password})
    r.raise_for_status()
    j = r.json()
    return {'access_token': j['access_token'], 'refresh_token': j['refresh_token']}


def sf_import(text):
    r = requests.post(f'{SF}/v1/docs/import', data=text.encode(),
                      headers={'Content-Type': 'application/x-yaml',
                               'Authorization': f'Bearer {sf_tokens()["access_token"]}'})
    r.raise_for_status()
    return r.json()['id']


def serve(directory):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=directory)
    handler.log_message = lambda *a: None
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f'http://127.0.0.1:{server.server_address[1]}'


def capture_dify(browsers, s, app_id, case, out):
    ctx = browsers.context(*case['window'])
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
    if case.get('select'):
        # Open the node's panel as a user would (the viewport is read before: the panel does not move it), clicking
        # near its top-left corner (the middle may be a control of its own, as an LLM node's model badge).
        node = page.locator(f'.react-flow__node[data-id="{case["select"]}"]')
        try:
            node.click(position={'x': 16, 'y': 16}, timeout=5000)
        except Exception:
            # Off screen (Dify fitted the view elsewhere): React Flow selects on the element's click all the same.
            node.dispatch_event('click')
        # Then off the canvas: the pointer resting on the node would show its hover state (the node control, the
        # highlighted edges), which ours, selected without a pointer, does not.
        page.mouse.move(0, 0)
        # Long enough for transient toasts to go (Dify reports the models it cannot load here, the failed request
        # coming back a while after the click): then until no toast is left (dify-ui's toast viewport is empty).
        page.wait_for_timeout(5000)
        try:
            page.wait_for_function(
                "() => [...document.querySelectorAll('[class*=\"toast-viewport\"] *')].every(e => !e.getClientRects().length)",
                timeout=15000)
            page.wait_for_timeout(300)
        except Exception:
            print(f'  {case["id"]}: a Dify toast stayed')
    shot(page, box, case, out)
    # Where Dify draws text (every non-empty text node on the page: canvas, header, node panel), relative to the
    # captured region.
    rects = page.evaluate(TEXT_RECTS)
    ox, oy = box['x'] + case['region'][0], box['y'] + case['region'][1]
    out.with_suffix('.text.json').write_text(
        json.dumps([[(r[0] - ox) * DSF, (r[1] - oy) * DSF, (r[2] - ox) * DSF, (r[3] - oy) * DSF] for r in rects]))
    ctx.close()
    return box, viewport


TEXT_RECTS = """() => {
  const out = [];
  const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n = walk.nextNode(); n; n = walk.nextNode()) {
    if (!n.textContent.trim()) continue;
    const range = document.createRange();
    range.selectNodeContents(n);
    for (const r of range.getClientRects()) if (r.width > 0 && r.height > 0) out.push([r.left, r.top, r.right, r.bottom]);
  }
  // Values and placeholders of text fields are not text nodes: their lines, measured with the field's font, from
  // the content box's left edge.
  const ctx = document.createElement('canvas').getContext('2d');
  for (const el of document.querySelectorAll('input, textarea')) {
    const text = el.value || el.placeholder;
    const r = el.getBoundingClientRect();
    if (!text || !r.width || !r.height || el.type === 'hidden' || el.type === 'checkbox' || el.type === 'radio') continue;
    const cs = getComputedStyle(el);
    ctx.font = cs.font;
    const left = r.left + parseFloat(cs.borderLeftWidth) + parseFloat(cs.paddingLeft);
    const top = r.top + parseFloat(cs.borderTopWidth) + parseFloat(cs.paddingTop);
    const lh = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.2;
    const lines = el.tagName === 'TEXTAREA' ? text.split('\\n') : [text];
    lines.forEach((line, i) => {
      const w = ctx.measureText(line).width;
      const y = el.tagName === 'TEXTAREA' ? top + i * lh : r.top + (r.height - lh) / 2;
      if (w > 0 && y < r.bottom) out.push([left, y, Math.min(left + w, r.right), Math.min(y + lh, r.bottom)]);
    });
  }
  return out;
}"""


def capture_ours(browsers, base, doc, case, out, viewport):
    # Our page is only the editor; Dify's has its app sidebar too, so a whole-canvas case gives ours the size of
    # Dify's canvas (`oursWindow`).
    w, h = case.get('oursWindow', case['window'])
    ctx = browsers.context(w, h)
    # Signed in before the app starts: its token store (web) is localStorage['dify-sf/tokens/<server>'].
    ctx.add_init_script(f'localStorage.setItem({json.dumps("dify-sf/tokens/" + SF)}, {json.dumps(json.dumps(sf_tokens()))})')
    page = ctx.new_page()
    rect = []
    views = []
    page.on('console', lambda m: rect.append(m.text) if m.text.startswith('CANVAS_RECT') else None)
    page.on('console', lambda m: views.append(m.text) if m.text.startswith('CANVAS_VIEW') else None)
    settled = []
    page.on('console', lambda m: settled.append(1) if m.text.startswith('CANVAS_SETTLED') else None)
    bars = []
    page.on('console', lambda m: bars.append(m.text) if m.text.startswith('NODE_CONTROL ') else None)
    x, y, z = viewport
    select = f'&select={case["select"]}' if case.get('select') else ''
    page.goto(f'{base}/?server={SF}&doc={doc}&view={x},{y},{z}&visual=1{select}' + (f'&{EXTRA}' if EXTRA else ''))
    t0 = time.time()
    while not rect and time.time() - t0 < 60:
        page.wait_for_timeout(200)
    # Until every card on screen shows its final capture (the scene renderer says so), at most 20 s.
    t1 = time.time()
    while not settled and time.time() - t1 < 20:
        page.wait_for_timeout(200)
    page.wait_for_timeout(500 if settled else 0)
    l, t, w, h = (float(v) for v in rect[-1].split()[1].split(','))
    box = {'x': l, 'y': t, 'width': w, 'height': h}
    shot(page, box, case, out)
    if views:
        print(f'  ours at rest: {views[-1]}{"" if settled else " (never settled)"}')
    ctx.close()
    masks = []
    if bars and 'node-run' in case.get('intentional', {}):
        masks.append(node_run_mask(bars[-1], box, case))
    out.with_suffix('.mask.json').write_text(json.dumps(masks))
    return box


def node_run_mask(line, box, case):
    """Intentional difference `node-run` (the owner's decision): our node control (node-control.tsx) shows "Run this
    step" left of the `…` button; Dify 1.17.1 never does, as its `!nodesReadOnly` tests the object useNodesReadOnly()
    returns (always truthy), a Dify bug. Ours reports where its bar is (`NODE_CONTROL left,top,width,height`, CSS px
    on the page, scaled with the canvas); the bars share their right end, Dify's being 20 px (at zoom 1) shorter: the
    part of ours left of Dify's bar and Dify's rounded left end with its shadow (shadow-md reaches ~5 px aside, ~9 px
    below) are left out of the measure, on both sides. Returns [left, top, right, bottom] in image pixels."""
    l, t, w, h = (float(v) for v in line.split()[1].split(','))
    k = h / 24  # the canvas zoom: the bar is h-6 at zoom 1
    ox, oy = box['x'] + case['region'][0], box['y'] + case['region'][1]
    # Ours: 0.5 border, px-0.5, run 20, `…` 20, px-0.5, 0.5 border; Dify's bar starts where our run button ends
    # (l + 20k), its rounded end (rounded-lg) and side shadow reach 8 px past that.
    rect = [l - 6 * k, t - 2 * k, l + (20 + 8 + 6) * k, t + h + 10 * k]
    return [(rect[0] - ox) * DSF, (rect[1] - oy) * DSF, (rect[2] - ox) * DSF, (rect[3] - oy) * DSF]


def shot(page, box, case, out):
    ox, oy, w, h = case['region']
    page.screenshot(path=str(out), clip={'x': box['x'] + ox, 'y': box['y'] + oy, 'width': w, 'height': h})


def similarity(a, b, text_rects=(), masks=()):
    """Share of pixels within 16/255: over all pixels, and over the pixels outside Dify's text boxes (the acceptance
    measure; browsers and Flutter rasterise glyphs differently, text placement is checked by alignment_audit.py) and
    outside the regions of intentional differences ([masks], image pixels; left out of both measures)."""
    ia = np.asarray(Image.open(a).convert('RGB'), dtype=np.int16)
    ib = np.asarray(Image.open(b).convert('RGB'), dtype=np.int16)
    diff = np.abs(ia - ib).max(axis=2)
    keep = np.ones(diff.shape, bool)
    h, w = diff.shape
    counted = np.ones(diff.shape, bool)
    for l, t, r, btm in masks:
        counted[max(0, int(t)):max(0, int(np.ceil(btm))), max(0, int(l)):max(0, int(np.ceil(r)))] = False
    for l, t, r, btm in text_rects:
        # Clamped to the image (text left of or above the region, as Dify's app sidebar, would index from the end).
        y0, y1 = max(0, int(t) - 1), min(h, int(np.ceil(btm)) + 1)
        x0, x1 = max(0, int(l) - 1), min(w, int(np.ceil(r)) + 1)
        if y0 < y1 and x0 < x1:
            keep[y0:y1, x0:x1] = False
    same = (diff[counted] <= 16).mean()
    non_text = (diff[keep & counted] <= 16).mean()
    heat = Image.fromarray(np.where(~counted, 120, np.where(diff > 16, 255, np.where(keep, 0, 60))).astype(np.uint8))
    return same, non_text, heat


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cases', default=str(ROOT / 'tool/visual/cases.json'))
    ap.add_argument('--only')
    ap.add_argument('--out', default=str(ROOT / 'build/visual'))
    ap.add_argument('--reuse-dify', action='store_true',
                    help="reuse the Dify captures already in --out (no Dify needed): re-shoot ours only")
    a = ap.parse_args()
    cases = json.loads(pathlib.Path(a.cases).read_text())
    if a.only:
        cases = [c for c in cases if c['id'] in a.only.split(',')]
    out = pathlib.Path(a.out)
    (out / 'visual-testing-results/react').mkdir(parents=True, exist_ok=True)
    (out / 'visual-testing-results/android').mkdir(parents=True, exist_ok=True)
    (out / 'diff').mkdir(exist_ok=True)
    (out / 'visual-testing-results/react/metadata.json').write_text(json.dumps({'density': DSF}))
    s = None if a.reuse_dify else dify_session()
    server, base = serve(str(ROOT / 'app/build/web'))
    rows = []
    with sync_playwright() as p:
        browsers = Browsers(p)
        for c in cases:
            text = with_viewport((ROOT / c['fixture']).read_text(), *c['viewport'])
            if not c.get('keepSelection'):
                # A node saved as selected opens its panel in Dify; canvas cases compare the canvas alone.
                text = re.sub(r'^(\s+)selected: true$', r'\1selected: false', text, flags=re.M)
            web = out / 'visual-testing-results/react' / f'{c["id"]}.png'
            ours = out / 'visual-testing-results/android' / f'{c["id"]}.png'
            view = web.with_suffix('.view.json')
            doc = sf_import(text)
            if a.reuse_dify:
                viewport = tuple(json.loads(view.read_text()))
                obox = capture_ours(browsers, base, doc, c, ours, viewport)
            else:
                app_id = dify_import(s, text)
                try:
                    dbox, viewport = capture_dify(browsers, s, app_id, c, web)
                    view.write_text(json.dumps(viewport))
                    obox = capture_ours(browsers, base, doc, c, ours, viewport)
                    print(f'{c["id"]}: Dify viewport x={viewport[0]:.3f} y={viewport[1]:.3f} zoom={viewport[2]:.4f}; '
                          f'canvas at Dify {dbox["x"]:.2f},{dbox["y"]:.2f} ours {obox["x"]:.2f},{obox["y"]:.2f}')
                finally:
                    s.delete(f'{DIFY}/console/api/apps/{app_id}')
            text_rects = json.loads(web.with_suffix('.text.json').read_text())
            masks = json.loads(ours.with_suffix('.mask.json').read_text())
            same, non_text, heat = similarity(web, ours, text_rects, masks)
            heat.save(out / 'diff' / f'{c["id"]}.png')
            rows.append((c['id'], non_text, same))
            unmasked = f' (unmasked non-text {similarity(web, ours, text_rects)[1] * 100:.2f}%)' if masks else ''
            print(f'{c["id"]}: non-text {non_text * 100:.2f}%, all {same * 100:.2f}% of pixels within 16/255{unmasked}')
        browsers.close()
    server.shutdown()
    (out / 'report.md').write_text(
        '| case | non-text pixels within 16/255 (pass: 99.5%) | all pixels |\n|---|---|---|\n'
        + ''.join(f'| {i} | {n * 100:.2f}% | {v * 100:.2f}% |\n' for i, n, v in rows))


if __name__ == '__main__':
    main()
