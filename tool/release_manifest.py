#!/usr/bin/env python3
"""Freeze a release's public identity and resource hashes after a successful build.

No environment values, credentials, hosts or local absolute paths enter the
manifest. Verification is read-only; upgrade/rollback changes only executables,
never restores a database/upload snapshot over newer user writes.
"""
import argparse,hashlib,json,re,subprocess
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def identity(value):
 if not re.fullmatch(r'[0-9a-f]{40}',value):raise ValueError('A full immutable commit is required')
 return value

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--web',type=Path,required=True);parser.add_argument('--revision');parser.add_argument('--check',action='store_true');parser.add_argument('--engine-proof',type=Path);args=parser.parse_args()
 root=args.web.resolve();manifest=root/'version.json'
 if args.check:
  recorded=json.loads(manifest.read_text());identity(recorded['revision']);bad=[]
  for name,row in recorded['files'].items():
   path=(root/name).resolve()
   if not path.is_relative_to(root) or not path.is_file() or path.stat().st_size!=row['bytes'] or digest(path)!=row['sha256']:bad.append(name)
  actual={str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and p!=manifest}
  if actual!=set(recorded['files']):raise SystemExit('Release file inventory changed')
  if bad:raise SystemExit('Release hash mismatch: '+', '.join(bad[:10]))
  print(json.dumps({'revision':recorded['revision'],'files':len(actual),'verified':True}));return
 if not args.revision or not args.engine_proof:parser.error('--revision and --engine-proof are required when freezing')
 rev=identity(args.revision)
 current=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip()
 if rev!=current:raise SystemExit('Revision must name the source currently checked out')
 dirty=subprocess.check_output(['git','-C',str(ROOT),'status','--porcelain','--untracked-files=normal'],text=True)
 if dirty.strip():raise SystemExit('A release requires a clean source tree')
 engine=json.loads(args.engine_proof.read_text())
 rows={str(p.relative_to(root)):{'bytes':p.stat().st_size,'sha256':digest(p)} for p in sorted(root.rglob('*')) if p.is_file() and p!=manifest}
 required=['main.dart.wasm','main.dart.js','flutter_bootstrap.js']
 if not all(name in rows for name in required):raise SystemExit('Both supported browser builds must exist')
 result={'schema':1,'product':'dify-sf','revision':rev,'protocol':{'workflow':'1.21','agent':'dify-sf-agent/1'},'font_provider_schema':1,
  'engine':engine,'files':rows}
 manifest.write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps({'revision':rev,'files':len(rows),'manifest_sha256':digest(manifest)}))
if __name__=='__main__':main()
