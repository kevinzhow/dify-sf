"""Formal Wasm UI: real two-turn sends, fresh history, HITL reconnect/restart and durable files. Isolated fixture only."""
import argparse, functools, http.server, json, re, subprocess, sys, threading, time, uuid
from pathlib import Path
from urllib.parse import urlsplit
import requests
from playwright.sync_api import sync_playwright, expect

p = argparse.ArgumentParser()
for key in ('base', 'stub', 'auth-file', 'compose', 'web-root', 'out'): p.add_argument('--' + key, required=True)
a = p.parse_args(); a.out = Path(a.out); a.out.mkdir(parents=True, exist_ok=True)
assert urlsplit(a.base).hostname == '127.0.0.1' and urlsplit(a.base).port == 19092
assert urlsplit(a.stub).hostname == '127.0.0.1' and urlsplit(a.stub).port == 19094
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compare import DifySF
from lib.e2ehttp import Session
from lib.dify import STUB_PROVIDER, stub_credentials
from runtime_files.acceptance_support import node, workflow
from runtime_files.origin import PNG
api = Session(a.base); login = api.post('/v1/auth/login', json.loads(Path(a.auth_file).read_text()))
tokens = {k: login[k] for k in ('access_token', 'refresh_token')}; api.headers['Authorization'] = 'Bearer ' + tokens['access_token']
client = DifySF.__new__(DifySF); client.s = api; stub = Session(a.stub)
def chat(nodes, **kw):
    doc = workflow(nodes, **kw); doc['app']['mode'] = 'advanced-chat'; return doc
model_name = 'stub-browser-reasoning-' + uuid.uuid4().hex[:10]
model = {'provider': STUB_PROVIDER, 'name': model_name, 'mode': 'chat', 'completion_params': {'max_tokens': 256}}
api.post(f'/v1/workspace/model-providers/{STUB_PROVIDER}/models/credentials', {'model': model_name, 'model_type': 'llm', 'credentials': {**stub_credentials(), 'agent_thought_support': 'only_thinking_supported'}})
llm = node('llm', 'llm', model=model, prompt_template=[{'role': 'system', 'text': 'A deterministic chat test'}],
    memory={'window': {'enabled': True, 'size': 10}, 'query_prompt_template': '{{#sys.query#}}'}, reasoning_format='separated',
    context={'enabled': False, 'variable_selector': []}, vision={'enabled': False})
app = client.import_dsl(chat([node('start', 'start', variables=[]), llm, node('answer', 'answer', answer='{{#llm.text#}}')], name='真实多轮对话验收'))
stub.post('/stub/script', {'rules': [{'match': 'browser-first', 'reply': '<think>plan-one</think>browser-reply-one'},
                                   {'match': '', 'reply': '<think>plan-two</think>browser-reply-two'}]})
case = uuid.uuid4().hex
http_node = node('http', 'http-request', method='get', url='http://llmstub:8000/http/browser-chat-effect?case=' + case,
    authorization={'type': 'no-auth'}, headers='', params='', body={'type': 'none', 'data': []})
human = node('human', 'human-input', form_content='审批说明 {{#$output.reply#}}',
    inputs=[{'type': 'paragraph', 'output_variable_name': 'reply'}], user_actions=[{'id': 'approve', 'title': '确认继续', 'button_style': 'primary'}])
hit_app = client.import_dsl(chat([node('start', 'start', variables=[]), http_node, human, node('answer', 'answer', answer='审批完成 {{#human.reply#}}')],
    edges=[('start', 'source', 'http'), ('http', 'source', 'human'), ('human', 'approve', 'answer')], name='对话暂停与重启恢复验收'))
file_app = client.import_dsl(chat([node('start', 'start', variables=[{
    'variable': 'attachment', 'label': '开始文件', 'type': 'file', 'required': True,
    'allowed_file_types': ['image'], 'allowed_file_upload_methods': ['local_file']}]),
    node('answer', 'answer', answer='文件 {{#start.attachment#}} {{#sys.files#}}')], name='对话文件历史验收'))
