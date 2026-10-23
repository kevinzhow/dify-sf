#!/usr/bin/env python3
"""Qualify the shared browser/provider builds, including actual Wasm loading and React platform fonts.

This is batch-level evidence. It does not invent per-case network or font observations.
"""
import argparse,hashlib,json
from pathlib import Path
from urllib.parse import urlencode
from playwright.sync_api import sync_playwright
from capture_components import serve

def fonts(page,selector):
    cdp=page.context.new_cdp_session(page);cdp.send('DOM.enable');cdp.send('CSS.enable')
    root=cdp.send('DOM.getDocument',{'depth':-1,'pierce':True})['root']['nodeId'];node=cdp.send('DOM.querySelector',{'nodeId':root,'selector':selector})['nodeId']
    if not node:return {'selector':selector,'missing':True}
    return {'selector':selector,'platformFonts':cdp.send('CSS.getPlatformFontsForNode',{'nodeId':node})['fonts'],'computedStyle':page.locator(selector).first.evaluate('(e)=>{let s=getComputedStyle(e);return {fontFamily:s.fontFamily,fontSize:s.fontSize,lineHeight:s.lineHeight,letterSpacing:s.letterSpacing}}')}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for k in ['reference-build','flutter-build','out']:p.add_argument('--'+k,type=Path,required=True)
    p.add_argument('--dify-base',default='http://localhost');a=p.parse_args();a.out.mkdir(parents=True,exist_ok=False)
    rs,react=serve(a.reference_build);fs,flutter=serve(a.flutter_build);rows=[]
    with sync_playwright() as pw:
        browser=pw.chromium.launch(headless=True,args=['--no-sandbox'])
        try:
            for theme in ['light','dark']:
                for locale in ['en-US','zh-Hans']:
                    row={'theme':theme,'locale':locale,'browserVersion':browser.version,'providerBuildQualification':True}
                    for provider,base in [('react',react),('flutter-web',flutter)]:
                        ctx=browser.new_context(viewport={'width':640,'height':480},device_scale_factor=2,locale='en-US',color_scheme=theme);page=ctx.new_page()
                        ctx.route('**/*',lambda r:r.abort('blockedbyclient') if r.request.method not in ['GET','HEAD'] else r.continue_())
                        page.goto(base+'/?'+urlencode({'case':'button-primary','theme':theme,'lang':locale}),wait_until='networkidle')
                        if provider=='flutter-web':
                            page.wait_for_function("document.documentElement.hasAttribute('data-ui-parity')")
                            if page.locator('flt-semantics-placeholder').count():page.locator('flt-semantics-placeholder').evaluate('(e)=>e.click()')
                        page.wait_for_timeout(1500);page.mouse.click(600,450);page.mouse.move(620,460);page.wait_for_timeout(300)
                        resources=page.evaluate("performance.getEntriesByType('resource').map(e=>e.name.split('/').pop().split('?')[0]).filter(n=>n.endsWith('.wasm'))")
                        if provider=='flutter-web':assert 'main.dart.wasm' in resources and any(n.startswith('skwasm') for n in resources),resources
                        row[provider]={'htmlLang':page.locator('html').get_attribute('lang'),'htmlColorScheme':page.evaluate('getComputedStyle(document.documentElement).colorScheme'),'loadedWasm':resources,'fonts':fonts(page,'#parity-component button') if provider=='react' else 'Canvas fonts bound by the checked source font assets, not semantics DOM fonts'}
                        page.screenshot(path=str(a.out/f'{provider}-{theme}-{locale}.png'));ctx.close()
                    # Anonymous live original; no account, cookie, login or write.
                    ctx=browser.new_context(viewport={'width':1440,'height':900},device_scale_factor=2,locale='en-US',color_scheme=theme);ctx.add_cookies([{'name':'locale','value':locale,'url':a.dify_base}]);ctx.add_init_script('if(window.top===window && /^https?:$/.test(location.protocol))localStorage.setItem("theme",'+json.dumps(theme)+')');page=ctx.new_page()
                    page.route('**/console/api/refresh-token',lambda r:r.fulfill(status=401,json={'code':'unauthorized','message':'Anonymous qualification'}))
                    page.goto(a.dify_base+'/signin',wait_until='networkidle');page.wait_for_timeout(1000);row['liveOriginalColorScheme']=page.evaluate('getComputedStyle(document.documentElement).colorScheme');row['liveOriginalHtmlLang']=page.locator('html').get_attribute('lang');row['liveOriginalFonts']=fonts(page,'h1');ctx.close();rows.append(row)
                    (a.out/'qualification.json').write_text(json.dumps({'scope':'Four representative contexts qualify the same immutable builds/browser configuration; not per-case resource observations','mainWasmSha256':hashlib.sha256((a.flutter_build/'main.dart.wasm').read_bytes()).hexdigest(),'contexts':rows},ensure_ascii=False,indent=2)+'\n');print(theme,locale,'Wasm and fonts recorded',flush=True)
        finally:browser.close();rs.shutdown();fs.shutdown()
if __name__=='__main__':main()
