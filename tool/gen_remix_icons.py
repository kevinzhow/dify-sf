"""Remix Icon SVGs as Dify uses them: the icon data of @iconify-json/ri at the version Dify pins (1.2.10), only the
icons Dify's web source references (`i-ri-*` classes and `Ri*` components from @remixicon/react), plus literal
RemixIcon references in this port's app/lib (offline/connection/DSL affordances).

Usage: python3 tool/gen_remix_icons.py <dify source root> app/assets/remix_icons
Remix Icon is Apache-2.0 (https://github.com/Remix-Design/RemixIcon).
"""
import io, json, re, sys, tarfile, urllib.request
from pathlib import Path

VERSION = '1.2.10'
root, out = Path(sys.argv[1]), Path(sys.argv[2])

used = set()
for f in (root / 'web').rglob('*'):
    if f.suffix not in ('.tsx', '.ts', '.css') or 'node_modules' in f.parts:
        continue
    t = f.read_text(errors='ignore')
    used.update(re.findall(r'i-ri-([a-z0-9]+(?:-[a-z0-9]+)*)', t))
    for name in re.findall(r'\bRi([A-Z][A-Za-z0-9]*)\b', t):
        used.add(re.sub(r'(?<!^)(?=[A-Z])|(?<=[a-z])(?=[0-9])', '-', name).lower())

# The port has its own connection/offline/DSL affordances as well. Include
# literal references so regenerating the pinned upstream set cannot omit them.
for f in (Path(__file__).resolve().parents[1] / 'app/lib').rglob('*.dart'):
    used.update(re.findall(r"RemixIcon\(\s*['\"]([a-z0-9-]+)['\"]", f.read_text()))

url = f'https://registry.npmjs.org/@iconify-json/ri/-/ri-{VERSION}.tgz'
data = urllib.request.urlopen(url, timeout=60).read()
with tarfile.open(fileobj=io.BytesIO(data)) as tar:
    icons = json.load(tar.extractfile('package/icons.json'))
size = icons.get('width', 24)
out.mkdir(parents=True, exist_ok=True)
found = 0
for name in sorted(used):
    icon = icons['icons'].get(name)
    if icon is None:
        alias = icons.get('aliases', {}).get(name)
        icon = icons['icons'].get(alias['parent']) if alias else None
    if icon is None:
        continue
    w, h = icon.get('width', size), icon.get('height', size)
    (out / f'{name}.svg').write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{icon["body"]}</svg>')
    found += 1
print(f'{found} of {len(used)} referenced names written (others are not Remix names)')
