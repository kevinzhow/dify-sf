"""Real original/candidate pages, resized while their actual drawer is open.

No pixel manipulation or scoring. Disposable sessions are private runtime input.
"""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlencode, urlsplit

import requests
from playwright.sync_api import sync_playwright

p = argparse.ArgumentParser()
for name in ['source', 'session', 'build', 'out']:
    p.add_argument('--' + name, type=Path, required=True)
p.add_argument('--revision', required=True)
a = p.parse_args()
sys.path.insert(0, str(a.source / 'tool/visual'))
import compare
from capture_contract import install_display_fixtures, wait_for_flutter_fonts, observe_capture_health, assert_capture_health

a.out.mkdir(exist_ok=False)
auth = json.loads(a.session.read_text())
compare.ROOT = a.source
compare.SF = auth['sf']['base']
compare.sf_tokens = lambda: auth['sf']['tokens']
compare.DIFY = auth['dify']['base']
compare.LOCALE = 'en-US'
session = requests.Session()
session.headers.update(auth['dify'].get('headers', {}))
for cookie in auth['dify']['cookies']:
    session.cookies.set(cookie['name'], cookie['value'])
annotations = next(c for c in json.loads((a.source / 'tool/visual/page_cases.json').read_text())
                   if c['id'] == 'pages.app-annotations.light.en-US')
