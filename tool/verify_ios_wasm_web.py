#!/usr/bin/env python3
"""Exercise the real Flutter loader and both artifacts, using Chromium.

iOS user-agent/vendor fixtures test policy and initialization, not Safari/iPhone
performance. All API responses are local anonymous fixtures; no account writes.
"""
import argparse
import json
import threading
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlencode, urlsplit, parse_qs

from playwright.sync_api import sync_playwright


class FixtureServer(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        data = {'/fixture/v1/setup': {'step': 'finished'},
                '/fixture/v1/system-features': {}}.get(urlsplit(self.path).path)
        if data is not None:
            body = json.dumps(data).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--baseline', action='store_true', help='Reproduce the prior WebKit fallback')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(('127.0.0.1', 0), partial(FixtureServer, directory=str(args.build)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    safari = lambda v: f'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 Version/{v} Mobile/15E148 Safari/604.1'
    cases = [dict(name='safari26.6', ua=safari('26.6'), vendor='Apple Computer, Inc.', platform='iPhone', wasm=not args.baseline)]
    if not args.baseline:
        cases += [
            dict(name='safari26.5', ua=safari('26.5'), vendor='Apple Computer, Inc.', platform='iPhone', wasm=False),
            dict(name='safari26.6-missing-features', ua=safari('26.6'), vendor='Apple Computer, Inc.', platform='iPhone', wasm=False, missing=True),
            dict(name='safari26.6-manual-compatibility', ua=safari('26.6'), vendor='Apple Computer, Inc.', platform='iPhone', wasm=False, compatibility=True),
            dict(name='ipad26.6-desktop-ua', ua='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/26.6 Safari/605.1.15', vendor='Apple Computer, Inc.', platform='MacIntel', wasm=True, width=820),
            dict(name='crios26.6-google-vendor', ua='Mozilla/5.0 (iPhone; CPU iPhone OS 26_6 like Mac OS X) AppleWebKit/605.1.15 CriOS/156.0 Mobile/15E148 Safari/604.1', vendor='Google Inc.', platform='iPhone', wasm=True),
            dict(name='mac-safari-unchanged', ua='Macintosh Version/26.6 Safari/605.1.15', vendor='Apple Computer, Inc.', platform='MacIntel', wasm=False, touch=False, width=1440),
            dict(name='android-unchanged', ua='Mozilla/5.0 (Linux; Android 15; Pixel 8) AppleWebKit/537.36 Chrome/156.0.0.0 Mobile Safari/537.36', vendor='Google Inc.', platform='Linux armv8l', wasm=True),
            dict(name='desktop-blink-unchanged', wasm=True, touch=False, width=1440),
            dict(name='safari26.6-main-download-failure', ua=safari('26.6'), vendor='Apple Computer, Inc.', platform='iPhone', wasm=False, fail='main.dart.wasm'),
            dict(name='safari26.6-engine-download-failure', ua=safari('26.6'), vendor='Apple Computer, Inc.', platform='iPhone', wasm=False, fail='skwasm_heavy.wasm'),
            dict(name='policy-download-failure', wasm=False, fail='wasm_policy.mjs'),
        ]
    results = []
    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch(headless=True, args=['--no-sandbox'])
            try:
                for case in cases:
                    touch = case.get('touch', True)
                    ctx = browser.new_context(viewport={'width': case.get('width', 390), 'height': 844},
                                              device_scale_factor=2, has_touch=touch, is_mobile=touch)
                    page = ctx.new_page()
                    errors, resources, writes, navigations, documents = [], [], [], [], []
                    page.on('pageerror', lambda e: errors.append(str(e)))
                    page.on('framenavigated', lambda frame: navigations.append(frame.url) if frame == page.main_frame else None)
                    page.on('request', lambda request: documents.append(request.url)
                            if request.resource_type == 'document' and request.frame == page.main_frame else None)
                    page.on('response', lambda r: resources.append({'path': urlsplit(r.url).path, 'status': r.status}))
                    if 'ua' in case:
                        ctx.add_init_script('Object.defineProperties(navigator,' + json.dumps({
                            k: {'value': v} for k, v in {'userAgent': case['ua'], 'vendor': case['vendor'],
                                'platform': case['platform'], 'maxTouchPoints': 5 if touch else 0}.items()
                        }) + ')')
                    if case.get('missing'):
                        ctx.add_init_script('''(() => {
                            const original=WebAssembly.compileStreaming;
                            WebAssembly.compileStreaming=source=>original(source);
                        })()''')

                    def guard(route):
                        request = route.request
                        if request.method not in ['GET', 'HEAD', 'OPTIONS']:
                            writes.append(request.method)
                            route.abort('blockedbyclient')
                        elif case.get('fail') and urlsplit(request.url).path.endswith('/' + case['fail']):
                            route.abort('failed')
                        else:
                            route.continue_()

                    ctx.route('**/*', guard)
                    params = {'server': base + '/fixture', 'lang': 'zh-Hans', 'v': 'ios-policy-test'}
                    if case.get('compatibility'):
                        params['renderer'] = 'canvaskit'
                    try:
                        page.goto(base + '/?' + urlencode(params), wait_until='domcontentloaded', timeout=90000)
                        if case.get('fail') in ['main.dart.wasm', 'skwasm_heavy.wasm']:
                            page.wait_for_url('**renderer=canvaskit', timeout=60000)
                        page.locator('flt-semantics-placeholder, flt-semantics').first.wait_for(state='attached', timeout=60000)
                        if page.locator('flt-semantics-placeholder').count():
                            # Flutter's iOS semantics enabler recognizes an AT
                            # click at the placeholder's center; e.click() at
                            # (0,0) only activates its desktop enabler.
                            page.locator('flt-semantics-placeholder').evaluate('''e => {
                                const r=e.getBoundingClientRect();
                                e.dispatchEvent(new MouseEvent('click', {bubbles:true,
                                    clientX:r.left+r.width/2, clientY:r.top+r.height/2}));
                            }''')
                        page.get_by_role('button', name='登录', exact=True).wait_for(timeout=60000)
                        page.wait_for_timeout(400)
                        runtime = page.evaluate('window.__difyWebRuntime || null')
                        if not args.baseline and case.get('fail') != 'wasm_policy.mjs':
                            assert runtime['phase'] == 'ready', runtime
                        paths = [r['path'] for r in resources if r['status'] == 200]
                        js = any(p.endswith('/main.dart.js') for p in paths)
                        wasm = any(p.endswith('/main.dart.wasm') for p in paths)
                        skwasm = any('/skwasm' in p and p.endswith('.wasm') for p in paths)
                        if case['wasm']:
                            assert wasm and skwasm and not js, (case, resources)
                        else:
                            assert js, (case, resources)
                        reload = case.get('fail') in ['main.dart.wasm', 'skwasm_heavy.wasm']
                        # Flutter's History API also emits framenavigated; count
                        # actual main-document requests to detect reload loops.
                        assert len(documents) == (2 if reload else 1), documents
                        if reload:
                            q = parse_qs(urlsplit(page.url).query)
                            assert q['server'] == [params['server']] and q['lang'] == ['zh-Hans'] and q['v'] == ['ios-policy-test']
                            assert q['renderer'] == ['canvaskit']
                        assert not errors and not writes, (errors, writes)
                        page.screenshot(path=str(args.output / (case['name'] + '.png')))
                        if case['name'] == 'safari26.6' and not args.baseline:
                            # A real app error after successful startup must not reload an active document.
                            before = page.url
                            page.evaluate("setTimeout(()=>{throw Error('intentional-after-ready')},0)")
                            page.wait_for_timeout(150)
                            assert errors == ['intentional-after-ready'] and page.url == before, errors
                            errors.clear()
                        result = {'case': case['name'], 'actualBrowser': browser.version, 'actualSafari': False,
                                  'expectedWasm': case['wasm'], 'dartWasmLoaded': wasm, 'skwasmLoaded': skwasm,
                                  'dartJsLoaded': js, 'runtime': runtime, 'mainDocumentLoads': len(documents),
                                  'errors': list(errors), 'mutatingRequests': list(writes), 'resources': resources}
                        results.append(result)
                        (args.output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
                        print(case['name'], 'PASS', flush=True)
                    except BaseException:
                        page.screenshot(path=str(args.output / (case['name'] + '-FAILED.png')))
                        (args.output / (case['name'] + '-FAILED.json')).write_text(json.dumps({
                            'errors': errors, 'resources': resources, 'navigations': navigations,
                            'runtime': page.evaluate('window.__difyWebRuntime || null')}, indent=2) + '\n')
                        raise
                    finally:
                        ctx.close()
            finally:
                browser.close()
    finally:
        server.shutdown()
        server.server_close()
    print(f'{len(results)} loader/runtime browser cases passed; not Safari hardware acceptance.', flush=True)


if __name__ == '__main__':
    main()
