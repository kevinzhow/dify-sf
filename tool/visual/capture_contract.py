"""Admission checks around the *final* screenshot, after pointer parking and animation.

The catalogue declares the state; these checks never modify product styles or PNGs.
"""

def assert_final_state(page, case, side, locate):
    expected = case.get('expected', {}).get(side)
    if expected:
        import re
        target = locate(page, expected) if isinstance(expected, dict) else page.get_by_text(re.compile(expected, re.I)).first
        if not target.is_visible():
            raise AssertionError(f'Final capture state disappeared: {expected}')
    for target in case.get('finalVisible', {}).get(side, []):
        if not locate(page, target).is_visible():
            raise AssertionError(f'Final capture state absent: {target}')
    for target in case.get('finalHidden', {}).get(side, []):
        if locate(page, target).is_visible():
            raise AssertionError(f'Unexpected final capture state: {target}')


def prepare_final_state(page, case, side, locate):
    pointer = case.get('pointer', {}).get(side)
    if pointer:
        locate(page, pointer).hover(timeout=10000)
    else:
        page.mouse.move(0, 0)
    page.evaluate('document.fonts.ready')
    page.wait_for_load_state('networkidle')
    page.wait_for_timeout(1200)

# Frozen browser wall clock only. Timers/animations and runtime status remain real.
FIXED_TIME_ISO = '2026-10-24T12:00:00+00:00'
FIXED_SECONDS = 1792843200


def install_display_fixtures(page, side):
    """Unify timezone and draft display timestamps without changing server accounts.

    Only root metadata on the named GET endpoints is normalized. Workflow
    variables, graph content, outputs, statuses and streaming frames are untouched.
    """
    # Playwright Clock also replaces Performance with an empty fake, which
    # would erase the native Wasm/resource evidence. Freeze Date alone: retain
    # native timers, animation frames, Performance and network observation.
    page.add_init_script("""(() => {
      const NativeDate = globalThis.Date;
      const fixed = """ + str(FIXED_SECONDS * 1000) + """;
      globalThis.Date = new Proxy(NativeDate, {
        construct(target, args, newTarget) {
          return Reflect.construct(target, args.length ? args : [fixed], newTarget);
        },
        apply() { return new NativeDate(fixed).toString(); },
        get(target, key, receiver) {
          return key === 'now' ? () => fixed : Reflect.get(target, key, receiver);
        },
      });
    })()""")

    def profile(route):
        if route.request.method != 'GET':
            route.fallback()
            return
        response = route.fetch()
        if response.status != 200:
            route.fulfill(response=response)
            return
        data = response.json()
        data['timezone'] = 'America/New_York'
        route.fulfill(response=response, json=data)

    def draft(route):
        if route.request.method != 'GET':
            route.fallback()
            return
        response = route.fetch()
        if response.status != 200:
            route.fulfill(response=response)
            return
        data = response.json()
        for key in ['created_at', 'updated_at']:
            if key in data:
                data[key] = FIXED_SECONDS
        route.fulfill(response=response, json=data)

    page.route('**/console/api/account/profile' if side == 'dify' else '**/v1/account', profile)
    page.route('**/console/api/apps/*/workflows/draft' if side == 'dify' else '**/v1/apps/*/workflows/draft', draft)


def observe_capture_health(page):
    """Record failed bundled assets and Flutter runtime errors, not expected API errors.

    The screenshot must not be admitted with a missing font/icon/engine even if
    Playwright emitted no pageerror (Flutter catches many exceptions itself).
    Only paths/statuses are retained; request headers and query values are not.
    """
    from urllib.parse import urlsplit
    failures = []

    def asset_path(url):
        path = urlsplit(url).path
        return path if (path.startswith(('/assets/', '/_next/static/', '/canvaskit/'))
                        or path.rsplit('/', 1)[-1] in {
                            'flutter_bootstrap.js', 'flutter.js', 'main.dart.js',
                            'main.dart.wasm', 'main.dart.mjs', 'skwasm.wasm',
                            'skwasm_heavy.wasm', 'canvaskit.wasm'}) else None

    def response(resp):
        path = asset_path(resp.url)
        if path and resp.status >= 400:
            failures.append({'kind':'asset-response', 'path':path, 'status':resp.status})

    def request_failed(request):
        path = asset_path(request.url)
        if path:
            failures.append({'kind':'asset-request', 'path':path, 'failure':request.failure})

    def console(message):
        import re
        if re.search(r'Unable to load asset|EXCEPTION CAUGHT BY|RenderFlex overflowed|Unhandled Exception', message.text, re.I):
            # The exception category is enough for the public receipt. Flutter's
            # full log may contain URLs or request data and stays in private logs.
            failures.append({'kind':'flutter-exception', 'category':re.search(
                r'Unable to load asset|EXCEPTION CAUGHT BY|RenderFlex overflowed|Unhandled Exception',
                message.text, re.I).group(0)})

    page.on('response', response)
    page.on('requestfailed', request_failed)
    page.on('console', console)
    return failures


def assert_capture_health(failures):
    if failures:
        raise AssertionError('Capture contains failed assets or Flutter exceptions: ' + str(failures))


def wait_for_flutter_fonts(page):
    """Admit actual Flutter glyph requests and repaint; do not alter capture pixels.

    document.fonts.ready only covers CSS fonts. Both pinned Flutter renderers
    publish their own font barrier. The ordinary reference path remains intact.
    """
    if page.evaluate("typeof window.difyFontIdle === 'function'"):
        page.evaluate("async () => { await window.difyFontIdle(); await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame); }")
        status=page.evaluate('window.difyFontStatus()')
        if status != {'pending':0,'busy':False,'failed':0}:
            raise AssertionError('Flutter font barrier did not settle cleanly: '+str(status))
