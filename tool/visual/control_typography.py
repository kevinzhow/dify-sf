"""Actual Wasm controls vs Chromium cap/alphabetic trimming, plus real field/state interactions."""
import functools,http.server,threading,json,re,math
from pathlib import Path
from playwright.sync_api import sync_playwright
from PIL import Image
import numpy as np
import argparse
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--web', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
parser.add_argument('--forms-only', action='store_true')
args=parser.parse_args();B=args.web.resolve();O=args.out.resolve();O.mkdir(parents=True,exist_ok=True)
assert (B/'main.dart.wasm').is_file(), 'Build the actual Wasm probe first'

class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*a):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Quiet,directory=str(B)));threading.Thread(target=server.serve_forever,daemon=True).start();base=f'http://127.0.0.1:{server.server_port}';results=[]
with sync_playwright() as p:
 browser=p.chromium.launch()
 for font in ([] if args.forms_only else ['Noto Sans','DejaVu Sans Mono','Dify CJK SC']):
  for theme in ['light','dark']:
   for dpr in [1,2]:
    name=font.replace(' ','-')+'-'+theme+'-'+str(dpr);ctx=browser.new_context(viewport={'width':1440,'height':1100},device_scale_factor=dpr);page=ctx.new_page();errors=[];resources=[];page.on('pageerror',lambda e:errors.append(str(e)));page.on('response',lambda r:resources.append(r.url));page.goto(base+'/?font='+font.replace(' ','%20')+'&theme='+theme,wait_until='networkidle');page.wait_for_function('document.documentElement.hasAttribute("data-control-metrics")');page.wait_for_timeout(400)
    rows=json.loads(page.locator('html').get_attribute('data-control-metrics'));assert len(rows)==60,len(rows)
    # Real, independently laid-out CSS cap/alphabetic trimmed labels using the same files.
    reference=page.evaluate('''async ({font,rows})=>{
      if(!CSS.supports('text-box-trim','trim-both'))throw Error('Chromium lacks text-box-trim');
      const style=document.createElement('style');style.textContent=`@font-face{font-family:RefPrimary;src:url(assets/assets/fonts/${font==='DejaVu Sans Mono'?'DejaVuSansMono.ttf':font==='Dify CJK SC'?'cjk/NotoSansCJKSC-Regular.woff2':'NotoSans-Regular.ttf'});font-weight:400 600}@font-face{font-family:RefFallback;src:url(assets/assets/fonts/cjk/NotoSansCJKSC-Regular.woff2)}`;document.head.append(style);
      await document.fonts.load('13px RefPrimary');await document.fonts.load('13px RefFallback');
      const root=document.createElement('section');root.style.cssText='position:absolute;left:-10000px;top:0';document.body.append(root);const out=[];
      for(const row of rows){const size=row.id.startsWith('small/')?12:row.id.startsWith('medium/')?13:14;
       const box=document.createElement('div');box.style.cssText=`display:flex;align-items:center;height:${row.button.height}px`;
       const label=document.createElement('div');label.style.cssText=`font-family:RefPrimary,RefFallback;font-size:${size}px;font-weight:${size===14?600:500};line-height:${size===14?20:16}px;text-box-trim:trim-both;text-box-edge:cap alphabetic;white-space:pre`;
       label.textContent='Create';const marker=document.createElement('i');marker.style.cssText='display:inline-block;width:0;height:0;vertical-align:baseline';label.append(marker);box.append(label);root.append(box);
       const b=box.getBoundingClientRect(),m=marker.getBoundingClientRect();out.push({id:row.id,baselineAboveCenter:m.y-(b.y+b.height/2)});
      }root.remove();return out;
    }''',{'font':font,'rows':rows})
    differences=[]
    for row,ref in zip(rows,reference):
     actual=row['label']['y']+row['baseline']-row['button']['y']-row['button']['height']/2;delta=abs(actual-ref['baselineAboveCenter']);differences.append(delta);assert delta < (.26 if font == 'DejaVu Sans Mono' else .06),(name,row,ref,delta)
    path=O/(name+'.png');page.screenshot(path=str(path));pixels=np.asarray(Image.open(path).convert('RGB')).astype(float);ink=[]
    for row in rows:
     if '/primary 创建' not in row['id'] or row['id'].endswith('App'):continue
     q=row['label'];x0=math.floor(q['x']*dpr);x1=math.ceil((q['x']+q['width'])*dpr);y0=math.floor(q['y']*dpr);y1=math.ceil((q['y']+q['height'])*dpr);crop=pixels[y0:y1,x0:x1];bg=pixels[(y0+y1)//2,x0-2];mask=np.linalg.norm(crop-bg,axis=2)>80;ys,xs=np.where(mask);assert len(ys);center=(y0+(ys.min()+ys.max()+1)/2)/dpr;target=row['icon']['y']+row['icon']['height']/2;ink.append({'id':row['id'],'visibleCenter':float(center),'iconCenter':target,'delta':float(center-target)})
    assert not errors,errors;assert any('/main.dart.wasm' in x for x in resources);result={'name':name,'font':font,'theme':theme,'dpr':dpr,'controls':len(rows),'maxCSSCapBaselineDelta':max(differences),'legacyCapMetric':font=='DejaVu Sans Mono','createInk':ink,'wasm':True,'errors':errors};(O/(name+'.json')).write_text(json.dumps(result,indent=2));results.append(result);ctx.close();print('PASS',name,len(rows),'CSS max',max(differences),'create ink',ink,flush=True)
 # Real keyboard/pointer input into actual controls; no semantics label assumptions.
 for theme in ['light','dark']:
  ctx=browser.new_context(viewport={'width':1440,'height':1800},device_scale_factor=2);page=ctx.new_page();errors=[];resources=[]
  page.on('pageerror',lambda e:errors.append(str(e)));page.on('response',lambda r:resources.append(r.url))
  page.goto(base+'/?set=forms&theme='+theme,wait_until='networkidle');page.wait_for_function('document.documentElement.hasAttribute("data-gallery-metrics")');page.wait_for_timeout(500)
  if page.locator('flt-semantics-placeholder').count():page.locator('flt-semantics-placeholder').evaluate('(e)=>e.click()')
  page.wait_for_timeout(200);before=json.loads(page.locator('html').get_attribute('data-gallery-metrics'));page.screenshot(path=str(O/('forms-'+theme+'-default.png')))
  def state():return json.loads(page.locator('html').get_attribute('data-gallery-state'))
  def at(key,dx=None):
   r=before[key];page.mouse.click(r['x']+(dx if dx is not None else r['width']/2),r['y']+r['height']/2);page.wait_for_timeout(250)
  def click(loc):
   r=loc.bounding_box();assert r;page.mouse.click(r['x']+r['width']/2,r['y']+r['height']/2);page.wait_for_timeout(250)
  at('input');page.keyboard.insert_text('创建 Create');page.wait_for_timeout(200);assert state()['input']=='创建 Create'
  focused=json.loads(page.locator('html').get_attribute('data-gallery-metrics'));assert focused['input']==before['input'];page.screenshot(path=str(O/('forms-'+theme+'-focused.png')))
  at('search');page.keyboard.insert_text('中文');page.wait_for_timeout(200);assert state()['search']=='中文'
  at('checkbox',8);assert state()['checked']
  at('switch',12);assert state()['switch']
  at('select');page.screenshot(path=str(O/('forms-'+theme+'-select-open.png')))
  options=page.get_by_role('menuitemradio',name='运行 Run',exact=True)
  if not options.count():options=page.get_by_role('option',name='运行 Run',exact=True)
  if not options.count():
   (O/('forms-'+theme+'-semantics.txt')).write_text(page.locator('body').inner_text());raise AssertionError('Real select option not accessible')
  click(options.last);assert state()['select']=='b'
  # The two tabs are scoped by their measured, actual widget row.
  r=before['tabs'];tabs=page.get_by_role('tab',name='运行 Run',exact=True)
  if tabs.count():click(tabs.first)
  else:page.mouse.click(r['x']+170,r['y']+r['height']/2);page.wait_for_timeout(250)
  assert state()['tab']=='b'
  page.screenshot(path=str(O/('forms-'+theme+'-selected.png')))
  assert not errors,errors;assert any('/main.dart.wasm' in x for x in resources);assert any('/canvaskit/skwasm' in x for x in resources)
  (O/('forms-'+theme+'.json')).write_text(json.dumps({'families':list(before),'inputAndFocusBoxStable':True,'unicodeInput':True,'searchInput':True,'checkboxChanged':True,'switchChanged':True,'selectChanged':True,'tabChanged':True,'wasm':True,'errors':errors},indent=2));ctx.close();print('PASS forms',theme,len(before),'families',flush=True)
 browser.close()
server.shutdown();(O/'result.json').write_text(json.dumps({'cases':results,'totalButtonCases':sum(x['controls'] for x in results),'formsThemes':['light','dark'],'success':True},indent=2))
