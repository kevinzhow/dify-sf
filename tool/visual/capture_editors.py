import copy,hashlib,json,re,sys,time,traceback
from pathlib import Path
from urllib.parse import urlsplit
from PIL import Image
from playwright.sync_api import sync_playwright
import argparse,requests
import compare
parser=argparse.ArgumentParser(description='Actual editor/node-panel capture, with original PNGs and no custom score.')
for name in ['session','catalog','flutter-build','out']:parser.add_argument('--'+name,type=Path,required=True)
parser.add_argument('--product-commit',help='Verified source base of the supplied Flutter build')
args=parser.parse_args();S=Path(__file__).resolve().parents[2];out=args.out;out.mkdir(parents=True,exist_ok=False)
private=json.loads(args.session.read_text());compare.SF=private['sf']['base'];compare.sf_tokens=lambda:private['sf']['tokens'];compare.DIFY=private['dify']['base'];compare.LOCALE='en-US';compare.ROOT=S
build=args.flutter_build;compiled=hashlib.sha256((build/'main.dart.wasm').read_bytes()).hexdigest();web,base=compare.serve(build)
class ClientSession:
 def __init__(self):
  self.s=requests.Session();self.s.headers.update(private['dify'].get('headers',{}))
  for cookie in private['dify']['cookies']:self.s.cookies.set(cookie['name'],cookie['value'])
client=ClientSession();cases=json.loads(args.catalog.read_text())
blocked=[];errors=[];results=[];owned=[];run_events={}
class SafeBrowsers(compare.Browsers):
 def context(self,*args):
  c=super().context(*args)
  def guard(route):
   path=urlsplit(route.request.url).path
   if route.request.method=='POST' and (any(x in path for x in ['/draft/run','/single-node/','/advanced-chat/','/chat-messages','delivery-test','/invoke']) or path.endswith('/run')):
    allowed=current.get('modelFreeRun') and any('/'+aid+'/' in path for aid in current.get('allowedAppIds',[]))
    if allowed:route.continue_()
    else:blocked.append({'case':current['id'],'path':path});route.abort('blockedbyclient')
   else:route.continue_()
  c.route('**/*',guard)
  def attach(page):
   page.on('pageerror',lambda e:errors.append({'case':current['id'],'error':str(e)}))
   page.on('console',lambda m:run_events.setdefault(current['id'],[]).append(m.text) if m.text.startswith('VISUAL_RUN ') else None)
  c.on('page',attach)
  return c
original_shot=compare.shot
facts={}
def shot(page,box,case,path):
 if page.locator('flt-semantics-placeholder').count():page.locator('flt-semantics-placeholder').evaluate('(e)=>e.click()');page.wait_for_timeout(500)
 page.wait_for_timeout(case.get('admissionWaitMs',1000))
 env=page.evaluate('({width:innerWidth,height:innerHeight,dpr:devicePixelRatio,scale:visualViewport.scale,userAgent:navigator.userAgent})');assert env['dpr']==2 and env['width']==case['window'][0]
 if case.get('select'):
  if 'flutter' in path.parts:
   panel=page.get_by_role('group',name=re.compile('Node configuration panel Width:'))
   if case.get('expectPanel',True):panel.wait_for(state='visible')
   else:assert panel.count()==0,'This selected simple node has no configuration panel'
   assert page.get_by_text(re.compile('^'+re.escape(case['expectedPanelTitle'])+', .*selected$',re.I)).count()>0,'Selected node identity missing'
  else:
   assert page.get_by_text(case['expectedPanelTitle'],exact=True).count()>0,'Expected selected panel title missing'
 if 'flutter' not in path.parts:
  corpus=page.locator('body').inner_text()+'\n'+'\n'.join(page.locator('[aria-label]').evaluate_all('(es)=>es.map(e=>e.getAttribute("aria-label"))'))
  for pattern in case.get('expectedReferenceCorpus',[]):assert re.search(pattern,corpus,re.I), 'Expected reference state absent: '+pattern
 if 'flutter' in path.parts:
  loaded=page.evaluate("performance.getEntriesByType('resource').map(e=>e.name.split('/').pop().split('?')[0]).filter(n=>n.endsWith('.wasm'))")
  assert 'main.dart.wasm' in loaded and any(n.startswith('skwasm') for n in loaded), 'Actual Dart/Skia Wasm resources were not loaded'
  corpus=page.locator('body').inner_text()+'\n'+'\n'.join(page.locator('[aria-label]').evaluate_all('(es)=>es.map(e=>e.getAttribute("aria-label"))'))
  for pattern in case.get('expectedCorpus',[]):
   assert re.search(pattern,corpus,re.I), 'Expected final UI state absent: '+pattern
  if case.get('expectedTab'):
   page.get_by_role('tab',name=re.compile('^'+re.escape(case['expectedTab'])+'$',re.I),selected=True).wait_for(state='visible',timeout=5000)
  if case.get('expectSucceeded'):
   assert any(re.search('VISUAL_RUN.*succeeded',m,re.I) for m in run_events.get(case['id'],[])), 'No successful model-free run terminal event: '+str(run_events.get(case['id'],[]))
  if case.get('expectCommentMode'):
   page.get_by_role('switch',name='Comment Mode',checked=True).wait_for(state='visible',timeout=5000)
 page.screenshot(path=str(path.with_suffix('.full.png')))
 original_shot(page,box,case,path);facts[str(path)]={'environment':env,'box':box,'source':'flutter-web-wasm' if 'flutter' in path.parts else 'dify-web-1.17.1','sourceCommit':args.product_commit if 'flutter' in path.parts else json.loads(Path(__file__).with_name('ui_reference.json').read_text())['commit'],'compiledSha256':compiled if 'flutter' in path.parts else None,'admission':{'loadedWasm':loaded if 'flutter' in path.parts else [],'expectedCorpus':case.get('expectedCorpus',[]),'expectedTab':case.get('expectedTab'),'runEvents':run_events.get(case['id'],[])}}
