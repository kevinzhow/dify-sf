"""Formal Wasm, real browser file chooser, real HTTP consumer and same-DB new-process human-input resume.

This operates ONLY on the existing isolated runtime-check fixture, with fixture credentials in a private file.
"""
import argparse, functools, http.server, json, re, subprocess, sys, threading, time, uuid
from pathlib import Path
import requests
from playwright.sync_api import sync_playwright

p=argparse.ArgumentParser();p.add_argument('--base',required=True);p.add_argument('--stub',required=True)
p.add_argument('--web-root',type=Path,required=True);p.add_argument('--compose',type=Path,required=True)
p.add_argument('--auth-file',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
a.out.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from compare import DifySF
from lib.e2ehttp import Session
from runtime_files.acceptance_support import node, workflow
from runtime_files.origin import PNG

api=Session(a.base);login=api.post('/v1/auth/login',json.loads(a.auth_file.read_text()));tokens={k:login[k] for k in ['access_token','refresh_token']}
api.headers['Authorization']='Bearer '+tokens['access_token'];client=DifySF.__new__(DifySF);client.s=api
case='browser-'+uuid.uuid4().hex
start=node('start','start',variables=[{'variable':'attachment','label':'开始文件','type':'file','required':True,'allowed_file_types':['image'],'allowed_file_upload_methods':['local_file']}])
http_node=node('http','http-request',method='post',url='http://llmstub:8000/files/echo?case='+case,authorization={'type':'no-auth'},headers='',params='',body={'type':'binary','data':[{'type':'file','file':['start','attachment']}]})
human=node('human','human-input',form_content='审批文件 {{#$output.answer_file#}}\n备注 {{#$output.note#}}',inputs=[{'type':'file','output_variable_name':'answer_file','allowed_file_types':['document'],'allowed_file_upload_methods':['local_file']},{'type':'paragraph','output_variable_name':'note'}],user_actions=[{'id':'approve','title':'继续处理','button_style':'primary'}])
end=node('end','end',outputs=[{'variable':'source','value_selector':['start','attachment']},{'variable':'approved','value_selector':['human','answer_file']},{'variable':'note','value_selector':['human','note']},{'variable':'echo','value_selector':['http','body']}])
dsl=workflow([start,http_node,human,end],[('start','source','http'),('http','source','human'),('human','approve','end')],name='文件上传与人工审批验收')
# The file-upload feature is irrelevant here: both files are explicit form fields, not an extra sys.files uploader.
dsl['workflow']['features']={}
app=client.import_dsl(dsl);(a.out/'workflow.json').write_text(json.dumps(dsl,ensure_ascii=False,indent=2))
files=a.out/'inputs';files.mkdir(exist_ok=True);(files/'source.png').write_bytes(PNG);(files/'wrong.png').write_bytes(PNG);(files/'approved.txt').write_text('approved after new server process\n')

class Quiet(http.server.SimpleHTTPRequestHandler):
 def log_message(self,*args):pass
 def end_headers(self):
  self.send_header('Cache-Control','no-store');self.send_header('Cross-Origin-Opener-Policy','same-origin');self.send_header('Cross-Origin-Embedder-Policy','require-corp');super().end_headers()
web=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(Quiet,directory=str(a.web_root)));threading.Thread(target=web.serve_forever,daemon=True).start();base=f'http://127.0.0.1:{web.server_port}';checks={};logs=[];errors=[]

def restart_server():
 old=subprocess.check_output(['docker','inspect','--format','{{.Id}}','winnie-runtime-check-server-1'],text=True).strip()
 subprocess.run(['docker','compose','-p','winnie-runtime-check','-f',str(a.compose),'--profile','runtime','up','-d','--force-recreate','--no-deps','--no-build','--pull','never','server'],check=True,stdout=subprocess.DEVNULL)
 for _ in range(100):
  try:
   if requests.get(a.base+'/v1/setup',timeout=2).status_code==200:break
  except requests.RequestException:pass
  time.sleep(.3)
 else:raise AssertionError('new fixture server never became ready')
 new=subprocess.check_output(['docker','inspect','--format','{{.Id}}','winnie-runtime-check-server-1'],text=True).strip();assert old!=new
 checks['independentProcessIdsDiffer']=True

