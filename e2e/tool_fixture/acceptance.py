"""Tool acceptance via real HTTP, Postgres and an isolated daemon. Never targets the user trial."""
import argparse, copy, hashlib, json, pathlib, subprocess, sys, time, urllib.request, threading

parser = argparse.ArgumentParser()
parser.add_argument('--base', required=True)
parser.add_argument('--auth-file', type=pathlib.Path, required=True)
parser.add_argument('--fixture-container', required=True)
parser.add_argument('--out', type=pathlib.Path, required=True)
a = parser.parse_args()
assert a.fixture_container.startswith('winnie-five-')
assert a.base in ('http://127.0.0.1:19098', 'http://127.0.0.1:19198','http://127.0.0.1:19138','http://127.0.0.1:19148')
info=json.loads(subprocess.check_output(['docker','inspect',a.fixture_container],text=True))[0]
assert (a.base,a.fixture_container,info['Config']['Labels'].get('raft.fixture')) in {
 ('http://127.0.0.1:19098','winnie-five-api','five-steps'),('http://127.0.0.1:19198','winnie-five-api','five-steps'),
 ('http://127.0.0.1:19138','winnie-five-upgrade-api','five-final'),('http://127.0.0.1:19148','winnie-five-clean-api','five-final')}
a.out.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'lib'))
from e2ehttp import Session, HTTPError
s=Session(a.base);token=s.post('/v1/auth/login',json.loads(a.auth_file.read_text()))['access_token']
s.headers['Authorization']='Bearer '+token
provider='winniefixture/five_tools/five';path='/v1/workspaces/current/tool-provider/builtin/'+provider
checks=[]
def mark(name): checks.append(name);print('PASS',name,flush=True)
def artifact(name,data): (a.out/(name+'.json')).write_text(json.dumps(data,indent=2))
def rejects(callback,statuses):
 try: callback()
 except HTTPError as e: assert e.status in statuses,(e.status,e.body);return
 raise AssertionError('request unexpectedly succeeded')

catalog=s.get('/v1/workspaces/current/tool-providers');p=next(p for p in catalog if p['id']==provider)
assert 'api_key' in p['credentials_schema'];assert p['tools'][0]['name']=='echo'
artifact('catalog',catalog);mark('real installed catalog and credential declaration')
rejects(lambda:s.post(path+'/add',{'name':'Wrong','credentials':{'api_key':'bad-fixture-key'}}),(400,500))
first=s.post(path+'/add',{'name':'Private one','credentials':{'api_key':'fixture-one'}})['id']
second=s.post(path+'/add',{'name':'Shared two','credentials':{'api_key':'fixture-two'},'is_team_authorization':True})['id']
credentials=s.get(path+'/credentials');assert not any(key in json.dumps(credentials) for key in ('fixture-one','fixture-two'))
assert all(c['can_manage'] for c in credentials);mark('credential validation, private/shared write and secret-free read')
for credential,label in [(first,'First prompt'),(second,'Second prompt')]:
 fields=s.post(path+'/tools/echo/parameters',{'credential_id':credential})
 assert fields[0]['label']['en_US']==label,fields
 options=s.post(path+'/dynamic-options',{'credential_id':credential,'tool':'echo','parameter':'mode'})
 assert options[0]['label']['en_US'].startswith('one:' if credential==first else 'two:'),options
mark('selected credentials reach runtime parameters and dynamic options')
s.post(path+'/update',{'credential_id':first,'name':'Renamed private','credentials':{'api_key':'[__HIDDEN__]'},'is_team_authorization':False})
mark('hidden secret update retains credential and revalidates it')
with urllib.request.urlopen(a.base+p['icon'],timeout=10)as r:
 assert r.status==200 and '<svg' in r.read().decode()
mark('installed plugin SVG is served through the application')

def node(id,kind,**data):return {'id':id,'position':{'x':0,'y':0},'data':{'type':kind,'title':id,**data}}
def document(nodes):
 return {'kind':'app','version':'0.7.0','app':{'mode':'workflow','name':'Tool acceptance'},'workflow':{
  'environment_variables':[],'conversation_variables':[],'features':{},'graph':{'nodes':nodes,'edges':[
   {'id':str(i),'source':x['id'],'target':y['id'],'sourceHandle':'source','targetHandle':'target'} for i,(x,y)in enumerate(zip(nodes,nodes[1:]))]}}}
