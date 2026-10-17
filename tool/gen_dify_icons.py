"""Dify's own SVG icons (packages/iconify-collections/assets, the source of Dify's `i-custom-*` icon classes and of
the old icon components) copied as app assets.

Usage: python3 tool/gen_dify_icons.py <dify source root> app/assets/dify_icons
Writes <out>/vender/<group>/<name>.svg and <out>/public/... (`i-custom-vender-workflow-user-input` is
vender/workflow/user-input.svg). `vender` icons draw with `currentColor`. Re-run when the Dify baseline moves.
"""
import shutil, sys
from pathlib import Path

src, out = Path(sys.argv[1]) / 'packages/iconify-collections/assets', Path(sys.argv[2])
if out.exists():
    shutil.rmtree(out)
n = 0
for f in sorted(src.rglob('*.svg')):
    dest = out / f.relative_to(src)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(f, dest)
    n += 1
print(f'{n} icons')
