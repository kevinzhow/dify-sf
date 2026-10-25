"""Real SQL/vector CRUD and SIGKILL/reclaim contract on OWN isolated fixture only."""
import argparse,fcntl,hashlib,json,os,pathlib,ssl,subprocess,sys,time,urllib.request
p=argparse.ArgumentParser();p.add_argument('--fixture-root',type=pathlib.Path,default=os.environ.get('DIFY_E2E_FIXTURE_ROOT'),required='DIFY_E2E_FIXTURE_ROOT' not in os.environ);p.add_argument('--out',type=pathlib.Path,required=True);p.add_argument('--cleanup-lock',type=pathlib.Path,default=os.environ.get('DIFY_E2E_CLEANUP_LOCK'),required='DIFY_E2E_CLEANUP_LOCK' not in os.environ);p.add_argument('--restart-suffix',default='index-restart');a=p.parse_args();assert a.restart_suffix.replace('-','').isalnum();a.out.mkdir(parents=True,exist_ok=True)
f=a.fixture_root.resolve();private=f/'private-fixture';info=json.loads((f/'d/fixture.json').read_text());data=json.loads((private/'helper-fixture.json').read_text())
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]));sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'lib'))
from lib.e2ehttp import Session,HTTPError
from lib.dify import STUB_PROVIDER
name='winnie-five-helper-api'
def command(args):return subprocess.check_output(args,text=True).strip()
def inspect():return json.loads(command(['docker','inspect',name]))[0]
old=inspect();assert old['Id']==info['api'] and old['Config']['Labels']['raft.fixture']=='five-helper'
def session(token):
 s=Session('https://127.0.0.1:19228',timeout=180);s.opener=urllib.request.build_opener(urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),urllib.request.HTTPCookieProcessor(s.jar));s.headers['Authorization']='Bearer '+token;return s
s=session(data['owner_token']);public=session(data['key']);origin=Session('http://127.0.0.1:19122');app=data['apps']['chat'];path='/v1/apps/'+app
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def log():return origin.get('/stub/log')['requests']
def reset():origin.post('/stub/reset',{})
def run(query,client=public):return client.post('/v1/chat-messages',{'query':query,'inputs':{},'response_mode':'blocking','user':'boundary-user'})
def index(appid=app):
 assert len(appid)==36 and all(c in '0123456789abcdef-'for c in appid)
 text=command(['docker','exec','winnie-five-tests-pg','psql','-U','collab','-d','five_helper','-Atc',"SELECT row_to_json(i) FROM app_annotation_indexes i WHERE doc_id='"+appid+"'"])
 return json.loads(text)if text else None
settings={'score_threshold':.9,'embedding_provider_name':STUB_PROVIDER,'embedding_model_name':'fixture-embed'}
def enable(model='fixture-embed'):return s.post(path+'/annotation-reply/enable',{**settings,'embedding_model_name':model})['job_id']
def wait_ready(timeout=55):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  row=index()
  if row and row['status']=='completed':return row
  if row and row['status']=='error':raise AssertionError('Real vector/index job failed')
  time.sleep(.3)
 raise AssertionError('Index never ready')
origin.post('/stub/modes',{});origin.post('/stub/script',{'rules':[{'match':'','reply':'normal model fallback'}]})
# Re-runnable preparation uses only the fixture's real public management APIs.
s.call('DELETE',path+'/annotations');s.post(path+'/annotations',{'question':'Fruit question','answer':'Curated fruit answer'});enable();wait_ready()
annotation=s.get(path+'/annotations')['data'][0];aid=annotation['id'];before=index();reset()
s.post(path+'/annotations/'+aid,{'question':'Fruit question','answer':'Fresh edited answer'})
assert index()['generation']==before['generation'];assert run('Same intent paraphrase')['answer']=='Fresh edited answer'
emb=[x for x in log()if x['path']=='/v1/embeddings'];assert len(emb)==1 and all('Fruit question'not in x['body'].get('input',[])for x in emb)
passed('answer-edit-uses-fresh-SQL-without-reembedding')
origin.post('/stub/modes',{'embeddingDelay':1});s.post(path+'/annotations/'+aid,{'question':'Other question','answer':'Other answer'})
after=index();assert after['generation']!=before['generation'] and after['status']in ['waiting','processing'];assert not s.get(path+'/annotation-setting')['enabled']
wait_ready();origin.post('/stub/modes',{});reset();assert run('Fruit question')['answer']=='normal model fallback';assert run('Other question')['answer']=='Other answer'
passed('question-edit-invalidates-immediately-and-rebuilds-semantic-match')
reset();generation=index()['generation'];job=enable('fixture-embed-two');rebuilt=wait_ready();assert rebuilt['generation']!=generation and rebuilt['model']=='fixture-embed-two'
assert any(x['path']=='/v1/embeddings'and x['body']['model']=='fixture-embed-two'for x in log())
assert run('Other question')['answer']=='Other answer';assert s.get(path+'/annotation-reply/enable/status/'+job)['job_status']=='completed'
passed('model-change-reembeds-through-real-plugin-before-ready')
# A second published app uses its own collection, answer, API key and history.
import yaml
source=yaml.safe_load(s.get(path+'/export')['data']);source['app']['name']='Other annotation scope';second=s.post('/v1/apps/imports',{'mode':'yaml-content','yaml_content':json.dumps(source)})['app_id']
s.post('/v1/apps/'+second+'/workflows/publish',{});otherkey=s.post('/v1/apps/'+second+'/api-keys',{})['token'];other=session(otherkey)
a2=s.post('/v1/apps/'+second+'/annotations',{'question':'Other question','answer':'Second app only'})['id'];s.post('/v1/apps/'+second+'/annotation-reply/enable',settings)
for _ in range(200):
 if s.get('/v1/apps/'+second+'/annotation-setting')['enabled']:break
 time.sleep(.3)
