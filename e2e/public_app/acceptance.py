"""Published runtime through real HTTPS, Postgres and signed model plugin.

Only the named throwaway fixture is accepted. No user deployment or paid model is used.
"""
import argparse,copy,json,os,pathlib,ssl,subprocess,sys,time,urllib.request,uuid
p=argparse.ArgumentParser();p.add_argument('--base',required=True);p.add_argument('--out',type=pathlib.Path,required=True);p.add_argument('--private',type=pathlib.Path,required=True);a=p.parse_args()
assert a.base=='https://127.0.0.1:19208'
info=json.loads(subprocess.check_output(['docker','inspect','winnie-five-public-api'],text=True))[0]
assert info['Config']['Labels'].get('raft.fixture')=='five-public'
a.out.mkdir(parents=True,exist_ok=True);a.private.mkdir(parents=True,exist_ok=True,mode=0o700)
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]));sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'lib'))
from lib.e2ehttp import Session,HTTPError
from lib.dify import STUB_PROVIDER,stub_credentials
from runtime_files.acceptance_support import node,workflow

def session(token=None,code=None):
 s=Session(a.base,timeout=90);s.opener=urllib.request.build_opener(urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),urllib.request.HTTPCookieProcessor(s.jar))
 if token:s.headers['Authorization']='Bearer '+token
 if code:s.headers['X-App-Code']=code
 return s
s=session();auth={'email':'public-five@example.com','password':'PublicFiveFixture#2026'}
if s.get('/v1/setup').get('step')!='finished':s.post('/v1/setup',{**auth,'name':'Public fixture owner'})
with (a.private/'public-auth.json').open('w')as f:os.chmod(f.fileno(),0o600);json.dump(auth,f)
s.headers['Authorization']='Bearer '+s.post('/v1/auth/login',auth)['access_token']
try:s.post(f'/v1/workspace/model-providers/{STUB_PROVIDER}/models/credentials',{'model':'stub-chat','model_type':'llm','credentials':stub_credentials('http://winnie-five-local-model:8000/v1')})
except HTTPError as e:
 if e.status!=409:raise
stub=Session('http://127.0.0.1:19112');checks=[];fixture={}
def mark(name):checks.append(name);print('PASS',name,flush=True)
def save(name,value):(a.out/(name+'.json')).write_text(json.dumps(value,indent=2,ensure_ascii=False))
def reject(fn,status):
 try:fn()
 except HTTPError as e:assert e.status==status,(e.status,e.body);return
 raise AssertionError('Expected '+str(status))
def create(doc,label):
 app=s.post('/v1/apps/imports',{'mode':'yaml-content','yaml_content':json.dumps(doc)})['app_id']
 s.post(f'/v1/apps/{app}/workflows/publish',{})
 key=s.post(f'/v1/apps/{app}/api-keys',{})
 detail=s.get(f'/v1/apps/{app}');code=detail['site']['code']
 fixture[label]={'app':app,'code':code,'key':key['token'],'key_id':key['id']}
 return app,key['token'],code