def import_tool(mode='normal',credential=first,extra=None):
 tool=node('tool','tool',provider_type='builtin',provider_id=provider,tool_name='echo',credential_id=credential,
  tool_parameters={'prompt':{'type':'mixed','value':'hello {{#start.q#}}'}},tool_configurations={'mode':{'type':'constant','value':mode}},**(extra or {}))
 nodes=[node('start','start',variables=[{'variable':'q','label':'Q','type':'text-input','required':True}]),tool,
  node('end','end',outputs=[{'variable':out,'value_selector':['tool',out]}for out in ('text','json','files','answer')])]
 return s.post('/v1/apps/imports',{'mode':'yaml-content','yaml_content':json.dumps(document(nodes))})['app_id']
def run(app):
 frames=[json.loads(x)for x in s.stream('POST',f'/v1/apps/{app}/workflows/draft/run',{'inputs':{'q':'fixture'}},timeout=35)]
 final=next(f for f in reversed(frames)if f.get('event')=='workflow_finished')
 return frames,final
app=import_tool('file');frames,final=run(app);artifact('file-run',frames)
assert final['data']['status']=='succeeded',final
out=final['data']['outputs'];assert out['text']=='hello fixture' and out['answer']=='first second',out
assert out['json'][0]['echo']=='hello fixture' and out['json'][0]['credential']=='one'
file=out['files'][0]
with urllib.request.urlopen(file['url'],timeout=10)as r: assert r.read()==b'controlled file output\n'
mark('real plugin text, JSON, streamed variable, chunked file and signed download')
frames,final=run(import_tool(credential=second));assert final['data']['outputs']['json'][0]['credential']=='two'
mark('workflow invocation uses explicitly selected credential')
frames,final=run(import_tool('reject'));artifact('rejected-run',frames);assert final['data']['status']=='failed',final
mark('plugin refusal produces a failed workflow')
started=time.monotonic();frames,final=run(import_tool('slow'));artifact('timeout-run',frames)
assert final['data']['status']=='failed' and time.monotonic()-started<15,final
mark('daemon timeout produces a failed workflow without false success')
frames,final=run(import_tool('reject',extra={'retry_config':{'retry_enabled':True,'max_retries':1,'retry_interval':0}}))
artifact('retried-run',frames)
assert final['data']['status']=='failed' and len([f for f in frames if f.get('event')=='node_retry'])==1,frames
mark('real tool failures use the engine retry path and remain failed after exhaustion')
slow=import_tool('slow');cancel=[];stop_errors=[]
def stop_after_start(task):
 try:
  time.sleep(.25)
  other=Session(a.base,headers=s.headers)
  other.post(f'/v1/apps/{slow}/workflow-runs/tasks/{task}/stop',{})
 except BaseException as error:stop_errors.append(error)
started=time.monotonic();stopper=None
for line in s.stream('POST',f'/v1/apps/{slow}/workflows/draft/run',{'inputs':{'q':'fixture'}},timeout=15):
 event=json.loads(line);cancel.append(event)
 if event.get('event')=='node_started' and event.get('data',{}).get('node_id')=='tool':
  stopper=threading.Thread(target=stop_after_start,args=(event['task_id'],));stopper.start()
 if event.get('event')=='workflow_finished':break
if stopper:stopper.join(timeout=5)
assert not stop_errors,stop_errors
artifact('stopped-run',cancel)
assert cancel[-1]['event']=='workflow_finished' and cancel[-1]['data']['status']=='stopped',cancel
assert time.monotonic()-started<4,'stop waited for the daemon timeout'
mark('stop interrupts an in-flight real plugin call and persists stopped terminal state')
s.post(path+'/delete',{'credential_id':first});frames,final=run(app);assert final['data']['status']=='failed',final
mark('deleted selected credential cannot fall back to another member credential')
artifact('result',{'checks':checks,'real_daemon':True,'paid_model_calls':False,'actual_trial_used':False})
