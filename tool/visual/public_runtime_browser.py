"""Real published UI -> built-in engine -> visitor SSE, no mocked execution responses."""
import argparse,hashlib,json,pathlib,sys,re,urllib.parse
from playwright.sync_api import sync_playwright
parser=argparse.ArgumentParser(description=__doc__)
for name in ['session','flutter-build','out']:parser.add_argument('--'+name,type=pathlib.Path,required=True)
parser.add_argument('--product-commit',required=True)
args=parser.parse_args();r=pathlib.Path(__file__).resolve().parents[2];sys.path.insert(0,str(r/'tool/visual'));import compare
from capture_contract import observe_capture_health, assert_capture_health
private=json.loads(args.session.read_text());compare.SF=private['sf']['base'];compare.sf_tokens=lambda:private['sf']['tokens'];compare.ROOT=r
out=args.out;out.mkdir(exist_ok=False);web,base=compare.serve(args.flutter_build,spa=True);owned=[];results=[]
compiled=hashlib.sha256((args.flutter_build/'main.dart.wasm').read_bytes()).hexdigest()
with sync_playwright() as pw:
 browser=pw.chromium.launch(headless=True,args=['--no-sandbox'])
 try:
  for mode,fixture,answer in [('workflow','ui_model_free_run.json','Browser workflow result'),('chat','public_chat.yml','Ready')]:
   text=(r/'tool/visual/fixtures'/fixture).read_text();doc=json.loads(text)
   allowed={'start','end','answer','variable-aggregator',''}
   assert all(n['data']['type'] in allowed for n in doc['workflow']['graph']['nodes'])
   app=compare.sf_import(text);owned.append(app);compare.sf_api('POST','/v1/apps/'+app+'/workflows/publish',{});code=compare.sf_api('GET','/v1/apps/'+app)['site']['code']
   for theme in ['light','dark']:
    ctx=browser.new_context(viewport={'width':1440,'height':900},device_scale_factor=2,color_scheme=theme)
    # A console session in the browser must never be borrowed by public transport.
    ctx.add_init_script('if(window.top===window&&/^http/.test(location.protocol))localStorage.setItem('+json.dumps('dify-sf/tokens/'+compare.SF)+','+json.dumps(json.dumps(private['sf']['tokens']))+')')
    page=ctx.new_page();errors=[];requests=[];terminals=[];bodies=[]
    page.on('pageerror',lambda e:errors.append(str(e)));health=observe_capture_health(page)
    def request(req):
     path=urllib.parse.urlsplit(req.url).path
     if path.startswith('/v1/'):
      console_used=req.headers.get('authorization','')=='Bearer '+private['sf']['tokens']['access_token']
      public_path=path in ['/v1/passport','/v1/site','/v1/workflows/run','/v1/chat-messages','/v1/messages','/v1/conversations'] or path.startswith(('/v1/workflow-runs/','/v1/form/human_input/'))
      requests.append({'path':path,'method':req.method,'consoleAuthUsed':console_used,'audience':'public'if public_path else'console-bootstrap'})
      (out/'request-paths.json').write_text(json.dumps(requests,indent=2))
      if public_path:assert not console_used,'Public API borrowed console auth: '+path
    def response(resp):
     if resp.request.method=='POST' and urllib.parse.urlsplit(resp.url).path in ['/v1/workflows/run','/v1/chat-messages']:
      assert resp.status==200,(mode,resp.status)
      body=resp.text();frames=[json.loads(line[6:])for line in body.splitlines()if line.startswith('data: ')]
      terminals.extend(f['data']['status']for f in frames if f.get('event')=='workflow_finished')
      bodies.append({'path':urllib.parse.urlsplit(resp.url).path,'events':[f.get('event')for f in frames],'terminal':terminals[-1]if terminals else None,'outputs':[f.get('data',{}).get('outputs')for f in frames if f.get('event')=='workflow_finished']})
    page.on('request',request);page.on('response',response)
    try:
     url=base+'/'+('workflow'if mode=='workflow'else'chat')+'/'+code+'?'+urllib.parse.urlencode({'server':compare.SF,'theme':theme,'lang':'en-US'})
     page.goto(url,wait_until='networkidle',timeout=60000);page.wait_for_selector('flutter-view',timeout=60000)
     if page.locator('flt-semantics-placeholder').count():page.locator('flt-semantics-placeholder').evaluate('(e)=>e.click()')
     field=page.get_by_role('textbox').first;field.wait_for(state='visible',timeout=30000);field.fill(answer if mode=='workflow'else'Browser public question')
     # Wait for the real Flutter semantics/input frame, then move focus as a
     # person does before activating the run button. The server output below
     # must still contain the exact typed input; status alone never passes.
     field.press('Tab');page.evaluate('new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))')
     page.get_by_role('button',name='Execute',exact=True).click(timeout=10000)
     for _ in range(120):
      if terminals:break
      page.wait_for_timeout(250)
     assert terminals==['succeeded'],(mode,terminals,errors)
     if mode=='workflow':assert answer in json.dumps(bodies[-1].get('outputs')), 'Real completed run did not preserve the typed fixture input'
     page.get_by_text(answer,exact=True).first.wait_for(state='visible',timeout=15000)
     page.screenshot(path=str(out/f'{mode}-{theme}-completed.png'))
     count=len(bodies);page.reload(wait_until='networkidle');page.wait_for_timeout(1000)
     if page.locator('flt-semantics-placeholder').count():page.locator('flt-semantics-placeholder').evaluate('(e)=>e.click()')
     page.get_by_text(answer,exact=True).first.wait_for(state='visible',timeout=15000);assert len(bodies)==count,'Reload started a duplicate run'
     page.screenshot(path=str(out/f'{mode}-{theme}-restored.png'))
     if mode=='chat':
      page.get_by_role('button',name='Start New chat',exact=True).click();page.wait_for_timeout(700)
      assert not page.get_by_text('Browser public question',exact=True).count(),'New chat retained the old question'
     page.set_viewport_size({'width':390,'height':844});page.wait_for_timeout(700)
     assert not errors,errors;assert_capture_health(health)
     wasm=page.evaluate("performance.getEntriesByType('resource').map(e=>e.name.split('/').pop().split('?')[0]).filter(n=>n.endsWith('.wasm'))")
     assert 'main.dart.wasm'in wasm and any(n.startswith('skwasm')for n in wasm),wasm
     page.screenshot(path=str(out/f'{mode}-{theme}-390.png'))
     results.append({'mode':mode,'theme':theme,'productCommit':args.product_commit,'compiledSha256':compiled,'realTerminals':terminals,'requests':requests,'runtime':bodies,'noDuplicateOnReload':True,'actualWasm':wasm,'pageErrors':errors,'assetErrors':list(health),'viewportWidths':[1440,390]})
     (out/'results.json').write_text(json.dumps(results,indent=2));print(mode,theme,'real run and restored UI passed',flush=True)
    except Exception as exc:
     page.screenshot(path=str(out/f'{mode}-{theme}-FAIL.png'))
     (out/f'{mode}-{theme}-FAIL.json').write_text(json.dumps({'error':str(exc),'ui':page.locator('body').inner_text(),'runtime':bodies,'paths':requests},indent=2))
     raise
    finally:ctx.close()
   compare.sf_api('DELETE','/v1/apps/'+app);owned.remove(app)
 finally:
  browser.close();web.shutdown()
  for app in owned:
   try:compare.sf_api('DELETE','/v1/apps/'+app)
   except Exception:pass
assert len(results)==4
