#!/usr/bin/env python3
"""Verify the deployed Chromium runtime, rather than only build metadata.

Requires Playwright with Chromium installed. The URL may be the public install
page or an offline demo; this tool does not sign in or modify backend data.
"""
import argparse
import json
from pathlib import Path
from urllib.parse import urlsplit

from playwright.sync_api import sync_playwright


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--wait-ms', type=int, default=3000)
    parser.add_argument('--require-https', action='store_true',
                        help='Fail unless the final document is HTTPS; this does not establish Safari JIT or performance')
    parser.add_argument('--capture-probe', action='store_true',
                        help='Also require the widget capture probe to report 20/20 correct textures')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    errors, resources, captures = [], [], []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        try:
            page = browser.new_page(viewport={'width': 1440, 'height': 1000})
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.on('console', lambda message: captures.append(message.text)
                    if message.text.startswith('CAPTURE') else None)

            def record(response):
                path = urlsplit(response.url).path
                if path.endswith(('.wasm', '.mjs', 'main.dart.js')):
                    resources.append({'url': response.url, 'status': response.status,
                                      'type': response.headers.get('content-type')})

            page.on('response', record)
            response = page.goto(args.url, wait_until='domcontentloaded')
            page.wait_for_selector('flutter-view', state='attached', timeout=60000)
            page.wait_for_timeout(args.wait_ms)
            if args.capture_probe:
                for _ in range(300):
                    if errors or any(line.startswith('CAPTURE_RESULT') for line in captures):
                        break
                    page.wait_for_timeout(200)
            context = page.evaluate('''({
                protocol:location.protocol, secure:isSecureContext,
                isolated:crossOriginIsolated,
                skwasmSingleThreaded:window._flutter_skwasmInstance?.skwasmSingleThreaded ?? null,
                runtime:window.__difyWebRuntime ?? null
            })''')
            page.screenshot(path=str(args.output / 'page.png'))
            wasm = [r for r in resources if urlsplit(r['url']).path.endswith('/main.dart.wasm')]
            skwasm = [r for r in resources if '/skwasm' in urlsplit(r['url']).path
                      and urlsplit(r['url']).path.endswith('.wasm')]
            fallback = any(urlsplit(r['url']).path.endswith('/main.dart.js') for r in resources)
            passed = (response is not None and response.status == 200 and not errors
                      and (not args.require_https or context['protocol'] == 'https:')
                      and any(r['status'] == 200 and (r['type'] or '').split(';')[0] == 'application/wasm' for r in wasm)
                      and any(r['status'] == 200 for r in skwasm) and not fallback
                      and (not args.capture_probe or 'CAPTURE_RESULT 20/20' in captures))
            result = {'passed': passed, 'browser': browser.version, 'context': context,
                      'requirements': {'https': args.require_https},
                      'resources': resources, 'errors': errors, 'captures': captures}
            (args.output / 'runtime.json').write_text(json.dumps(result, indent=2) + '\n')
            print(json.dumps({'passed': passed, 'browser': browser.version, 'context': context}))
            return 0 if passed else 1
        finally:
            browser.close()


if __name__ == '__main__':
    raise SystemExit(main())
