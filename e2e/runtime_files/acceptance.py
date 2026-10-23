"""Actual file IO -> graph consumers -> signed download, through the signed model plugin and strict proxy.

Requires an existing isolated account. Never run this against a user deployment. No setup, reset or external model calls.
"""
import argparse, base64, copy, hashlib, hmac, json, sys, time
from pathlib import Path
from urllib.parse import urlsplit
import requests

parser = argparse.ArgumentParser()
parser.add_argument('--base', required=True); parser.add_argument('--stub', required=True)
parser.add_argument('--auth-file', type=Path, required=True); parser.add_argument('--fixture-compose', type=Path, required=True)
parser.add_argument('--out', type=Path, required=True)
a = parser.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compare import DifySF
from lib.e2ehttp import Session
from lib.dify import STUB_PROVIDER, stub_credentials
from runtime_files.origin import PNG, PDF

session = Session(a.base); login = session.post('/v1/auth/login', json.loads(a.auth_file.read_text()))
session.headers['Authorization'] = 'Bearer ' + login['access_token']
client = DifySF.__new__(DifySF); client.s = session
stub = Session(a.stub); checks = []; artifacts = {}

def save(name, value):
    (a.out / (name + '.json')).write_text(json.dumps(value, indent=2, ensure_ascii=False))

def mark(name):
    checks.append(name); print('PASS', name, flush=True)

def node(id, kind, **data):
    return {'id': id, 'position': {'x': 80, 'y': 120}, 'data': {'type': kind, 'title': id, **data}}

def workflow(nodes, edges=None, name='Runtime files acceptance'):
    for i, n in enumerate(nodes): n['position'] = {'x': 80 + i * 280, 'y': 160}
    edges = edges or [(s['id'], 'source', t['id']) for s,t in zip(nodes, nodes[1:])]
    return {'kind': 'app', 'version': '0.3.1', 'app': {'mode': 'workflow', 'name': name}, 'workflow': {
        'environment_variables': [], 'conversation_variables': [],
        'features': {'file_upload': {'enabled': True, 'allowed_file_types': ['image', 'document'], 'allowed_file_upload_methods': ['local_file', 'remote_url'], 'number_limits': 5}},
        'graph': {'nodes': nodes, 'edges': [{'id':str(i), 'source':s,'sourceHandle':h,'target':t,'targetHandle':'target'} for i,(s,h,t) in enumerate(edges)]}}}

def upload(name, content):
    return session.multipart('/v1/files/upload', {}, {'file': (name, content)})

def ref(file):
    return {'transfer_method': 'local_file', 'upload_file_id': file['id']}

def run(app, inputs, files=()):
    frames = [json.loads(line) for line in session.stream('POST', f'/v1/apps/{app}/workflows/draft/run', {'inputs': inputs, 'files': list(files)})]
    return frames, next((f['data'] for f in reversed(frames) if f.get('event') == 'workflow_finished'), None)

def downloaded(file, expected):
    response = requests.get(file['url'], timeout=10); assert response.status_code == 200, response.status_code
    assert response.content == expected, (hashlib.sha256(response.content).hexdigest(), len(expected))

picture = upload('图片.png', PNG); document = upload('résumé.txt', b'UTF-8 file\x00\xff\xc3\xa9')
save('uploads', {'picture': picture, 'document': document}); artifacts.update(picture=picture, document=document)
start = node('start', 'start', variables=[{'variable':'picture','label':'图片','type':'file','required':True,'allowed_file_types':['image']},
    {'variable':'documents','label':'文档','type':'file-list','required':True,'max_length':2,'allowed_file_types':['document']}])
end = node('end', 'end', outputs=[{'variable':'picture','value_selector':['start','picture']},{'variable':'documents','value_selector':['start','documents']},{'variable':'system_files','value_selector':['sys','files']}])
app = client.import_dsl(workflow([start, end])); frames, terminal = run(app, {'picture':ref(picture),'documents':[ref(document)]}, [ref(picture)])
assert terminal and terminal['status'] == 'succeeded', terminal
assert terminal['outputs']['picture']['related_id'] == picture['id']; assert len(terminal['outputs']['system_files']) == 1
downloaded(terminal['outputs']['picture'], PNG); downloaded(terminal['outputs']['documents'][0], b'UTF-8 file\x00\xff\xc3\xa9')
save('file-whole-run', frames); artifacts.update(app=app, run=frames[0]['workflow_run_id']); mark('upload-graph-output-signed-bytes')
# Empty lists retain file types in cached variables and are reusable by a later single step.
empty_frames, empty = run(app, {'picture':ref(picture),'documents':[]})
assert empty['status'] == 'succeeded' and empty['outputs']['documents'] == []
variables = session.get(f'/v1/apps/{app}/workflows/draft/nodes/start/variables')['items']
assert next(x for x in variables if x['name']=='documents')['value_type'] == 'array[file]'
single = client.run_node(app,'end',{}); assert single['status']=='succeeded' and single['outputs']['picture']['related_id']==picture['id'],single
assert single['outputs']['documents']==[]; save('file-single-cache',single); mark('typed-empty-files-and-single-step-cache')
# The real strict proxy receives exact binary and multipart fields, filenames, MIME and bytes.
for kind, selector in [('binary',['start','picture']),('form-data',['start','documents'])]:
    n=node('http','http-request',method='post',url='http://llmstub:8000/files/echo',authorization={'type':'no-auth'},headers='',params='',
           body={'type':kind,'data':[{'type':'file','key':'attachment','file':selector}]})
    httpapp=client.import_dsl(workflow([start,n])); selected=ref(picture) if kind=='binary' else [ref(document),ref(document)]
    result=client.run_node(httpapp,'http',{'http.#'+'.'.join(selector)+'#':selected}); assert result['status']=='succeeded',result
    echo=json.loads(result['outputs']['body']); save('http-'+kind,echo)
    if kind=='binary': assert base64.b64decode(echo['base64'])==PNG
    else:
        assert len(echo['parts'])==2,echo
        for part in echo['parts']:
            assert part['name']=='attachment' and part['filename']=='résumé.txt' and part['mime']=='text/plain',part
            assert base64.b64decode(part['base64'])==b'UTF-8 file\x00\xff\xc3\xa9'
    mark('actual-http-'+kind+'-bytes')
