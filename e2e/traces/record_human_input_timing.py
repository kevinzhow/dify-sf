"""Record Dify 1.17.1's human-input timing over its own HTTP API: pause -> wait -> resume -> finish.

Needs the local Dify ($DIFY_URL, $DIFY_EMAIL, $DIFY_PASSWORD). Imports a workflow with a human-input node,
runs it, waits $WAIT_SECONDS, answers the form, follows the events endpoint, then reads the run's detail and
history. Prints one JSON report: the frames (event, created_at, elapsed_time, status) and the three clock
surfaces (paused row, stream, records), so our server's values can be compared field by field.

Dify's answer, on the recorded run: the paused row has `elapsed_time` 0 with `finished_at` null; the finished
stream frame's `created_at` is the resumed round's start with the round's `elapsed_time`; the detail and the
history keep the run's `created_at` with the round's `elapsed_time`; the events endpoint's snapshot starts with
the run's original `created_at`; `human_input_form_filled` precedes the human node's `node_finished`.
"""
import base64, json, os, re, sys, time
import requests

DIFY = os.environ.get('DIFY_URL', 'http://localhost')
EMAIL = os.environ['DIFY_EMAIL']
PASSWORD = os.environ['DIFY_PASSWORD']
WAIT_SECONDS = float(os.environ.get('WAIT_SECONDS', '3'))

YAML = """
app:
  mode: workflow
  name: hitl-timing
kind: app
version: 0.3.1
workflow:
  conversation_variables: []
  environment_variables: []
  features: {}
  graph:
    edges:
    - {id: e1, source: start, sourceHandle: source, target: human, targetHandle: target}
    - {id: e2, source: human, sourceHandle: approve, target: end, targetHandle: target}
    nodes:
    - id: start
      data:
        title: Start
        type: start
        variables: []
    - id: human
      data:
        title: Approve
        type: human-input
        form_content: 'Please approve'
        inputs:
        - {type: paragraph, output_variable_name: reply}
        user_actions:
        - {id: approve, title: Approve it, button_style: primary}
        delivery_methods:
        - {type: webapp, enabled: true}
    - id: end
      data:
        title: End
        type: end
        outputs:
        - {variable: reply, value_selector: [human, reply]}
"""

s = requests.Session()
pw = base64.b64encode(PASSWORD.encode()).decode()
r = s.post(f'{DIFY}/console/api/login', json={'email': EMAIL, 'password': pw, 'remember_me': True, 'language': 'en-US'})
r.raise_for_status()
csrf = s.cookies.get('csrf_token')
if csrf:
    s.headers['X-CSRF-Token'] = csrf

imp = s.post(f'{DIFY}/console/api/apps/imports', json={'mode': 'yaml-content', 'yaml_content': YAML})
imp.raise_for_status()
body = imp.json()
if body.get('status') == 'pending':
    body = s.post(f'{DIFY}/console/api/apps/imports/{body["id"]}/confirm').json()
app = body['app_id']

report = {'app': app, 'wait_seconds': WAIT_SECONDS, 'frames': [], 'detail': {}, 'history': {}, 'error': None}


def record(name, data, when=None):
    entry = {'event': name, 'at': round(when if when is not None else time.time(), 3)}
    if isinstance(data, dict):
        for key in ('created_at', 'finished_at', 'elapsed_time', 'status', 'workflow_run_id'):
            if key in data:
                entry[key] = data[key]
        entry['keys'] = sorted(data.keys())
    report['frames'].append(entry)


def stream(url, until, timeout=120):
    with s.get(url, stream=True, timeout=timeout, headers={'Accept': 'text/event-stream'}) as res:
        res.raise_for_status()
        for raw in res.iter_lines(decode_unicode=True):
            if not raw or not raw.startswith('data:'):
                continue
            try:
                payload = json.loads(raw[5:].strip())
            except json.JSONDecodeError:
                continue
            event = payload.get('event')
            if event:
                record(event, payload.get('data') or payload, when=time.time())
            if event == until:
                return payload


try:
    run = {}
    with s.post(f'{DIFY}/console/api/apps/{app}/workflows/draft/run', json={'inputs': {}, 'files': []},
                stream=True, timeout=120, headers={'Accept': 'text/event-stream'}) as res:
        res.raise_for_status()
        token = None
        for raw in res.iter_lines(decode_unicode=True):
            if not raw or not raw.startswith('data:'):
                continue
            payload = json.loads(raw[5:].strip())
            event, data = payload.get('event'), payload.get('data') or payload
            if event:
                record(event, data, when=time.time())
            if event == 'human_input_required':
                token = data.get('form_token')
            if event == 'workflow_paused':
                run['paused'] = data
                break
    run_id = (run.get('paused') or {}).get('workflow_run_id') or ''
    report['run_id'] = run_id
    # Detail while paused.
    paused_detail = s.get(f'{DIFY}/console/api/apps/{app}/workflow-runs/{run_id}').json()
    report['paused_detail'] = {k: paused_detail.get(k) for k in ('id', 'status', 'created_at', 'finished_at', 'elapsed_time',
                                                                'total_tokens', 'total_steps')}
    time.sleep(WAIT_SECONDS)
    sub = s.post(f'{DIFY}/console/api/form/human_input/{token}', json={'inputs': {'reply': 'ok'}, 'action': 'approve'})
    report['submit_status'] = sub.status_code
    # Follow the resume on the events endpoint.
    stream(f'{DIFY}/console/api/workflow/{run_id}/events?include_state_snapshot=true&continue_on_pause=true',
           until='workflow_finished')
    detail = s.get(f'{DIFY}/console/api/apps/{app}/workflow-runs/{run_id}').json()
    report['detail'] = {k: detail.get(k) for k in ('id', 'status', 'created_at', 'finished_at', 'elapsed_time',
                                                   'total_tokens', 'total_steps')}
    history = s.get(f'{DIFY}/console/api/apps/{app}/workflow-runs', params={'limit': 5}).json()
    rows = history.get('data') or []
    row = next((x for x in rows if x.get('id') == run_id), {})
    report['history'] = {k: row.get(k) for k in ('id', 'status', 'created_at', 'finished_at', 'elapsed_time',
                                                 'total_tokens', 'total_steps')}
except Exception as exc:  # keep whatever was recorded
    report['error'] = f'{type(exc).__name__}: {exc}'

print(json.dumps(report, ensure_ascii=False, indent=1))
