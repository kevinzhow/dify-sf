#!/usr/bin/env python3
"""Real process restart, unanswered-pause renewal, shell side effects and nested uploaded files.

Requires Docker, the signed official OpenAI-compatible plugin fixture, and built Swift/Dart binaries.
All inputs are synthetic. Does not connect to a vendor or change a trial deployment.
See README.md for environment variables and limits. Containers/data are retained for failure inspection.
"""
import base64
import hashlib
import json
import os
import pathlib
import subprocess
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent
OUT = pathlib.Path(os.environ['AGENT_E2E_OUT']).resolve()
TOOLS = pathlib.Path(os.environ['AGENT_E2E_TOOLS']).resolve()
BUILD = pathlib.Path(os.environ['AGENT_E2E_BUILD']).resolve()
PREFIX = os.environ.get('AGENT_E2E_PREFIX', 'winnie-agent-restart')
NETWORK = os.environ.get('AGENT_E2E_NETWORK', 'winnie-agent-inline-tests')
IMAGE = os.environ.get('AGENT_E2E_IMAGE', 'winnie-runtime-dev:local')
DART_IMAGE = os.environ.get('AGENT_E2E_DART_IMAGE', 'sha256:52e3b8dd5c1ece67fa823a469500a424abfc411d9c7dbf2123899477b8685984')
PORT = int(os.environ.get('AGENT_E2E_PORT', '21406'))
CORE_BIN = os.environ.get('AGENT_E2E_CORE_BIN', 'agent-service-core-2395331')
SUPERVISOR_BIN = os.environ.get('AGENT_E2E_SUPERVISOR_BIN', 'agent-supervisor-2395331')
assert all(pathlib.PurePath(name).name == name and name not in ['', '.', '..'] for name in [CORE_BIN, SUPERVISOR_BIN])
LABEL = 'raft.fixture=agent-restart-20261025'
PG, ALIAS, SERVICE, SUPERVISOR, PROVIDER = [PREFIX + '-' + suffix for suffix in ['pg', 'api', 'runtime', 'supervisor', 'provider']]
BASE = f'http://127.0.0.1:{PORT}'
TOKEN = None
OUT.mkdir(parents=True, exist_ok=True)
(OUT / 'provider').mkdir(exist_ok=True)
(OUT / 'files').mkdir(exist_ok=True)


def docker(*args, binary=False):
    return subprocess.check_output(['docker', *args], text=not binary).strip()


