"""Real daemon/plugin, sandbox and proxy checks against an isolated runtime stack.

Uses the existing DifySF and llmstub adapters. Never run setup against a populated
user deployment: this requires a dedicated fixture account under --out/private.
"""
import argparse,json,os,secrets,sys
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--base',required=True);p.add_argument('--stub',required=True);p.add_argument('--out',type=Path,required=True);args=p.parse_args()
e2e=Path(__file__).resolve().parents[1];sys.path.insert(0,str(e2e));from compare import DifySF,Stub
from lib.e2ehttp import Session
args.out.mkdir(parents=True,exist_ok=True);private=args.out/'private';private.mkdir(exist_ok=True,mode=0o700);auth=private/'fixture-auth.json'
if not auth.exists():auth.write_text(json.dumps({'email':'runtime-owner@example.test','password':'Aa1-'+secrets.token_urlsafe(24)}));auth.chmod(0o600)
a=json.loads(auth.read_text());client=DifySF(args.base,a['email'],a['password']);stub=Stub(args.stub)
# Keep browser tokens in the private fixture directory only, never in results/logs.
(private/'session.json').write_text(json.dumps({'email':a['email'],'password':a['password'],'headers':client.s.headers}));(private/'session.json').chmod(0o600)
checks=[];apps={}
def node(id,type,**data):return {'id':id,'data':{'type':type,'title':id,**data},'position':{'x':80+len(id)*40,'y':120}}
def graph(nodes,edges=None,name="Runtime phase1 verified (local test model)"):
 for i,item in enumerate(nodes):item['position']={'x':80+i*280,'y':160}
 edges=edges or list(zip([x['id'] for x in nodes][:-1],[x['id'] for x in nodes][1:]))
 return {'kind':'app','version':'0.3.1','app':{'mode':'workflow','name':name},'workflow':{'features':{},'environment_variables':[],'conversation_variables':[],'graph':{'nodes':nodes,'edges':[{'id':s+'-'+t,'source':s,'sourceHandle':'source','target':t,'targetHandle':'target'} for s,t in edges]}}}
start=node('start','start',variables=[{'variable':'q','type':'text-input','label':'q','required':True}])
llm=node('llm','llm',model={'provider':'langgenius/openai_api_compatible/openai_api_compatible','name':'stub-chat','mode':'chat','completion_params':{'temperature':0}},prompt_template=[{'role':'user','text':'[[stub:fixed]] {{#start.q#}}'}],context={'enabled':False,'variable_selector':[]},vision={'enabled':False})
py=node('python','code',code_language='python3',code='def main(q: str):\n    return {"result": "python:" + q}\n',variables=[{'variable':'q','value_selector':['start','q']}],outputs={'result':{'type':'string','children':None}})
js=node('javascript','code',code_language='javascript',code='function main({q}) { return {result: "javascript:" + q}; }',variables=[{'variable':'q','value_selector':['start','q']}],outputs={'result':{'type':'string','children':None}})
template=node('template','template-transform',template='Hello {{ q | upper }}',variables=[{'variable':'q','value_selector':['start','q']}])
http=node('http','http-request',method='post',url='http://llmstub:8000/echo',authorization={'type':'no-auth','config':None},headers='X-Runtime-Probe: phase1',params='',body={'type':'raw-text','data':[{'key':'','value':'{{#python.result#}}','type':'text'}]},timeout={'connect':5,'read':5,'write':5},ssl_verify=True)
end=node('end','end',outputs=[{'variable':'text','value_selector':['llm','text']},{'variable':'python','value_selector':['python','result']},{'variable':'javascript','value_selector':['javascript','result']},{'variable':'template','value_selector':['template','output']},{'variable':'http','value_selector':['http','body']}])
dsl=graph([start,llm,py,js,template,http,end]);(args.out/'workflow.json').write_text(json.dumps(dsl,indent=2));app=client.import_dsl(dsl);apps['main']=app;stub.reset()
def save(name,obj): (args.out/(name+'.json')).write_text(json.dumps(obj,indent=2))
for id,inputs,want in [('python',{'python.q':'hello'},'python:hello'),('javascript',{'javascript.q':'hello'},'javascript:hello'),('template',{'template.q':'hello'},'Hello HELLO')]:
 result=client.run_node(app,id,inputs);save('single-'+id,result);assert result['status']=='succeeded',result.get('error');assert want in result['outputs'].values(),result['outputs'];checks.append('single-'+id)
frames=list(client.run_draft(app,'workflow',{'q':'hello'}));save('draft-frames',frames);finished=[e['data'] for e in frames if e.get('event')=='workflow_finished'];assert len(finished)==1 and finished[0]['status']=='succeeded',finished
out=finished[0]['outputs'];assert out['text']=='This is the fixed stub answer.' and out['python']=='python:hello' and out['javascript']=='javascript:hello' and out['template']=='Hello HELLO',out
body=json.loads(out['http']);assert body['body']=='python:hello',body
requests=stub.requests();assert any('[[stub:fixed]] hello' in json.dumps(x) for x in requests),requests;save('model-requests',requests);checks.append('whole-real-services')
# A private destination must be rejected by Squid, even though the fixture host alone is allowed.
blocked=json.loads(json.dumps(http));blocked['data']['url']='http://127.0.0.1:8080/healthz';blocked['data']['body']={'type':'none','data':[]};blockedapp=client.import_dsl(graph([start,blocked],name='Runtime SSRF rejection fixture'));blockedresult=client.run_node(blockedapp,'http',{});save('ssrf-blocked',blockedresult);assert blockedresult['status']=='failed' and 'SSRF' in blockedresult['error'],blockedresult;checks.append('ssrf-private-blocked')
run_id=next(e['workflow_run_id'] for e in frames if e.get('workflow_run_id'));detail=client.s.get(f'/v1/apps/{app}/workflow-runs/{run_id}');save('run-detail',detail);assert detail['status']=='succeeded' and detail['outputs']==out
save('result',{'checks':checks,'app':app,'run':run_id,'apps':apps,'outputs':out,'errors':[],'model':'deterministic local test via real signed plugin','credentialsOrTokensIncluded':False})
print('PASS:',', '.join(checks),flush=True)
