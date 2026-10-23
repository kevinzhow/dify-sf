#!/usr/bin/env python3
"""Exercise the unchanged generated report in desktop/mobile Chromium; no UI scoring."""
import argparse
import json
from pathlib import Path
from playwright.sync_api import sync_playwright


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--url',required=True);p.add_argument('--expected-cases',type=int,required=True)
    p.add_argument('--case-id',default='controls.button-primary.light.en-US');p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();a.out.mkdir(parents=True,exist_ok=False);proof=[]
    with sync_playwright() as pw:
        browser=pw.chromium.launch(headless=True,args=['--no-sandbox'])
        try:
            for width in [1440,390]:
                ctx=browser.new_context(viewport={'width':width,'height':1000});page=ctx.new_page();errors=[];bad=[]
                page.on('pageerror',lambda e:errors.append(str(e)))
                page.on('response',lambda r:bad.append({'status':r.status,'path':r.url.split('/')[-1]}) if r.status>=400 else None)
                page.goto(a.url,wait_until='networkidle',timeout=90000);page.wait_for_timeout(500)
                data=page.locator('#vt-data').evaluate('(e)=>JSON.parse(e.textContent)')
                assert len(data['cases'])==a.expected_cases,(len(data['cases']),a.expected_cases)
                assert {p['id'] if isinstance(p,dict) else p for p in data['providers']}=={'react','flutter-web'},data['providers']
                page.screenshot(path=str(a.out/f'{width}-overview.png'))
                page.get_by_role('button',name='Matrix',exact=True).click();page.locator('.sb-matrix').wait_for(state='visible')
                page.screenshot(path=str(a.out/f'{width}-matrix.png'))
                if width==390:page.locator('#vt-menu').click()
                page.locator('#vt-search').fill(a.case_id)
                target=page.locator('[data-case-id="'+a.case_id+'"]').first;target.wait_for(state='visible');target.click();page.wait_for_timeout(700)
                assert page.locator('#vt-stage').is_visible();assert '%' in page.locator('#vt-addon-body').inner_text()
                for label in ['React','flutter-web','Side-by-side']:
                    page.locator('#vt-comptabs').get_by_role('button',name=label,exact=True).click();page.wait_for_timeout(300)
                    assert page.locator('#vt-stage img').count()>0
                    assert page.locator('#vt-stage img').evaluate_all('(xs)=>xs.every(x=>x.complete&&x.naturalWidth>0)'),label
                page.screenshot(path=str(a.out/f'{width}-case.png'));assert not errors and not bad,(errors,bad)
                proof.append({'viewport':{'width':width,'height':1000},'caseCount':len(data['cases']),'summary':data['summary'],'selectedCase':a.case_id,'matrixVisible':True,'rawProviderTabsLoaded':True,'browserVersion':browser.version,'pageErrors':errors,'badResponses':bad})
                (a.out/'result.json').write_text(json.dumps(proof,indent=2)+'\n');print(width,'Raft report UI verified',flush=True);ctx.close()
        finally:browser.close()
if __name__=='__main__':main()
