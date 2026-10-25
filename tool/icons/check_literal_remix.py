#!/usr/bin/env python3
"""Reject missing SVGs for literal RemixIcon calls; dynamic names need UI checks."""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
missing = []
for path in (root / 'app/lib').rglob('*.dart'):
    for match in re.finditer(r"RemixIcon\(\s*['\"]([a-z0-9-]+)['\"]", path.read_text()):
        name = match[1]
        if not (root / 'app/assets/remix_icons' / (name + '.svg')).is_file():
            missing.append(f'{path.relative_to(root)}:{path.read_text()[:match.start()].count(chr(10)) + 1}: {name}')
if missing:
    print('\n'.join(missing))
    sys.exit(1)
print('All literal RemixIcon names have bundled SVGs; dynamic names also require browser asset admission.')
