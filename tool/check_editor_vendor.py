#!/usr/bin/env python3
"""Fail on unreviewed changes to the pinned native editor integration."""
import hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];vendor=ROOT/'third_party/re_editor'
lock=json.loads((vendor/'UPSTREAM.json').read_text())
assert lock['version']=='0.10.0' and lock['license']=='MIT'
actual={p.relative_to(vendor).as_posix() for p in vendor.rglob('*') if p.is_file() and p.name not in ['UPSTREAM.json','PATCHES.md']}
assert actual==set(lock['files']),'Vendored file inventory changed'
for name,row in lock['files'].items():assert hashlib.sha256((vendor/name).read_bytes()).hexdigest()==row['vendored_sha256'],f'Unreviewed editor patch: {name}'
assert lock['files']['LICENSE']['upstream_sha256']==lock['files']['LICENSE']['vendored_sha256'],'Upstream license changed'
oracle=json.loads((ROOT/'app/test/code_editor/monaco_wrapping.json').read_text())
assert oracle['version']=='0.52.2' and oracle['sourceSha256']=='f29e97145978518e2877ff4d473fedd56ddd8405b48773c03a80ef1ea79cc009'
print(json.dumps({'vendor_files':len(actual),'upstream_commit':lock['commit'],'monaco_wrapping_cases':len(oracle['cases'])}))
