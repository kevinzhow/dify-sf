"""Run the web build in Chromium on a Wayland compositor and collect the benchmark lines from the console.

Usage: python web_bench.py <build/web dir> <out.log> KEY=VALUE...   (the KEY=VALUEs become the URL query)
Needs WAYLAND_DISPLAY (tool/bench.sh-style headless Weston) and Playwright's Chromium.
"""
import functools, http.server, sys, threading, time, urllib.parse
from playwright.sync_api import sync_playwright

root, out = sys.argv[1], sys.argv[2]
query = urllib.parse.urlencode(dict(a.split('=', 1) for a in sys.argv[3:]))

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
handler.log_message = lambda *a: None
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f'http://127.0.0.1:{server.server_address[1]}/?{query}'

lines = []
with sync_playwright() as p:
    browser = p.chromium.launch(headless=False, args=[
        '--ozone-platform=wayland', '--enable-gpu', '--ignore-gpu-blocklist', '--use-angle=gl-egl',
        '--window-size=1600,1000', '--start-fullscreen'])
    page = browser.new_page(viewport={'width': 1600, 'height': 1000})
    page.on('console', lambda m: lines.append(m.text))
    page.on('pageerror', lambda e: lines.append(f'PAGEERROR {e}'))
    page.goto(url)
    renderer = page.evaluate('''() => { const c = document.createElement('canvas').getContext('webgl2');
        const d = c && c.getExtension('WEBGL_debug_renderer_info');
        return c ? (d ? c.getParameter(d.UNMASKED_RENDERER_WEBGL) : c.getParameter(c.RENDERER)) : 'no webgl2'; }''')
    lines.insert(0, f'RENDERER {renderer}')
    t0 = time.time()
    while time.time() - t0 < 150 and not any(l == 'DONE' for l in lines):
        page.wait_for_timeout(250)
    browser.close()
server.shutdown()
open(out, 'w').write('\n'.join(lines) + '\n')
