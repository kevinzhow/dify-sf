"""Dify's own SVG icons (packages/iconify-collections/assets, the source of Dify's `i-custom-*` icon classes and of
the old icon components) copied as app assets.

Usage: python3 tool/gen_dify_icons.py <dify source root> app/assets/dify_icons
Writes <out>/vender/<group>/<name>.svg and <out>/public/... (`i-custom-vender-workflow-user-input` is
vender/workflow/user-input.svg). Like Dify's collection build (generate-collections.ts: `parseColors` with a
callback returning `currentColor` for custom-vender), every colour in a `vender` icon becomes `currentColor`;
`public` icons keep theirs. Re-run when the Dify baseline moves.
"""
import re, shutil, sys
from pathlib import Path

KEEP = {'none', 'transparent', 'currentcolor', 'inherit'}

def monotone(svg):
    def attr(m):
        v = m.group(3)
        return m.group(0) if v.lower() in KEEP or v.startswith('url(') else f'{m.group(1)}={m.group(2)}currentColor{m.group(2)}'
    svg = re.sub(r'\b(fill|stroke|stop-color|color)=(["\'])([^"\']*)\2', attr, svg)
    def style(m):
        v = m.group(2).strip()
        return m.group(0) if v.lower() in KEEP or v.startswith('url(') else f'{m.group(1)}:currentColor'
    return re.sub(r'\b(fill|stroke|stop-color)\s*:\s*([^;"\']+)', style, svg)

src, out = Path(sys.argv[1]) / 'packages/iconify-collections/assets', Path(sys.argv[2])
if out.exists():
    shutil.rmtree(out)
n = 0
for f in sorted(src.rglob('*.svg')):
    dest = out / f.relative_to(src)
    dest.parent.mkdir(parents=True, exist_ok=True)
    if f.relative_to(src).parts[0] == 'vender':
        dest.write_text(monotone(f.read_text()))
    else:
        shutil.copyfile(f, dest)
    n += 1
print(f'{n} icons')