def create(name, image, memory, cpus, args, command):
    # Never reuse another invocation's containers, including an earlier failed run.
    result = subprocess.run(['docker', 'inspect', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode == 0:
        raise RuntimeError(f'Container already exists: {name}; choose a new prefix')
    return docker('run', '-d', '--name', name, '--label', 'raft.owner=Winnie', '--label', LABEL,
                  '--network', NETWORK, '--memory', memory, '--memory-swap', memory, '--cpus', cpus,
                  '--pids-limit', '128', *args, *(['--entrypoint', command[0]] if command else []), image, *command[1:])


def request(path, body=None, method=None, token=True, raw=False, timeout=180):
    headers = {'Content-Type': 'application/json'}
    if TOKEN and token:
        headers['Authorization'] = 'Bearer ' + TOKEN
    data = None if body is None else body.encode() if isinstance(body, str) else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            payload = response.read()
    except urllib.error.HTTPError as error:
        raise RuntimeError(f'HTTP {error.code} {path}: {error.read().decode()}') from error
    return payload.decode() if raw else json.loads(payload)


def sql(statement):
    return docker('exec', PG, 'psql', '-U', 'collab', '-d', 'collab', '-Atc', statement)


def wait_until(check, seconds=90):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            last = check()
            if last:
                return last
        except (OSError, ValueError, RuntimeError) as error:
            last = str(error)
        time.sleep(.5)
    raise RuntimeError(f'Timeout: {last}')


def api(name):
    env = {'COLLAB_DB_HOST': PG, 'COLLAB_DB_USER': 'collab', 'COLLAB_DB_PASSWORD': 'collab', 'COLLAB_DB_NAME': 'collab',
        'COLLAB_HTTP_HOST': '0.0.0.0', 'COLLAB_HTTP_PORT': '8080', 'COLLAB_HUMAN_INPUT_WEB_ENABLED': 'true',
        'COLLAB_AGENT_INLINE_ENABLED': 'true', 'COLLAB_AGENT_SHELL_ENABLED': 'true', 'COLLAB_AGENT_SERVICE_URL': f'http://{SERVICE}:5050',
        'COLLAB_AGENT_SERVICE_KEY': 'fixture-agent-service-key', 'COLLAB_AGENT_TIMEOUT_SECONDS': '600',
        'COLLAB_PLUGIN_DAEMON_URL': 'http://winnie-agent-plugin-daemon:5002', 'COLLAB_PLUGIN_DAEMON_KEY': 'fixture-daemon-key',
        'COLLAB_PLUGIN_DAEMON_TENANT': '00000000-0000-0000-0000-000000000001', 'COLLAB_MODELS_VALIDATE': 'false',
        'COLLAB_SECRETS_KEY': base64.b64encode(b'F' * 32).decode(), 'COLLAB_FILES_DIRECTORY': '/files',
        'COLLAB_FILES_SIGNING_KEY': 'fixture-only-signing-key' * 2, 'COLLAB_FILES_INTERNAL_URL': f'http://{ALIAS}:8080',
        'COLLAB_FILES_URL': BASE, 'COLLAB_LOG_LEVEL': 'info'}
    args = ['--network-alias', ALIAS, '--user', f'{os.getuid()}:{os.getgid()}', '-p', f'127.0.0.1:{PORT}:8080',
            '-v', str(BUILD) + ':/build:ro', '-v', str(OUT / 'files') + ':/files']
    for key, value in env.items():
        args += ['-e', f'{key}={value}']
    create(name, IMAGE, '1g', '1', args, ['/build/release/collab-server'])
    wait_until(lambda: request('/v1/setup', token=False))


def frames(wire):
    return [json.loads(line[6:]) for line in wire.splitlines() if line.startswith('data: {')]


names = [PG, SERVICE, SUPERVISOR, PROVIDER, PREFIX + '-a', PREFIX + '-b']
try:
    create(PG, 'postgres:15-alpine', '512m', '.5', ['-e', 'POSTGRES_USER=collab', '-e', 'POSTGRES_PASSWORD=collab', '-e', 'POSTGRES_DB=collab'], [])
    wait_until(lambda: subprocess.run(['docker', 'exec', PG, 'pg_isready', '-U', 'collab'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0)
    create(PROVIDER, 'python:3.12-alpine', '96m', '.2', ['-v', str(ROOT / 'provider.py') + ':/provider.py:ro', '-v', str(OUT / 'provider') + ':/evidence'], ['python', '/provider.py'])
    group = str(os.stat('/var/run/docker.sock').st_gid)
    common = ['--read-only', '--tmpfs', '/tmp:rw,nosuid,nodev,size=32m', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true', '--user', '10001:10001', '-v', str(TOOLS) + ':/tools:ro']
    create(SUPERVISOR, DART_IMAGE, '256m', '.5', common + ['--group-add', group, '-v', '/var/run/docker.sock:/var/run/docker.sock',
        '-e', 'SANDBOX_SUPERVISOR_KEY=fixture-supervisor-key', '-e', 'SANDBOX_AGENT_PEERS=' + SERVICE,
        '-e', 'SANDBOX_LABEL=winnie.agent-restart=20261025', '-e', 'SANDBOX_NAME_PREFIX=' + PREFIX + '-sandbox-',
        '-e', 'SANDBOX_SUBNET_POOL=10.219.240.0/20', '-e', 'SANDBOX_STATE_FILE=/tmp/state.json',
        '-e', 'SANDBOX_MEMORY_MB=384', '-e', 'SANDBOX_CPUS=.5', '-e', 'SANDBOX_HOME_MB=64', '-e', 'SANDBOX_WORKSPACE_MB=128'], ['/tools/' + SUPERVISOR_BIN])
    create(SERVICE, DART_IMAGE, '384m', '.5', common + ['-e', 'AGENT_SERVICE_KEY=fixture-agent-service-key', '-e', 'AGENT_DATA_DIR=/tmp/state',
        '-e', 'AGENT_INNER_URL=http://' + ALIAS + ':8080', '-e', 'AGENT_SANDBOX_SUPERVISOR_URL=http://' + SUPERVISOR + ':5060',
        '-e', 'AGENT_SANDBOX_SUPERVISOR_KEY=fixture-supervisor-key'], ['/tools/' + CORE_BIN])
    # A created container is not a ready HTTP endpoint, especially under bounded CPU during the full suite.
    def http_ready(url, isolated=False):
        code = ('import json,sys,urllib.request; '
                'req=urllib.request.Request(sys.argv[1],headers={"Authorization":"Bearer fixture-agent-service-key"}); '
                'value=json.load(urllib.request.urlopen(req,timeout=2)); '
                'assert sys.argv[2]!="isolated" or value.get("sandbox")=="isolated"')
        return subprocess.run(['docker', 'exec', PROVIDER, 'python', '-c', code, url,
                               'isolated' if isolated else 'http'], capture_output=True).returncode == 0
    wait_until(lambda: http_ready('http://127.0.0.1:8000/v1/models'))
    wait_until(lambda: http_ready(f'http://{SERVICE}:5050/v1/health', isolated=True))
    api(PREFIX + '-a')
    TOKEN = request('/v1/setup', {'email': 'agent-restart@example.test', 'name': 'Agent restart fixture', 'password': 'fixture-password-1234'}, token=False)['access_token']
    request('/v1/workspace/model-providers/langgenius/openai_api_compatible/openai_api_compatible/models/credentials',
        {'model': 'stub-chat', 'model_type': 'llm', 'credentials': {'endpoint_url': f'http://{PROVIDER}:8000/v1', 'api_key': 'synthetic-not-a-vendor-key',
        'mode': 'chat', 'context_size': '4096', 'max_tokens_to_sample': '4096', 'function_calling_type': 'tool_call', 'agent_thought_support': 'only_thinking_supported'}})
    yaml = '''app: {mode: workflow, name: Agent restart fixture}
kind: app
version: 0.3.1
workflow:
  features: {}
  environment_variables: []
  conversation_variables: []
  graph:
    nodes:
    - id: start
      data: {type: start, title: Start, variables: []}
    - id: inline-agent
      data: {type: agent, version: '2', title: 'Fixture operator', agent_node_kind: dify_agent, agent_task: fixture-restart, agent_declared_outputs: []}
    - id: end
      data:
        type: end
        title: End
        outputs: [{variable: bundle, value_selector: [inline-agent, bundle]}, {variable: score, value_selector: [inline-agent, score]}]
    edges:
    - {id: a, source: start, sourceHandle: source, target: inline-agent, targetHandle: target}
    - {id: b, source: inline-agent, sourceHandle: source, target: end, targetHandle: target}
'''
    app = request('/v1/docs/import', yaml)['id']
    soul = {'model': {'plugin_id': 'langgenius/openai_api_compatible', 'model_provider': 'openai_api_compatible', 'model': 'stub-chat', 'model_settings': {}},
        'prompt': {'system_prompt': 'Execute the deterministic fixture tools.'}, 'human': {'contacts': [{'id': 'operator', 'name': 'Operator', 'method': 'web_app'}], 'tools': []}}
    import uuid
    request(f'/v1/apps/{app}/workflows/draft/nodes/inline-agent/agent-composer', {'variant': 'workflow', 'expected_seq': 0,
        'idempotency_key': str(uuid.uuid4()), 'save_strategy': 'save_to_current_version', 'agent_soul': soul,
        'node_job': {'workflow_prompt': 'fixture-restart', 'declared_outputs': [{'name': 'score', 'type': 'number'},
            {'name': 'bundle', 'type': 'object', 'children': [{'name': 'artifacts', 'type': 'array', 'array_item': {'type': 'file'}}]}]}}, method='PUT')
    wire = request(f'/v1/apps/{app}/workflows/draft/run', {'inputs': {}}, raw=True)
    (OUT / 'first.sse').write_text(wire)
    initial_logs = [frame['data'] for frame in frames(wire) if frame['event'] == 'agent_log']
    assert initial_logs, 'Live tool/thought logs must arrive before the first pause'
    first = next(frame['data'] for frame in frames(wire) if frame['event'] == 'human_input_required')
    run = sql('SELECT workflow_run_id FROM human_input_forms WHERE token = ' + "'" + first['form_token'] + "'")
    execution = sql("SELECT execution_id FROM agent_node_sessions WHERE workflow_run_id='" + run + "'")
    owner = sql("SELECT owner_id FROM agent_node_sessions WHERE execution_id='" + execution + "'")
    container_a = json.loads(docker('inspect', PREFIX + '-a'))[0]
    assert sql("SELECT status FROM workflow_runs WHERE id='" + run + "'") == 'paused'
    docker('stop', '-t', '15', PREFIX + '-a')
    docker('network', 'disconnect', NETWORK, PREFIX + '-a')
    api(PREFIX + '-b')
    container_b = json.loads(docker('inspect', PREFIX + '-b'))[0]
    assert container_a['Id'] != container_b['Id']
    assert container_a['State']['Pid'] != container_b['State']['Pid']
    wait_until(lambda: sql("SELECT generation FROM agent_node_sessions WHERE execution_id='" + execution + "'") == '2')
    assert sql("SELECT owner_id FROM agent_node_sessions WHERE execution_id='" + execution + "'") != owner
    replay_wire = request(f'/v1/workflow/{run}/events?include_state_snapshot=true', raw=True)
    (OUT / 'restarted-paused.sse').write_text(replay_wire)
    replay = frames(replay_wire)
    replay_logs = [frame['data'] for frame in replay if frame['event'] == 'agent_log']
    assert replay_logs == initial_logs, 'A new process must recover every committed log in the same order'
    original_started = next(frame['data'] for frame in frames(wire) if frame['event'] == 'node_started' and frame['data']['id'] == execution)
    assert next(frame['data'] for frame in replay if frame['event'] == 'node_started' and frame['data']['id'] == execution) == original_started


    print('New process adopted unanswered pause. Waiting beyond remote lease TTL.', flush=True)
    waited = time.monotonic()
    while time.monotonic() - waited < 130:
        time.sleep(5)
        assert sql("SELECT status FROM agent_node_sessions WHERE execution_id='" + execution + "'") == 'paused'
    request('/v1/form/human_input/' + first['form_token'], {'action': 'submit', 'inputs': {'answer': 'First answer'}})
    second = wait_until(lambda: sql("SELECT token FROM human_input_forms WHERE workflow_run_id='" + run + "' AND question_id='" + execution + ":q2'"))
    request('/v1/form/human_input/' + second, {'action': 'submit', 'inputs': {'answer': 'Second answer'}})
    wait_until(lambda: sql("SELECT status FROM workflow_runs WHERE id='" + run + "'") in ['succeeded', 'failed'])
    state = sql("SELECT row_to_json(r)::text FROM workflow_runs r WHERE id='" + run + "'")
    (OUT / 'run.json').write_text(state)
    result = json.loads(state)
    assert result['status'] == 'succeeded', state
    terminal_wire = request(f'/v1/workflow/{run}/events?include_state_snapshot=true', raw=True)
    (OUT / 'completed-replay.sse').write_text(terminal_wire)
    terminal = frames(terminal_wire)
    # Completed events queries intentionally return only the terminal frame (Dify 1.16).
    assert [frame['event'] for frame in terminal] == ['workflow_finished']
    assert terminal[-1]['data']['status'] == 'succeeded'
    detail = request(f'/v1/apps/{app}/workflow-runs/{run}/node-executions')
    (OUT / 'node-executions.json').write_text(json.dumps(detail))
    trace = next(item for item in detail['data'] if item['id'] == execution)
    final_logs = trace['execution_metadata']['agent_log']
    assert final_logs[:len(initial_logs)] == initial_logs and len(final_logs) > len(initial_logs)
    assert len({log['message_id'] for log in final_logs}) == len(final_logs), 'Persisted log IDs must be unique'
    archived_logs = json.loads(sql("SELECT coalesce(jsonb_agg(item ORDER BY ordinal), '[]'::jsonb) FROM agent_event_records, LATERAL jsonb_array_elements(log::jsonb) item WHERE execution_id='" + execution + "' AND log IS NOT NULL"))
    assert final_logs == archived_logs, 'Finished node detail must retain the same durable logs'
    outputs = result['outputs']
    if isinstance(outputs, str): outputs = json.loads(outputs)
    assert outputs['score'] == 7
    artifact = outputs['bundle']['artifacts'][0]
    downloaded = urllib.request.urlopen(artifact['url']).read()
    assert downloaded == b'owned artifact; counter=1\n', downloaded
    requests = [json.loads(line) for line in (OUT / 'provider/requests.jsonl').read_text().splitlines()]
    assert len(requests) == 5, len(requests)
    history = requests[-1]['messages']
    assert sum(m.get('tool_call_id') == 'side-effect/once' for m in history if m.get('role') == 'tool') == 1
    assert 'counter=1' in str(next(m['content'] for m in history if m.get('tool_call_id') == 'verify/after-restart'))
    wait_until(lambda: sql("SELECT count(*) FROM agent_runtime_outbox WHERE done_at IS NULL") == '0')
    (OUT / 'result.json').write_text(json.dumps({'passed': True, 'app': app, 'run': run, 'execution': execution,
        'process_a': container_a['Id'], 'process_b': container_b['Id'], 'generation': 2, 'unanswered_wait_seconds': time.monotonic() - waited,
        'model_calls': 5, 'shell_side_effect_count': 1, 'initial_log_count': len(initial_logs),
        'recovered_log_count': len(replay_logs), 'completed_log_count': len(final_logs), 'unique_log_ids': True, 'nested_file_sha256': hashlib.sha256(downloaded).hexdigest()}, indent=2))
    print('PASS: real process restart; lease renewal beyond TTL; two questions; shell side effect once; nested uploaded file; ACK and cleanup.', flush=True)
finally:
    for name in names:
        info = subprocess.run(['docker', 'inspect', name], capture_output=True, text=True)
        if info.returncode == 0:
            (OUT / (name + '.inspect.json')).write_text(info.stdout)
            logs = subprocess.run(['docker', 'logs', name], capture_output=True, text=True)
            (OUT / (name + '.log')).write_text(logs.stdout + logs.stderr)
            subprocess.run(['docker', 'stop', '-t', '10', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