compare.shot=shot
with sync_playwright() as p:
 browsers=SafeBrowsers(p)
 try:
  for theme in ['light','dark']:
   compare.THEME=theme
   for index,raw in enumerate(cases):
    if theme not in raw.get('themes',['light','dark']):continue
    if index and index%18==0:client=ClientSession()
    case=copy.deepcopy(raw);case['realEditor']=True;case.pop('masks',None);case.pop('intentional',None);current=case
    cid=f"editors.{case['id']}.{theme}.en-US";case['id']=cid
    row={'captureType':'component-fixture','id':cid,'case':raw['id'],'theme':theme,'locale':'en-US','sourceCommit':args.product_commit,'captures':{},'errors':[]};d=sf=None;started=time.monotonic()
    try:
     text=compare.with_viewport((S/case['fixture']).read_text(),*case['viewport']);text=re.sub(r'^(\s+)selected: true$',r'\1selected: false',text,flags=re.M)
     if case.get('select'):
      import subprocess
      # System Python's YAML dependency is used only to read the shared, immutable fixture.
      js=subprocess.check_output(['/usr/bin/python3','-c','import sys,yaml,json;print(json.dumps(yaml.safe_load(sys.stdin.read())))'],input=text.encode());graph=json.loads(js)['workflow']['graph'];case['expectedPanelTitle']=next(n['data']['title'] for n in graph['nodes'] if n['id']==case['select'])
     if case.get('modelFreeRun'):
      import subprocess
      doc=json.loads(subprocess.check_output(['/usr/bin/python3','-c','import sys,yaml,json;print(json.dumps(yaml.safe_load(sys.stdin.read())))'],input=text.encode()))
      assert all(n.get('data',{}).get('type','') in {'start','end','answer','variable-aggregator',''} for n in doc['workflow']['graph']['nodes']), 'Built-in-only runtime whitelist failed'
     row['fixtureSha256']=hashlib.sha256(text.encode()).hexdigest()
     d=compare.dify_import(client.s,text);sf=compare.sf_import(text);case['allowedAppIds']=[d,sf];owned.append({'dify':d,'sf':sf});(out/'owned-resources.json').write_text(json.dumps(owned))
     compare.add_comments(case,client.s,d,sf)
     dp=out/'react'/f'{cid}.png';dp.parent.mkdir(exist_ok=True);box,vp=compare.capture_dify(browsers,client.s,d,case,dp)
     assert not [x for x in errors if x['case']==cid], 'Page error in reference capture'
     row['captures']['react']={'image':str(dp),'fixtureSha256':row['fixtureSha256'],**facts[str(dp)]};steps=json.loads(dp.with_suffix('.steps.json').read_text())
     sp=out/'flutter'/f'{cid}.png';sp.parent.mkdir(exist_ok=True);compare.capture_ours(browsers,base,sf,case,sp,vp,steps);assert Image.open(dp).size==Image.open(sp).size
     assert not [x for x in blocked if x['case']==cid], 'Unexpected runtime call blocked'
     assert not [x for x in errors if x['case']==cid], 'Page error during capture'
     row['captures']['flutter-web']={'image':str(sp),'fixtureSha256':row['fixtureSha256'],**facts[str(sp)]}
     row['status']='captured'
    except Exception as e:
     row['status']='capture-failed';row['errors'].append({'type':type(e).__name__,'message':str(e)});(out/'failures').mkdir(exist_ok=True)
     for browser in browsers.browsers.values():
      for ctx in browser.contexts:
       for page in ctx.pages:
        try:
         failure=out/'failures'/f'{cid}-{len(list((out/"failures").glob(cid+"*")))}'
         page.screenshot(path=str(failure.with_suffix('.png')))
         failure.with_suffix('.json').write_text(json.dumps({'text':page.locator('body').inner_text(),'semantics':page.locator('[aria-label]').evaluate_all('(es)=>es.map(e=>({role:e.getAttribute("role"),label:e.getAttribute("aria-label")}))')},ensure_ascii=False,indent=2))
        except Exception:pass
     print(cid,'FAILED',type(e).__name__,str(e)[:350],flush=True)
    finally:
     for browser in browsers.browsers.values():
      for ctx in browser.contexts:ctx.close()
     if d:
      try:client.s.delete(compare.DIFY+'/console/api/apps/'+d,timeout=15)
      except Exception:pass
     if sf:
      try:compare.sf_api('DELETE','/v1/apps/'+sf)
      except Exception:pass
    row['seconds']=round(time.monotonic()-started,2);results.append(row);(out/'results.json').write_text(json.dumps({'results':results,'blockedRequests':blocked,'pageErrors':errors},ensure_ascii=False,indent=2));print(cid,row['status'],len(results),'/',sum(len(c.get('themes',['light','dark'])) for c in cases),flush=True)
 finally:browsers.close();web.shutdown()
print('EDITOR MATRIX COMPLETE',len(results),flush=True)
