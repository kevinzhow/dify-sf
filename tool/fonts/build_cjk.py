"""Losslessly compress pinned upstream regional Noto Sans 2.004 faces.
Build only: fonttools[woff]==4.59.0, brotli==1.1.0. No runtime dependency.
Usage: python tool/fonts/build_cjk.py --cache /path/to/font-cache
"""
from pathlib import Path
import argparse,hashlib,json,gc,urllib.request
from fontTools.ttLib import TTFont,woff2
p=argparse.ArgumentParser();p.add_argument('--cache',type=Path,required=True);p.add_argument('--out',type=Path,default=Path(__file__).resolve().parents[2]/'app/assets/fonts/cjk');a=p.parse_args();a.cache.mkdir(parents=True,exist_ok=True);a.out.mkdir(parents=True,exist_ok=True)
sources=json.loads(Path(__file__).with_name('sources.json').read_text())
# WOFF2/Brotli is lossless at every quality. 6 avoids minutes of build CPU per
# face for the marginal size reduction of quality 11; never edits the glyphs.
compress=woff2.brotli.compress
woff2.brotli.compress=lambda data,**kw:compress(data,quality=6,**kw)
result={'upstreamCommit':sources['commit'],'version':'2.004','deployment':'upstream regional subsets; no further glyph subsetting','compression':'lossless WOFF2, Brotli quality 6','sources':sources['files'],'files':{}}
for name,row in sources['files'].items():
 source=a.cache/name
 if not source.exists():
  with urllib.request.urlopen(row['url'],timeout=120) as response,source.open('wb') as output:
   while block:=response.read(262144):output.write(block)
 assert source.stat().st_size==row['bytes'] and hashlib.sha256(source.read_bytes()).hexdigest()==row['sha256'],'pinned font changed'
 region,weight=name.removeprefix('NotoSans').removesuffix('.otf').split('-');f=TTFont(source);assert '2.004' in f['name'].getDebugName(5)
 target=a.out/f'NotoSansCJK{region}-{weight}.woff2';f.flavor='woff2';f.save(target)
 loaded=TTFont(target);assert loaded.getBestCmap()==f.getBestCmap();assert loaded['hhea'].ascent==f['hhea'].ascent and loaded['hhea'].descent==f['hhea'].descent
 result['files'][target.name]={'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'bytes':target.stat().st_size,'family':loaded['name'].getDebugName(1),'weight':loaded['OS/2'].usWeightClass,'glyphs':loaded['maxp'].numGlyphs};print('PASS',target.name,target.stat().st_size,flush=True);loaded.close();f.close();del loaded,f;gc.collect()
(a.out/'provenance.json').write_text(json.dumps(result,indent=2)+'\n')
