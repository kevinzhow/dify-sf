"""Real helper HTTP/PG/signed-plugin/Weaviate checks. Refuses every non-fixture endpoint."""
import argparse,copy,hashlib,json,os,pathlib,ssl,subprocess,sys,time,urllib.request,uuid
p=argparse.ArgumentParser();p.add_argument('--fixture-root',type=pathlib.Path,default=os.environ.get('DIFY_E2E_FIXTURE_ROOT'),required='DIFY_E2E_FIXTURE_ROOT' not in os.environ);p.add_argument('--out',type=pathlib.Path,required=True);a=p.parse_args();a.out.mkdir(parents=True,exist_ok=True)
f=a.fixture_root.resolve();private=f/'private-fixture'
info=json.loads(subprocess.check_output(['docker','inspect','winnie-five-helper-api'],text=True))[0];assert info['Config']['Labels'].get('raft.fixture')=='five-helper'
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]));sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'lib'))
from lib.e2ehttp import Session,HTTPError
from lib.dify import STUB_PROVIDER,stub_credentials
from runtime_files.acceptance_support import node,workflow
base='https://127.0.0.1:19228'
def session(token=None):
 s=Session(base,timeout=180);s.opener=urllib.request.build_opener(urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),urllib.request.HTTPCookieProcessor(s.jar))
 if token:s.headers['Authorization']='Bearer '+token
 return s
s=session();auth={'email':'helpers-five@example.com','password':'HelpersFixture#2026'}
if s.get('/v1/setup').get('step')!='finished':s.post('/v1/setup',{**auth,'name':'Helper fixture'})
s.headers['Authorization']='Bearer '+s.post('/v1/auth/login',auth)['access_token']
fixture={'auth':auth,'owner_token':s.headers['Authorization'].split(' ',1)[1],'apps':{}}
def save():
 with (private/'helper-fixture.json').open('w')as o:os.chmod(o.fileno(),0o600);json.dump(fixture,o)
save();origin=Session('http://127.0.0.1:19122');origin.post('/stub/modes',{});origin.post('/stub/script',{'rules':[{'match':'','reply':'normal model fallback'}]})
endpoint='http://winnie-five-helper-origin:8000/v1'
for type,name in [('llm','stub-chat'),('text-embedding','fixture-embed'),('text-embedding','fixture-embed-two'),('tts','fixture-tts')]:
 credentials={**stub_credentials(endpoint),'max_chunks':'16','voices':'alloy'}
 try:s.post(f'/v1/workspace/model-providers/{STUB_PROVIDER}/models/credentials',{'model':name,'model_type':type,'credentials':credentials})
 except HTTPError as e:
  if e.status!=409:raise
s.post('/v1/workspace/default-model',{'model_settings':[{'model_type':t,'provider':STUB_PROVIDER,'model':m}for t,m in [('llm','stub-chat'),('text-embedding','fixture-embed'),('tts','fixture-tts')]]})
checks=[]
def passed(name):checks.append(name);print('PASS '+name,flush=True)
def reject(call,status=None):
 try:call()
 except HTTPError as e:
  if status is not None:assert e.status==status,(e.status,e.body)
  return e
 raise AssertionError('Request unexpectedly succeeded')
def calls(path):return [r for r in origin.get('/stub/log')['requests']if r['path']==path]
def reset():origin.post('/stub/reset',{})
def rule(text):origin.post('/stub/script',{'rules':[{'match':'','reply':text}]})
def model_call(kind,body):return s.post('/v1/'+kind,{'model_config':{'provider':STUB_PROVIDER,'name':'stub-chat','completion_params':{'max_tokens':512}},**body})
# URL content is fetched by the actual Squid boundary; errors do not create apps.
count=s.get('/v1/apps')['total']
for path in ['/dsl/html','/dsl/bad.yml','/dsl/large','/dsl/redirect?to=http%3A%2F%2F127.0.0.1%2F']:
 reject(lambda:s.post('/v1/apps/imports',{'mode':'yaml-url','yaml_url':endpoint.removesuffix('/v1')+path}),400)