model={'provider':STUB_PROVIDER,'name':'stub-chat','mode':'chat','completion_params':{'max_tokens':128}}
def llm(prompt):return node('llm','llm',model=model,prompt_template=[{'role':'user','text':prompt}],context={'enabled':False,'variable_selector':[]},vision={'enabled':False})
def run(client,body,chat=False):return client.post('/v1/chat-messages'if chat else'/v1/workflows/run',{'inputs':{},'response_mode':'blocking',**body})
def events(client,path,body=None):return [json.loads(line)for line in client.stream('POST'if body is not None else'GET',path,body)]
def final(fs):return next(f['data']for f in reversed(fs)if f.get('event')=='workflow_finished')
# This endpoint never accepts the owner's console session.
reject(lambda:run(s,{'user':'alice'}),401)
app,key,code=create(workflow([node('start','start',variables=[{'type':'text-input','variable':'q','label':'Question','required':True}]),llm('{{#start.q#}}'),node('end','end',outputs=[{'variable':'text','value_selector':['llm','text']}])],name='Published model fixture'),'workflow')
alice=session(key);bob=session(key);stub.post('/stub/script',{'rules':[{'match':'','reply':'published model answer'}]});stub.post('/stub/reset',{})
one=run(alice,{'inputs':{'q':'published input'},'user':'alice'});assert one['data']['status']=='succeeded',one
assert one['data']['outputs']['text']=='published model answer';assert len(stub.get('/stub/log')['requests'])==1
assert one['data']['total_tokens']>0;rid=one['workflow_run_id'];save('blocking',one)
reject(lambda:bob.get(f'/v1/workflows/run/{rid}?user=bob'),404)
reject(lambda:bob.get(f'/v1/workflow/{rid}/events?user=bob'),404)
assert alice.get(f'/v1/workflows/run/{rid}?user=alice')['status']=='succeeded'
fs=events(alice,'/v1/workflows/run',{'inputs':{'q':'stream input'},'user':'alice','response_mode':'streaming'});assert final(fs)['status']=='succeeded';save('streaming',fs)
assert not any('public-five@example.com'in json.dumps(f)for f in fs);mark('blocking and streaming execute the signed plugin; end-user isolation and no owner email')
# Draft changes have no effect until explicitly published.
client=s.post(f'/v1/docs/{app}/clients',{})['client']
s.post(f'/v1/docs/{app}/ops',{'client':client,'ops':[{'cseq':1,'base':0,'op':{'t':'setField','node':'end','field':{'k':'config','path':['outputs']},'value':[{'variable':'after','value_selector':['llm','text']}]}}]})
assert 'text'in run(alice,{'inputs':{'q':'old revision'},'user':'alice'})['data']['outputs']
s.post(f'/v1/apps/{app}/workflows/publish',{})
assert 'after'in run(alice,{'inputs':{'q':'new revision'},'user':'bob'})['data']['outputs']
assert alice.get(f'/v1/workflows/run/{rid}?user=alice')['outputs']==one['data']['outputs'];mark('public runs bind immutable revisions across draft edits and republishing')
# Two browser passports remain distinct and cannot authenticate to console.
visitor=session(code=code);passport=visitor.get('/v1/passport')['access_token'];visitor=session(passport,code)
other=session(code=code);other=session(other.get('/v1/passport')['access_token'],code)
reject(lambda:visitor.get('/v1/account'),401)
web=run(visitor,{'inputs':{'q':'web visitor'}})
reject(lambda:other.get('/v1/workflows/run/'+web['workflow_run_id']),404)
assert visitor.get('/v1/site')['title']=='Published model fixture';mark('independent opaque web passports have no console authority')
# Chatflow uses real model history and parent linkage.
ll=llm('Answer the current query');ll['data']['memory']={'window':{'enabled':True,'size':10},'query_prompt_template':'{{#sys.query#}}'}
doc=workflow([node('start','start',variables=[]),ll,node('answer','answer',answer='{{#llm.text#}}')],name='Published chat fixture');doc['app']['mode']='advanced-chat'
chat,chatkey,chatcode=create(doc,'chat');cs=session(chatkey)
stub.post('/stub/script',{'rules':[{'match':'first public','reply':'first reply'},{'match':'','reply':'second reply'}]});stub.post('/stub/reset',{})
c1=run(cs,{'query':'first public','user':'alice'},True);assert c1['answer']=='first reply',c1
cid=c1['conversation_id'];mid=c1['message_id']
stub.post('/stub/reset',{})
c2=run(cs,{'query':'second public','user':'alice','conversation_id':cid,'parent_message_id':mid},True);assert c2['answer']=='second reply',c2
requests=stub.get('/stub/log')['requests'];assert len(requests)==1
messages=requests[0]['body']['messages'];assert [m['role']for m in messages]==['user','user','assistant','user'],messages
assert messages[-3]['content']=='first public'and messages[-2]['content']=='first reply'
assert len(cs.get('/v1/messages?conversation_id='+cid+'&user=alice')['data'])==2
reject(lambda:cs.get('/v1/messages?conversation_id='+cid+'&user=bob'),404)
assert cs.get('/v1/conversations?user=bob')['data']==[]
reject(lambda:run(cs,{'query':'foreign','user':'bob','conversation_id':cid},True),404)
save('chat-history-request',messages);mark('real second-turn model memory, durable history and foreign conversation rejection')
stub.post('/stub/script',{'rules':[{'match':'','status':400,'error':'controlled public blocking refusal'}]})
reject(lambda:run(cs,{'query':'failed public blocking request','user':'alice','conversation_id':cid,'parent_message_id':c2['message_id']},True),400)
mark('a real signed-plugin refusal in blocking chat returns an error instead of an empty successful message')