text = (a.source / 'tool/visual/fixtures/sf_chat_preview.yml').read_text()
owned = {}
rows = []
server, base = compare.serve(a.build)
wasm_hash = hashlib.sha256((a.build / 'main.dart.wasm').read_bytes()).hexdigest()
try:
    owned['react'] = compare.dify_import(session, text)
    owned['flutter-web'] = compare.sf_import(text)
    (a.out / 'owned-resources.json').write_text(json.dumps(owned))
    with sync_playwright() as pw:
        browsers = compare.Browsers(pw)
        try:
            for family in ['annotation-add']:
                for theme in ['light', 'dark']:
                    compare.THEME = theme
                    for width in [1440, 390, 320]:
                        height = 900 if width == 1440 else 760
                        for side in ['react', 'flutter-web']:
                            cid = f'{family}.{theme}.{width}.{side}'
                            row = dict(id=cid, family=family, theme=theme, viewport=[width, height],
                                       provider=side, sourceCommit='8387590ace4a094de812b7847fc6a4c3a27cd52b' if side == 'react' else a.revision,
                                       wasmSha256=wasm_hash if side == 'flutter-web' else None,
                                       method='Open the real page drawer at 1440px, then resize the viewport; this is not a physical-device test.')
                            ctx = browsers.context(1440, 900)
                            errors, blocked, overflows = [], [], []
                            try:
                                if side == 'react':
                                    ctx.add_cookies([{'name': c['name'], 'value': c['value'], 'url': compare.DIFY}
                                                     for c in auth['dify']['cookies'] if c['name'] != 'locale'])
                                    ctx.add_cookies([{'name': 'locale', 'value': 'en-US', 'url': compare.DIFY}])
                                    ctx.add_init_script('localStorage.setItem("theme",' + json.dumps(theme) + ')')
                                else:
                                    ctx.add_init_script('localStorage.setItem(' + json.dumps('dify-sf/tokens/' + compare.SF)
                                                        + ',' + json.dumps(json.dumps(auth['sf']['tokens'])) + ')')
                                page = ctx.new_page()
                                page.on('pageerror', lambda e: errors.append(str(e)))
                                page.on('console', lambda m: overflows.append(m.text) if 'overflowed by' in m.text else None)
                                health = observe_capture_health(page)
                                def deny_execution(route):
                                    path = urlsplit(route.request.url).path
                                    if route.request.method == 'POST' and (
                                        any(x in path for x in ['/draft/run', '/single-node/', '/advanced-chat/', '/chat-messages', '/invoke'])
                                        or path.endswith('/run')
                                    ):
                                        blocked.append(path)
                                        route.abort('blockedbyclient')
                                    else:
                                        route.fallback()
                                page.route('**/*', deny_execution)
                                original_side = 'dify' if side == 'react' else 'ours'
                                install_display_fixtures(page, original_side)
                                if family == 'annotation-add':
                                    for fixture in annotations['network']:
                                        if fixture.get('side', 'both') not in [original_side, 'both']:
                                            continue
                                        def answer(route, request=None, f=fixture):
                                            if route.request.method != f.get('method', 'GET'):
                                                route.fallback()
                                            else:
                                                route.fulfill(status=f.get('status', 200), json=f['json'])
                                        page.route(fixture['url'], answer)
                                app = owned[side]
                                target = 'annotations' if family == 'annotation-add' else 'workflow'
                                url = compare.DIFY + f'/app/{app}/{target}' if side == 'react' else base + '/?' + urlencode(
                                    dict(server=compare.SF, app=app, page=target, lang='en-US', theme=theme, visual='1'))
                                page.goto(url, wait_until='networkidle', timeout=60000)
                                if side == 'flutter-web':
                                    page.wait_for_selector('flutter-view', timeout=60000)
                                    if page.locator('flt-semantics-placeholder').count():
                                        page.locator('flt-semantics-placeholder').evaluate('(e)=>e.click()')
                                    wait_for_flutter_fonts(page)
                                else:
                                    page.evaluate('document.fonts.ready')
                                trigger = 'Features' if family == 'features' else 'Add Annotation'
                                page.get_by_role('button', name=trigger, exact=True).click(timeout=15000)
                                popup = page.get_by_role('dialog').last
                                popup.wait_for(state='visible')
                                page.wait_for_timeout(600)
                                row['initialActiveElement'] = page.evaluate("(()=>{let e=document.activeElement;return {tag:e.tagName,label:e.getAttribute('aria-label'),placeholder:e.getAttribute('placeholder')}})()")
                                row['initialFields'] = page.get_by_role('textbox').evaluate_all("es=>es.filter(e=>['Question','Answer'].includes(e.getAttribute('aria-label'))).map(e=>({label:e.getAttribute('aria-label'),active:e===document.activeElement,background:getComputedStyle(e).backgroundColor,border:getComputedStyle(e).borderColor}))")
                                page.keyboard.insert_text('autofocus-probe-TEST')
                                page.wait_for_timeout(300)
                                row['immediateTypingAccepted'] = page.locator('textarea,input').evaluate_all("es=>es.some(e=>e.value==='autofocus-probe-TEST')")
                                row['focusedAfterTyping'] = page.evaluate("(()=>{let e=document.activeElement;return {tag:e.tagName,label:e.getAttribute('aria-label'),placeholder:e.getAttribute('placeholder'),hasProbe:e.value==='autofocus-probe-TEST'}})()")
                                assert row['immediateTypingAccepted'], 'Initial direct typing did not reach a focused text input'
                                cdp = ctx.new_cdp_session(page)
                                window = cdp.send('Browser.getWindowForTarget')['windowId']
                                cdp.send('Browser.setWindowBounds', dict(windowId=window, bounds=dict(width=width, height=height)))
                                page.wait_for_timeout(900)
                                wait_for_flutter_fonts(page)
                                page.mouse.move(0, 0)
                                row['typingSurvivesResize'] = page.locator('textarea,input').evaluate_all("es=>es.some(e=>e===document.activeElement&&e.value==='autofocus-probe-TEST')")
                                assert row['typingSurvivesResize'], 'Answer focus/value lost during native window resize'
                                initial = a.out / f'{cid}.initial.png'
                                page.screenshot(path=str(initial))
                                row['initialImage'] = initial.name
                                row['initialImageSha256'] = hashlib.sha256(initial.read_bytes()).hexdigest()
                                row['textboxRoles'] = popup.get_by_role('textbox').evaluate_all("es=>es.map(e=>({tag:e.tagName,label:e.getAttribute('aria-label'),labelledBy:e.getAttribute('aria-labelledby')}))")
                                assert popup.get_by_role('textbox').count()==2, row['textboxRoles']
                                question = popup.get_by_role('textbox').first
                                question.click()
                                def active_listeners():
                                    obj = cdp.send('Runtime.evaluate', {'expression': 'document.activeElement'})['result']['objectId']
                                    try:
                                        return sorted(x['type'] for x in cdp.send('DOMDebugger.getEventListeners', {'objectId': obj})['listeners'])
                                    finally:
                                        cdp.send('Runtime.releaseObject', {'objectId': obj})
                                row['switchImmediateInputListenerTypes'] = active_listeners()
                                polls = 0
                                while not question.evaluate('(e)=>e===document.activeElement') or (side == 'flutter-web' and 'input' not in active_listeners()):
                                    if polls >= 80:
                                        raise AssertionError('Question input connection did not become ready')
                                    page.wait_for_timeout(25)
                                    polls += 1
                                row['inputActivationPolls'] = polls
                                row['switchReadyInputListenerTypes'] = active_listeners()
                                page.keyboard.insert_text('question-probe-TEST')
                                page.wait_for_timeout(300)
                                row['questionTypingAccepted'] = page.locator('textarea,input').evaluate_all("es=>es.some(e=>e===document.activeElement&&e.value==='question-probe-TEST')")
                                assert row['questionTypingAccepted'], 'User-selected Question lost focus on controlled-value rebuild'
                                rect = popup.bounding_box()
                                row['popupRect'] = rect
                                expected_width = min(420, width - 32) if family == 'features' else min(480, width - 16)
                                expected = dict(x=width - expected_width - (0 if family == 'features' else 8),
                                                y=112 if family == 'features' else 64,
                                                width=expected_width,
                                                height=height - (120 if family == 'features' else 76))
                                row['sourceRecipeRect'] = expected
                                row['geometryMatchesSource'] = all(abs(rect[k] - expected[k]) <= .5 for k in expected)
                                row['environment'] = page.evaluate('({width:innerWidth,height:innerHeight,dpr:devicePixelRatio})')
                                assert row['environment'] == dict(width=width, height=height, dpr=2)
                                if side == 'react':
                                    row['computedBorder'] = popup.evaluate('(e)=>{let c=getComputedStyle(e);return {top:c.borderTopWidth,right:c.borderRightWidth,bottom:c.borderBottomWidth,left:c.borderLeftWidth,color:c.borderColor}}')
                                else:
                                    row['loadedWasm'] = page.evaluate("performance.getEntriesByType('resource').map(e=>e.name.split('/').pop()).filter(n=>n.endsWith('.wasm'))")
                                    assert 'main.dart.wasm' in row['loadedWasm']
                                assert_capture_health(health)
                                dest = a.out / f'{cid}.png'
                                page.screenshot(path=str(dest))
                                row['image'] = dest.name
                                row['imageSha256'] = hashlib.sha256(dest.read_bytes()).hexdigest()
                                assert not errors and not blocked and not overflows, dict(pageErrors=errors, blocked=blocked, overflows=overflows)
                                if family == 'features':
                                    page.mouse.click(16, max(200, height / 2))
                                    popup.wait_for(state='hidden', timeout=10000)
                                    row['gutterDismissed'] = True
                                else:
                                    popup.get_by_role('button', name=re.compile(r'^Close(?: drawer)?$')).click()
                                    popup.wait_for(state='hidden', timeout=10000)
                                    row['closeButtonDismissed'] = True
                                row['status'] = 'passed' if row['geometryMatchesSource'] else 'geometry-difference'
                            except Exception as e:
                                row['status'] = 'failed'
                                row['error'] = f'{type(e).__name__}: {e}'
                                try:
                                    page.screenshot(path=str(a.out / f'{cid}.failure.png'))
                                except Exception:
                                    pass
                            finally:
                                row['pageErrors'], row['blockedRequests'], row['overflows'] = errors, blocked, overflows
                                ctx.close()
                            rows.append(row)
                            (a.out / 'results.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2))
                            print(cid, row['status'], row.get('popupRect'), row.get('error', '')[:350], flush=True)
        finally:
            browsers.close()
finally:
    server.shutdown()
    if owned.get('react'):
        session.delete(compare.DIFY + '/console/api/apps/' + owned['react'], timeout=15).raise_for_status()
    if owned.get('flutter-web'):
        compare.sf_api('DELETE', '/v1/apps/' + owned['flutter-web'])
    (a.out / 'owned-resource-cleanup.json').write_text(json.dumps(dict(deleted=list(owned))))
if any(r['status'] != 'passed' for r in rows):
    raise SystemExit('Some real-page geometry or interaction checks failed; raw attempts retained')