http=node('http','http-request',method='get',url='http://llmstub:8000/files/fixture.pdf',authorization={'type':'no-auth'},headers='',params='',body={'type':'none','data':[]})
httpapp=client.import_dsl(workflow([node('start','start',variables=[]),http])); result=client.run_node(httpapp,'http',{})
assert result['status']=='succeeded' and result['outputs']['body']=='',result
output=result['outputs']['files'][0]; assert output['type']=='document' and output['mime_type']=='application/pdf' and output['filename'].endswith('.pdf'),output
downloaded(output,PDF); save('http-file-output',result); artifacts['httpOutput']=output; mark('actual-http-response-file-and-download')
# Remote imports reuse strict proxy; a redirect cannot bypass its private-network denial.
remote={'transfer_method':'remote_url','url':'http://llmstub:8000/files/pixel.png'}
remote_frames, terminal=run(app,{'picture':remote,'documents':[]}); assert terminal['status']=='succeeded',terminal
downloaded(terminal['outputs']['picture'],PNG);save('remote-file-run',remote_frames);mark('remote-import-persisted-bytes')
for name,url in [('private','http://127.0.0.1:8080/healthz'),('redirect-private','http://llmstub:8000/files/redirect?to=http%3A%2F%2F127.0.0.1%3A8080%2Fhealthz')]:
    r=requests.post(a.base+f'/v1/apps/{app}/workflows/draft/run',headers=session.headers,json={'inputs':{'picture':{'transfer_method':'remote_url','url':url},'documents':[]}},timeout=20)
    assert r.status_code>=400,(name,r.status_code,r.text[:300]); mark('remote-'+name+'-rejected')
# Actual signed plugin invocation (vision capability comes from the provider's own schema, not a node fake).
creds=stub_credentials();creds['vision_support']='support'
session.post(f'/v1/workspace/model-providers/{STUB_PROVIDER}/models/credentials',{'model':'stub-vision','model_type':'llm','credentials':creds})
model={'provider':STUB_PROVIDER,'name':'stub-vision','mode':'chat','completion_params':{}}
llm=node('llm','llm',model=model,prompt_template=[{'role':'user','text':'Describe the uploaded image'}],context={'enabled':False,'variable_selector':[]},vision={'enabled':True,'configs':{'variable_selector':['start','picture'],'detail':'low'}})
llmapp=client.import_dsl(workflow([start,llm])); stub.post('/stub/reset',{})
result=client.run_node(llmapp,'llm',{'llm.#files#':ref(picture)});assert result['status']=='succeeded',result
requests_seen=stub.get('/stub/log')['requests'];assert len(requests_seen)==1,requests_seen
parts=[p for m in requests_seen[0]['body']['messages'] for p in (m.get('content') if isinstance(m.get('content'),list) else []) if p.get('type')=='image_url']
assert len(parts)==1 and parts[0]['image_url']['detail']=='low',requests_seen
url=parts[0]['image_url']['url']; assert base64.b64decode(url.split(',',1)[1])==PNG and url.startswith('data:image/png;base64,'),parts
save('vision-provider-request',requests_seen);save('vision-result',result);artifacts['visionApp']=llmapp;mark('signed-plugin-real-vision-image-bytes-detail')
# A validly signed but expired preview must still be refused; record references can refresh the link afterwards.
compose=json.loads(a.fixture_compose.read_text());key=compose['services']['server']['environment']['COLLAB_FILES_SIGNING_KEY'];stamp=str(int(time.time())-301);nonce='f'*32
message=f'file-preview|{picture["id"]}|{stamp}|{nonce}'.encode();sig=base64.urlsafe_b64encode(hmac.new(key.encode(),message,hashlib.sha256).digest()).decode()
expired=requests.get(a.base+f'/files/{picture["id"]}/file-preview',params={'timestamp':stamp,'nonce':nonce,'sign':sig},timeout=10)
assert expired.status_code==404,expired.status_code;mark('correctly-signed-expired-link-refused')
save('artifacts',artifacts);save('result',{'checks':checks,'success':True,'model':'local deterministic model through real signed OpenAI-compatible plugin','publicEndUserOrMail':False})
print('PASS: runtime-file boundary matrix complete',flush=True)
