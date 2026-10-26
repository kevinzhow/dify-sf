#!/usr/bin/env python3
"""Deterministic, self-hosted subsets of the existing pinned CJK faces.

Requires fonttools[woff]==4.59.0; no font is fetched or substituted. Outputs
are generated build assets (including both original weights), not a new font.
"""
import argparse, copy, hashlib, json
from pathlib import Path
from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.ttLib.woff2 import WOFF2FlavorData

ROOT = Path(__file__).resolve().parents[2]
REGIONS = {'SC':'zh-Hans', 'TC':'zh-Hant', 'HK':'zh-Hant', 'JP':'ja-JP', 'KR':'ko-KR'}
METRICS = {'head':['unitsPerEm','xMin','yMin','xMax','yMax'], 'hhea':['ascent','descent','lineGap','advanceWidthMax','minLeftSideBearing','minRightSideBearing','xMaxExtent'],
           'OS/2':['xAvgCharWidth','sTypoAscender','sTypoDescender','sTypoLineGap','usWinAscent','usWinDescent','sCapHeight','sxHeight','usWeightClass']}

def metrics(f):
    return {table:{key:getattr(f[table],key) for key in keys if hasattr(f[table],key)} for table,keys in METRICS.items()}

def glyph_digest(f, names):
    # Unhinted geometry and exact advances, independent from subset glyph IDs.
    from fontTools.pens.recordingPen import RecordingPen
    gs=f.getGlyphSet(); result={}
    for name in names:
        pen=RecordingPen(); gs[name].draw(pen)
        result[name]=(f['hmtx'][name],pen.value)
    return hashlib.sha256(repr(sorted(result.items())).encode()).hexdigest()

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,default=ROOT/'app/assets/fonts/subsets');parser.add_argument('--region',choices=REGIONS);args=parser.parse_args()
    out=args.output;out.mkdir(parents=True,exist_ok=True)
    catalog={'schema':1,'chunk_size':512,'regions':{}}
    for region,lang in REGIONS.items():
        if args.region and region!=args.region:continue
        sources={w:ROOT/f'app/assets/fonts/cjk/NotoSansCJK{region}-{w}.woff2' for w in ['Regular','Bold']}
        fonts={w:TTFont(p,recalcTimestamp=False) for w,p in sources.items()}
        maps={w:f.getBestCmap() for w,f in fonts.items()}
        coverage=set(maps['Regular'])
        assert coverage==set(maps['Bold']), 'both weights must have identical coverage'
        texts=''.join(p.read_text() for p in sorted((ROOT/f'app/assets/i18n/{lang}').glob('*.json')))
        extension=ROOT/f'app/assets/extension_i18n/{lang}.json'
        if extension.exists():texts+=extension.read_text()
        core=sorted(coverage.intersection(map(ord,texts)))
        rest=sorted(coverage-set(core))
        chunks=[core]+[rest[i:i+512] for i in range(0,len(rest),512)]
        manifest={'source_sha256':{w:hashlib.sha256(p.read_bytes()).hexdigest() for w,p in sources.items()},'codepoints':chunks,'chunks':[]}
        for index,cps in enumerate(chunks):
            files={}
            for weight,original in fonts.items():
                f=copy.deepcopy(original); expected=metrics(original)
                options=subset.Options();options.recalc_bounds=False;options.recalc_timestamp=False;options.recalc_average_width=False
                options.name_IDs=['*'];options.name_legacy=True;options.name_languages=['*'];options.notdef_glyph=True;options.notdef_outline=True
                options.layout_features=['*'];options.glyph_names=True;options.bidi_closure=False
                worker=subset.Subsetter(options=options);worker.populate(unicodes=cps);worker.subset(f)
                for table,entries in expected.items():
                    for key,value in entries.items():setattr(f[table],key,value)
                # OS/2 and hhea global measurements remain those of the full face.
                f['head'].flags=original['head'].flags
                f.recalcBBoxes=False
                f.flavorData=WOFF2FlavorData(transformedTables=set())
                name=f'{region}-{index:03d}-{weight}.woff2';path=out/name;f.save(path)
                checked=TTFont(path,recalcTimestamp=False)
                assert metrics(checked)==expected,(name,'global metrics changed')
                actual=checked.getBestCmap();assert set(actual)==set(cps),(name,'coverage changed')
                names=[maps[weight][cp] for cp in cps]
                assert all(actual[cp]==maps[weight][cp] for cp in cps),(name,'glyph names changed')
                assert glyph_digest(checked,names)==glyph_digest(original,names),(name,'glyph outlines/advance changed')
                files[weight]={'path':name,'bytes':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
            manifest['chunks'].append(files)
        assert set().union(*map(set,chunks))==coverage
        manifest['metrics']={w:metrics(f) for w,f in fonts.items()}
        catalog['regions'][region]=manifest
        (out/f'{region}.json').write_text(json.dumps(manifest,separators=(',',':'),ensure_ascii=False)+'\n')
        print(region,len(coverage),len(chunks),sum(v['bytes'] for chunk in manifest['chunks'] for v in chunk.values()),flush=True)
    if not args.region:(out/'catalog.json').write_text(json.dumps(catalog,separators=(',',':'),ensure_ascii=False)+'\n')

if __name__=='__main__':main()
