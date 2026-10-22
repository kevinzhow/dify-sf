#!/usr/bin/env python3
"""Real Wasm UI, failed submit, SSE reconnect and durable periodic resume.

Needs Docker, dify-sf-dev:local, a release binary/catalog in --runtime-cache/release,
and Playwright Chromium. Every database/container is private to this invocation.
This never connects to or changes the user's trial database.
"""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from playwright.sync_api import sync_playwright


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-cache', type=Path)
    parser.add_argument('--web-build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--image', default='dify-sf-dev:local')
    parser.add_argument('--production-image', action='store_true', help='Use the image entrypoint and bundled binary instead of a mounted release cache')
    parser.add_argument('--server-port', type=int, default=19092)
    parser.add_argument('--web-port', type=int, default=18992)
    args = parser.parse_args()
    if not args.production_image:
        assert args.runtime_cache and (args.runtime_cache / 'release/collab-server').is_file()
    assert (args.web_build / 'main.dart.wasm').is_file()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    out.chmod(0o700)
    for port in (args.server_port, args.web_port):
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            probe.bind(('127.0.0.1', port))
    tag = 'dify-hitl-web-' + str(os.getpid()) + '-' + secrets.token_hex(3)
    net, pg = tag + '-net', tag + '-pg'
    names, checks, resources, errors, follows, failed_requests, console = [], [], [], [], [], [], []
    http = browser = page = playwright = None
    base = 'http://127.0.0.1:' + str(args.server_port)
    site = 'http://127.0.0.1:' + str(args.web_port)
    root = Path(__file__).resolve().parents[2]
    token = None

    def command(*argv):
        return subprocess.check_output(argv, stderr=subprocess.STDOUT, text=True).strip()

    def check(name, ok):
        if not ok:
            raise AssertionError(name)
        checks.append(name)
        print('PASS ' + name, flush=True)

    def request(method, path, body=None, authenticated=True):
        headers = {}
        if authenticated and token:
            headers['Authorization'] = 'Bearer ' + token
        if isinstance(body, dict):
            body = json.dumps(body).encode()
            headers['Content-Type'] = 'application/json'
        elif isinstance(body, str):
            body = body.encode()
        try:
            response = urllib.request.urlopen(urllib.request.Request(base + path, data=body,
                                                headers=headers, method=method), timeout=15)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, json.loads(response.read())

    def sql(statement):
        return command('docker', 'exec', pg, 'psql', '-U', 'collab', '-d', 'collab',
                       '-v', 'ON_ERROR_STOP=1', '-At', '-c', statement)

    def start(name):
        names.append(name)
        argv = ['docker', 'run', '-d', '--name', name, '--label', 'raft.owner=Winnie', '--network', net,
                '--memory', '1g', '--cpus', '.75',
                *([] if args.production_image else ['--user', str(os.getuid()) + ':' + str(os.getgid())]),
                '-e', 'HOME=/tmp', '-e', 'COLLAB_DB_HOST=' + pg, '-e', 'COLLAB_DB_USER=collab',
                '-e', 'COLLAB_DB_PASSWORD=collab', '-e', 'COLLAB_DB_NAME=collab',
                '-e', 'COLLAB_HTTP_HOST=0.0.0.0', '-e', 'COLLAB_HTTP_PORT=8080',
                '-e', 'COLLAB_HUMAN_INPUT_WEB_ENABLED=true', '-e', 'COLLAB_HUMAN_INPUT_EMAIL_ENABLED=false',
                '-e', 'COLLAB_FILES_DIRECTORY=/tmp/uploads', '-e', 'COLLAB_CORS_ALLOWED_ORIGINS=' + site,
                '-p', '127.0.0.1:' + str(args.server_port) + ':8080']
        if args.production_image:
            # Exercise the shipped entrypoint and its bundled model catalog.
            argv += [args.image]
        else:
            argv += ['-v', str(root / 'server') + ':/work:ro',
                     '-v', str(args.runtime_cache.resolve()) + ':/work/.build:ro',
                     '-w', '/work', args.image, '.build/release/collab-server']
        command(*argv)
        for _ in range(100):
            try:
                if request('GET', '/v1/setup', authenticated=False)[0] == 200:
                    return
            except (OSError, ValueError):
                pass
            time.sleep(.2)
        raise AssertionError('private server did not become ready')

    def click_control(control):
        # Flutter's canvas semantics containers may overlap in the DOM. Click
        # the real rendered control through its screen position/hit testing.
        control.wait_for(state='visible')
        box = control.bounding_box()
        assert box is not None
        page.mouse.click(box['x'] + box['width'] / 2, box['y'] + box['height'] / 2)

    def wait_page(predicate, message, seconds=20):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if predicate():
                return
            page.wait_for_timeout(100)
        raise AssertionError(message)

    try:
        command('docker', 'network', 'create', '--label', 'raft.owner=Winnie', net)
        names.append(pg)
        command('docker', 'run', '-d', '--name', pg, '--label', 'raft.owner=Winnie', '--network', net, '--memory', '512m', '--cpus', '.5',
                '-e', 'POSTGRES_USER=collab', '-e', 'POSTGRES_PASSWORD=collab', '-e', 'POSTGRES_DB=collab',
                'postgres:15-alpine')
        for _ in range(100):
            if subprocess.run(['docker', 'exec', pg, 'pg_isready', '-U', 'collab', '-d', 'collab'],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                break
            time.sleep(.2)
        first = tag + '-a'
        start(first)
        password = 'Aa1-' + secrets.token_urlsafe(24)
        email = 'hitl-browser@example.test'
        status, auth = request('POST', '/v1/setup', {'email': email, 'name': 'HITL Browser', 'password': password}, False)
        check('private owner setup', status == 201)
        token = auth['access_token']
        runtime = request('GET', '/v1/system-features')[1]['workflow_runtime']
        check('web enabled without a model daemon, email disabled', runtime['human_input'] and not runtime['human_input_email'])
        status, imported = request('POST', '/v1/docs/import', (Path(__file__).parent / 'workflow.yml').read_text())
        check('fixture import', status == 201)
        app = imported['id']
        http = subprocess.Popen([sys.executable, '-m', 'http.server', str(args.web_port), '--bind', '127.0.0.1',
                                 '--directory', str(args.web_build.resolve())], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Docker's veth/route notifications can reach Chromium after the API
        # already responds. Let this fixture's network changes settle before
        # fetching engine/assets; the later server kill remains a real fault.
        time.sleep(8)
        playwright = sync_playwright().start()
        browser = playwright.chromium.launch(headless=True)
        page = browser.new_page(viewport={'width': 1600, 'height': 1000})
        page.on('pageerror', lambda error: errors.append({'message': str(error), 'stack': error.stack, 'after': checks[-1] if checks else ''}))
        page.on('console', lambda message: console.append({'type': message.type, 'text': message.text}) if message.type in ('error', 'warning') else None)
        page.on('requestfailed', lambda req: failed_requests.append({'path': urllib.parse.urlsplit(req.url).path, 'error': req.failure}))

        def response(response):
            path = urllib.parse.urlsplit(response.url).path
            if path.endswith(('.wasm', '.mjs', 'main.dart.js')):
                resources.append({'path': path, 'status': response.status})
            if '/v1/workflow/' in path and path.endswith('/events') and response.status == 200:
                follows.append(path)

        page.on('response', response)
        for theme in ('light', 'dark'):
            url = site + '/?' + urllib.parse.urlencode({'server': base, 'app': app, 'theme': theme,
                                                        'lang': 'en-US', 'visual': '1'})
            page.goto(url, wait_until='domcontentloaded')
            page.wait_for_selector('flutter-view', state='attached', timeout=60000)
            page.wait_for_timeout(2000)
            placeholder = page.locator('flt-semantics-placeholder')
            # Web-engine/font startup can outlast a fixed sleep. Wait for the
            # semantics entry point, then for either the login or editor UI.
            if not page.locator('flt-semantics-host').count():
                placeholder.wait_for(state='attached', timeout=30000)
            if placeholder.count():
                placeholder.evaluate('(el)=>el.click()')
            wait_page(lambda: page.get_by_role('button', name='Sign in', exact=True).count() > 0 or
                      page.get_by_role('button', name=re.compile(r'^Test Run')).count() > 0,
                      'neither login nor editor became ready', seconds=30)
            if page.get_by_role('button', name='Sign in', exact=True).count():
                page.get_by_role('textbox', name=re.compile('Email address')).click()
                page.wait_for_timeout(200)
                page.keyboard.type(email, delay=20)
                page.get_by_role('textbox', name=re.compile('password', re.I)).click()
                page.wait_for_timeout(200)
                page.keyboard.type(password, delay=20)
                with page.expect_response(lambda r: r.url.endswith('/v1/auth/login')) as signed:
                    page.get_by_role('button', name='Sign in', exact=True).click()
                check('actual browser login', signed.value.status == 200)
            run_button = page.get_by_role('button', name=re.compile(r'^Test Run')).first
            run_button.wait_for(timeout=60000)
            with page.expect_response(lambda r: r.url.endswith('/workflows/draft/run') and r.request.method == 'POST') as started:
                click_control(run_button)
            check(theme + ' actual UI started a server workflow', started.value.status == 200)
            frames = [json.loads(line[6:]) for line in started.value.text().splitlines() if line.startswith('data: ')]
            required = next(frame for frame in frames if frame.get('event') == 'human_input_required')
            run_id, form_token = required['workflow_run_id'], required['data']['form_token']
            approve = page.get_by_role('button', name='Approve it', exact=True)
            approve.wait_for(timeout=15000)
            fields = page.locator('[data-semantics-role="text-field"]:enabled')
            fields.first.wait_for(timeout=10000)
            check(theme + ' one actual form field (got ' + str(fields.count()) + ')', fields.count() == 1)
            click_control(fields)
            page.wait_for_timeout(200)
            reply = 'from Wasm ' + theme
            page.keyboard.type(reply, delay=30)
            page.wait_for_timeout(300)
            page.screenshot(path=str(out / (theme + '-paused.png')))
            if theme == 'light':
                initial_follows = len(follows)
                command('docker', 'kill', '--signal', 'KILL', first)
                with page.expect_request(lambda r: '/v1/form/human_input/' in r.url and r.method == 'POST'):
                    click_control(approve)
                page.wait_for_timeout(1000)
                check('failed submit left the server form unanswered', sql("SELECT status FROM human_input_forms WHERE token = '" + form_token + "'") == 'waiting')
                page.screenshot(path=str(out / 'light-offline.png'))
                (out / 'process-a.log').write_text(command('docker', 'logs', first))
                command('docker', 'rm', first)
                start(tag + '-b')
                wait_page(lambda: len(follows) > initial_follows, 'the browser did not re-subscribe after restart')
                page.wait_for_timeout(800)
                # A sequence survives the failing transaction, proving that the
                # immediate attempt AND a later production scan tried the claim.
                sql("CREATE SEQUENCE hitl_claim_attempts; CREATE FUNCTION hitl_deny_claim() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF OLD.status = 'paused' AND NEW.status = 'running' THEN PERFORM nextval('hitl_claim_attempts'); RAISE EXCEPTION 'temporary claim failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER hitl_deny BEFORE UPDATE ON workflow_runs FOR EACH ROW EXECUTE FUNCTION hitl_deny_claim()")
            with page.expect_response(lambda r: '/v1/form/human_input/' in r.url and r.request.method == 'POST') as answered:
                click_control(approve)
            check(theme + ' actual form accepted', answered.value.status == 200)
            check(theme + ' typed input was preserved', answered.value.request.post_data_json['inputs']['reply'] == reply)
            if theme == 'light':
                wait_page(lambda: int(sql('SELECT CASE WHEN is_called THEN last_value ELSE 0 END FROM hitl_claim_attempts')) >= 2,
                          'the periodic production worker never retried the accepted answer', seconds=15)
                check('claim failures left the accepted answer durable', sql("SELECT status FROM human_input_forms WHERE token = '" + form_token + "'") == 'submitted')
                sql('DROP TRIGGER hitl_deny ON workflow_runs; DROP FUNCTION hitl_deny_claim()')
            wait_page(lambda: request('GET', '/v1/apps/' + app + '/workflow-runs/' + run_id)[1].get('status') == 'succeeded',
                      'the real server never finished the answered workflow', seconds=15)
            detail = request('GET', '/v1/apps/' + app + '/workflow-runs/' + run_id)[1]
            check(theme + ' persisted correct output', detail['outputs'] == {'reply': reply})
            # RESULT renders its Copy control only for a succeeded run with
            # nonempty resultText; the status badge belongs to the DETAIL tab.
            page.get_by_role('button', name='Copy', exact=True).wait_for(timeout=15000)
            wait_page(lambda: page.get_by_text(reply, exact=True).count() >= 2,
                      'the page lacks its filled form and final output')
            check(theme + ' the page received its terminal result', True)
            page.screenshot(path=str(out / (theme + '-finished.png')))
        check('actual Dart Wasm runtime', any(r['path'].endswith('/main.dart.wasm') and r['status'] == 200 for r in resources))
        check('actual skwasm renderer', any('/skwasm' in r['path'] and r['path'].endswith('.wasm') and r['status'] == 200 for r in resources))
        check('no JavaScript app fallback selected', not any(r['path'].endswith('/main.dart.js') for r in resources))
        check('no uncaught page errors', not errors)
        (out / 'result.json').write_text(json.dumps({'checks': checks, 'count': len(checks), 'resources': resources,
                                                   'errors': errors, 'failed_requests': failed_requests, 'console': console, 'follows': len(follows)}, indent=2) + '\n')
        print(json.dumps({'passed': len(checks), 'follows': len(follows)}))
    finally:
        (out / 'partial-result.json').write_text(json.dumps({'checks': checks, 'resources': resources, 'errors': errors, 'failed_requests': failed_requests, 'console': console, 'follows': len(follows)}, indent=2) + '\n')
        if page:
            try:
                page.screenshot(path=str(out / 'last-state.png'))
                (out / 'semantics.txt').write_text(page.locator('body').inner_text())
                (out / 'semantics.html').write_text(page.locator('flt-semantics-host').inner_html(timeout=2000))
            except Exception:
                pass
        if browser:
            try:
                browser.close()
            except Exception:
                pass
        if playwright:
            playwright.stop()
        for name in names:
            if name != pg:
                try:
                    (out / (name.rsplit('-', 1)[-1] + '.log')).write_text(command('docker', 'logs', name))
                except subprocess.CalledProcessError:
                    pass
        for name in reversed(names):
            subprocess.run(['docker', 'rm', '-f', '-v', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(['docker', 'network', 'rm', net], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if http:
            http.terminate()
            http.wait()


if __name__ == '__main__':
    main()
