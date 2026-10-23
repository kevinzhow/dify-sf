#!/usr/bin/env python3
"""Assemble declared cases and ordered capture attempts for the unchanged Raft reporter.

Latest attempt wins, including failures. No best-score selection, image edits or omitted catalog entries.
"""
import argparse,hashlib,json,re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
FOLDER=Path(__file__).parent

def read_rows(folder):
    data=json.loads((folder/'results.json').read_text())
    return data['results'] if isinstance(data,dict) else data

def scenario(row):
    if row['id'].startswith(('controls.','pages.')):return row['id']
    logical=row.get('case') or row['id'].split('.',1)[-1].rsplit('.',2)[0]
    return f"editors.{logical}.{row['theme']}.{row.get('locale','en-US')}"

def expected_cases():
    inventory=json.loads((FOLDER/'ui_coverage.json').read_text());out={}
    for name in inventory['catalogs']:
        rows=json.loads((FOLDER/name).read_text())
        for row in rows:
            variants=[row] if row['id'].startswith(('controls.','pages.')) else [{**row,'id':f"editors.{row['id']}.{theme}.en-US",'theme':theme,'locale':'en-US','logicalCase':row['id']} for theme in ['light','dark']]
            for item in variants:
                cid=item['id'];fixture=item.get('fixture')
                if cid in out:raise ValueError('Duplicate scenario in the declared catalogs: '+cid)
                out[cid]={'id':cid,'title':cid,'captureType':item.get('captureType','component-fixture'),'theme':item['theme'],'locale':item['locale'],'state':item.get('state','selected' if item.get('select') else 'after declared interaction sequence' if item.get('steps') else 'default'),'logicalCase':item.get('logicalCase',cid),'sourceCatalog':name,'fixture':fixture or 'tool/visual/'+name,'region':item.get('region'),'viewport':{'width':640 if cid.startswith('controls.') else 1440,'height':480 if cid.startswith('controls.') else 900,'density':2},'category':'Shared controls' if cid.startswith('controls.') else 'Product pages' if cid.startswith('pages.') else 'Node panels' if '.panel-' in cid else 'Editor and canvas','surface':item.get('kind',item.get('logicalCase',cid.split('.')[1])),'fixtureSha256':hashlib.sha256((ROOT/fixture).read_bytes()).hexdigest() if fixture else None,'tags':[cid.split('.')[0],item['theme'],item['locale']]}
    return out,inventory

def normalized_crop(capture,case):
    anchor=capture['box'];region=case.get('region')
    origin={'x':anchor['x']+region[0],'y':anchor['y']+region[1],'width':region[2],'height':region[3]} if region else anchor
    env=capture.get('environment') or capture.get('viewport') or case['viewport']
    return {'canvasAnchor':anchor,'declaredRegion':region,'origin':origin,'relativeRect':{k:origin[k]/env['width' if k in ['x','width'] else 'height'] for k in ['x','y','width','height']},'units':'CSS px; recorded canvas anchor + declared screenshot region, no resampling'}

def superseded_cases():
    return json.loads((FOLDER/'superseded_cases.json').read_text())['cases']

def assemble(runs,allow_incomplete=False,product_commit=None,run_id="ui-parity"):
    cases,inventory=expected_cases();history={};chosen={};retired=superseded_cases();superseded={}
    for cid,reason in retired.items():
        if cid in cases:raise ValueError(f'Superseded case is still declared: {cid}')
        if not reason.get('reason') or not reason.get('referenceEvidence') or not reason.get('replacement') or not set(reason['replacement'])<=cases.keys():raise ValueError(f'Invalid supersession: {cid}')
    for folder in runs:
        for row in read_rows(folder):
            cid=scenario(row)
            if cid not in cases:
                if cid not in retired:raise ValueError(f'Capture is outside the declared matrix: {cid}')
                if set(row.get('captures',{}))-{'react','flutter-web'}:raise ValueError(f'Unexpected provider for {cid}')
                superseded.setdefault(cid,{'decision':retired[cid],'attempts':[]})['attempts'].append({'run':folder.name,'sourceCaseId':row['id'],'captures':{p:{'image':c['image']} for p,c in row.get('captures',{}).items()},'errors':row.get('captureErrors',row.get('errors',[]))})
                continue
            errors=row.get('captureErrors',row.get('errors',[]))
            history.setdefault(cid,[]).append({'run':folder.name,'sourceCaseId':row['id'],'providers':sorted(row['captures']),'errors':errors,'status':row.get('status','captured' if len(row['captures'])==2 else 'capture-failed')})
            chosen[cid]=(folder,row)
    missing=sorted(set(cases)-chosen.keys())
    if missing and not allow_incomplete:raise ValueError(f'{len(missing)} cases have no attempt receipt: '+', '.join(missing[:12]))
    normalized=[]
    for cid,case in sorted(cases.items()):
        row=chosen.get(cid,(None,{}))[1];caps={}
        if set(row.get('captures',{}))-{'react','flutter-web'}:raise ValueError(f'Unexpected provider for {cid}')
        for provider,capture in row.get('captures',{}).items():
            caps[provider]={k:v for k,v in capture.items() if k in {'image','source','sourceCommit','sourceInputHash','compiledSha256','viewport','crop','browserVersion','theme','locale','state','capturedAt','admission','fixtureSha256'}}
            if 'environment' in capture:caps[provider]['viewport']=capture['environment']
            if 'box' in capture:caps[provider]['crop']=normalized_crop(capture,case)
            caps[provider].update(theme=case['theme'],locale=case['locale'],state=case['state']);caps[provider].setdefault('fixtureSha256',case['fixtureSha256'])
        errors=row.get('captureErrors',row.get('errors',[]))
        if len(caps)<2 and not errors:errors=[{'error':'No admitted capture for all providers' if row else 'No attempt receipt'}]
        normalized.append({**case,'captures':caps,'captureErrors':errors})
    receipt={'name':'Dify shared controls, pages and node panels — actual Raft UI audit','runId':run_id,'framework':json.loads((FOLDER/'raft_framework.json').read_text()),'project':{'repository':'dify-sf','productCommit':product_commit,'reference':json.loads((FOLDER/'ui_reference.json').read_text()),'matrix':'component English/Chinese × light/dark; real pages/editor declared locales × light/dark','sourceInventory':'ui_coverage.json','scoring':'unchanged upstream exact RGBA Pixel and average RGB; no masks, text exclusion, resizing or model analysis'},'pairs':['react__flutter-web'],'cases':normalized}
    coverage={'declaredCases':len(cases),'attemptedCases':len(chosen),'pairedCases':sum(len(c['captures'])==2 for c in normalized),'missingProviderCases':sum(len(c['captures'])<2 for c in normalized),'unattempted':missing,'sourceCounts':{k:len(inventory[k]) for k in ['exports','pages','nodeBodies']},'acceptance':'Capture completion is not visual acceptance. Read the original framework metrics and images.','attempts':history,'supersededAttempts':superseded}
    return receipt,coverage

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--run',type=Path,action='append',required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--allow-incomplete',action='store_true');p.add_argument('--product-commit');p.add_argument('--run-id',default='ui-parity');a=p.parse_args()
    if a.out.exists():raise ValueError('Fresh receipt directory required')
    receipt,coverage=assemble(a.run,a.allow_incomplete,a.product_commit,a.run_id);a.out.mkdir(parents=True)
    (a.out/'receipt.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n');(a.out/'coverage.json').write_text(json.dumps(coverage,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:v for k,v in coverage.items() if k not in {'attempts','supersededAttempts','unattempted'}},ensure_ascii=False))
if __name__=='__main__':main()
