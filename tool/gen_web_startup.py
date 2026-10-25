#!/usr/bin/env python3
"""Regenerate the tiny pre-Flutter theme/translation subset from the design system.

No remote font, CSS framework, or second token authority is introduced. Run --check
in verification; updating Dify's tokens/translations then regenerating updates the shell.
The loading glyph/animation is ported from Dify 1.17.1 base/loading (see docs).
"""
import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
TOKENS = ROOT / 'app/lib/src/design/dify_tokens.g.dart'
NAMES = ['backgroundDefault', 'textTertiary', 'textLogoText', 'textDestructive',
         'componentsButtonPrimaryBg', 'componentsButtonPrimaryBgHover', 'componentsButtonPrimaryText',
         'textAccentSecondary']


def css_color(value):
    solid = re.fullmatch(r'Color\(0x([A-Fa-f0-9]{8})\)', value)
    if solid:
        color = solid[1]
        if color[:2].upper() == 'FF':
            return '#' + color[2:].lower()
        return f'#{color[2:]}{color[:2]}'.lower()
    channels = re.fullmatch(r'Color.from\(alpha: ([\d.]+), red: (\d+) / 255, green: (\d+) / 255, blue: (\d+) / 255\)', value)
    if not channels:
        raise ValueError(value)
    a, r, g, b = channels.groups()
    return f'rgba({r}, {g}, {b}, {a})'


def variables(dark):
    tokens = TOKENS.read_text()
    result = []
    for name in NAMES:
        body = re.search(r'static Color get ' + name + r'\s*=>\s*(.*?);', tokens, re.S)[1]
        colors = re.findall(r'const (Color(?:\.from)?\([^)]*\))', body)
        value = colors[0 if dark or len(colors) == 1 else 1]
        variable = re.sub(r'[A-Z]', lambda m: '-' + m[0].lower(), name)
        result.append(f'  --{variable}: {css_color(value)};')
    return '\n'.join(result)


def outputs():
    js = ROOT / 'app/web/startup.js'
    labels = {}
    for path in sorted((ROOT / 'app/assets/i18n').iterdir()):
        app, common = path / 'app-api.json', path / 'common.json'
        if not app.exists() or not common.exists():
            continue
        labels[path.name] = {'loading': json.loads(app.read_text()).get('loading', 'Loading'),
                            'retry': json.loads(common.read_text()).get('operation.retry', 'Retry')}
    statement = 'window.__difyStartupLabels = ' + json.dumps(labels, ensure_ascii=False, separators=(',', ':')) + ';'
    content = re.sub(r'window\.__difyStartupLabels = .*?;', lambda _: statement, js.read_text(), count=1)
    css = ROOT / 'app/web/startup.css'
    style = css.read_text()
    for theme in ['light', 'dark']:
        pattern = rf'/\* BEGIN {theme} tokens \*/.*?/\* END {theme} tokens \*/'
        replacement = f'/* BEGIN {theme} tokens */\n{variables(theme == "dark")}\n/* END {theme} tokens */'
        style = re.sub(pattern, lambda _: replacement, style, flags=re.S)
    return {js: content, css: style}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    for path, content in outputs().items():
        if args.check:
            if path.read_text() != content:
                raise SystemExit(f'Stale generated startup design values: {path}')
        else:
            path.write_text(content)
    print('Web startup design values match the shared tokens and translations.')


if __name__ == '__main__':
    main()
