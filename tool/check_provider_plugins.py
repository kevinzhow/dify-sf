#!/usr/bin/env python3
"""The runtime package lock, bundled definitions and server resource must agree."""
import json
from pathlib import Path
import yaml
root=Path(__file__).resolve().parents[1]
lock=root/'e2e/plugins.lock.json'
assert lock.read_bytes()==(root/'server/Sources/CollabModels/Resources/provider-plugins.lock.json').read_bytes(), 'Regenerate the server runtime lock from e2e/plugins.lock.json'
pins=json.loads(lock.read_text())['plugins'];by_id={p['id']:p for p in pins}
assert len(by_id)==len(pins)==10
for path in (root/'server/Sources/CollabModels/Resources/dify-official-plugins').glob('*/manifest.yaml'):
 m=yaml.safe_load(path.read_text());pin=by_id[f"{m['author']}/{m['name']}"]
 assert pin['version']==m['version']
 assert pin['unique_identifier'].startswith(f"{pin['id']}:{pin['version']}@") and len(pin['sha256'])==64
print('10 provider definitions and signed runtime pins agree')
