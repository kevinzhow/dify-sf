"""Run a large independent oracle corpus in bounded, disposable Node processes."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

p = argparse.ArgumentParser()
p.add_argument('input', type=Path)
p.add_argument('output', type=Path)
p.add_argument('--elkjs', type=Path, required=True, help='Extracted elkjs 0.11.1 package directory')
p.add_argument('--image', default='node:22-alpine')
p.add_argument('--batch-size', type=int, default=40)
args = p.parse_args()
if args.batch_size < 1:
    p.error('--batch-size must be positive')
root = Path.cwd().resolve()
records = json.loads(args.input.read_text())
results = []
(root/'.dart_tool').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='elk-oracle-', dir=root/'.dart_tool') as temporary:
    folder = Path(temporary)
    work_path = Path('/work')/folder.relative_to(root)
    for i in range(0, len(records), args.batch_size):
        (folder/'input.json').write_text(json.dumps(records[i:i+args.batch_size]))
        subprocess.run([
            'docker', 'run', '--rm', '--user', f'{os.getuid()}:{os.getgid()}',
            '--memory=512m', '--memory-swap=512m', '--cpus=1', '--ulimit', 'core=0',
            '-v', f'{root}:/work', '-v', f'{args.elkjs.resolve()}:/elk:ro',
            '-e', 'ELK_MODULE=/elk/lib/elk.bundled.js', '--entrypoint', 'node', args.image,
            '/work/research/reference.cjs', str(work_path/'input.json'), str(work_path/'output.json'),
        ], check=True)
        results.extend(json.loads((folder/'output.json').read_text()))
        print(f'Oracle completed {len(results)}/{len(records)} graphs', flush=True)
args.output.write_text(json.dumps(results, separators=(',', ':'))+'\n')
