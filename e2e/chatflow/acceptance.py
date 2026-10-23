"""Durable console Chatflow through the real signed model plugin, local HTTP origin and Postgres.

Isolated fixture only. Uses an existing throwaway account; never creates/resets a user deployment or invokes a paid model.
"""
import argparse, json, sys, time, subprocess, uuid
from pathlib import Path
from urllib.parse import urlsplit
import requests

p = argparse.ArgumentParser()
p.add_argument('--base', required=True); p.add_argument('--stub', required=True)
p.add_argument('--auth-file', type=Path, required=True); p.add_argument('--compose', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
assert urlsplit(a.base).hostname in ('127.0.0.1', 'localhost') and urlsplit(a.base).port == 19092, 'isolated fixture only'
assert urlsplit(a.stub).hostname in ('127.0.0.1', 'localhost') and urlsplit(a.stub).port == 19094, 'local model only'
a.out.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compare import DifySF
from lib.e2ehttp import Session, HTTPError
from lib.dify import STUB_PROVIDER, stub_credentials
from runtime_files.acceptance_support import node, workflow

session = Session(a.base)
login = session.post('/v1/auth/login', json.loads(a.auth_file.read_text()))
session.headers['Authorization'] = 'Bearer ' + login['access_token']
client = DifySF.__new__(DifySF); client.s = session
stub = Session(a.stub); checks = []
def save(name, value): (a.out / (name + '.json')).write_text(json.dumps(value, ensure_ascii=False, indent=2))
def mark(name): checks.append(name); print('PASS', name, flush=True)
def frames(method, path, body=None): return [json.loads(line) for line in session.stream(method, path, body)]
def send(app, query, cid=None, parent=None):
    body = {'query': query, 'inputs': {}, 'files': []}
    if cid: body['conversation_id'] = cid
    if parent: body['parent_message_id'] = parent
    return frames('POST', f'/v1/apps/{app}/advanced-chat/workflows/draft/run', body)
def terminal(fs): return next(f['data'] for f in reversed(fs) if f.get('event') == 'workflow_finished')
def common(fs):
    start = next(f for f in fs if f.get('event') == 'workflow_started')
    return start['conversation_id'], start['message_id'], start['workflow_run_id']
def answer(fs): return ''.join(f.get('answer', '') for f in fs if f.get('event') == 'message')
def chat(nodes, **kw):
    doc = workflow(nodes, **kw); doc['app']['mode'] = 'advanced-chat'; return doc

def model_request():
    seen = stub.get('/stub/log')['requests']
    assert len(seen) == 1, len(seen)
    return seen[0]['body']['messages']
def text(message):
    content = message.get('content')
    return content if isinstance(content, str) else ''.join(x.get('text', '') for x in content or [] if x.get('type') == 'text')
def expect_status(call, status):
    try: call()
    except HTTPError as e: assert e.status == status, e.status; return
    raise AssertionError('expected HTTP ' + str(status))

session.post(f'/v1/workspace/model-providers/{STUB_PROVIDER}/models/credentials',
    {'model': 'stub-chat', 'model_type': 'llm', 'credentials': stub_credentials()})
model = {'provider': STUB_PROVIDER, 'name': 'stub-chat', 'mode': 'chat', 'completion_params': {'max_tokens': 256}}
llm = node('llm', 'llm', model=model, prompt_template=[{'role': 'system', 'text': 'Previous topic={{#conversation.topic#}}'}],
    memory={'window': {'enabled': True, 'size': 10}, 'query_prompt_template': '{{#sys.query#}}'},
    context={'enabled': False, 'variable_selector': []}, vision={'enabled': False})
assign = node('assign', 'assigner', assigned_variable_selector=['conversation', 'topic'], write_mode='over-write', input_variable_selector=['sys', 'query'])
# The v1 variable assigner's Dify node type is `assigner`.
doc = chat([node('start', 'start', variables=[]), llm, assign,
            node('answer', 'answer', answer='{{#llm.text#}}')], name='Chatflow durable context acceptance')
doc['workflow']['conversation_variables'] = [{'id': str(uuid.uuid4()), 'name': 'topic', 'value_type': 'string', 'value': 'initial'}]
app = client.import_dsl(doc)
stub.post('/stub/script', {'rules': [{'match': 'first-literal', 'reply': 'reply-one'}, {'match': 'second', 'reply': 'reply-two'},
                                   {'match': '', 'reply': 'reply-branch'}]})
q1 = 'first-literal {{#sys.query#}}'
stub.post('/stub/reset', {})
f1 = send(app, q1); cid, m1, run1 = common(f1)
assert terminal(f1)['status'] == 'succeeded', terminal(f1)
assert answer(f1) == 'reply-one' and f1[-1]['event'] == 'message_end', f1
req1 = model_request(); assert [m['role'] for m in req1] == ['system', 'user'], req1
save('turn-one', f1); save('request-one', req1); mark('first-turn-signed-plugin-and-durable-message')
stub.post('/stub/reset', {})
f2 = send(app, 'second', cid, m1); _, m2, run2 = common(f2)
assert terminal(f2)['status'] == 'succeeded' and answer(f2) == 'reply-two', f2
req2 = model_request()
assert [m['role'] for m in req2] == ['system', 'user', 'assistant', 'user'], req2
assert text(req2[1]) == q1 and text(req2[2]) == 'reply-one' and text(req2[3]) == 'second', req2
assert q1 in text(req2[0]), req2
save('turn-two', f2); save('request-two', req2); mark('actual-second-turn-parent-memory-literal-query-and-conversation-variable')
variables = session.get(f'/v1/apps/{app}/advanced-chat/workflows/draft/conversation-variables?conversation_id={cid}')
assert next(x['value'] for x in variables['data'] if x['name'] == 'topic') == 'second', variables
save('conversation-variables', variables)
stub.post('/stub/reset', {})
f3 = send(app, 'regenerated branch', cid, m1)
assert terminal(f3)['status'] == 'succeeded', f3
req3 = model_request(); assert all(text(m) != 'second' for m in req3[1:]), req3
assert text(req3[1]) == q1 and text(req3[2]) == 'reply-one', req3
save('branch-request', req3); mark('regeneration-follows-parent-branch')
stub.post('/stub/reset', {})
other = send(app, 'new independent conversation')
assert common(other)[0] != cid and len(model_request()) == 2, other
mark('independent-conversation-has-no-foreign-history')
expect_status(lambda: send(app, 'foreign parent', common(other)[0], m1), 400)
mark('foreign-parent-rejected-before-execution')
# A refused provider invocation closes ownership; an explicit retry creates a new durable turn, without replaying it.
stub.post('/stub/script', {'rules': [{'match': '', 'status': 400, 'error': 'deterministic refusal'}]})
failure = send(app, 'failed turn', cid, m2)
assert terminal(failure)['status'] == 'failed', failure
stub.post('/stub/script', {'rules': [{'match': '', 'reply': 'recovered'}]})
retry = send(app, 'retry turn', cid, m2)
assert terminal(retry)['status'] == 'succeeded' and answer(retry) == 'recovered', retry
history = session.get(f'/v1/apps/{app}/chat-messages?conversation_id={cid}')['data']
assert len(history) == 5 and len({m['id'] for m in history}) == 5, history
assert next(m for m in history if m['query'] == 'failed turn')['status'] == 'error', history
save('history-after-retry', history); mark('provider-failure-releases-turn-for-explicit-retry')
# Pure HTTP -> human input -> answer. A real new process resumes the snapshot, never replays the HTTP effect.
http = node('http', 'http-request', method='get', url='http://llmstub:8000/http/chatflow-effect?case=' + str(uuid.uuid4()),
    authorization={'type': 'no-auth'}, headers='', params='', body={'type': 'none', 'data': []})
human = node('human', 'human-input', form_content='Your answer {{#$output.reply#}}',
    inputs=[{'type': 'paragraph', 'output_variable_name': 'reply'}],
    user_actions=[{'id': 'approve', 'title': 'Approve', 'button_style': 'primary'}])
paused_app = client.import_dsl(chat([node('start', 'start', variables=[]), http, human,
    node('answer', 'answer', answer='Accepted {{#human.reply#}}')],
    edges=[('start', 'source', 'http'), ('http', 'source', 'human'), ('human', 'approve', 'answer')], name='Chatflow pause restart acceptance'))
paused = send(paused_app, 'pause then restart'); pcid, pmid, prid = common(paused)
assert paused[-1]['event'] == 'workflow_paused', paused
form = next(f['data'] for f in paused if f.get('event') == 'human_input_required')
expect_status(lambda: send(paused_app, 'concurrent rejected', pcid, pmid), 409)
mark('paused-turn-blocks-concurrent-send')
before = subprocess.check_output(['docker', 'inspect', 'winnie-runtime-check-server-1', '--format', '{{.State.Pid}}'], text=True).strip()
subprocess.run(['docker', 'compose', '-p', 'winnie-runtime-check', '-f', str(a.compose), '--profile', 'runtime', 'restart', 'server'], check=True)
for _ in range(120):
    try:
        if requests.get(a.base + '/healthz', timeout=2).status_code == 200: break
    except requests.RequestException: pass
    time.sleep(.25)
else: raise AssertionError('new process did not start')
after = subprocess.check_output(['docker', 'inspect', 'winnie-runtime-check-server-1', '--format', '{{.State.Pid}}'], text=True).strip()
assert before != after
replay = frames('GET', f'/v1/workflow/{prid}/events?include_state_snapshot=true&continue_on_pause=false')
assert any(f.get('event') == 'human_input_required' for f in replay), replay
session.post('/v1/form/human_input/' + form['form_token'], {'inputs': {'reply': 'after restart'}, 'action': 'approve'})
for _ in range(120):
    detail = session.get(f'/v1/apps/{paused_app}/workflow-runs/{prid}')
    if detail['status'] != 'paused' and detail['status'] != 'running': break
    time.sleep(.1)
assert detail['status'] == 'succeeded', detail
restored = session.get(f'/v1/apps/{paused_app}/chat-messages?conversation_id={pcid}')['data']
assert len(restored) == 1 and restored[0]['id'] == pmid and restored[0]['answer'] == 'Accepted after restart', restored
http_calls = [x for x in stub.get('/http/log')['requests'] if x['path'] == http['data']['url'].split('8000', 1)[1]]
assert len(http_calls) == 1, http_calls
ended = frames('GET', f'/v1/workflow/{prid}/events?include_state_snapshot=true')
assert [f['event'] for f in ended] == ['message_replace', 'workflow_finished', 'message_end'], ended
assert ended[0]['answer'] == restored[0]['answer'], ended
save('restart-evidence', {'pidChanged': True, 'paused': paused, 'replay': replay, 'restored': restored, 'ended': ended, 'httpCalls': len(http_calls)})
mark('new-service-process-same-database-human-input-recovery-no-http-replay')
# A mid-invocation crash has no resumable node checkpoint. Expire its durable lease, retain the message, and require
# an explicit new turn rather than automatically repeating the external request.
def started_slow_turn(app_id, query, cid=None, parent=None):
    body = {'query': query, 'inputs': {}}
    if cid: body['conversation_id'] = cid
    if parent: body['parent_message_id'] = parent
    response = requests.post(a.base + f'/v1/apps/{app_id}/advanced-chat/workflows/draft/run', headers=session.headers,
                             json=body, stream=True, timeout=20)
    assert response.status_code == 200, response.status_code
    for line in response.iter_lines(chunk_size=1, decode_unicode=True):
        if line.startswith('data: '):
            frame = json.loads(line[6:])
            if frame.get('event') == 'workflow_started': return response, frame
    raise AssertionError('no accepted turn')
slow = node('http', 'http-request', method='get', url='http://llmstub:8000/http/slow?seconds=5&case=' + str(uuid.uuid4()),
    authorization={'type': 'no-auth'}, headers='', params='', body={'type': 'none', 'data': []})
slow_app = client.import_dsl(chat([node('start', 'start', variables=[]), slow,
    node('answer', 'answer', answer='completed {{#sys.query#}}')], name='Chatflow interrupted invocation acceptance'))
response, started = started_slow_turn(slow_app, 'interrupted')
scid, smid, srid = started['conversation_id'], started['message_id'], started['workflow_run_id']
path = slow['data']['url'].split('8000', 1)[1]
for _ in range(100):
    calls = [x for x in stub.get('/http/log')['requests'] if x['path'] == path]
    if calls: break
    time.sleep(.03)
assert len(calls) == 1, calls
subprocess.run(['docker', 'kill', '--signal', 'KILL', 'winnie-runtime-check-server-1'], check=True, stdout=subprocess.DEVNULL)
response.close()
subprocess.run(['docker', 'compose', '-p', 'winnie-runtime-check', '-f', str(a.compose), '--profile', 'runtime',
                'up', '-d', '--force-recreate', '--no-deps', '--no-build', '--pull', 'never', 'server'], check=True, stdout=subprocess.DEVNULL)
for _ in range(200):
    try:
        state = session.get(f'/v1/apps/{slow_app}/workflow-runs/{srid}')
        if state['status'] == 'failed': break
    except Exception: pass
    time.sleep(.25)
else: raise AssertionError('abandoned turn never released its conversation')
assert len([x for x in stub.get('/http/log')['requests'] if x['path'] == path]) == 1
crashed = session.get(f'/v1/apps/{slow_app}/chat-messages?conversation_id={scid}')['data']
assert len(crashed) == 1 and crashed[0]['id'] == smid and crashed[0]['status'] == 'error', crashed
save('interrupted-turn', {'run': state, 'messages': crashed, 'httpCallsBeforeRetry': 1})
recovered = send(slow_app, 'explicit retry', scid, smid)
assert terminal(recovered)['status'] == 'succeeded' and answer(recovered) == 'completed explicit retry', recovered
assert len([x for x in stub.get('/http/log')['requests'] if x['path'] == path]) == 2
mark('actual-process-kill-abandoned-turn-expires-without-external-replay-explicit-retry-succeeds')
# Stop is durable too; it releases the conversation, and a late external response cannot turn it back into success.
response, stop_started = started_slow_turn(slow_app, 'stop this turn', scid, common(recovered)[1])
stop_run = stop_started['workflow_run_id']
session.post(f'/v1/apps/{slow_app}/chat-messages/{stop_run}/stop', {})
response.close(); time.sleep(.3)
assert session.get(f'/v1/apps/{slow_app}/workflow-runs/{stop_run}')['status'] == 'stopped'
final = send(slow_app, 'after stop', scid, common(recovered)[1])
assert terminal(final)['status'] == 'succeeded' and answer(final) == 'completed after stop', final
assert session.get(f'/v1/apps/{slow_app}/workflow-runs/{stop_run}')['status'] == 'stopped'
mark('stopped-turn-remains-terminal-and-next-turn-is-accepted')
# The other model nodes use the same durable, literal parent history, not a second memory store.
for kind in ('question-classifier', 'parameter-extractor'):
    memory = {'window': {'enabled': True, 'size': 10}}
    if kind == 'question-classifier':
        model_node = node('model', kind, model=model, query_variable_selector=['sys', 'query'],
            classes=[{'id': 'tech', 'name': 'Tech'}], instruction='', memory=memory)
        answer_node = node('answer', 'answer', answer='{{#model.class_id#}}')
        edges = [('start', 'source', 'model'), ('model', 'tech', 'answer')]
        reply, expected = '{"category_id":"tech","category_name":"Tech"}', 'tech'
    else:
        model_node = node('model', kind, model=model, query=['sys', 'query'], parameters=[
            {'name': 'name', 'type': 'string', 'description': 'Name', 'required': True}],
            instruction='', reasoning_mode='prompt', memory=memory)
        answer_node = node('answer', 'answer', answer='{{#model.name#}}')
        edges = [('start', 'source', 'model'), ('model', 'source', 'answer')]
        reply, expected = '{"name":"Ann"}', 'Ann'
    memory_app = client.import_dsl(chat([node('start', 'start', variables=[]), model_node, answer_node], edges=edges,
        name=kind + ' actual durable memory'))
    stub.post('/stub/script', {'rules': [{'match': '', 'reply': reply}]})
    prior_query = 'prior-' + kind + ' {{#sys.query#}}'
    first = send(memory_app, prior_query)
    assert terminal(first)['status'] == 'succeeded' and answer(first) == expected, first
    stub.post('/stub/reset', {})
    second = send(memory_app, 'second-' + kind, common(first)[0], common(first)[1])
    assert terminal(second)['status'] == 'succeeded' and answer(second) == expected, second
    prompt = '\n'.join(text(m) for m in model_request())
    assert prior_query in prompt and expected in prompt, prompt
    save(kind + '-memory', {'frames': second, 'request': model_request()})
    mark(kind + '-actual-parent-history-is-literal')
save('artifacts', {'app': app, 'conversation': cid, 'pausedApp': paused_app, 'pausedConversation': pcid, 'pausedRun': prid})
save('result', {'success': True, 'checks': checks, 'actualSignedPlugin': True, 'externalPaidModel': False})