else:raise AssertionError('Second app index not ready')
assert run('Other question',other)['answer']=='Second app only';assert run('Other question')['answer']=='Other answer'
try:s.get('/v1/apps/'+second+'/annotations/'+aid+'/hit-histories')
except HTTPError as error:assert error.status==404
else:raise AssertionError('Foreign app annotation history must be hidden')
passed('second-app-collection-key-answer-and-hit-history-isolation')
assert s.get(path+'/annotations/'+aid+'/hit-histories')['total']>=1
s.call('DELETE',path+'/annotations/'+aid)
assert command(['docker','exec','winnie-five-tests-pg','psql','-U','collab','-d','five_helper','-Atc',"SELECT count(*) FROM app_annotation_hits WHERE doc_id='"+app+"' AND annotation_id='"+aid+"'"])=='0'
try:s.get(path+'/annotations/'+aid+'/hit-histories')
except HTTPError as error:assert error.status==404
else:raise AssertionError('Deleted annotation must be hidden')
wait_ready();assert run('Other question')['answer']=='normal model fallback'
passed('delete-removes-hit-history-and-stale-vector-cannot-answer')
# Keep an observable processing lease across TWO real container processes and the genuine 120s expiry.
origin.post('/stub/modes',{'embeddingDelay':10});reset();aid=s.post(path+'/annotations',{'question':'Fruit question','answer':'After process restart'})['id'];enable('fixture-embed')
end=time.monotonic()+45
while time.monotonic()<end:
 pending=index()
 if pending and pending['status']=='processing'and any(x['path']=='/v1/embeddings'for x in log()):break
 time.sleep(.2)
else:raise AssertionError('Did not enter delayed real embedding request')
old=inspect();assert old['Config']['Labels']['raft.fixture']=='five-helper';start=time.monotonic()
with a.cleanup_lock.open('a')as lock:
 fcntl.flock(lock,fcntl.LOCK_EX);command(['docker','kill','--signal','KILL',name]);command(['docker','rename',name,name+'-before-'+a.restart_suffix]);origin.post('/stub/modes',{});newid=command(info['apiArgs'])
for _ in range(200):
 try:urllib.request.urlopen('http://127.0.0.1:19128/healthz',timeout=2);break
 except OSError:time.sleep(.25)
else:raise AssertionError('New process health failed')
new=inspect();assert old['Id']!=new['Id']and old['State']['Pid']!=new['State']['Pid'];assert old['Config']['Env']==new['Config']['Env'];assert old['Mounts']==new['Mounts']
assert index()['status']=='processing','New process must not steal an unexpired lease'
resumed=wait_ready(160);elapsed=time.monotonic()-start;assert elapsed>90 and resumed['generation']==pending['generation']
reset();assert run('Same intent paraphrase')['answer']=='After process restart';assert not any(x['path']=='/v1/chat/completions'for x in log())
info['api']=newid;(f/'d/fixture.json').write_text(json.dumps(info,indent=2));data['restart_annotation']=aid;data['second_app']=second
with (private/'helper-fixture.json').open('w')as out:os.chmod(out.fileno(),0o600);json.dump(data,out)
(a.out/'restart.json').write_text(json.dumps({'oldContainer':old['Id'],'newContainer':new['Id'],'oldPID':old['State']['Pid'],'newPID':new['State']['Pid'],'sameDBEnvAndMounts':True,'realLeaseSeconds':120,'elapsed':elapsed,'generationRecovered':resumed['generation']==pending['generation'],'actualTrialChanged':False},indent=2))
passed('SIGKILL-independent-process-same-database-genuine-lease-reclaim-and-answer')
(a.out/'result.json').write_text(json.dumps({'checks':checks,'actualTrialChanged':False,'paidCalls':False},indent=2))
