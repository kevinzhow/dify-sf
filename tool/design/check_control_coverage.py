"""Fail when a shared widget is added without a recorded typography test strategy.

This gate is deliberately separate from actual rendering/behavior tests. A mapped
file is not a passing screenshot and cannot be used as a visual parity score.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
widgets = ROOT / 'app/lib/src/design/widgets'
coverage = json.loads((ROOT / 'tool/design/control_coverage.json').read_text())['files']
files = {p.name for p in widgets.glob('*.dart') if p.name != 'widgets.dart'}
errors = []
if files != set(coverage):
    errors.append(f'Inventory mismatch; missing={sorted(files-set(coverage))}; stale={sorted(set(coverage)-files)}')
for name, row in coverage.items():
    if row['kind'] not in {'gallery', 'text-composition', 'layout-or-non-text'} or not row['note']:
        errors.append(f'{name}: missing test strategy')
    for path in row['evidence']:
        if not (ROOT / path).is_file():
            errors.append(f'{name}: missing evidence source {path}')
if errors:
    raise SystemExit('\n'.join(errors))
print(f'Control typography inventory: {len(files)} shared widget files accounted for (not a visual score).')
