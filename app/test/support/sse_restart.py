"""A run pauses; its follower's connection is cut when the server restarts; the new process finishes the run and, in the
same window, the follower's stream (a separate HTTP connection) stops receiving. Prints the frames each connection saw."""
import json, os, subprocess, threading, time, urllib.request, urllib.error

B = os.environ.get('DIFYSF_RUNTIME_URL', 'http://127.0.0.1:18080')
E = os.environ.get('DIFYSF_EMAIL', 'e2e-owner@example.test')
P = os.environ.get('DIFYSF_PASSWORD', 'E2e-throwaway-1')
SERVER = os.environ.get('DIFYSF_SERVER_CONTAINER', 'difydesign-server-1')
WORKFLOW = os.environ.get('DIFYSF_HUMAN_YAML', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sse_restart_workflow.yaml'))

def call(method, path, body=None, token=None):
    r = urllib.request.Request(B + path, data=json.dumps(body).encode() if body is not None else None, method=method)
    r.add_header('Content-Type', 'application/json')
    if token: r.add_header('Authorization', 'Bearer ' + token)
    try:
        with urllib.request.urlopen(r, timeout=30) as f:
            raw = f.read(); return f.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:200]

_, login = call('POST', '/v1/auth/login', {'email': E, 'password': P})
T = login['access_token']
yaml = open(WORKFLOW).read()
st, imp = call('POST', '/v1/docs/import', {'yaml': yaml}, T)
app = imp['id']
r = urllib.request.Request(f'{B}/v1/apps/{app}/workflows/draft/run', data=b'{"inputs":{}}', method='POST')
r.add_header('Content-Type', 'application/json'); r.add_header('Accept', 'text/event-stream'); r.add_header('Authorization', 'Bearer ' + T)
token = run = None
with urllib.request.urlopen(r, timeout=30) as f:
    for raw in f:
        line = raw.decode().strip()
        if line.startswith('data: '):
            fr = json.loads(line[6:])
            run = fr.get('workflow_run_id', run)
            if fr.get('event') == 'human_input_required': token = fr['data']['form_token']
            if fr.get('event') == 'workflow_paused': break
print('run', run, 'form', token)

seen = []
def follow():
    """The client's own behaviour after a server restart: one more `GET /events` once the TCP connection is gone."""
    r = urllib.request.Request(f'{B}/v1/workflow/{run}/events?include_state_snapshot=true&continue_on_pause=true')
    r.add_header('Authorization', 'Bearer ' + T); r.add_header('Accept', 'text/event-stream')
    try:
        with urllib.request.urlopen(r, timeout=60) as f:
            for raw in f:
                line = raw.decode().strip()
                if line.startswith('data: '):
                    seen.append(json.loads(line[6:]).get('event'))
    except Exception as e:
        seen.append('CONNECTION-LOST: %s' % type(e).__name__)

first = threading.Thread(target=follow); first.start()
time.sleep(1)
print('restarting the server (SIGTERM), then answering over HTTP')
subprocess.run(['docker', 'stop', '--time', '20', SERVER], capture_output=True)
subprocess.run(['docker', 'start', SERVER], capture_output=True)
for _ in range(60):
    try:
        st, _b = call('GET', '/v1/setup')
        if st == 200: break
    except Exception:
        pass
    time.sleep(1)
try:
    print('answer:', call('POST', f'/v1/form/human_input/{token}', {'inputs': {'reply': 'yes'}, 'action': 'approve'}, T)[0])
except Exception as e:
    print('answer failed:', e)
first.join(60)
print('frames of the original follow:', seen)
# The reconnect the client makes after a lost connection: its stream replays the run from the records.
seen2 = []
def follow2():
    r = urllib.request.Request(f'{B}/v1/workflow/{run}/events?include_state_snapshot=true&continue_on_pause=true')
    r.add_header('Authorization', 'Bearer ' + T); r.add_header('Accept', 'text/event-stream')
    with urllib.request.urlopen(r, timeout=30) as f:
        for raw in f:
            line = raw.decode().strip()
            if line.startswith('data: '): seen2.append(json.loads(line[6:]).get('event'))
follow2()
print('frames of a follow after the restart:', seen2)
st, detail = call('GET', f'/v1/apps/{app}/workflow-runs/{run}', None, T)
print('run status:', detail.get('status'), 'outputs:', detail.get('outputs'))

# The frames of the very first pause (the stream the run started on is separate; here the follow's own).
import pathlib
pathlib.Path(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'sse_restart.frames.json')).write_text(
    json.dumps({'original': seen, 'after_restart': seen2}, indent=1) + '\n')
