#!/usr/bin/env python3
"""Mirror the exact pinned Flutter fallback fonts; no Google runtime dependency.
First run records SHA-256s. Later builds require those locked bytes. Noto and
Roboto are distributed under OFL; app/assets/fonts/OFL.txt is shipped with them.
"""
import argparse,concurrent.futures,hashlib,json,re,time,urllib.request
from pathlib import Path

parser=argparse.ArgumentParser();parser.add_argument('--sdk',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--lock',type=Path,required=True);args=parser.parse_args()
table=args.sdk/'lib/_engine/engine/font_fallback_data.dart';text=table.read_text();table_sha=hashlib.sha256(table.read_bytes()).hexdigest()
fonts=re.findall(r"NotoFont\(\s*'([^']+)',\s*'([^']+)'",text)
fonts.append(('Roboto','roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2'))
paths=sorted(set(path for _,path in fonts));assert len(paths)>700
old=json.loads(args.lock.read_text()) if args.lock.exists() else None
if old and old['engine_table_sha256']!=table_sha:raise SystemExit('Pinned Flutter font table changed; review and refresh the lock')
expected={x['path']:x for x in old['files']} if old else {}
args.output.mkdir(parents=True,exist_ok=True)
def fetch(path):
 assert re.fullmatch(r'[A-Za-z0-9_./-]+',path) and '..' not in path
 file=args.output/path
 if file.exists():data=file.read_bytes()
 else:
  for attempt in range(3):
   try:
    with urllib.request.urlopen('https://fonts.gstatic.com/s/'+path,timeout=30) as response:data=response.read((16<<20)+1)
    break
   except Exception:
    if attempt==2:raise
    time.sleep(.5*(attempt+1))
 assert data[:4]==b'wOF2' and len(data)<=16<<20,(path,'invalid font')
 row={'path':path,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
 if old and row!=expected.get(path):raise ValueError('Font differs from lock: '+path)
 if not file.exists():file.parent.mkdir(parents=True,exist_ok=True);file.write_bytes(data)
 return row
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:rows=list(pool.map(fetch,paths))
assert sum(x['bytes'] for x in rows)<256<<20
result={'schema':1,'engine_table_sha256':table_sha,'origin':'https://fonts.gstatic.com/s/','license':'OFL-1.1','files':rows}
if not old:args.lock.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'fonts':len(rows),'bytes':sum(x['bytes'] for x in rows),'lock_sha256':hashlib.sha256(args.lock.read_bytes()).hexdigest()}))
