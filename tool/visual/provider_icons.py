#!/usr/bin/env python3
"""Compare all provider icon fixtures to Chromium's original SVG rendering in both themes.

Run app/test/provider_icon_render_test.dart with PROVIDER_ICON_OUT set to an absolute
output directory first. This script captures the original fixtures at the same 40px/2x
size, records unmasked RGB differences and writes side-by-side sheets for inspection.
"""
import argparse
import base64
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from playwright.sync_api import sync_playwright


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    fixtures = root / 'app/test/fixtures/provider_icons'
    cases = json.loads((fixtures / 'cases.json').read_text())
    args.out.mkdir(parents=True, exist_ok=True)
    rows = []
    sheets = {}
    with sync_playwright() as p:
        browser = p.chromium.launch(args=['--force-device-scale-factor=2'])
        page = browser.new_page(viewport={'width': 400, 'height': 300}, device_scale_factor=2)
        for case in cases:
            name, dark = case['name'], case['dark']
            bg = '#101828' if dark else '#ffffff'
            svg = (fixtures / f'{name}.svg').read_bytes()
            src = 'data:image/svg+xml;base64,' + base64.b64encode(svg).decode()
            page.set_content(f'<body style="margin:0;background:{bg}"><img style="display:block" width="40" height="40" src="{src}"></body>')
            page.locator('img').evaluate('(e) => e.decode()')
            expected = args.out / f'{name}-browser.png'
            page.locator('img').screenshot(path=str(expected))
            actual = args.out / f'{name}-flutter.png'
            a = np.array(Image.open(expected).convert('RGB'))
            b = np.array(Image.open(actual).convert('RGB'))
            delta = np.abs(a.astype(int) - b.astype(int))
            rows.append({'name': name, 'within16': float((delta.max(2) <= 16).mean()),
                         'meanAbsoluteError': float(delta.mean()), 'maximum': int(delta.max())})
            key = 'dark' if dark else 'light'
            if key not in sheets:
                sheets[key] = Image.new('RGB', (400, 100 * (len(cases)//2)), bg)
            sheet = sheets[key]
            y = (len([c for c in rows if c['name'].endswith(key)]) - 1) * 100
            ImageDraw.Draw(sheet).text((180, y + 30), name, fill='white' if dark else 'black')
            sheet.paste(Image.fromarray(a), (0, y))
            sheet.paste(Image.fromarray(b), (90, y))
        browser.close()
    for key, sheet in sheets.items():
        sheet.save(args.out / f'{key}-browser-flutter.png')
    (args.out / 'metrics.json').write_text(json.dumps(rows, indent=2) + '\n')
    for row in rows:
        print(f"{row['name']}: {row['within16']:.3%}, MAE {row['meanAbsoluteError']:.3f}")


if __name__ == '__main__':
    main()
