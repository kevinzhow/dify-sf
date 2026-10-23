"""Exercise real shared menu widgets in the standalone Wasm fixture, without a backend or account.

Build app/tool/menu_interaction_probe.dart with tool/build_web.sh, serve that directory,
then pass its URL here. Screenshots are evidence of selected states; this is not a
claim that every application call site or physical Android device was tested.
"""
import argparse
import json
from pathlib import Path
import re
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from playwright.sync_api import sync_playwright


def url_for(base, theme):
    parts = urlsplit(base)
    query = dict(parse_qsl(parts.query))
    query['theme'] = theme
    return urlunsplit(parts._replace(query=urlencode(query)))


def run_case(browser, url, width, theme, out):
    touch = width < 1000
    context = browser.new_context(viewport={'width': width, 'height': 900},
                                  device_scale_factor=2, is_mobile=touch, has_touch=touch)
    page = context.new_page()
    page.set_default_timeout(10000)
    errors = []
    resources = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.on('response', lambda response: resources.append(response.url))
    page.goto(url_for(url, theme), wait_until='networkidle')
    if page.locator('flt-semantics-placeholder').count():
        page.locator('flt-semantics-placeholder').evaluate('(element) => element.click()')
    page.get_by_text('共享菜单交互测试', exact=True).wait_for()

    def settle():
        page.wait_for_timeout(400)

    def activate(locator):
        locator.wait_for(state='visible')
        rect = locator.bounding_box()
        assert rect, 'No hit rectangle'
        x, y = rect['x'] + rect['width'] / 2, rect['y'] + rect['height'] / 2
        if touch:
            page.touchscreen.tap(x, y)
        else:
            page.mouse.click(x, y)
        settle()

    def popup_bounds():
        rects = page.get_by_role('menu').evaluate_all(
            '(nodes) => nodes.map(node => node.getBoundingClientRect().toJSON())')
        for rect in rects:
            assert rect['left'] >= 4.5 and rect['right'] <= width - 4.5, rect
            assert rect['top'] >= 4.5 and rect['bottom'] <= 895.5, rect
        return rects

    def screenshot(name):
        # The semantics tree can precede the rendered Wasm frame.
        page.wait_for_timeout(1000)
        page.evaluate('() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))')
        page.screenshot(path=str(out / f'{width}-{theme}-{name}.png'))

    account = page.get_by_role('button', name=re.compile('菜单验收.*账户'))
    activate(account)
    activate(page.get_by_role('menuitem', name='外观', exact=True))
    # A touch-opened menu must not be closed by later compatibility/other-device hover.
    page.mouse.move(1, 1)
    settle()
    assert page.get_by_role('menuitemradio').count() == 3
    rects = popup_bounds()
    assert abs(rects[0]['width'] - 240) <= .5 and abs(rects[1]['width'] - 139) <= .5, rects
    screenshot('appearance')
    activate(page.get_by_role('menuitemradio', name='浅色' if theme == 'dark' else '深色', exact=True))
    assert page.get_by_role('menu').count() == 0, 'Choosing a theme closes the complete account menu'

    activate(account)
    activate(page.get_by_role('menuitem', name='外观', exact=True))
    activate(page.get_by_role('menuitemradio', name='深色' if theme == 'dark' else '浅色', exact=True))

    activate(page.get_by_role('button', name='打开菜单', exact=True))
    activate(page.get_by_role('menuitem', name='禁用操作', exact=True))
    assert page.get_by_role('menu').count() == 1, 'Disabled actions must not close menus'
    activate(page.get_by_role('menuitemcheckbox', name='保持打开', exact=True))
    assert page.get_by_role('menuitemcheckbox', name='保持打开', checked=True).count() == 1
    activate(page.get_by_role('menuitemradio', name='选项乙', exact=True))
    assert page.get_by_role('menuitemradio', name='选项乙', checked=True).count() == 1
    activate(page.get_by_role('menuitem', name='次级菜单', exact=True))
    activate(page.get_by_role('menuitem', name='深层菜单', exact=True))
    activate(page.get_by_role('menuitemcheckbox', name='深层保持', exact=True))
    assert page.get_by_role('menu').count() == 3
    assert page.get_by_role('menuitemcheckbox', name='深层保持', checked=True).count() == 1
    popup_bounds()
    if width == 1440:
        screenshot('nested-menu')
    page.mouse.click(width - 6, 12)
    settle()
    assert page.get_by_role('menu').count() == 0

    for label in ['第一层弹出框', '第二层弹出框', '第三层菜单']:
        activate(page.get_by_role('button', name=label, exact=True))
    activate(page.get_by_role('menuitemcheckbox', name='混合保持', exact=True))
    assert page.get_by_role('dialog').count() == 2
    assert page.get_by_role('menu').count() == 1, 'Grandchild taps must preserve all ancestor popups'
    popup_bounds()
    if width == 1440:
        screenshot('mixed-popups')
    for _ in range(3):
        page.keyboard.press('Escape')
        settle()
    assert page.get_by_role('menu').count() == page.get_by_role('dialog').count() == 0

    area = page.get_by_text('右键或长按区域', exact=True)
    if touch:
        rect = area.bounding_box()
        cdp = context.new_cdp_session(page)
        cdp.send('Input.dispatchTouchEvent', {'type': 'touchStart', 'touchPoints': [
            {'id': 1, 'x': rect['x'] + rect['width'] / 2, 'y': rect['y'] + rect['height'] / 2}]})
        page.wait_for_timeout(650)
        cdp.send('Input.dispatchTouchEvent', {'type': 'touchEnd', 'touchPoints': []})
        cdp.detach()
    else:
        rect = area.bounding_box()
        assert rect
        # A semantics text node need not own DOM pointer events. Send the real
        # right click at its painted position, as for every other pointer case.
        page.mouse.click(rect['x'] + rect['width'] / 2, rect['y'] + rect['height'] / 2, button='right')
    settle()
    assert page.get_by_role('menu').count() == 1
    activate(page.get_by_role('menuitem', name='普通操作', exact=True))
    assert page.get_by_role('menu').count() == 0
    assert 'actions=1' in page.locator('body').inner_text()

    activate(page.get_by_role('button', name=re.compile('^菜单选择器')))
    popup_bounds()
    select_rect = page.get_by_role('menu').bounding_box()
    assert abs(select_rect['width'] - 240) <= .5, select_rect
    activate(page.get_by_role('menuitemradio', name='选择乙', exact=True))
    assert page.get_by_role('menu').count() == 0
    assert 'select=乙' in page.locator('body').inner_text()
    assert any('/main.dart.wasm' in resource for resource in resources)
    assert not errors, errors
    result = {'width': width, 'theme': theme, 'touch': touch, 'actualWasm': True,
              'touchThenHoverStaysOpen': True, 'nestedAndMixedPopupGroups': True,
              'disabledCheckboxRadio': True, 'contextMenuLongPressOrRightClick': True,
              'selectionAndOutsideDismissal': True, 'errors': errors}
    context.close()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--widths', default='320,390,414,640,1440')
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    results = []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        try:
            for width in map(int, args.widths.split(',')):
                for theme in ['light', 'dark']:
                    result = run_case(browser, args.url, width, theme, args.out)
                    results.append(result)
                    print(json.dumps(result, ensure_ascii=False), flush=True)
                    (args.out / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
        finally:
            browser.close()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
