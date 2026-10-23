#!/usr/bin/env python3
"""Capture actual React and Flutter fixtures; no scoring, resizing or network model calls."""
import argparse,datetime,hashlib,json,threading,time
from PIL import Image
from functools import partial
from http.server import SimpleHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlencode
from playwright.sync_api import sync_playwright

class Quiet(SimpleHTTPRequestHandler):
    def log_message(self,*args): pass

def serve(root):
    server=ThreadingHTTPServer(('127.0.0.1',0),partial(Quiet,directory=str(root)))
    threading.Thread(target=server.serve_forever,daemon=True).start()
    return server,f'http://127.0.0.1:{server.server_port}'

def apply_state(page,case):
    page.mouse.click(600,450);page.mouse.move(620,460);page.wait_for_timeout(300)
    if case['kind']=='context-menu':page.mouse.click(35,30,button='right');page.wait_for_timeout(600)
    if case['kind']=='infotip':page.mouse.move(24,24);page.wait_for_timeout(700)
    if case['kind']=='select' and case['state']=='open':page.mouse.click(40,30);page.wait_for_timeout(600)
    if case['state']=='focus':page.mouse.click(40,30);page.wait_for_timeout(400)

def main():
    a=argparse.ArgumentParser(description=__doc__)
    for name in ['reference-build','flutter-build','catalog','out']:a.add_argument('--'+name,type=Path,required=True)
    a.add_argument('--product-commit',help='Verified source base of the supplied compiled Flutter build; omitted when unknown')
    args=a.parse_args();args.out.mkdir(parents=True,exist_ok=False)
    catalog=json.loads(args.catalog.read_text());servers=[];bases={}
    for provider,root in [('react',args.reference_build),('flutter-web',args.flutter_build)]:
        server,base=serve(root);servers.append(server);bases[provider]=base
    compiled=hashlib.sha256((args.flutter_build/'main.dart.wasm').read_bytes()).hexdigest()
    probe_source=args.flutter_build.with_name(args.flutter_build.name+'-source.dart')
    probe_hash=hashlib.sha256(probe_source.read_bytes()).hexdigest() if probe_source.is_file() else None
    results=[]
    with sync_playwright() as p:
        browser=p.chromium.launch(headless=True,args=['--no-sandbox'])
        try:
            for case in catalog:
                row={**case,'captures':{},'captureErrors':[]}
                for provider in bases:
                    ctx=browser.new_context(viewport={'width':640,'height':480},device_scale_factor=2,locale='en-US',color_scheme=case['theme'])
                    page=ctx.new_page();errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
                    try:
                        ctx.route('**/*',lambda r:r.abort('blockedbyclient') if r.request.method not in ['GET','HEAD'] else r.continue_())
                        page.goto(bases[provider]+'/?'+urlencode({'case':case['kind'],'theme':case['theme'],'lang':case['locale']}),wait_until='networkidle',timeout=45000)
                        if provider=='react':
                            page.locator('#parity-component').wait_for();page.evaluate('document.fonts.ready');page.wait_for_timeout(500)
                            bounds=page.locator('#parity-component').evaluate('(e)=>e.firstElementChild?.getBoundingClientRect().toJSON()||null')
                        else:
                            page.wait_for_function("document.documentElement.hasAttribute('data-ui-parity')",timeout=45000)
                            if page.locator('flt-semantics-placeholder').count():page.locator('flt-semantics-placeholder').evaluate('(e)=>e.click()')
                            page.wait_for_timeout(1500)
                            fixture_facts=json.loads(page.locator('html').get_attribute('data-ui-parity'))
                            bounds=fixture_facts['bounds']
                        if provider=='flutter-web' and case.get('fixtureWidth') is not None:
                            assert bounds and abs(bounds['width']-case['fixtureWidth'])<0.1, 'Fixture caller width was not preserved: '+str(bounds)
                        apply_state(page,case)
                        corpus=page.locator('body').inner_text()+'\n'+'\n'.join(page.locator('[aria-label]').evaluate_all('(es)=>es.map(e=>e.getAttribute("aria-label"))'))
                        for text in case.get('expectedText',[]):assert text in corpus, 'Expected fixture content missing: '+text
                        loaded=page.evaluate("performance.getEntriesByType('resource').map(e=>e.name.split('/').pop().split('?')[0]).filter(n=>n.endsWith('.wasm'))")
                        if provider=='flutter-web':assert 'main.dart.wasm' in loaded and any(n.startswith('skwasm') for n in loaded), 'Actual Dart/Skia Wasm was not loaded'
                        if provider=='react':
                            assert page.locator('html').get_attribute('lang')==case['locale'], 'Reference host must retain the production HTML language'
                            assert page.evaluate('getComputedStyle(document.documentElement).colorScheme')==case['theme'], 'Reference host must retain the production native color scheme'
                        if errors:raise RuntimeError('; '.join(errors))
                        env=page.evaluate('({width:innerWidth,height:innerHeight,dpr:devicePixelRatio,scale:visualViewport.scale})')
                        assert env=={'width':640,'height':480,'dpr':2,'scale':1},env
                        dest=args.out/provider/(case['id']+'.png');dest.parent.mkdir(exist_ok=True)
                        page.screenshot(path=str(dest))
                        with Image.open(dest) as raster:
                            colors=raster.convert('RGB').getcolors(raster.width*raster.height)
                            ink=raster.width*raster.height-max(n for n,_ in colors)
                        if ink<12:raise RuntimeError('Expected actual control ink; the frame is blank')
                        overlays=page.locator('[role=dialog],[role=alertdialog],[role=menu],[role=listbox],[role=tooltip]').evaluate_all('(es)=>es.map(e=>({role:e.getAttribute("role"),rect:e.getBoundingClientRect().toJSON()}))')
                        row['captures'][provider]={'image':str(dest.resolve()),'source':case['sources'][provider],'sourceCommit':case['commits']['react'] if provider=='react' else args.product_commit,'sourceInputHash':hashlib.sha256(((args.reference_build if provider=='react' else args.flutter_build)/'source-binding.json').read_bytes()).hexdigest() if ((args.reference_build if provider=='react' else args.flutter_build)/'source-binding.json').exists() else probe_hash if provider=='flutter-web' else None,'compiledSha256':compiled if provider=='flutter-web' else None,'viewport':env,'theme':case['theme'],'locale':case['locale'],'state':case['state'],'browserVersion':browser.version,'admission':{'expectedCase':case['kind'],'htmlLang':page.locator('html').get_attribute('lang'),'htmlColorScheme':page.evaluate('getComputedStyle(document.documentElement).colorScheme'),'loadedWasm':loaded,'componentBounds':bounds,'flutterWidgetTypes':fixture_facts.get('widgetTypes',[]) if provider=='flutter-web' else None,'overlayRoleBounds':overlays,'boundsMethod':'React direct fixture child / Flutter GlobalKey; overlay role rectangles recorded separately','inkPixels':ink,'pageErrors':errors,'waitAfterStateMs':1500 if provider=='flutter-web' else 500}}
                    except Exception as e:
                        row['captureErrors'].append({'provider':provider,'error':str(e),'pageErrors':list(errors)})
                        failed=args.out/'failures'/provider;failed.mkdir(parents=True,exist_ok=True)
                        try:page.screenshot(path=str(failed/(case['id']+'.png')))
                        except Exception:pass
                    finally:ctx.close()
                results.append(row);(args.out/'results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
                print(case['id'],len(row['captures']),row['captureErrors'],flush=True)
        finally:
            browser.close()
            for server in servers:server.shutdown()
if __name__=='__main__':main()
