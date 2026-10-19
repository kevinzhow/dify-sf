"""Visual comparison: the same Dify workflow file in Dify Web (the specification) and in our web build.

  tool/visual/.venv/bin/python tool/visual/compare.py [--cases tool/visual/cases.json] [--only ID,...] [--out DIR]
                                                     [--theme light|dark]

Needs, while it runs (start them only for the run):
  * a local Dify 1.17.1 at $DIFY_URL (default http://localhost) and an account: $DIFY_EMAIL, $DIFY_PASSWORD
  * the dify-sf server at $DIFYSF_URL (default http://127.0.0.1:18080); protocol 1.8 accounts: the script signs in as
    $DIFYSF_EMAIL / $DIFYSF_PASSWORD (default alice@example.test / Visual12345: Dify's local account's email, and its
    name "alice", so names, avatars and the workspace's name lay out alike), setting that owner up on a fresh server,
    and hands our app the session the way it keeps one (localStorage `dify-sf/tokens/<server>`)
  * our web build: app/build/web (flutter build web --profile), served by this script; $OURS_QUERY adds query
    parameters to its URL (canvas=widgets: the widget renderer)

For each case: the workflow file (with the case's viewport written into it) is imported into Dify and into dify-sf;
both editors are opened in the same Chromium at the same window size; the same region of each canvas (relative to
the canvas's top-left corner) is captured. Results go to DIR/visual-testing-results/{react,android}/<case>.png (the
layout alignment_audit.py reads; react = Dify, android = ours) plus a pixel-difference summary in DIR/report.md.
--reuse-dify keeps the Dify captures of an earlier run in DIR (with the viewport Dify showed) and re-shoots ours
only: Dify need not run.

--theme dark: the cases marked "dark": true only, both sides in the dark theme: both browsers prefer a dark colour
scheme (prefers-color-scheme), Dify is told so as its theme switch stores it (localStorage `theme`, next-themes) and
ours by `&theme=dark` on its URL; the results go to build/visual-dark unless --out says otherwise (so light and dark
captures never mix). The default, light, is the browsers' default scheme and Dify's default theme (system).

Cases beyond the canvas (cases.json):
  * "steps": what a user does after the editor opened, done in Dify by element (Playwright locators) and replayed in
    ours at the same place relative to the canvas (or, on a "page" case, the window): ours is driven through its own UI
    the same way, so both arrive in the same state by the same clicks. A step is one of
      {"click": LOC, "at": [x, y]?}   LOC: a CSS selector, {"role": ..., "name": ...} or {"text": ...}; "at": the
                                      point inside the element (CSS px from its top-left; default its middle)
      {"hover": LOC}  {"type": "text"}  {"press": "Enter"}  {"park": true} (the pointer to 0,0)
      {"wait": ms, "ours": ms?}       (ours: the wait on our side when it differs, e.g. the mock run's pace)
    with "dify": true on a step that is Dify's alone (not replayed). The resolved points are kept with the Dify capture
    (<case>.steps.json) for --reuse-dify.
  * "page": {"dify": "/signin", "ours": "query", "signedIn": false, "routes": [...]}: a page outside the editor; the
    region is relative to the window. "routes": canned answers, [{"side": "dify"|"ours", "url": glob, "method",
    "json"}] (Dify's /install only renders before Dify's setup: its setup status is answered "not_started").
  * "page" with a "fixture": a page of an app (`{app}` in "dify" / "ours" is each side's id of the fixture, imported on
    both sides first, e.g. {"dify": "/app/{app}/access-point", "ours": "app={app}&page=access-point"}); its "setup"
    requests ([{"method", "path", "json"?}], Dify's console paths with `{app}`) run on both sides after the import
    (Dify: /console/api<path>, dify-sf: /v1<path>), e.g. API keys or annotations both apps should have.
  * "comments": [{"x", "y", "content", "replies": [...]}]: canvas comments created through each side's API first.
  * "members": true: dify-sf's workspace gets the members Dify's has (same roles, active), by invitation.
  * "invite": true: an invitation is created on both sides first; "{token}" and "{email}" in "page" paths and queries
    are its own on each side (deleted again afterwards).
"""
import argparse, base64, functools, http.server, json, os, pathlib, re, sys, threading, time
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
# The theme of both sides (--theme): 'light' (the browsers' default colour scheme) or 'dark'.
THEME = 'light'


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
        if THEME == 'dark':
            return self.browsers[size].new_context(no_viewport=True, color_scheme='dark')
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
    email = os.environ.get('DIFYSF_EMAIL', 'alice@example.test')
    password = os.environ.get('DIFYSF_PASSWORD', 'Visual12345')
    if requests.get(f'{SF}/v1/setup').json().get('step') != 'finished':
        r = requests.post(f'{SF}/v1/setup', json={'email': email, 'name': os.environ.get('DIFYSF_NAME', 'alice'), 'password': password})
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


