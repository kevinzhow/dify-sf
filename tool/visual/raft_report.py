#!/usr/bin/env python3
"""Feed actual Dify / Flutter captures into Raft's unchanged visual-testing diff + site CLI.

The caller supplies screenshots and source receipts; this adapter never renders fake UI, changes images,
uses AI analysis, or writes into the upstream checkout. Use a fresh output/site directory for each run.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def png_size(path):
    with path.open('rb') as stream:
        header = stream.read(24)
    if header[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'Expected a raw PNG: {path.name}')
    return list(struct.unpack('>II', header[16:24]))


def generate(receipt_path, framework_root, out, site, node):
    receipt = json.loads(receipt_path.read_text())
    if out.exists() or site.exists():
        raise ValueError('Choose fresh output and site directories; preserve prior runs.')
    root = framework_root.resolve()
    for name, expected in receipt['framework']['files'].items():
        if sha(root / name) != expected:
            raise ValueError(f'Framework source does not match pinned receipt: {name}')
    pairs = receipt['pairs']
    if not pairs or any(not re.fullmatch(r'[a-z0-9-]+__[a-z0-9-]+', pair) for pair in pairs):
        raise ValueError('Explicit provider pairs are required.')
    out.mkdir(parents=True)
    manifest = {'version': 1, 'name': receipt['name'], 'cases': []}
    raw = []
    seen = set()
    for case in receipt['cases']:
        cid = case['id']
        if cid in seen or not re.fullmatch(r'[a-zA-Z0-9._-]+', cid):
            raise ValueError('Case IDs must be unique safe filenames.')
        seen.add(cid)
        manifest['cases'].append({k: v for k, v in case.items() if k != 'captures'})
        sizes = []
        for provider, capture in case['captures'].items():
            if not re.fullmatch(r'[a-z0-9-]+', provider):
                raise ValueError('Unsafe provider name.')
            source = Path(capture['image'])
            size = png_size(source)
            sizes.append(size)
            view=capture.get('viewport',{})
            clip=capture.get('crop',{}).get('origin')
            density=view.get('density',view.get('dpr'))
            if clip and density:
                expected=[round(clip['width']*density),round(clip['height']*density)]
                if size!=expected:raise ValueError(f'PNG dimensions disagree with the declared crop for {cid}: {size} != {expected}')
            dest = out / 'visual-testing-results' / provider / f'{cid}.png'
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, dest)
            assert sha(dest) == sha(source)
            # Explicit allowlist: no auth state, request headers, URLs or arbitrary capture payloads.
            meta = {k: v for k, v in capture.items() if k in {
                'source', 'sourceCommit', 'sourceInputHash', 'compiledSha256', 'viewport', 'crop',
                'browserVersion', 'fixtureSha256', 'theme', 'locale', 'state', 'capturedAt', 'admission',
            }}
            meta.update(provider=provider, providerType='playwright-real-product', rawSha256=sha(dest),
                        rawSize=size, captureType=case['captureType'])
            if 'capturedAt' not in meta:
                meta['capturedAt'] = dt.datetime.fromtimestamp(source.stat().st_mtime, dt.timezone.utc).isoformat()
            dest.with_suffix('.metadata.json').write_text(json.dumps(meta, ensure_ascii=False, indent=2)+'\n')
            raw.append({'case': cid, 'provider': provider, 'sha256': sha(dest), 'size': size})
        if not sizes and not case.get('captureErrors'):
            raise ValueError(f'Empty capture {cid} requires explicit captureErrors; never drop failed cases.')
        if sizes and any(size != sizes[0] for size in sizes):
            raise ValueError(f'Unequal original dimensions for {cid}; no resize/padding allowed by this adapter.')
    manifest_path = out / 'cases.json'
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
    env = dict(os.environ, SLOCK_VISUAL_REPO_ROOT=str(out.resolve()))
    env['PATH'] = str(node.resolve().parent) + os.pathsep + env.get('PATH', '')
    cli = [str(node), str(root / 'src/cli.mjs')]
    common = ['--manifest', str(manifest_path.resolve()), '--pairs', ','.join(pairs)]
    subprocess.run(cli + ['diff'] + common, env=env, check=True)
    subprocess.run(cli + ['site'] + common + ['--skip-analysis', '--site-dir', str(site.resolve()),
                    '--run-id', receipt['runId'], '--commit-subject', receipt['name']], env=env, check=True)
    provenance = {'framework': receipt['framework'], 'project': receipt['project'], 'images': raw,
                  'imageNormalization': 'none; original PNG copied byte-for-byte',
                  'analysis': 'disabled; no model requests', 'pairs': pairs}
    (site / 'provenance.json').write_text(json.dumps(provenance, ensure_ascii=False, indent=2)+'\n')
    return provenance


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--receipt', type=Path, required=True)
    p.add_argument('--framework-root', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--site-dir', type=Path, required=True)
    p.add_argument('--node', type=Path, required=True)
    args = p.parse_args()
    pinned = json.loads(Path(__file__).with_name('raft_framework.json').read_text())
    actual = json.loads(args.receipt.read_text())['framework']
    if actual != pinned:
        p.error('Receipt framework must match the repository raft_framework.json pin.')
    generate(args.receipt, args.framework_root, args.out, args.site_dir, args.node)


if __name__ == '__main__':
    main()
