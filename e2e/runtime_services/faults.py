"""Restart/configuration checks on Winnie's isolated fixture (never a user deployment)."""
import copy,json,subprocess,sys,time,urllib.request
from pathlib import Path
r=Path(sys.argv[1]);manifest=r/'deploy.json';original=json.loads(manifest.read_text());out=r/'faults';out.mkdir(exist_ok=True)
e2e=Path(__file__).resolve().parents[1];sys.path.insert(0,str(e2e/'lib'));from e2ehttp import Session
headers=json.loads((r/'smoke/private/session.json').read_text())['headers'];s=Session('http://127.0.0.1:19092',headers=headers);app=json.loads((r/'smoke/result.json').read_text())['app'];run=json.loads((r/'smoke/result.json').read_text())['run'];checks=[]
assert original['services']['server']['ports']==['127.0.0.1:19092:8080'], 'not the dedicated fixture manifest'
labels=json.loads(subprocess.check_output(['docker','inspect','--format','{{json .Config.Labels}}','winnie-runtime-check-postgres-1'],text=True));assert labels['com.docker.compose.project']=='winnie-runtime-check'
def restart(changes):
 d=copy.deepcopy(original);d['services']['server']['environment'].update(changes);
 if changes:d['services']['server']['environment'].update(COLLAB_PLUGIN_DAEMON_TIMEOUT_SECONDS='3',COLLAB_SANDBOX_CONNECT_TIMEOUT_SECONDS='1',COLLAB_SANDBOX_READ_TIMEOUT_SECONDS='3',COLLAB_SANDBOX_WRITE_TIMEOUT_SECONDS='3')
 manifest.write_text(json.dumps(d));manifest.chmod(0o600)
 subprocess.run(['docker','compose','-p','winnie-runtime-check','-f',str(manifest),'--profile','runtime','up','-d','--force-recreate','--no-deps','--no-build','--pull','never','server'],check=True,stdout=subprocess.DEVNULL)
 for _ in range(100):
  try:
   with urllib.request.urlopen(s.base+'/v1/setup',timeout=2) as v:
    if v.status==200:return
  except Exception:pass
  time.sleep(.3)
 raise AssertionError('new fixture process not ready')
def refused(label,node,inputs):
 v=s.call('POST',f'/v1/apps/{app}/workflows/draft/nodes/{node}/run',{'inputs':inputs},ok=(200,400,503));(out/(label+'.json')).write_text(json.dumps(v,indent=2));assert v.get('status')!='succeeded' and (v.get('status')=='failed' or v.get('error')),v;checks.append(label);print('PASS',label,flush=True)
try:
 for label,changes,node,inputs in [
  ('daemon-unconfigured',{'COLLAB_PLUGIN_DAEMON_URL':''},'llm',{'llm.#start.q#':'hello'}),
  ('daemon-key-refused',{'COLLAB_PLUGIN_DAEMON_KEY':'fixture-invalid-key'},'llm',{'llm.#start.q#':'hello'}),
  ('daemon-unreachable',{'COLLAB_PLUGIN_DAEMON_URL':'http://plugin_daemon:9'},'llm',{'llm.#start.q#':'hello'}),
  ('sandbox-unconfigured',{'COLLAB_SANDBOX_URL':''},'python',{'python.q':'hello'}),
  ('sandbox-key-refused',{'COLLAB_SANDBOX_KEY':'fixture-invalid-key'},'python',{'python.q':'hello'}),
  ('sandbox-unreachable',{'COLLAB_SANDBOX_URL':'http://sandbox:9'},'python',{'python.q':'hello'}),
  ('proxy-unreachable',{'COLLAB_SSRF_PROXY_URL':'http://ssrf_proxy:9'},'http',{'http.#python.result#':'hello'})]:
  restart(changes);refused(label,node,inputs)
finally:restart({})
v=s.get(f'/v1/apps/{app}/workflow-runs/{run}');expected=json.loads((r/'smoke/run-detail.json').read_text());assert v==expected;checks.append('independent-process-history-identical')
(out/'result.json').write_text(json.dumps({'checks':checks,'sameDatabase':True,'sameUploads':True,'secretsKeyUnchanged':True},indent=2));print('PASS: configuration failures and independent-process history',flush=True)
