#!/usr/bin/env python3
"""Export the immutable upstream test source to a fresh owned dependency stage.

Run npm ci in --deps-root separately, then --link-deps. Never writes into the upstream checkout.
"""
import argparse,hashlib,json,subprocess,tarfile
from pathlib import Path
REFERENCE=json.loads(Path(__file__).with_name('ui_reference.json').read_text())
PIN=REFERENCE['commit']
TAG=REFERENCE['tag']

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--checkout',type=Path,required=True);p.add_argument('--deps-root',type=Path,required=True);p.add_argument('--link-deps',action='store_true');a=p.parse_args()
    root=a.deps_root.resolve();ref=root/'reference'
    commit=subprocess.check_output(['git','-C',str(a.checkout),'rev-parse',TAG+'^{commit}'],text=True).strip()
    if commit != PIN:raise ValueError('Expected the Dify 1.17.1 reference pin')
    if a.link_deps:
        for name,target in {'@langgenius/dify-ui':'dify-ui','@dify/iconify-collections':'iconify-collections','@dify/tsconfig':'tsconfig'}.items():
            dest=root/'node_modules'/name
            if dest.exists() or dest.is_symlink():raise ValueError(f'Refusing to replace an existing dependency: {name}')
            dest.parent.mkdir(parents=True,exist_ok=True);dest.symlink_to(ref/'packages'/target)
        return
    if ref.exists():raise ValueError('Fresh reference export required')
    root.mkdir(parents=True,exist_ok=True);archive=root/'reference-source.tar'
    with archive.open('xb') as stream:subprocess.run(['git','-C',str(a.checkout),'archive',commit,'web','packages/dify-ui','packages/iconify-collections','packages/tsconfig'],stdout=stream,check=True)
    ref.mkdir()
    with tarfile.open(archive) as stream:stream.extractall(ref,filter='data')
    (ref/'source-binding.json').write_text(json.dumps({'repository':'https://github.com/langgenius/dify','tag':TAG,'commit':commit,'archiveSha256':hashlib.sha256(archive.read_bytes()).hexdigest()},indent=2)+'\n')
if __name__=='__main__':main()