start_file = a.out / 'chat-start.png'; start_file.write_bytes(PNG)

class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args): pass
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store'); self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp'); super().end_headers()
web = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Quiet, directory=a.web_root))
threading.Thread(target=web.serve_forever, daemon=True).start(); webbase = f'http://127.0.0.1:{web.server_port}'
checks = {}; logs = []; errors = []
def save_json(name, value): (a.out / (name + '.json')).write_text(json.dumps(value, ensure_ascii=False, indent=2))
def payloads(text): return [json.loads(line[6:]) for line in text.splitlines() if line.startswith('data: ')]
def restart():
    old = subprocess.check_output(['docker', 'inspect', '--format', '{{.Id}}', 'winnie-runtime-check-server-1'], text=True).strip()
    subprocess.run(['docker', 'compose', '-p', 'winnie-runtime-check', '-f', a.compose, '--profile', 'runtime', 'up', '-d',
                    '--force-recreate', '--no-deps', '--no-build', '--pull', 'never', 'server'], check=True, stdout=subprocess.DEVNULL)
    for _ in range(120):
        try:
            if requests.get(a.base + '/healthz', timeout=2).status_code == 200: break
        except requests.RequestException: pass
        time.sleep(.25)
    else: raise AssertionError('new server process unavailable')
    new = subprocess.check_output(['docker', 'inspect', '--format', '{{.Id}}', 'winnie-runtime-check-server-1'], text=True).strip()
    assert old != new

