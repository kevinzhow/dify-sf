"""A real, isolated Codex process driven over app-server; no account login."""
import json, os, pathlib, queue, subprocess, tempfile, threading, time, signal
signal.pthread_sigmask(signal.SIG_SETMASK, [])

binary = os.environ['AGENT_CODEX_BINARY']
root = pathlib.Path(tempfile.mkdtemp(prefix='official-codex-'))
(root/'codex-home').mkdir(mode=0o700)
options = {
    'model': os.environ['CODEX_FIXTURE_MODEL'], 'model_provider': 'difysf',
    'model_reasoning_effort': 'max', 'approval_policy': 'never',
    'sandbox_mode': 'danger-full-access', 'web_search': 'disabled',
    'model_providers.difysf.name': 'dify-sf fixture',
    'model_providers.difysf.base_url': os.environ['CODEX_FIXTURE_URL'],
    'model_providers.difysf.env_key': 'DIFYSF_RUN_TOKEN',
    'model_providers.difysf.requires_openai_auth': False,
    'model_providers.difysf.supports_websockets': True,
    'model_providers.difysf.http_headers': {'X-DifySF-Require-Incremental':'v1'},
    'model_providers.difysf.stream_max_retries': 2 if os.environ.get('CODEX_FIXTURE_RECOVERY') else 0,
}
args = [binary, 'app-server', '--listen', 'stdio://']
for key, value in options.items():
    encoded = '{ '+', '.join(json.dumps(k)+' = '+json.dumps(v) for k,v in value.items())+' }' if isinstance(value,dict) else json.dumps(value)
    args += ['-c', key+'='+encoded]
env = {'PATH': '/usr/local/bin:/usr/bin:/bin', 'CODEX_HOME': str(root/'codex-home'),
       'DIFYSF_RUN_TOKEN': os.environ['CODEX_FIXTURE_RUN_TOKEN'], 'NO_PROXY': '*', 'no_proxy': '*'}
errors = (root/'stderr.log').open('wb')
process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, env=env, cwd=root)
messages = queue.Queue()
def read():
    for line in process.stdout: messages.put(json.loads(line))
    messages.put({"fixture_eof":True})
threading.Thread(target=read, daemon=True).start()
def send(value): process.stdin.write(json.dumps(value).encode()+b'\n'); process.stdin.flush()
def until(predicate, timeout=40):
    deadline = time.monotonic()+timeout
    while time.monotonic()<deadline:
        value = messages.get(timeout=max(.01, deadline-time.monotonic()))
        if value.get("fixture_eof"): raise RuntimeError("synthetic app-server exited")
        if predicate(value): return value
    raise TimeoutError()
try:
    send({'id':1,'method':'initialize','params':{'clientInfo':{'name':'dify_sf_fixture','version':'1'},'capabilities':{'experimentalApi':True}}})
    assert 'result' in until(lambda v:v.get('id')==1)
    send({'method':'initialized','params':{}})
    send({'id':2,'method':'thread/start','params':{'model':options['model'],'modelProvider':'difysf','cwd':str(root),'approvalPolicy':'never','sandbox':'danger-full-access','ephemeral':True}})
    started = until(lambda v:v.get('id')==2)
    thread = started['result']['thread']['id']
    send({'id':3,'method':'turn/start','params':{'threadId':thread,'input':[{'type':'text','text':'Return a short synthetic fixture answer.'}],'effort':'max'}})
    done = until(lambda v:v.get('method')=='turn/completed')
    mode=os.environ.get('CODEX_FIXTURE_RECOVERY')
    expected='failed' if mode=='burst_exhausted' else 'completed'
    assert done['params']['turn']['status']==expected,done
    turns=1 if mode=='burst_exhausted' else 4 if mode in ('thrice','exhausted') else 2
    for turn in range(2,turns+1):
        send({'id':turn+2,'method':'turn/start','params':{'threadId':thread,'input':[{'type':'text','text':'One more synthetic answer.'}],'effort':'max'}})
        done=until(lambda v:v.get('method')=='turn/completed')
        expected='failed' if mode=='exhausted' and turn==4 else 'completed'
        assert done['params']['turn']['status']==expected,done
    count=(root/'recovery-counter').read_text().count('fixture-delta') if os.environ.get('CODEX_FIXTURE_RECOVERY') else None
    if os.environ.get('CODEX_FIXTURE_RECOVERY'):assert count==1,count
    assert not (root/'partial-was-executed').exists(), 'an incomplete tool was executed'
    if os.environ.get('CODEX_FIXTURE_RECOVERY')=='background':assert (root/'recovery-finished').read_text()=='completed'
    print(json.dumps({'turns':turns,'status':expected,'officialCodex':True,'accountLogin':False,'toolExecutions':count}))
finally:
    process.terminate()
    try:process.wait(timeout=5)
    except subprocess.TimeoutExpired:process.kill();process.wait()
    errors.close()
