#!/usr/bin/env python3
"""Check reference dependencies and token-source bytes, independently of screenshots."""
import argparse,hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--root',type=Path,required=True);args=p.parse_args()
lock=json.loads((ROOT/'tool/design/reference.json').read_text())
for name,expected in lock['source_files'].items():
 assert hashlib.sha256((args.root/name).read_bytes()).hexdigest()==expected,f'Reference source drift: {name}; review the affected component families and regenerate tokens/recipes'
package=json.loads((args.root/'packages/dify-ui/package.json').read_text());web=json.loads((args.root/'web/package.json').read_text())
assert package['name']==lock['design_package'] and package['version']==lock['design_version']
deps={**web.get('devDependencies',{}),**web.get('dependencies',{})}
assert deps[package['name']]==lock['web_dependency'],'Reference dependency resolution changed'
print(json.dumps({'reference_commit':lock['commit'],'design_package':package['name'],'version':package['version'],'verified_source_files':len(lock['source_files'])}))
