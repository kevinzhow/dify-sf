#!/usr/bin/env python3
"""Validate generated assets against their reviewed lock; --certify checks all
outlines/advances/metrics against the original faces before writing a new lock.
"""
import argparse,hashlib,importlib.util,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'app/assets/fonts/subsets'
LOCK=ROOT/'tool/fonts/subsets.lock.json'
REGIONS={'SC':'zh-Hans','TC':'zh-Hant','HK':'zh-Hant','JP':'ja-JP','KR':'ko-KR'}
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--certify',action='store_true');parser.add_argument('--output',type=Path,default=OUT);args=parser.parse_args();out=args.output
 if args.certify:
  spec=importlib.util.spec_from_file_location('subset_tool',ROOT/'tool/fonts/subset.py');tool=importlib.util.module_from_spec(spec);spec.loader.exec_module(tool)
  sources={};files={}
  for region,lang in REGIONS.items():
   manifest=json.loads((out/f'{region}.json').read_text());declared=manifest['codepoints'];shared=manifest.get('shared_codepoints',[]);union=set().union(*map(set,declared))
   assert sum(map(len,declared))==len(union),'Duplicate shard code points'
   for weight in ['Regular','Bold']:
    original_path=ROOT/f'app/assets/fonts/cjk/NotoSansCJK{region}-{weight}.woff2';original=tool.TTFont(original_path,recalcTimestamp=False);cmap=original.getBestCmap()
    assert set(cmap)==union and sha(original_path)==manifest['source_sha256'][weight]
    sources[str(original_path.relative_to(ROOT))]=sha(original_path)
    for index,cps in enumerate(declared):
     requested=sorted(set(cps)|set(shared))
     row=manifest['chunks'][index][weight];path=out/row['path'];font=tool.TTFont(path,recalcTimestamp=False);actual=font.getBestCmap()
     assert sha(path)==row['sha256'] and path.stat().st_size==row['bytes']
     assert tool.metrics(font)==tool.metrics(original)
     assert set(actual)==set(requested) and all(actual[cp]==cmap[cp] for cp in requested)
     assert tool.variation_mapping(font,requested)==tool.variation_mapping(original,requested),'Unicode variation mapping changed'
     names=tool.certified_names(original,requested)
     assert tool.glyph_digest(font,names)==tool.glyph_digest(original,names)
   print(region,'all glyphs/weights/global metrics certified',flush=True)
  for path in sorted(out.iterdir()):
   if path.is_file():files[path.name]={'bytes':path.stat().st_size,'sha256':sha(path)}
  LOCK.write_text(json.dumps({'schema':1,'generator_sha256':sha(ROOT/'tool/fonts/subset.py'),'sources':sources,'unicode_sha256':sha(tool.GRAPHEME_DATA),'files':files},indent=2)+'\n')
 lock=json.loads(LOCK.read_text());assert lock['generator_sha256']==sha(ROOT/'tool/fonts/subset.py'),'Font generator changed; regenerate/certify explicitly'
 assert lock['unicode_sha256']==sha(ROOT/'tool/fonts/unicode/GraphemeBreakProperty-16.0.0.txt'),'Pinned Unicode shaping data changed'
 assert {p.name for p in out.iterdir() if p.is_file()}==set(lock['files']),'Unexpected or missing generated font assets'
 for path,digest in lock['sources'].items():assert sha(ROOT/path)==digest,'Original font source changed'
 for name,row in lock['files'].items():
  path=out/name;assert path.stat().st_size==row['bytes'] and sha(path)==row['sha256'],f'Generated font changed: {name}'
 for region,lang in REGIONS.items():
  manifest=json.loads((out/f'{region}.json').read_text());coverage=set().union(*map(set,manifest['codepoints']))
  texts=''.join(p.read_text() for p in (ROOT/f'app/assets/i18n/{lang}').glob('*.json'))
  extra=ROOT/f'app/assets/extension_i18n/{lang}.json'
  if extra.exists():texts+=extra.read_text()
  assert set(manifest['codepoints'][0])==coverage.intersection(map(ord,texts))|set(manifest.get('shared_codepoints',[])),f'{region} core text coverage changed; regenerate/certify'
 print(json.dumps({'verified_font_assets':len(lock['files']),'lock_sha256':sha(LOCK)}))
if __name__=='__main__':main()