def sf_api(method, path, body=None):
    r = requests.request(method, f'{SF}{path}', json=body,
                         headers={'Authorization': f'Bearer {sf_tokens()["access_token"]}'})
    r.raise_for_status()
    return r.json() if r.content else None


def add_comments(case, s, app_id, doc):
    """The case's canvas comments, on Dify's app (when [s]) and on our document."""
    for c in case.get('comments', []):
        body = {'position_x': c['x'], 'position_y': c['y'], 'content': c['content'], 'mentioned_user_ids': []}
        if s:
            r = s.post(f'{DIFY}/console/api/apps/{app_id}/workflow/comments', json=body)
            r.raise_for_status()
            for reply in c.get('replies', []):
                s.post(f'{DIFY}/console/api/apps/{app_id}/workflow/comments/{r.json()["id"]}/replies',
                       json={'content': reply, 'mentioned_user_ids': []}).raise_for_status()
        made = sf_api('POST', f'/v1/docs/{doc}/comments', body)
        for reply in c.get('replies', []):
            sf_api('POST', f'/v1/docs/{doc}/comments/{made["id"]}/replies', {'content': reply})


def mirror_members(s):
    """dify-sf's workspace gets the members of Dify's (beside its owner): the same roles, activated, in Dify's order of
    joining (so both member lists have the same rows)."""
    if s is None:
        return
    ours = {m['email'] for m in sf_api('GET', '/v1/workspace/members')['accounts']}
    for m in sorted(s.get(f'{DIFY}/console/api/workspaces/current/members').json()['accounts'],
                    key=lambda m: m['created_at']):
        if m['role'] == 'owner' or m['status'] != 'active' or m['email'] in ours:
            continue
        res = sf_api('POST', '/v1/workspace/members/invite-email', {'emails': [m['email']], 'role': m['role']})
        token = re.search(r'token=([^&]+)', res['invitation_results'][0]['url']).group(1)
        requests.post(f'{SF}/v1/activate', json={'token': requests.utils.unquote(token), 'name': m['name'],
                                                  'password': 'Visual12345'}).raise_for_status()


# A new address each run (Dify keeps an account that once joined, and inviting it again is another flow), of one length.
INVITEE = f'invitee{int(time.time()) % 1000000:06d}@example.com'


def make_invites(s):
    """An invitation on each side (Dify's when [s]): {side: {'token', 'email'}}."""
    drop_invites(s)  # one left by an interrupted run
    out = {}
    res = sf_api('POST', '/v1/workspace/members/invite-email', {'emails': [INVITEE], 'role': 'normal'})
    url = res['invitation_results'][0]['url']
    out['ours'] = {'token': re.search(r'token=([^&]+)', url).group(1), 'email': requests.utils.quote(INVITEE)}
    if s:
        r = s.post(f'{DIFY}/console/api/workspaces/current/members/invite-email',
                   json={'emails': [INVITEE], 'role': 'normal', 'language': 'en-US'})
        r.raise_for_status()
        url = r.json()['invitation_results'][0]['url']
        out['dify'] = {'token': re.search(r'token=([^&]+)', url).group(1), 'email': requests.utils.quote(INVITEE)}
    return out


def drop_invites(s):
    """Removes the invited (pending) member again on both sides."""
    for m in sf_api('GET', '/v1/workspace/members')['accounts']:
        if m['email'].startswith('invitee'):
            sf_api('DELETE', f'/v1/workspace/members/{m["id"]}')
    if s:
        for m in s.get(f'{DIFY}/console/api/workspaces/current/members').json()['accounts']:
            if m['email'].startswith('invitee'):
                s.delete(f'{DIFY}/console/api/workspaces/current/members/{m["id"]}')


def serve(directory):
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a):
            pass

    handler = functools.partial(Quiet, directory=directory)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f'http://127.0.0.1:{server.server_address[1]}'


def locate(page, loc):
    if isinstance(loc, str):
        return page.locator(loc).first
    if 'role' in loc:
        return page.get_by_role(loc['role'], name=loc['name'], exact=loc.get('exact', True)).first
    return page.get_by_text(loc['text'], exact=loc.get('exact', True)).first