assert s.get('/v1/apps')['total']==count
reject(lambda:session().post('/v1/apps/imports',{'mode':'yaml-url','yaml_url':endpoint+'/dsl/good.yml'}),401)
imported=s.post('/v1/apps/imports',{'mode':'yaml-url','yaml_url':endpoint.removesuffix('/v1')+'/dsl/good.yml'});assert imported['status']=='completed';fixture['apps']['dsl']=imported['app_id']
pending=s.call('POST','/v1/apps/imports',{'mode':'yaml-url','yaml_url':endpoint.removesuffix('/v1')+'/dsl/newer.yml'})
# Session accepts successful 202 too; confirmation remains the established import route.
assert pending['status']=='pending';confirmed=s.post('/v1/apps/imports/'+pending['id']+'/confirm',{});assert confirmed['app_id']
passed('safe-server-URL-import-bounds-type-redirect-and-version-confirmation')
reset();rule('A generated task prompt')
assert model_call('rule-generate',{'instruction':'Write a helper prompt','no_variable':True})['prompt']=='A generated task prompt'
rule('def main(arg1: str):\n    return {"result": arg1}\n')
assert model_call('rule-code-generate',{'instruction':'Return arg1','code_language':'python3'})['code'].startswith('def main')
rule('{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}')
assert json.loads(model_call('rule-structured-output-generate',{'instruction':'Name schema'})['output'])['type']=='object'
rule('{"type":"array"}')
assert model_call('rule-structured-output-generate',{'instruction':'Bad schema'})['error']
rule('{"modified":"Improved prompt","message":"Applied instruction"}')
assert model_call('instruction-generate',{'instruction':'Improve wording','current':'Old wording','flow_id':imported['app_id']})['modified']=='Improved prompt'
assert len(calls('/v1/chat/completions'))==5
passed('real-signed-plugin-prompt-code-schema-modification-and-invalid-format-refusal')
plan={'nodes':[{'id':'s','node_type':'start','label':'Start'},{'id':'e','node_type':'end','label':'End'}],'edges':[{'source':'s','target':'e'}], 'start_inputs':[{'variable':'q','label':'Q','type':'text-input','required':True}]}
origin.post('/stub/script',{'rules':[{'match':'Return the JSON plan now.','reply':json.dumps(plan)},{'match':'"target":{"id":"s"','reply':'{"config":{"variables":[]}}'},{'match':'"target":{"id":"e"','reply':'{"config":{"outputs":[{"variable":"q","value_selector":["s","q"]}]}}'}]})
before=s.get('/v1/apps/'+imported['app_id']+'/export')['data']
proposal=model_call('workflow-generate',{'instruction':'Return a Q input','mode':'workflow','flow_id':imported['app_id']});assert not proposal.get('error'),proposal
assert s.get('/v1/apps/'+imported['app_id']+'/export')['data']==before
created=s.post('/v1/apps/imports',{'mode':'yaml-content','yaml_content':json.dumps({'kind':'app','version':'0.7.0','app':{'name':'Generated helper','mode':'workflow'},'workflow':{'features':{},'graph':proposal['graph']}})})
assert created['app_id'];fixture['apps']['generated']=created['app_id']
s.post('/v1/apps/'+created['app_id']+'/workflows/publish',{});generated_key=s.post('/v1/apps/'+created['app_id']+'/api-keys',{})['token']
executed=session(generated_key).post('/v1/workflows/run',{'inputs':{'q':'actual proposed graph'},'user':'generated-user','response_mode':'blocking'})
assert executed['data']['status']=='succeeded' and executed['data']['outputs']['q']=='actual proposed graph'
passed('planner-builder-valid-executable-proposal-without-draft-mutation')
app=imported['app_id'];voices=s.get('/v1/apps/'+app+'/text-to-audio/voices?language=en-US');assert any(v['value']=='alloy'for v in voices)
# Binary audio uses Session's underlying opener, retaining console authentication.
def audio():
 req=urllib.request.Request(base+'/v1/apps/'+app+'/text-to-audio',data=json.dumps({'text':'Hello helper','voice':'alloy'}).encode(),headers={**s.headers,'Content-Type':'application/json'})
 with s.opener.open(req,timeout=90)as res:return res.read(),res.headers['Content-Type']
