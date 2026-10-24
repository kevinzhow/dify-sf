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
    import datetime
    page.clock.set_fixed_time(datetime.datetime.fromisoformat(FIXED_TIME_ISO))

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
