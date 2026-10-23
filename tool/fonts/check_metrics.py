#!/usr/bin/env python3
"""A font asset cannot silently drift away from the generated alignment profile."""
from pathlib import Path
import hashlib,json
repo=Path(__file__).resolve().parents[2];rows=json.loads((repo/'tool/fonts/metrics.json').read_text())
expected={r['file'] for r in rows};actual={str(p.relative_to(repo)) for p in (repo/'app/assets/fonts').rglob('*') if p.suffix.lower() in {'.ttf','.woff2','.otf'}}
assert actual==expected, 'Font set changed; regenerate using tool/fonts/build_metrics.py'
for row in rows:
 assert hashlib.sha256((repo/row['file']).read_bytes()).hexdigest()==row['sha256'], f"Font bytes changed: {row['file']}; regenerate metrics"
print(f'Font alignment profiles match all {len(rows)} bundled font files')