try:
 with sync_playwright() as pw:
  browser=pw.chromium.launch();ctx=browser.new_context(viewport={'width':1440,'height':1000});ctx.add_init_script(f'localStorage.setItem({json.dumps("dify-sf/tokens/"+a.base)},{json.dumps(json.dumps(tokens))})');page=ctx.new_page()
  page.on('console',lambda m:logs.append(m.text));page.on('pageerror',lambda e:errors.append(str(e)))
  def save(name):
   page.screenshot(path=str(a.out/(name+'.png')));(a.out/(name+'.txt')).write_text(page.locator('body').inner_text());(a.out/'diagnostics.json').write_text(json.dumps({'logs':logs,'pageErrors':errors},indent=2,ensure_ascii=False))
  def click(loc):
   loc.wait_for(state='visible',timeout=20000);b=loc.bounding_box();assert b;page.mouse.click(b['x']+b['width']/2,b['y']+b['height']/2);page.wait_for_timeout(350)
  def open_page(theme='light'):
   page.goto(base+f'/?server={a.base}&app={app}&page=workflow&lang=zh-Hans&theme={theme}&visual=1')
   page.wait_for_function("document.querySelector('flt-semantics-placeholder') || document.querySelector('flt-semantics')",timeout=90000)
   if page.locator('flt-semantics-placeholder').count():page.locator('flt-semantics-placeholder').evaluate('(e)=>e.click()')
   page.get_by_role('button',name=re.compile('^测试运行')).first.wait_for(state='visible',timeout=90000);page.wait_for_timeout(700)
  def choose(path):
   button=page.get_by_role('button',name='从本地上传',exact=True).first
   with page.expect_file_chooser(timeout=20000) as selection:click(button)
   selection.value.set_files(str(path));page.wait_for_timeout(900)
   page.get_by_text(path.name,exact=True).first.wait_for(state='visible',timeout=20000)
  open_page();click(page.get_by_role('button',name=re.compile('^测试运行')).first)
  choose(files/'source.png');save('01-start-file-uploaded');click(page.get_by_role('button',name='开始运行',exact=True).first)
  page.get_by_role('button',name='继续处理',exact=True).wait_for(state='visible',timeout=30000);save('02-paused-file-form')
  latest=api.get(f'/v1/apps/{app}/workflow-runs?limit=1')['data'][0];run=latest['id'];assert latest['status']=='paused',latest
  http_before=[x for x in requests.get(a.stub+'/files/log').json()['requests'] if ('case='+case) in x['path']];assert len(http_before)==1,http_before
  import base64
  assert base64.b64decode(http_before[0]['base64'])==PNG;checks['realChooserUploadToActualHTTPBytes']=True
  textbox=page.get_by_role('textbox').last;click(textbox);page.keyboard.type('保留的审批备注',delay=40)
  choose(files/'wrong.png');click(page.get_by_role('button',name='继续处理',exact=True));page.wait_for_timeout(700);save('03-real-server-rejection-preserves-form')
  assert 'File validation failed' in page.locator('body').inner_text(),page.locator('body').inner_text()
  assert api.get(f'/v1/apps/{app}/workflow-runs/{run}')['status']=='paused'
  assert page.get_by_text('wrong.png',exact=True).count();checks['realServerRefusalKeepsFileAndForm']=True
  click(page.get_by_role('button',name='移除',exact=True).first);choose(files/'approved.txt');save('04-corrected-file-ready')
  restart_server();page.wait_for_timeout(1800);save('05-pause-after-independent-server-process')
  assert page.get_by_text('approved.txt',exact=True).count();assert not any(x=='VISUAL_RUN failed' for x in logs),logs[-20:]
  click(page.get_by_role('button',name='继续处理',exact=True))
  for _ in range(150):
   if 'VISUAL_RUN succeeded' in logs:break
   page.wait_for_timeout(200)
  else:save('06-no-terminal-result');raise AssertionError('the resumed result never reached the page')
  detail=api.get(f'/v1/apps/{app}/workflow-runs/{run}');assert detail['status']=='succeeded',detail
  assert detail['outputs']['note']=='保留的审批备注',detail['outputs'];assert detail['outputs']['source']['filename']=='source.png';assert detail['outputs']['approved']['filename']=='approved.txt'
  assert requests.get(detail['outputs']['source']['url']).content==PNG
  assert requests.get(detail['outputs']['approved']['url']).content==(files/'approved.txt').read_bytes()
  http_after=[x for x in requests.get(a.stub+'/files/log').json()['requests'] if ('case='+case) in x['path']];assert len(http_after)==1,http_after
  page.get_by_role('button',name='source.png',exact=True).first.wait_for(state='visible',timeout=20000);page.wait_for_timeout(6000)
  save('06-resumed-result-light');checks['fileAndTextSurviveProcessRestartAndResume']=True;checks['HTTPBeforePauseNotReplayed']=True
  with page.expect_popup(timeout=20000) as opening:click(page.get_by_role('button',name='source.png',exact=True).first)
  preview=opening.value;preview.wait_for_load_state();preview.set_viewport_size({'width':800,'height':600});preview.wait_for_timeout(300);assert preview.url.startswith(a.base+'/files/');assert preview.locator('img').evaluate('(e)=>e.naturalWidth')==1;preview.screenshot(path=str(a.out/'07-signed-preview.png'));preview.close();checks['actualResultCardOpensSignedPreview']=True
  resources=page.evaluate("performance.getEntriesByType('resource').map(e=>e.name)");assert any('main.dart.wasm' in x for x in resources) and any('skwasm' in x and '.wasm' in x for x in resources),resources
  checks['actualMainAndRendererWasmLoaded']=True
  open_page('dark');click(page.get_by_role('button',name='查看运行历史',exact=True));page.wait_for_timeout(600);click(page.get_by_role('button',name=re.compile('Test Run')).first);page.wait_for_timeout(900);save('08-new-page-history-dark')
  assert '返回编辑模式' in page.locator('body').inner_text();checks['freshPageReadsPersistedHistory']=True
  page.set_viewport_size({'width':390,'height':844});page.wait_for_timeout(700);save('09-history-mobile-dark');checks['mobileViewport390Captured']=True
  assert not errors,errors
  checks.update(success=True,app=app,run=run,serverImage=subprocess.check_output(['docker','inspect','--format','{{.Image}}','winnie-runtime-check-server-1'],text=True).strip(),device='Chromium desktop and narrow viewport; physical Android not tested')
  (a.out/'result.json').write_text(json.dumps(checks,indent=2,ensure_ascii=False));browser.close()
finally:web.shutdown()
print('PASS: actual Wasm file workflow, real rejection/retry, new process resume and signed preview',flush=True)