def run_dify_steps(page, steps, box):
    """Does [steps] in Dify; returns them with each pointer step's point relative to [box] (for the replay)."""
    done = []
    for i, st in enumerate(steps):
        st = dict(st)
        for k in ('click', 'hover'):
            if k in st:
                el = locate(page, st[k])
                try:
                    el.wait_for(state='visible', timeout=30000)
                except Exception:
                    page.screenshot(path='/tmp/visual-step-failed.png')
                    raise RuntimeError(f'step {i} {st}: not found (Dify page in /tmp/visual-step-failed.png)')
                r = el.bounding_box()
                ax, ay = st.get('at', [r['width'] / 2, r['height'] / 2])
                x, y = r['x'] + ax, r['y'] + ay
                if k == 'click':
                    page.mouse.click(x, y)
                else:
                    page.mouse.move(x, y)
                st['point'] = [x - box['x'], y - box['y']]
        if 'type' in st:
            page.keyboard.type(st['type'], delay=20)
        if 'press' in st:
            page.keyboard.press(st['press'])
        if st.get('park'):
            page.mouse.move(0, 0)
        if 'wait' in st:
            page.wait_for_timeout(st['wait'])
        done.append(st)
    return done


def run_our_steps(page, steps, box, log=()):
    """Replays the steps done in Dify ([run_dify_steps]) on ours, at the same points relative to [box]. A step's
    "until" (ours only): after its wait, also until our app has printed that many lines starting with it (e.g.
    `VISUAL_RUN`: a run came to an end; the mock run's pace depends on how fast the browser draws), at most 30 s."""
    for st in steps:
        if st.get('dify'):
            continue
        if 'point' in st:
            x, y = box['x'] + st['point'][0], box['y'] + st['point'][1]
            if 'click' in st:
                page.mouse.click(x, y)
            else:
                page.mouse.move(x, y)
            page.wait_for_timeout(150)
        if 'type' in st:
            page.keyboard.type(st['type'], delay=20)
        if 'press' in st:
            page.keyboard.press(st['press'])
        if st.get('park'):
            page.mouse.move(0, 0)
        if 'wait' in st:
            page.wait_for_timeout(st.get('ours', st['wait']))
        if 'until' in st:
            t0 = time.time()
            while sum(1 for m in log if m.startswith(st['until'])) < st.get('count', 1) and time.time() - t0 < 30:
                page.wait_for_timeout(200)
            page.wait_for_timeout(300)


def add_routes(page, case, side):
    for r in [*case.get('routes', []), *(case.get('page') or {}).get('routes', [])]:
        if r.get('side', 'both') not in (side, 'both'):
            continue
        if 'bodyFile' in r:
            body = (ROOT / r['bodyFile']).read_bytes()
        elif 'jsonFile' in r:
            body = (ROOT / r['jsonFile']).read_bytes()
        else:
            body = json.dumps(r['json'])
        page.route(r['url'], canned(r.get('method', 'GET'), body, r.get('contentType', 'application/json')))


def canned(method, body, content_type='application/json'):
    """A route handler answering [method] requests with the JSON [body] (others go through)."""
    def handler(route):
        if route.request.method == method:
            route.fulfill(status=200, content_type=content_type, body=body)
        else:
            route.continue_()
    return handler


def fill(text, invite):
    return text.format(**invite) if invite else text


def is_app_page(case):
    """A page of an imported app ("page" with a "fixture")."""
    return bool(case.get('page') and case.get('fixture'))


def with_app(case, side, app_id):
    """[case] with `{app}` in its page path / query of [side] ('dify' or 'ours') replaced by that side's app id."""
    if not is_app_page(case) or not app_id:
        return case
    page = dict(case['page'])
    page[side] = page.get(side, '').replace('{app}', app_id)
    return {**case, 'page': page}


def app_setup(case, s, dify_app, sf_app):
    """The case's "setup" requests on both sides (Dify's console paths; dify-sf serves them under /v1)."""
    for r in (case.get('page') or {}).get('setup', []):
        method, path, body = r.get('method', 'POST'), r['path'], r.get('json')
        if s is not None and dify_app:
            s.request(method, f'{DIFY}/console/api' + path.replace('{app}', dify_app), json=body).raise_for_status()
        if sf_app:
            sf_api(method, '/v1' + path.replace('{app}', sf_app), body)


