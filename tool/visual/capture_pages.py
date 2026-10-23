#!/usr/bin/env python3
"""Actual product page captures with isolated session input and explicit network fixtures.

Sessions stay private. Output contains only PNGs and allowlisted provenance. No scoring.
"""
import argparse,hashlib,json,re,time
from pathlib import Path
from urllib.parse import urlencode,urlsplit
import requests
from playwright.sync_api import sync_playwright
import compare


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['session','catalog','flutter-build','out']:p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--product-commit',help='Verified source base of the supplied Flutter build')
    args=p.parse_args();args.out.mkdir(parents=True,exist_ok=False)
    auth=json.loads(args.session.read_text());compare.SF=auth['sf']['base'];compare.sf_tokens=lambda:auth['sf']['tokens'];compare.DIFY=auth['dify']['base'];compare.LOCALE='en-US'
    session=requests.Session()
    session.headers.update(auth['dify'].get('headers',{}))
    for c in auth['dify']['cookies']:session.cookies.set(c['name'],c['value'])
    server,base=compare.serve(args.flutter_build);compiled=hashlib.sha256((args.flutter_build/'main.dart.wasm').read_bytes()).hexdigest();rows=[];owned=[]
    with sync_playwright() as pw:
        browser=pw.chromium.launch(headless=True,args=['--no-sandbox'])
        try:
            for raw in json.loads(args.catalog.read_text()):
                row={**raw,'captures':{},'captureErrors':[]};d=sf=None
                try:
                    if raw.get('fixture'):
                        text=(compare.ROOT/raw['fixture']).read_text();d=compare.dify_import(session,text);sf=compare.sf_import(text);owned.append({'dify':d,'sf':sf});(args.out/'owned-resources.json').write_text(json.dumps(owned))
                    for side,provider in [('dify','react'),('ours','flutter-web')]:
                        compare.THEME=raw['theme'];ctx=browser.new_context(viewport={'width':1440,'height':900},device_scale_factor=2,locale='en-US',color_scheme=raw['theme'],timezone_id='America/New_York');page=ctx.new_page();errors=[];blocked=[];page.on('pageerror',lambda e:errors.append(str(e)))
                        try:
                            def guard(r):
                                path=urlsplit(r.request.url).path
                                is_owned_client = side=='ours' and sf and re.fullmatch(r'/v1/docs/'+re.escape(sf)+r'/clients(?:/[^/]+)?',path) and r.request.method in ['POST','PUT']
                                if r.request.method not in ['GET','HEAD','OPTIONS'] and not is_owned_client:
                                    blocked.append({'method':r.request.method,'path':path});r.abort('blockedbyclient')
                                else:r.continue_()
                            ctx.route('**/*',guard)
                            ctx.add_init_script('if(window.top===window && /^https?:$/.test(location.protocol))localStorage.setItem("theme",'+json.dumps(raw['theme'])+')')
                            signed=raw.get('signedIn',True)
                            if side=='dify':
                                if signed:ctx.add_cookies([{**c,'url':compare.DIFY} for c in auth['dify']['cookies'] if c['name']!='locale'])
                                ctx.add_cookies([{'name':'locale','value':raw['locale'],'url':compare.DIFY}])
                            elif signed:ctx.add_init_script('if(window.top===window && /^https?:$/.test(location.protocol))localStorage.setItem('+json.dumps('dify-sf/tokens/'+compare.SF)+','+json.dumps(json.dumps(auth['sf']['tokens']))+')')
                            # Original fixture routes, including statistics/logs, are served before the deny-write guard.
                            compare.add_routes(page,raw,side)
                            for fixture in raw.get('network',[]):
                                if fixture.get('side','both') not in [side,'both']:continue
                                def answer(route,request=None,f=fixture):
                                    if f.get('method','GET')!=route.request.method:route.fallback();return
                                    route.fulfill(status=f.get('status',200),content_type='application/json',body=json.dumps(f['json']))
                                page.route(fixture['url'],answer)
                            if raw.get('emptyStudio'):
                                page.route('**/console/api/apps?*' if side=='dify' else '**/v1/apps?*',lambda r:r.fulfill(status=200,json={'data':[],'page':1,'limit':30,'total':0,'has_more':False}) if r.request.method=='GET' else r.fallback())
                            path=raw[side].replace('{app}',d if side=='dify' and d else sf or '')
                            if side=='dify':url=compare.DIFY+path
                            else:url=base+'/?'+urlencode({'server':compare.SF,'lang':raw['locale'],'theme':raw['theme'],'visual':'1'})+('&'+path if path and not path.startswith('#') else path)
                            page.goto(url,wait_until='networkidle',timeout=60000)
                            if side=='ours':
                                page.wait_for_selector('flutter-view',timeout=60000)
                                if page.locator('flt-semantics-placeholder').count():page.locator('flt-semantics-placeholder').evaluate('(e)=>e.click()')
                            page.wait_for_timeout(1800)
                            for action in raw.get('actions',{}).get(side,[]):
                                if 'focus' in action:
                                    trace=args.out/(raw['id']+'-'+provider+'.focus.png')
                                    compare.THEME=raw['theme'];compare.keyboard_focus_control(page,compare.locate(page,action['focus']),side,trace)
                                elif 'press' in action:page.keyboard.press(action['press'])
                                elif 'fill' in action:compare.locate(page,action['locator']).fill(action['fill'])
                                else:compare.locate(page,action).click(timeout=10000)
                                page.wait_for_timeout(500)
                            expected=raw.get('expected',{}).get(side)
                            if expected:
                                target=compare.locate(page,expected) if isinstance(expected,dict) else page.get_by_text(re.compile(expected,re.I)).first
                                target.wait_for(state='visible',timeout=10000)
                            if page.get_by_text('An unexpected error occurred while rendering this component.',exact=True).count():raise RuntimeError('Original React error boundary, not the declared page')
                            if errors:raise RuntimeError('; '.join(errors))
                            page.mouse.move(0,0);page.wait_for_timeout(1200)
                            if blocked:raise RuntimeError('Unexpected write was blocked: '+json.dumps(blocked))
                            wasm=page.evaluate("performance.getEntriesByType('resource').map(e=>e.name.split('/').pop().split('?')[0]).filter(n=>n.endsWith('.wasm'))") if side=='ours' else []
                            if side=='ours':assert 'main.dart.wasm' in wasm and any(n.startswith('skwasm') for n in wasm), 'Actual Dart/Skia Wasm was not loaded'
                            dest=args.out/provider/(raw['id']+'.png');dest.parent.mkdir(exist_ok=True);page.screenshot(path=str(dest))
                            row['captures'][provider]={'image':str(dest.resolve()),'source':'actual Dify 1.17.1 page' if side=='dify' else 'actual Flutter Web Wasm page','sourceCommit':json.loads(Path(__file__).with_name('ui_reference.json').read_text())['commit'] if side=='dify' else args.product_commit,'compiledSha256':compiled if side=='ours' else None,'viewport':{'width':1440,'height':900,'dpr':2},'browserVersion':browser.version,'theme':raw['theme'],'locale':raw['locale'],'state':raw['state'],'admission':{'expected':expected,'loadedWasm':wasm,'pageErrors':errors,'blockedRequests':blocked,'networkFixtureCount':len(raw.get('network',[]))+len(raw.get('page',{}).get('routes',[]))}}
                        except Exception as e:
                            row['captureErrors'].append({'provider':provider,'error':str(e)});fd=args.out/'failures'/provider;fd.mkdir(parents=True,exist_ok=True)
                            try:page.screenshot(path=str(fd/(raw['id']+'.png')));(fd/(raw['id']+'.txt')).write_text(page.locator('body').inner_text())
                            except Exception:pass
                        finally:ctx.close()
                except Exception as e:row['captureErrors'].append({'provider':'fixture','error':str(e)})
                finally:
                    if d:
                        try:session.delete(compare.DIFY+'/console/api/apps/'+d,timeout=15)
                        except Exception:pass
                    if sf:
                        try:compare.sf_api('DELETE','/v1/apps/'+sf)
                        except Exception:pass
                rows.append(row);(args.out/'results.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2)+'\n');print(raw['id'],len(row['captures']),row['captureErrors'],flush=True)
        finally:browser.close();server.shutdown()
if __name__=='__main__':main()
