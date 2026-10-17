"""Diff map of one case: Dify on top, ours below, differing pixels (> 16/255) in red on a faded copy at the bottom.

  tool/visual/.venv/bin/python tool/visual/diffmap.py <results dir> <case> <out.png> [x0 y0 x1 y1]
"""
import sys
import numpy as np
from PIL import Image

root, case, out = sys.argv[1:4]
a = Image.open(f'{root}/visual-testing-results/react/{case}.png').convert('RGB')
b = Image.open(f'{root}/visual-testing-results/android/{case}.png').convert('RGB')
if len(sys.argv) > 4:
    box = tuple(int(v) for v in sys.argv[4:8])
    a, b = a.crop(box), b.crop(box)
A, B = np.asarray(a).astype(int), np.asarray(b).astype(int)
bad = np.abs(A - B).max(axis=2) > 16
faded = (A * 0.35 + 165).astype(np.uint8)
faded[bad] = [230, 0, 0]
w, h = a.size
im = Image.new('RGB', (w, h * 3 + 8), 'white')
im.paste(a, (0, 0)); im.paste(b, (0, h + 4)); im.paste(Image.fromarray(faded), (0, 2 * h + 8))
scale = max(1, 900 // max(w, 1))
if scale > 1:
    im = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
im.save(out)
print(f'{bad.mean() * 100:.2f}% differ')