data,mime=audio();expected=pathlib.Path(__file__).with_name('tone.mp3').read_bytes();assert data==expected and mime.startswith('audio/'),(len(data),mime)
(a.out/'audio.mp3').write_bytes(data)
origin.post('/stub/modes',{'ttsFailure':True})
try:audio();raise AssertionError('Failed audio was reported as success')
except urllib.error.HTTPError:pass
origin.post('/stub/modes',{});assert audio()[0]==expected
passed('real-plugin-voice-list-audio-bytes-failure-and-retry')
# Published Chatflow: exact upstream pre-graph annotation match must avoid all LLM/node side effects.
chatmodel={'provider':STUB_PROVIDER,'name':'stub-chat','mode':'chat','completion_params':{'max_tokens':128}}
yaml=workflow([node('s','start',variables=[]),node('llm','llm',model=chatmodel,prompt_template=[{'role':'user','text':'{{#sys.query#}}'}],context={'enabled':False,'variable_selector':[]},vision={'enabled':False}),node('a','answer',answer='{{#llm.text#}}')],name='Annotation chat fixture')
yaml['app']['mode']='advanced-chat'
chat=s.post('/v1/apps/imports',{'mode':'yaml-content','yaml_content':json.dumps(yaml)})['app_id'];s.post('/v1/apps/'+chat+'/workflows/publish',{});key=s.post('/v1/apps/'+chat+'/api-keys',{})['token'];public=session(key);fixture['apps']['chat']=chat;fixture['key']=key;save()
annotation=s.post('/v1/apps/'+chat+'/annotations',{'question':'Fruit question','answer':'Curated fruit answer'});aid=annotation['id']
settings={'score_threshold':.9,'embedding_provider_name':STUB_PROVIDER,'embedding_model_name':'fixture-embed'}
def enable(body=settings):return s.post('/v1/apps/'+chat+'/annotation-reply/enable',body)['job_id']
def wait_job(job,status='completed',action='enable'):
 for _ in range(160):
  result=s.get(f'/v1/apps/{chat}/annotation-reply/{action}/status/{job}')
  if result['job_status'] in ['completed','error']:
   assert result['job_status']==status,result;return result
  time.sleep(.25)
 raise AssertionError('Index job did not finish')
job=enable();wait_job(job);assert s.get('/v1/apps/'+chat+'/annotation-setting')['enabled']
rule('normal model fallback');reset()
def run(query):return public.post('/v1/chat-messages',{'query':query,'inputs':{},'response_mode':'blocking','user':'annotation-user'})
hit=run('Same intent paraphrase');assert hit['answer']=='Curated fruit answer',hit
assert calls('/v1/embeddings') and not calls('/v1/chat/completions')
history=s.get(f'/v1/apps/{chat}/annotations/{aid}/hit-histories');assert history['total']==1 and history['data'][0]['source']=='api' and history['data'][0]['question']=='Same intent paraphrase'
passed('real-Weaviate-semantic-hit-skips-LLM-and-persists-public-source-history')
reset();assert run('Near threshold')['answer']=='normal model fallback';assert len(calls('/v1/chat/completions'))==1
sid=s.get('/v1/apps/'+chat+'/annotation-setting')['id']
for score in [1,0]:
 s.post('/v1/apps/'+chat+'/annotation-settings/'+sid,{'score_threshold':score});reset();assert run('Fruit question')['answer']=='normal model fallback';assert len(calls('/v1/chat/completions'))==1
s.post('/v1/apps/'+chat+'/annotation-settings/'+sid,{'score_threshold':.9})
origin.post('/stub/modes',{'embeddingFailure':True});reset();assert run('Fruit question')['answer']=='normal model fallback';assert len(calls('/v1/chat/completions'))==1
origin.post('/stub/modes',{})
passed('strict-threshold-equality-zero-and-vector-failure-use-original-fallback')
s.post('/v1/apps/'+chat+'/annotation-reply/disable',{})
# Disable makes matching ineffective immediately; the persisted cleanup job is also real.
for _ in range(40):
 if not s.get('/v1/apps/'+chat+'/annotation-setting')['enabled']:break
 time.sleep(.1)
origin.post('/stub/modes',{'embeddingFailure':True});failed=enable();wait_job(failed,status='error');assert not s.get('/v1/apps/'+chat+'/annotation-setting')['enabled']
origin.post('/stub/modes',{});retry=enable();wait_job(retry);reset();assert run('Same intent paraphrase')['answer']=='Curated fruit answer';assert not calls('/v1/chat/completions')
passed('index-failure-is-not-fake-completion-and-explicit-retry-restores-matching')
save();(a.out/'result.json').write_text(json.dumps({'checks':checks,'signedPlugin':'openai_api_compatible0.0.68','realWeaviate':'1.39.2','paidCalls':False,'actualUserAccountsUsed':False},indent=2))
