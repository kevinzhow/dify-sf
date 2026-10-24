"""Revocation and nested-tool files through the isolated HTTPS public fixture."""
import argparse,json,pathlib,ssl,sys,urllib.request,uuid,subprocess
p=argparse.ArgumentParser();p.add_argument('--base',required=True);p.add_argument('--private',type=pathlib.Path,required=True);p.add_argument('--out',type=pathlib.Path,required=True);p.add_argument('--fixture-container',default='winnie-five-public-api');a=p.parse_args();a.out.mkdir(exist_ok=True,parents=True)
info=json.loads(subprocess.check_output(['docker','inspect',a.fixture_container],text=True))[0]
assert (a.base,a.fixture_container,info['Config']['Labels'].get('raft.fixture'))in {('https://127.0.0.1:19208','winnie-five-public-api','five-public'),('http://127.0.0.1:19138','winnie-five-upgrade-api','five-final'),('http://127.0.0.1:19148','winnie-five-clean-api','five-final')}
sys.path[:0]=[str(pathlib.Path(__file__).resolve().parents[1]),str(pathlib.Path(__file__).resolve().parents[1]/'lib')]
from e2ehttp import Session,HTTPError
from runtime_files.acceptance_support import node,workflow

def session(token=None,code=None):
 s=Session(a.base,headers={}if token is None else{'Authorization':'Bearer '+token});s.opener=urllib.request.build_opener(urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
 if code:s.headers['X-App-Code']=code
 return s
s=session();s.headers['Authorization']='Bearer '+s.post('/v1/auth/login',json.loads((a.private/'public-auth.json').read_text()))['access_token'];checks=[]
def mark(t):checks.append(t);print('PASS',t,flush=True)
def reject(fn,code):
 try:fn()
 except HTTPError as e:assert e.status==code,(e.status,e.body);return
 raise AssertionError('Expected '+str(code))
def create(doc):
 app=s.post('/v1/apps/imports',{'mode':'yaml-content','yaml_content':json.dumps(doc)})['app_id'];s.post(f'/v1/apps/{app}/workflows/publish',{});return app
start=node('start','start',variables=[{'variable':'q','type':'text-input','label':'Q','required':True}]);end=node('end','end',outputs=[{'variable':'q','value_selector':['start','q']}]);app=create(workflow([start,end],name='Revocation fixture'))
ka=s.post(f'/v1/apps/{app}/api-keys',{});kb=s.post(f'/v1/apps/{app}/api-keys',{});sa,sb=session(ka['token']),session(kb['token'])
def run(c,user='same',inputs=None):return c.post('/v1/workflows/run',{'user':user,'inputs':inputs or{'q':'fixture'},'response_mode':'blocking'})
r=run(sa);rid=r['workflow_run_id'];reject(lambda:sb.get('/v1/workflows/run/'+rid+'?user=same'),404)
reject(lambda:session('wrong-key').get('/v1/workflows/run/'+rid+'?user=same'),401)
s.post(f'/v1/apps/{app}/api-enable',{'enable_api':False});reject(lambda:run(sa),401)
s.post(f'/v1/apps/{app}/api-enable',{'enable_api':True});assert run(sb)['data']['status']=='succeeded'
s.delete(f'/v1/apps/{app}/api-keys/'+ka['id']);reject(lambda:sa.get('/v1/workflows/run/'+rid+'?user=same'),401)
assert sb.get('/v1/conversations?user=same')['data']==[];mark('two API keys, wrong key, disable/re-enable and deleted key obey live authorization')
code=s.get(f'/v1/apps/{app}')['site']['code'];v=session(code=code);passport=v.get('/v1/passport')['access_token'];v=session(passport,code)
s.post(f'/v1/apps/{app}/site-enable',{'enable_site':False});reject(lambda:run(v),401);reject(lambda:session(code=code).get('/v1/passport'),404)
s.post(f'/v1/apps/{app}/site-enable',{'enable_site':True});assert run(v)['data']['status']=='succeeded'
s.post(f'/v1/apps/{app}/site/access-token-reset',{});reject(lambda:run(v),401);reject(lambda:session(code=code).get('/v1/passport'),404);mark('site disable and code rotation revoke stored browser passports')
# Controlled tool in this fixture database, executed through the real daemon.
provider='winniefixture/five_tools/five';existing=s.get('/v1/workspaces/current/tool-provider/builtin/'+provider+'/credentials');credential=next((c['id']for c in existing if c['name']=='Public nested fixture'),None)
if credential is None:credential=s.post('/v1/workspaces/current/tool-provider/builtin/'+provider+'/add',{'name':'Public nested fixture','credentials':{'api_key':'fixture-two'}})['id']
tool=node('plugin','tool',provider_type='builtin',provider_id=provider,tool_name='echo',credential_id=credential,tool_parameters={'prompt':{'type':'mixed','value':'public nested file'}},tool_configurations={'mode':{'type':'constant','value':'file'}})
child=create(workflow([node('start','start',variables=[]),tool,node('end','end',outputs=[{'variable':'assets','value_selector':['plugin','files']}])],name='Public tool child'))
name='public_file_'+uuid.uuid4().hex[:8];definition=s.post('/v1/workspaces/current/tool-provider/workflow/create',{'workflow_app_id':child,'name':name,'label':'Public file child','description':'Controlled nested file fixture','parameters':[]})
parent=create(workflow([node('start','start',variables=[{'variable':'attachment','type':'file','label':'Attachment','required':False}]),node('child','tool',provider_type='workflow',provider_id=definition['id'],tool_name=name,tool_parameters={},tool_configurations={}),node('end','end',outputs=[{'variable':'assets','value_selector':['child','assets']}])],name='Public nested file fixture'))
key=s.post(f'/v1/apps/{parent}/api-keys',{})['token'];pc=session(key)
r=pc.post('/v1/workflows/run',{'user':'alice','inputs':{},'response_mode':'blocking'});assert r['data']['status']=='succeeded',r
file=r['data']['outputs']['assets'][0]
with pc.opener.open(file['url'])as response:assert response.read()==b'controlled file output\n'
reject(lambda:pc.post('/v1/workflows/run',{'user':'bob','inputs':{'attachment':file},'response_mode':'blocking'}),400)
assert s.get(f'/v1/apps/{parent}/workflow-app-logs')['total']==1
assert s.get(f'/v1/apps/{child}/workflow-app-logs')['total']==0
mark('nested workflow tool generates real signed file; another user cannot reuse it and child traces do not inflate published logs')

chatdoc=workflow([node('start','start',variables=[{'variable':'attachment','type':'file','required':True}]),node('answer','answer',answer='{{#start.attachment#}}')],name='Published chat files');chatdoc['app']['mode']='advanced-chat'
chat=create(chatdoc);chatkey=s.post(f'/v1/apps/{chat}/api-keys',{})['token'];cc=session(chatkey)
u=cc.multipart('/v1/files/upload',{'user':'alice'},{'file':('chat-output.txt',b'published chat file bytes')})
body={'query':'show file','user':'alice','inputs':{'attachment':{'type':'document','transfer_method':'local_file','upload_file_id':u['id']}},'response_mode':'streaming'}
frames=[json.loads(x)for x in cc.stream('POST','/v1/chat-messages',body)]
end=frames[-1];assert end['event']=='message_end' and end['files'][0]['url'],end
with cc.opener.open(end['files'][0]['url'])as response:assert response.read()==b'published chat file bytes'
cid=frames[0]['conversation_id'];runid=frames[0]['workflow_run_id']
assert cc.get('/v1/messages?user=alice&conversation_id='+cid)['data'][0]['files'][0]['url']
replay=[json.loads(x)for x in cc.stream('GET',f'/v1/workflow/{runid}/events?user=alice&include_state_snapshot=true')]
assert replay[-1]['files'][0]['url']
body['response_mode']='blocking';blocked=cc.post('/v1/chat-messages',body);assert blocked['files'][0]['url'],blocked
with cc.opener.open(blocked['files'][0]['url'])as response:assert response.read()==b'published chat file bytes'
body['user']='bob';reject(lambda:cc.post('/v1/chat-messages',body),400)
mark('public Chatflow files remain downloadable in live/message-end, blocking, history and reconnect, with foreign ownership rejected')
hdoc=workflow([node('start','start',variables=[]),node('human','human-input',form_content='Approve {{#$output.reply#}}',inputs=[{'type':'paragraph','output_variable_name':'reply'}],user_actions=[{'id':'approve','title':'Approve','button_style':'primary'}],delivery_methods=[{'type':'webapp','enabled':True}]),node('answer','answer',answer='{{#human.reply#}}')],edges=[('start','source','human'),('human','approve','answer')],name='Published chat approval');hdoc['app']['mode']='advanced-chat'
ha=create(hdoc);hk=s.post(f'/v1/apps/{ha}/api-keys',{})['token'];hc=session(hk)
paused=hc.post('/v1/chat-messages',{'query':'approval','inputs':{},'user':'alice','response_mode':'blocking'})
assert paused['event']=='workflow_paused'and paused['data']['status']=='paused'and paused['workflow_run_id']==paused['data']['workflow_run_id'],paused
hr=paused['workflow_run_id'];stream=[json.loads(x)for x in hc.stream('GET',f'/v1/workflow/{hr}/events?user=alice&include_state_snapshot=true')]
form=next(x['data']['form_token']for x in stream if x['event']=='human_input_required')
hc.post('/v1/form/human_input/'+form,{'user':'alice','inputs':{'reply':'public chat approved'},'action':'approve'})
import time
for _ in range(100):
 result=hc.get('/v1/workflows/run/'+hr+'?user=alice')
 if result['status']=='succeeded':break
 time.sleep(.05)
assert result['status']=='succeeded',result
assert hc.get('/v1/messages?user=alice&conversation_id='+paused['conversation_id'])['data'][0]['answer']=='public chat approved'
mark('blocking Chatflow pause preserves the original message envelope and resumes its durable public answer')

# Ownership is checked again on stop; the owner can interrupt an actual in-flight plugin invocation.
import threading
slow=create(workflow([node('start','start',variables=[]),node('plugin','tool',provider_type='builtin',provider_id=provider,tool_name='echo',credential_id=credential,tool_parameters={'prompt':{'type':'mixed','value':'controlled public stop'}},tool_configurations={'mode':{'type':'constant','value':'slow'}}),node('end','end',outputs=[{'variable':'result','value_selector':['plugin','text']}])],name='Published cancellation fixture'))
sk=s.post(f'/v1/apps/{slow}/api-keys',{})['token'];sc=session(sk);failures=[];stopper=None;frames=[]
def stop_public(run):
 try:
  time.sleep(.25);other=session(sk)
  reject(lambda:other.post('/v1/workflows/tasks/'+run+'/stop',{'user':'bob'}),404)
  other.post('/v1/workflows/tasks/'+run+'/stop',{'user':'alice'})
 except BaseException as e:failures.append(str(e))
began=time.monotonic()
for line in sc.stream('POST','/v1/workflows/run',{'user':'alice','inputs':{},'response_mode':'streaming'},timeout=15):
 frame=json.loads(line);frames.append(frame)
 if frame.get('event')=='node_started'and frame.get('data',{}).get('node_id')=='plugin':
  stopper=threading.Thread(target=stop_public,args=(frame['task_id'],));stopper.start()
 if frame.get('event')=='workflow_finished':break
if stopper:stopper.join(timeout=5)
assert not failures,failures
assert frames[-1]['data']['status']=='stopped'and time.monotonic()-began<4,frames
assert sc.get('/v1/workflows/run/'+frames[-1]['workflow_run_id']+'?user=alice')['status']=='stopped'
mark('the owning public user cancels a real in-flight plugin call; a foreign user cannot stop it and stopped state persists')
(a.out/'result.json').write_text(json.dumps({'checks':checks,'actualTrialUsed':False,'paidModelCalls':False,'realDaemon':True},indent=2))