def capture_dify(browsers, s, app_id, case, out, invite=None):
    ctx = browsers.context(*case['window'])
    if THEME == 'dark':
        # Dify's theme switch (next-themes: localStorage `theme`, light | dark | system), set before the app starts.
        ctx.add_init_script("localStorage.setItem('theme', 'dark')")
    pg_case = case.get('page')
    if not pg_case or pg_case.get('signedIn', True):
        ctx.add_cookies([{'name': c.name, 'value': c.value, 'url': DIFY} for c in s.cookies])
    page = ctx.new_page()
    add_routes(page, case, 'dify')
    if pg_case:
        page.goto(DIFY + fill(pg_case['dify'], invite))
        page.wait_for_load_state('networkidle')
        page.wait_for_timeout(2500)  # fonts, the page's own checks
        box = {'x': 0, 'y': 0, 'width': case['window'][0], 'height': case['window'][1]}
        viewport = (0, 0, 1)
    else:
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
    steps = run_dify_steps(page, case.get('steps', []), box)
    out.with_suffix('.steps.json').write_text(json.dumps(steps))
    if steps:
        page.wait_for_timeout(800)
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


def capture_ours(browsers, base, doc, case, out, viewport, steps=(), invite=None):
    # Our page is only the editor; Dify's has its app sidebar too, so a whole-canvas case gives ours the size of
    # Dify's canvas (`oursWindow`).
    w, h = case.get('oursWindow', case['window'])
    ctx = browsers.context(w, h)
    pg_case = case.get('page')
    # Signed in before the app starts: its token store (web) is localStorage['dify-sf/tokens/<server>'].
    if not pg_case or pg_case.get('signedIn', True):
        ctx.add_init_script(
            f'localStorage.setItem({json.dumps("dify-sf/tokens/" + SF)}, {json.dumps(json.dumps(sf_tokens()))})')
    page = ctx.new_page()
    add_routes(page, case, 'ours')
    rect = []
    views = []
    page.on('console', lambda m: rect.append(m.text) if m.text.startswith('CANVAS_RECT') else None)
    page.on('console', lambda m: views.append(m.text) if m.text.startswith('CANVAS_VIEW') else None)
    settled = []
    page.on('console', lambda m: settled.append(1) if m.text.startswith('CANVAS_SETTLED') else None)
    bars = []
    page.on('console', lambda m: bars.append(m.text) if m.text.startswith('NODE_CONTROL ') else None)
    log = []
    page.on('console', lambda m: log.append(m.text) if m.text.startswith('VISUAL_') else None)
    theme = '&theme=dark' if THEME == 'dark' else ''
    if pg_case:
        query = fill(pg_case.get('ours', ''), invite)
        page.goto(f'{base}/?server={SF}&visual=1' + (f'&{query}' if query else '') + (f'&{EXTRA}' if EXTRA else '')
                  + theme)
        page.wait_for_selector('flutter-view', timeout=60000)
        page.wait_for_load_state('networkidle')
        page.wait_for_timeout(3000)  # the first frames, fonts, the page's own requests
        box = {'x': 0, 'y': 0, 'width': w, 'height': h}
    else:
        x, y, z = viewport
        select = f'&select={case["select"]}' if case.get('select') else ''
        page.goto(f'{base}/?server={SF}&doc={doc}&view={x},{y},{z}&visual=1{select}' + (f'&{EXTRA}' if EXTRA else '')
                  + theme)
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
    if steps:
        run_our_steps(page, steps, box, log)
        page.wait_for_timeout(1200)
    shot(page, box, case, out)
    if views:
        print(f'  ours at rest: {views[-1]}{"" if settled or pg_case else " (never settled)"}')
    ctx.close()
    masks = []
    if bars and 'node-run' in case.get('intentional', {}):
        masks.append(node_run_mask(bars[-1], box, case))
    for rect_ in case.get('masks', {}).values():
        # The case's documented masks ({name: {"rect": [left, top, right, bottom] in CSS px of the region, "why"}}):
        # what dify-sf intentionally lacks, or content that depends on data (times, ids) beyond its text.
        masks.append([v * DSF for v in rect_['rect']])
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
    sys.stdout.reconfigure(line_buffering=True)
    ap = argparse.ArgumentParser()
    ap.add_argument('--cases', default=str(ROOT / 'tool/visual/cases.json'))
    ap.add_argument('--only')
    ap.add_argument('--out', help='default build/visual (light) or build/visual-dark (dark)')
    ap.add_argument('--ours-build', default=str(ROOT / 'app/build/web'),
                    help='web build to serve; use a fixed copy when another job may rebuild the app')
    ap.add_argument('--theme', choices=('light', 'dark'), default='light',
                    help='dark: the cases marked "dark" only, both sides in the dark theme')
    ap.add_argument('--reuse-dify', action='store_true',
                    help="reuse the Dify captures already in --out (no Dify needed): re-shoot ours only")
    ap.add_argument('--reuse-dify-from', metavar='DIR',
                    help='--reuse-dify with the Dify captures of DIR (copied into --out), e.g. the widget renderer '
                         'against the captures the scene renderer was compared with')
    a = ap.parse_args()
    global THEME
    THEME = a.theme
    cases = json.loads(pathlib.Path(a.cases).read_text())
    if THEME == 'dark':
        cases = [c for c in cases if c.get('dark')]
    if a.only:
        cases = [c for c in cases if c['id'] in a.only.split(',')]
    out = pathlib.Path(a.out or ROOT / ('build/visual-dark' if THEME == 'dark' else 'build/visual'))
    (out / 'visual-testing-results/react').mkdir(parents=True, exist_ok=True)
    (out / 'visual-testing-results/android').mkdir(parents=True, exist_ok=True)
    (out / 'diff').mkdir(exist_ok=True)
    (out / 'visual-testing-results/react/metadata.json').write_text(json.dumps({'density': DSF}))
    if a.reuse_dify_from:
        import shutil
        src = pathlib.Path(a.reuse_dify_from) / 'visual-testing-results/react'
        for c in cases:
            for f in src.glob(f'{c["id"]}.*'):
                shutil.copy(f, out / 'visual-testing-results/react' / f.name)
        a.reuse_dify = True
    s = None if a.reuse_dify else dify_session()
    server, base = serve(a.ours_build)
    rows = []
    with sync_playwright() as p:
        browsers = Browsers(p)
        for c in cases:
            text = with_viewport((ROOT / c['fixture']).read_text(), *c['viewport']) if c.get('fixture') else ''
            if not c.get('keepSelection'):
                # A node saved as selected opens its panel in Dify; canvas cases compare the canvas alone.
                text = re.sub(r'^(\s+)selected: true$', r'\1selected: false', text, flags=re.M)
            web = out / 'visual-testing-results/react' / f'{c["id"]}.png'
            ours = out / 'visual-testing-results/android' / f'{c["id"]}.png'
            view = web.with_suffix('.view.json')
            doc = sf_import(text) if not c.get('page') or is_app_page(c) else None
            if c.get('members'):
                mirror_members(s)
            invites = make_invites(s) if c.get('invite') else {}
            try:
                if a.reuse_dify:
                    viewport = tuple(json.loads(view.read_text()))
                    if doc:
                        add_comments(c, None, None, doc)
                    steps = json.loads(web.with_suffix('.steps.json').read_text()) \
                        if web.with_suffix('.steps.json').exists() else []
                    if is_app_page(c):
                        app_setup(c, None, None, doc)
                    obox = capture_ours(browsers, base, doc, with_app(c, 'ours', doc), ours, viewport, steps,
                                        invites.get('ours'))
                else:
                    app_id = dify_import(s, text) if not c.get('page') or is_app_page(c) else None
                    try:
                        if app_id and not c.get('page'):
                            add_comments(c, s, app_id, doc)
                        if is_app_page(c):
                            app_setup(c, s, app_id, doc)
                        dbox, viewport = capture_dify(browsers, s, app_id, with_app(c, 'dify', app_id), web,
                                                      invites.get('dify'))
                        view.write_text(json.dumps(viewport))
                        steps = json.loads(web.with_suffix('.steps.json').read_text())
                        obox = capture_ours(browsers, base, doc, with_app(c, 'ours', doc), ours, viewport, steps,
                                            invites.get('ours'))
                        print(f'{c["id"]}: Dify viewport x={viewport[0]:.3f} y={viewport[1]:.3f} '
                              f'zoom={viewport[2]:.4f}; canvas at Dify {dbox["x"]:.2f},{dbox["y"]:.2f} '
                              f'ours {obox["x"]:.2f},{obox["y"]:.2f}')
                    finally:
                        if app_id:
                            s.delete(f'{DIFY}/console/api/apps/{app_id}')
            finally:
                if c.get('invite'):
                    drop_invites(s)
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
        f'Theme: {THEME}\n\n'
        '| case | non-text pixels within 16/255 (pass: 99.5%) | all pixels |\n|---|---|---|\n'
        + ''.join(f'| {i} | {n * 100:.2f}% | {v * 100:.2f}% |\n' for i, n, v in rows))


if __name__ == '__main__':
    main()