try:
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        context = browser.new_context(viewport={'width': 1440, 'height': 1000})
        context.add_init_script(f'localStorage.setItem({json.dumps("dify-sf/tokens/" + a.base)}, {json.dumps(json.dumps(tokens))})')
        page = context.new_page(); page.on('console', lambda m: logs.append(m.text)); page.on('pageerror', lambda e: errors.append(str(e)))
        def save(name):
            # Semantics can precede asynchronous Wasm painting; capture the rendered state after it settles.
            page.wait_for_timeout(1800)
            page.evaluate('() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))')
            page.screenshot(path=str(a.out / (name + '.png')))
            (a.out / (name + '.txt')).write_text(page.locator('body').inner_text())
            save_json('diagnostics', {'logs': logs, 'errors': errors})
        def click(loc):
            loc.wait_for(state='visible', timeout=30000); box = loc.bounding_box(); assert box
            page.mouse.click(box['x'] + box['width'] / 2, box['y'] + box['height'] / 2); page.wait_for_timeout(250)
        def open_page(id, theme='light'):
            page.goto(webbase + f'/?server={a.base}&app={id}&page=workflow&lang=zh-Hans&theme={theme}&visual=1')
            page.wait_for_function("document.querySelector('flt-semantics-placeholder') || document.querySelector('flt-semantics')", timeout=90000)
            if page.locator('flt-semantics-placeholder').count(): page.locator('flt-semantics-placeholder').evaluate('(e)=>e.click()')
            button = page.get_by_role('button', name='预览', exact=True).first
            try: button.wait_for(state='visible', timeout=90000)
            except Exception:
                save('navigation-failure'); raise
            click(button); page.wait_for_timeout(1500)
            save_json('geometry', page.locator('flt-semantics').evaluate_all("els=>els.filter(e=>['button','textbox'].includes(e.getAttribute('role'))).map(e=>({role:e.getAttribute('role'),label:e.getAttribute('aria-label'),text:e.innerText,rect:e.getBoundingClientRect().toJSON()}))"))
        def send(query):
            expect(page.get_by_role('button', name='停止响应', exact=True)).to_be_hidden(timeout=30000)
            page.wait_for_timeout(500)
            field = page.get_by_role('textbox').last; click(field)
            save_json('input-debug', {'box': field.bounding_box(), 'html': field.evaluate('(e)=>e.outerHTML'), 'focused': field.evaluate('(e)=>document.activeElement===e'), 'allFields': page.get_by_role('textbox').evaluate_all('(els)=>els.map(e=>({html:e.outerHTML,parent:e.parentElement.outerHTML.slice(0,7000)}))')})
            page.keyboard.type(query, delay=30); page.wait_for_timeout(500)
            assert field.input_value() == query, {'query': query, 'actual': field.input_value(), 'focused': field.evaluate('(e)=>document.activeElement===e')}
            expect(page.get_by_role('button', name='发送', exact=True).first).to_be_enabled(timeout=15000)
            save('before-send')
            try:
                with page.expect_response(lambda r: r.url.endswith('/advanced-chat/workflows/draft/run') and r.request.method == 'POST', timeout=30000) as response:
                    click(page.get_by_role('button', name='发送', exact=True).first)
            except Exception:
                save('send-failure'); raise
            r = response.value; assert r.status == 200, r.status
            # CDP may discard a completed streaming Fetch body. Read the accepted message from the actual
            # durable API, using the same scoped preference the page uses on refresh; do not resend the POST.
            app_id = re.search(r'/apps/([^/]+)/', r.url).group(1)
            pref = "app => Object.entries(localStorage).find(([k,v]) => k.includes('chatflow:') && k.endsWith(':'+app) && v && v!='\"\"')?.[1]"
            page.wait_for_function(pref, arg=app_id, timeout=30000)
            selected = page.evaluate(pref, app_id)
            try: selected = json.loads(selected)
            except ValueError: pass
            for _ in range(150):
                messages = api.get(f'/v1/apps/{app_id}/chat-messages?conversation_id={selected}')['data']
                message = next((m for m in messages if m['query'] == query), None)
                if message:
                    state = api.get(f"/v1/apps/{app_id}/workflow-runs/{message['workflow_run_id']}")
                    if state['status'] in ('succeeded', 'paused', 'failed', 'stopped'): break
                page.wait_for_timeout(100)
            else: save('accepted-message-missing'); raise AssertionError('accepted UI turn never reached a durable boundary')
            assert state['status'] in ('succeeded', 'paused'), state
            return {'message': message, 'request': r.request.post_data_json, 'run': state, 'httpStatus': r.status}
        open_page(app)
        f1 = send('browser-first'); one = f1['message']
        page.get_by_text('browser-reply-one', exact=False).first.wait_for(state='visible', timeout=30000)
        cid = one['conversation_id']; mid = one['id']
        for _ in range(100):
            if 'VISUAL_RUN succeeded' in logs: break
            page.wait_for_timeout(100)
        else: save('first-not-finished'); raise AssertionError('first turn never finished in the UI')
        f2 = send('browser-second')
        page.get_by_text('browser-reply-two', exact=False).first.wait_for(state='visible', timeout=30000)
        history = api.get(f'/v1/apps/{app}/chat-messages?conversation_id={cid}')['data']
        assert len(history) == 2 and history[1]['parent_message_id'] == mid, history
        assert history[0]['reasoning']['llm'] == 'plan-one' and history[1]['reasoning']['llm'] == 'plan-two', history
        assert history[1]['metadata']['usage']['total_tokens'] > 0, history
        save('01-two-turn-light'); save_json('two-turn-frames', {'first': f1, 'second': f2, 'history': history})
        checks['actualUIModelSendsAndReasoningPersist'] = True
        open_page(app, 'dark')
        page.get_by_text('browser-reply-one', exact=False).first.wait_for(state='visible', timeout=30000)
        page.get_by_text('browser-reply-two', exact=False).first.wait_for(state='visible', timeout=30000)
        assert len(api.get(f'/v1/apps/{app}/chat-messages?conversation_id={cid}')['data']) == 2
        save('02-fresh-page-history-dark'); checks['freshPageRestoresSameTwoMessagesWithoutReexecution'] = True
        # The live SSE connection actually drops on process replacement, while the form input must stay editable.
        open_page(hit_app)
        paused = send('restart-browser-pause')
        start = paused['message']; rid = start['workflow_run_id']; pcid = start['conversation_id']
        page.get_by_role('button', name='确认继续', exact=True).wait_for(state='visible', timeout=30000)
        field = page.get_by_role('textbox').first; click(field); page.keyboard.type('保留输入并恢复', delay=30)
        save('03-paused-with-input-light'); restart(); page.wait_for_timeout(2000)
        save('04-after-real-process-restart')
        click(page.get_by_role('button', name='确认继续', exact=True))
        for _ in range(150):
            detail = api.get(f'/v1/apps/{hit_app}/workflow-runs/{rid}')
            if detail['status'] == 'succeeded': break
            page.wait_for_timeout(200)
        else: save('05-missing-result'); raise AssertionError('chat did not resume')
        page.get_by_text('审批完成 保留输入并恢复', exact=False).first.wait_for(state='visible', timeout=30000)
        calls = [x for x in stub.get('/http/log')['requests'] if ('case=' + case) in x['path']]
        assert len(calls) == 1, calls
        record = api.get(f'/v1/apps/{hit_app}/chat-messages?conversation_id={pcid}')['data']; assert len(record) == 1
        save('05-resumed-answer-light'); checks['actualDroppedSSEReconnectedAndInputSubmittedOnce'] = True
        open_page(hit_app, 'dark')
        page.get_by_text('审批完成 保留输入并恢复', exact=False).first.wait_for(state='visible', timeout=30000)
        save('06-fresh-restored-answer-dark')
        # A real stored file in a later turn is recovered by the page, and its preview returns the original bytes.
        open_page(file_app)
        with page.expect_file_chooser(timeout=20000) as selection:
            click(page.get_by_role('button', name='从本地上传', exact=True).first)
        selection.value.set_files(str(start_file))
        page.get_by_text('chat-start.png', exact=True).first.wait_for(state='visible', timeout=30000)
        save('07-real-chat-start-file-picker')
        root = send('start file conversation')
        assert root['message']['inputs']['attachment']['filename'] == 'chat-start.png', root
        assert root['message']['files'][0]['filename'] == 'chat-start.png', root
        checks['realChatStartFileChooserReachesDurableTurnAndOutput'] = True
        fc = root['message']
        uploaded = api.multipart('/v1/files/upload', {}, {'file': ('chat-history.png', PNG)})
        file_frames = [json.loads(line) for line in api.stream('POST', f'/v1/apps/{file_app}/advanced-chat/workflows/draft/run',
            {'query': 'file turn', 'inputs': {}, 'conversation_id': fc['conversation_id'], 'parent_message_id': fc['id'],
             'files': [{'transfer_method': 'local_file', 'upload_file_id': uploaded['id']}]})]
        assert file_frames[-1]['event'] == 'message_end' and len(file_frames[-1]['files']) == 2, file_frames
        open_page(file_app, 'dark')
        file_button = page.get_by_role('button', name='chat-history.png', exact=True).first
        file_button.wait_for(state='visible', timeout=30000)
        assert page.get_by_role('button', name='chat-history.png', exact=True).count() == 2, 'question and answer retain their file identities'
        save('07-file-history-dark')
        with page.expect_popup(timeout=20000) as previewing: click(file_button)
        preview = previewing.value; preview.wait_for_load_state(); assert requests.get(preview.url, timeout=10).content == PNG
        preview.close(); checks['freshChatFileHistoryAndActualSignedPreview'] = True
        resources = page.evaluate("performance.getEntriesByType('resource').map(e=>e.name)")
        assert any('main.dart.wasm' in x for x in resources) and any('skwasm' in x and '.wasm' in x for x in resources)
        checks['formalMainAndRendererWasmLoaded'] = True
        assert not errors, errors
        checks.update(success=True, app=app, conversation=cid, hitlApp=hit_app, fileApp=file_app,
            serverImage=subprocess.check_output(['docker', 'inspect', '--format', '{{.Image}}', 'winnie-runtime-check-server-1'], text=True).strip(),
            device='Chromium desktop; no physical Android claim')
        save_json('result', checks); browser.close()
finally: web.shutdown()