# Files and forms use the same published user, including after a new server process.
fdoc=workflow([node('start','start',variables=[{'type':'file','variable':'attachment','label':'Attachment','required':True}]),node('end','end',outputs=[{'variable':'file','value_selector':['start','attachment']}])],name='Published files fixture')
fapp,fkey,fcode=create(fdoc,'files');fc=session(fkey)
upload=fc.multipart('/v1/files/upload',{'user':'alice'},{'file':('public.txt',b'public isolated file')})
file={'type':'document','transfer_method':'local_file','upload_file_id':upload['id']}
r=run(fc,{'inputs':{'attachment':file},'user':'alice'});assert r['data']['status']=='succeeded',r
assert fc.get('/v1/files/'+upload['id']+'/preview?user=alice')['content']=='public isolated file'
reject(lambda:fc.get('/v1/files/'+upload['id']+'/preview?user=bob'),404)
reject(lambda:run(fc,{'inputs':{'attachment':file},'user':'bob'}),400)
mark('uploaded file references and text preview are scoped to the public end user')
hdoc=workflow([node('start','start',variables=[]),llm('before public pause'),node('human','human-input',form_content='Please approve {{#$output.reply#}}',inputs=[{'type':'paragraph','output_variable_name':'reply'}],user_actions=[{'id':'approve','title':'Approve it','button_style':'primary'}],delivery_methods=[{'type':'webapp','enabled':True}]),node('end','end',outputs=[{'variable':'reply','value_selector':['human','reply']}])],edges=[('start','source','llm'),('llm','source','human'),('human','approve','end')],name='Published approval fixture')
happ,hkey,hcode=create(hdoc,'human');hc=session(hkey);stub.post('/stub/script',{'rules':[{'match':'','reply':'before public approval'}]});stub.post('/stub/reset',{})
paused=run(hc,{'user':'alice'});assert paused['data']['status']=='paused',paused
hrun=paused['workflow_run_id'];replay=events(hc,f'/v1/workflow/{hrun}/events?user=alice&include_state_snapshot=true')
form=next(f['data']for f in replay if f['event']=='human_input_required');ft=form['form_token'];assert form['display_in_ui']is True
reject(lambda:hc.get(f'/v1/form/human_input/{ft}?user=bob'),404)
reject(lambda:s.get(f'/v1/form/human_input/{ft}'),404)
assert len(stub.get('/stub/log')['requests'])==1
fixture['paused']={'run':hrun,'form':ft,'key':hkey,'user':'alice'}
# Persist fixture-only credentials for the browser/restart checks; never attach this file.
with(a.private/'public-fixture.json').open('w')as f:os.chmod(f.fileno(),0o600);json.dump(fixture,f,indent=2)
mark('published human-input pause and private form identity before independent-process restart')
logs=s.get(f'/v1/apps/{app}/workflow-app-logs?limit=2');assert logs['total']==5,logs
stats=s.get(f'/v1/apps/{app}/workflow/statistics/token-costs');assert sum(x['token_count']for x in stats['data'])>0
assert all(x['workflow_run']['total_tokens']>0 for x in logs['data']);save('logs',logs);save('token-statistics',stats)
mark('monitoring reads real persisted published runs and signed-plugin token usage')
save('result',{'checks':checks,'realDaemon':True,'HTTPS':'self-signed isolated localhost fixture','actualTrialUsed':False,'paidModelCalls':False})
