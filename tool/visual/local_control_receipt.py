#!/usr/bin/env python3
"""Create common control crops for a SECOND, unchanged Raft report.

The complete stage report remains authoritative for placement/outside pixels. This
view prevents its large background from diluting a small control's differences.
No score, masks, text exclusion, image resizing or pixel rewriting is performed.
"""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
from PIL import Image


def common_crop(case):
    rects=[]
    for capture in case['captures'].values():
        facts=capture['admission'];rects.append(facts['componentBounds'])
        rects.extend(r['rect'] for r in facts.get('overlayRoleBounds',[]))
    rects=[r for r in rects if r and r['width']>0 and r['height']>0]
    if not rects:raise ValueError('No observed control rectangles: '+case['id'])
    view=case['viewport'];margin=2 # Same surrounding stroke margin as the existing control-crop contract.
    x=max(0,math.floor(min(r['x'] for r in rects)-margin));y=max(0,math.floor(min(r['y'] for r in rects)-margin))
    right=min(view['width'],math.ceil(max(r['x']+r['width'] for r in rects)+margin));bottom=min(view['height'],math.ceil(max(r['y']+r['height'] for r in rects)+margin))
    if right<=x or bottom<=y:raise ValueError('Control rectangles are outside the stage: '+case['id'])
    density=view['density'];return (x,y,right,bottom),tuple(round(v*density) for v in (x,y,right,bottom))


def build(receipt,out):
    if out.exists():raise ValueError('Fresh crop directory required; preserve earlier attempts')
    out.mkdir(parents=True);result=copy.deepcopy(receipt);result['name']='Dify controls — common local crops, with full stage retained separately';result['runId']+='-controls-local';result['cases']=[];proof=[]
    result['project']['localCropContract']='SECOND view only: union of both observed control/overlay rectangles + 2 CSS px stroke margin, clipped to stage. Both PNGs get the identical integer pixel crop. No resize or masks. Full stage report must also be reviewed.'
    for raw in receipt['cases']:
        if not raw['id'].startswith('controls.'):continue
        case=copy.deepcopy(raw);case['category']='Shared controls — local view';case['tags']=[*case.get('tags',[]),'local-view']
        if len(case['captures'])==2:
            css,pixels=common_crop(case)
            for provider,capture in case['captures'].items():
                src=Path(capture['image']);dest=out/provider/src.name;dest.parent.mkdir(exist_ok=True)
                with Image.open(src) as image:
                    if image.size!=(case['viewport']['width']*case['viewport']['density'],case['viewport']['height']*case['viewport']['density']):raise ValueError('Unexpected original stage dimensions')
                    image.crop(pixels).save(dest)
                capture['image']=str(dest.resolve());capture['crop']={'cssLTRB':css,'pixelLTRB':pixels,'fullContextSha256':hashlib.sha256(src.read_bytes()).hexdigest(),'fullContextCase':case['id'],'method':'common observed union crop; no resize or pixel edits'}
                proof.append({'case':case['id'],'provider':provider,'original':str(src),'originalSha256':capture['crop']['fullContextSha256'],'pixelLTRB':pixels,'cropSha256':hashlib.sha256(dest.read_bytes()).hexdigest()})
        else:
            # A local view cannot hide a missing provider or manufacture a comparison.
            case['captures']={};case['captureErrors']=[*case.get('captureErrors',[]),{'error':'Local pair unavailable because the stage pair is incomplete'}]
        result['cases'].append(case)
    (out/'receipt.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');(out/'crop-provenance.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n');return result


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--receipt',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();result=build(json.loads(a.receipt.read_text()),a.out);print('Supplemental local control views:',len(result['cases']))
if __name__=='__main__':main()
