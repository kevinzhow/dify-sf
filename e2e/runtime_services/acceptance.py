"""Phase 1 real-boundary matrix. Isolated fixture only; no external model calls."""
import argparse,copy,json,sys,threading,time
from pathlib import Path
import yaml
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);a=p.parse_args();r=a.out;r.mkdir(exist_ok=True)
e2e=Path(__file__).resolve().parents[1];sys.path.insert(0,str(e2e));from compare import DifySF,Stub,rewrite_models
from lib.e2ehttp import Session
root=r.parent;auth=json.loads((root/'smoke/private/fixture-auth.json').read_text());c=DifySF('http://127.0.0.1:19092',**auth);s=Stub('http://127.0.0.1:19094');origin=s.s
base=json.loads((root/'smoke/workflow.json').read_text());nodes={n['id']:n for n in base['workflow']['graph']['nodes']};results=[]
def save(name,x):(r/(name+'.json')).write_text(json.dumps(x,indent=2))
def graph(ns,edges=None):
 d=copy.deepcopy(base);d['app']['name']='Runtime acceptance '+str(len(results));d['workflow']['graph']={'nodes':ns,'edges':[{'id':str(i),'source':x,'sourceHandle':h,'target':y,'targetHandle':'target'} for i,(x,h,y) in enumerate(edges or [(x['id'],'source',y['id']) for x,y in zip(ns,ns[1:])])]};return d

def single(label,n,inputs,want='succeeded'):
 app=c.import_dsl(graph([copy.deepcopy(nodes['start']),n]));v=c.run_node(app,n['id'],inputs);save(label,v);assert v['status']==want,(label,v);results.append(label);print('PASS',label,flush=True);return v

def run(label,d,inputs,want='succeeded'):
 app=c.import_dsl(d);frames=list(c.run_draft(app,'workflow',inputs));save(label,frames);end=[v['data'] for v in frames if v.get('event')=='workflow_finished'];assert len(end)==1 and end[0]['status']==want,(label,end);results.append(label);print('PASS',label,flush=True);return end[0],frames
