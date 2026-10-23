#!/usr/bin/env python3
"""Compare a complete native SVG inventory with Chromium at 40 CSS px / 2x, without masks.

First render from app/:
  SVG_ASSET_OUT=/absolute/output SVG_ASSET_ROOT=/checkout/app/assets flutter test ../tool/visual/render_svg_inventory.dart
Then run this script with --out pointing to that same directory. SVGs use their intrinsic aspect ratio and
Noto/Dify foreground colors (#101828 / #f9fafb) for inherited currentColor on white / #101828 backgrounds.
The native index records every original asset path; the result also records SHA-256 for reproducibility.
"""
import argparse
import base64
import functools
import http.server
import threading
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

import numpy as np
from PIL import Image, ImageDraw
from playwright.sync_api import sync_playwright

SVG_NS = 'http://www.w3.org/2000/svg'
ET.register_namespace('', SVG_NS)
ET.register_namespace('xlink', 'http://www.w3.org/1999/xlink')
RARE = {'embedded/chromeplugin-option.svg', 'embedded/scripts-option.svg',
        'dify_icons/public/knowledge/online-drive/buckets-blue.svg',
        'dify_icons/public/knowledge/online-drive/buckets-gray.svg',
        'dify_icons/public/knowledge/online-drive/folder.svg'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--flutter-web', type=Path, help='compiled svg_gallery.dart Web output')
    parser.add_argument('--reuse-reference', action='store_true', help='reuse matching original Chromium captures from the native stage')
    args = parser.parse_args()
    rows = json.loads((args.out / 'index.json').read_text())
    code_sha = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    contract = args.out / 'reference-contract.json'
    reuse = args.reuse_reference and contract.exists() and json.loads(contract.read_text()).get('scriptSha256') == code_sha
    reference = {r['id']: r for r in json.loads((args.out / 'metrics.json').read_text())} if reuse else {}
    sheets = {theme: Image.new('RGB', (760, 100 * len(RARE)), '#101828' if theme == 'dark' else '#ffffff')
              for theme in ('light', 'dark')}
    rare_y = {'light': 0, 'dark': 0}
    server = None
    if args.flutter_web:
        by_id = {row['id']: row for row in rows}
        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                if self.path == '/index.json':
                    body, kind = json.dumps(rows).encode(), 'application/json'
                elif self.path.startswith('/svg/'):
                    row = by_id.get(self.path.rsplit('/', 1)[-1].removesuffix('.svg'))
                    if row is None:
                        self.send_error(404);return
                    body, kind = Path(row['source']).read_bytes(), 'image/svg+xml'
                else:
                    return super().do_GET()
                self.send_response(200);self.send_header('Content-Type', kind)
                self.send_header('Content-Length', str(len(body)));self.end_headers();self.wfile.write(body)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(args.flutter_web)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
    with sync_playwright() as p:
        browser = p.chromium.launch(args=['--force-device-scale-factor=2', '--window-size=400,300'])
        context = browser.new_context(no_viewport=True)
        page = context.new_page()
        gallery = None
        if server:
            gallery = context.new_page()
            gallery.goto(f'http://127.0.0.1:{server.server_address[1]}/')
        for i, row in enumerate(rows):
            source = Path(row['source']).read_bytes()
            root = ET.fromstring(source)
            if 'color' not in root.attrib:
                root.set('color', '#f9fafb' if row['dark'] else '#101828')
            svg = ET.tostring(root, encoding='utf-8')
            url = 'data:image/svg+xml;base64,' + base64.b64encode(svg).decode()
            bg = '#101828' if row['dark'] else '#ffffff'
            page.set_content(f'<body style="margin:0;background:{bg}"><img style="display:block" width="40" height="40" src="{url}"></body>')
            page.locator('img').evaluate('(e) => e.decode()')
            expected = args.out / f'{row["id"]}-browser.png'
            if not (reuse and expected.exists() and reference.get(row['id'], {}).get('sha256') == hashlib.sha256(source).hexdigest()):
                page.locator('img').screenshot(path=str(expected))
            a = np.asarray(Image.open(expected).convert('RGB'))
            actual = args.out / f'{row["id"]}-flutter.png'
            if gallery:
                gallery.evaluate('(id) => { window.__svgReady = null; location.hash = id; }', row['id'])
                gallery.wait_for_function('(id) => window.__svgReady === id || String(window.__svgReady).startsWith("ERROR ")', arg=row['id'], timeout=30000)
                ready = gallery.evaluate('window.__svgReady')
                if ready != row['id']:
                    raise RuntimeError(ready)
                actual = args.out / f'{row["id"]}-web.png'
                gallery.screenshot(path=str(actual), clip={'x': 0, 'y': 0, 'width': 40, 'height': 40})
            b = np.asarray(Image.open(actual).convert('RGB'))
            delta = np.abs(a.astype(int) - b.astype(int))
            row.update(sha256=hashlib.sha256(source).hexdigest(), within16=float((delta.max(2) <= 16).mean()),
                       meanAbsoluteError=float(delta.mean()), maximum=int(delta.max()), deferred=row['name'] in RARE)
            if row['deferred']:
                theme = 'dark' if row['dark'] else 'light'
                y = rare_y[theme];rare_y[theme] += 100
                sheets[theme].paste(Image.fromarray(a), (0, y))
                sheets[theme].paste(Image.fromarray(b), (90, y))
                ImageDraw.Draw(sheets[theme]).text((180, y + 20), f'{row["name"]}\nwithin16={row["within16"]:.3%} MAE={row["meanAbsoluteError"]:.3f}', fill='#ffffff' if row['dark'] else '#101828')
            if (i + 1) % 100 == 0:
                print(f'{i + 1}/{len(rows)} compared', flush=True)
        browser.close()
    if server:
        server.shutdown()
    (args.out / ('web-metrics.json' if args.flutter_web else 'metrics.json')).write_text(json.dumps(rows, indent=2) + '\n')
    if not args.flutter_web:
        contract.write_text(json.dumps({'scriptSha256': code_sha, 'deviceScaleFactor': 2, 'cssSize': 40}) + '\n')
    for theme, sheet in sheets.items():
        sheet.save(args.out / f'rare-{theme}-browser-{"web" if args.flutter_web else "flutter"}.png')
    common = [r for r in rows if not r['deferred']]
    bad = [r for r in common if r['within16'] < .995]
    print(f'{len(rows)} theme cases; {len(common) - len(bad)}/{len(common)} non-deferred at >=99.5%; {len(rows)-len(common)} deferred')
    for row in sorted(bad, key=lambda r: r['within16']):
        print(f'{row["name"]} {"dark" if row["dark"] else "light"}: {row["within16"]:.3%}, MAE={row["meanAbsoluteError"]:.3f}')


if __name__ == '__main__':
    main()