try:
 # Prompt-only structured extraction: this provider advertises no tool-call feature.
 origin.post('/stub/script',{'rules':[{'match':'','reply':'{"ok":true}'}]})
 n=copy.deepcopy(nodes['llm']);n['data'].update(structured_output_enabled=True,structured_output={'schema':{'type':'object','properties':{'ok':{'type':'boolean'}},'required':['ok'],'additionalProperties':False}})
 v=single('model-structured',n,{'llm.#start.q#':'structured'});assert v['outputs']['structured_output']=={'ok':True} and v['outputs']['usage']['total_tokens']>0,v
 origin.post('/stub/script',{'rules':[{'match':'','reply':'{"category_id":"tech","category_name":"Tech"}'}]})
 n={'id':'qc','position':{'x':300,'y':160},'data':{'type':'question-classifier','title':'QC','model':nodes['llm']['data']['model'],'query_variable_selector':['start','q'],'classes':[{'id':'billing','name':'Billing'},{'id':'tech','name':'Tech'}],'instruction':''}}
 v=single('model-classifier',n,{'qc.query':'wifi is broken'});assert v['outputs']['class_id']=='tech',v
 origin.post('/stub/script',{'rules':[{'match':'','reply':'{"name":"Ann","age":31}'}]})
 n={'id':'pe','position':{'x':300,'y':160},'data':{'type':'parameter-extractor','title':'PE','model':nodes['llm']['data']['model'],'query':['start','q'],'parameters':[{'name':'name','type':'string','description':'Name','required':True},{'name':'age','type':'number','description':'Age','required':True}],'instruction':'','reasoning_mode':'prompt'}}
 v=single('model-extractor',n,{'pe.query':'Ann is 31'});assert v['outputs']['name']=='Ann' and v['outputs']['age']==31 and v['outputs']['__is_success']==1,v
 origin.post('/stub/script',{'rules':[{'match':'','status':401,'error':'fixture provider refuses credential'}]})
 v=single('model-provider-rejected',copy.deepcopy(nodes['llm']),{'llm.#start.q#':'refuse'},'failed');assert v.get('error'),v
 origin.post('/stub/script',{'rules':[{'match':'[[stub:fixed]]','reply':'This is the fixed stub answer.'}]})
 n=copy.deepcopy(nodes['python']);n['data']['code']='def main(q):\n    raise ValueError("fixture code rejected")\n';single('python-error',n,{'python.q':'hello'},'failed')
 n=copy.deepcopy(nodes['template']);n['data']['template']='{% invalid_fixture %}';single('template-error',n,{'template.q':'hello'},'failed')
 n=copy.deepcopy(nodes['http']);n['data'].update(method='get',url='http://llmstub:8000/http/echo?status=403',body={'type':'none','data':[]});v=single('http-upstream-403',n,{});assert v['outputs']['status_code']==403,v
 n['data']['url']='http://llmstub:8000/http/slow?seconds=3';n['data']['timeout']['read']=1;single('http-timeout',n,{},'failed')
 n['data']['url']='http://llmstub:9/http/echo';single('http-connection-refused',n,{},'failed')
 # Existing Dify comparison cases: actual sandbox, nested model calls and loop branches.
 cases=[('iteration_modes_parallel.yml',{},'partial-succeeded'),('iteration_nested_llm.yml',{'topic':'rivers'},'succeeded'),('loop_variables_break_end.yml',{'base':1},'succeeded'),('loop_variables_break_end.yml',{'base':0},'succeeded'),('iteration_retry_terminated.yml',{},'failed')]
 for i,(file,inputs,status) in enumerate(cases):
  modelCount=len(s.requests())
  d=yaml.safe_load((e2e/'cases'/file).read_text());d['workflow']['graph']=rewrite_models(d['workflow']['graph']);end,frames=run('existing-'+str(i)+'-'+file.removesuffix('.yml'),d,inputs,status)
  if file=='loop_variables_break_end.yml':assert end['outputs']['total']==(5 if inputs['base']==1 else 8),end
  if file=='iteration_nested_llm.yml':assert len(s.requests())-modelCount==3 and len(end['outputs']['lines'])==2,end
  if file=='iteration_modes_parallel.yml':assert end['exceptions_count']==2 and end['outputs']=={'a':[10,20,30,None,50,60,70],'b':[1,102,203,405,506,607]},end
 # Persistent 500 exercises retry count and the fail branch, not a mocked node.
 n=copy.deepcopy(nodes['http']);n['data'].update(method='get',url='http://llmstub:8000/http/echo?status=500&case=retry',body={'type':'none','data':[]},retry_config={'retry_enabled':True,'max_retries':2,'retry_interval':0},error_strategy='fail-branch')
 end=copy.deepcopy(nodes['end']);end['data']['outputs']=[{'variable':'error','value_selector':['http','error_message']}]
 before=len(origin.get('/http/log')['requests']);v,frames=run('http-retry-fail-branch',graph([copy.deepcopy(nodes['start']),n,end],[('start','source','http'),('http','fail-branch','end')]),{'q':'hello'},'partial-succeeded');after=origin.get('/http/log')['requests'][before:];assert len([x for x in after if 'case=retry' in x['path']])==3,after
 # Stop after an actual upstream request has started; downstream must not execute.
 n=copy.deepcopy(nodes['http']);n['data'].update(method='get',url='http://llmstub:8000/http/slow?seconds=8&case=stop',body={'type':'none','data':[]});n['data']['timeout']['read']=20
 downstream=copy.deepcopy(n);downstream['id']='downstream';downstream['data']['url']='http://llmstub:8000/http/echo?case=must-not-run'
 app=c.import_dsl(graph([copy.deepcopy(nodes['start']),n,downstream]));frames=[];errors=[];beforeStop=len(origin.get('/http/log')['requests'])
 # append incrementally, so the stop command can obtain its task id.
 def consume():
  try:
   for f in c.run_draft(app,'workflow',{'q':'stop'}):frames.append(f)
  except Exception as e:errors.append(str(e))
 t=threading.Thread(target=consume,daemon=True);t.start()
 for _ in range(150):
  if any('case=stop' in x['path'] for x in origin.get('/http/log')['requests'][beforeStop:]):break
  time.sleep(.1)
 else:raise AssertionError('slow upstream was never called')
 task=next(x['task_id'] for x in frames if x.get('task_id'));c.s.post(f'/v1/apps/{app}/workflow-runs/tasks/{task}/stop',{});t.join(30);assert not t.is_alive() and not errors,errors;save('stop-frames',frames);terminal=[f['data'] for f in frames if f.get('event')=='workflow_finished'];assert len(terminal)==1 and terminal[0]['status']=='stopped',terminal;assert not any('case=must-not-run' in x['path'] for x in origin.get('/http/log')['requests']);results.append('stop-no-downstream')
 save('result',{'checks':results,'model':'deterministic local fixture through real signed provider plugin','success':True});print('PASS: matrix complete',flush=True)
finally:origin.post('/stub/script',{'rules':[{'match':'[[stub:fixed]]','reply':'This is the fixed stub answer.'}]})
