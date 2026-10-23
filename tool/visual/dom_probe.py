"""Print the layout boxes of a node card in Dify (the specification), to compare sizes with ours.

  tool/visual/.venv/bin/python tool/visual/dom_probe.py <workflow file> <node title> [depth]
  tool/visual/.venv/bin/python tool/visual/dom_probe.py --panels <out dir> [case id,...]

Needs the local Dify ($DIFY_URL, $DIFY_EMAIL, $DIFY_PASSWORD) running. Boxes are in canvas units (divided by zoom),
relative to the node element, one line per element down to [depth] levels, with its classes.

--panels: for each panel case of cases.json (or the given ones), opens the case's node panel at the case's window
size and device pixel ratio (compare.Browsers: a real ratio, as compare.py) and writes <out dir>/<case>.txt: every visible element of the panel, in CSS px relative to the panel's
top-left corner, with its non-zero paddings and borders, and for elements holding text, their font size, line
height, weight and text.
"""
import json, os, pathlib, re, sys
from playwright.sync_api import sync_playwright
import compare

PROBE = """([title, depth]) => {
  const node = [...document.querySelectorAll('.react-flow__node')].find(n => n.textContent.includes(title));
  if (!node) return ['not found'];
  const t = getComputedStyle(document.querySelector('.react-flow__viewport')).transform;
  const zoom = parseFloat(t.split('(')[1]);
  const o = node.getBoundingClientRect();
  const out = [];
  const walk = (el, d) => {
    const r = el.getBoundingClientRect();
    const f = v => (v / zoom).toFixed(2);
    const own = [...el.childNodes].filter(c => c.nodeType === 3 && c.textContent.trim()).map(c => c.textContent.trim()).join(' ');
    out.push(`${'  '.repeat(d)}${el.tagName.toLowerCase()} x=${f(r.left - o.left)} y=${f(r.top - o.top)} w=${f(r.width)} h=${f(r.height)} ${own ? JSON.stringify(own.slice(0, 40)) : ''} .${(el.getAttribute('class') || '').slice(0, 120)}`);
    if (d < depth) for (const c of el.children) walk(c, d + 1);
  };
  walk(node, 0);
  return out;
}"""


PANEL = """() => {
  // The panel: the rounded box around the Settings / Last Run tabs (other tab lists may come first).
  let panel = null;
  for (const tabs of document.querySelectorAll('[role=tablist]')) {
    for (let el = tabs; el && !panel; el = el.parentElement) {
      const c = (el.className || '').toString();
      if (c.includes('rounded-2xl') && c.includes('h-full') && c.includes('flex-col')) panel = el;
    }
    if (panel) break;
  }
  if (!panel) return ['no panel'];
  const o = panel.getBoundingClientRect();
  const out = [];
  const px = v => { const n = parseFloat(v); return Number.isInteger(n) ? `${n}` : n.toFixed(2); };
  const box = (cs, k) => {
    const v = ['Top', 'Right', 'Bottom', 'Left'].map(sd => px(cs[k.replace('$', sd)]));
    return v.every(x => x === '0') ? '' : ` ${k.split('$')[0]}=${v.join(',')}`;
  };
  const walk = (el, d) => {
    const r = el.getBoundingClientRect();
    if (!r.width || !r.height) return;
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden') return;
    const f = v => v.toFixed(2);
    const own = [...el.childNodes].filter(c => c.nodeType === 3 && c.textContent.trim()).map(c => c.textContent.trim()).join(' ')
      || ((el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') ? (el.value || el.placeholder) : '');
    const font = own ? ` font=${px(cs.fontSize)}/${px(cs.lineHeight) || cs.lineHeight}/${cs.fontWeight} ${JSON.stringify(own.slice(0, 40))}` : '';
    const bg = cs.backgroundColor !== 'rgba(0, 0, 0, 0)' ? ` bg=${cs.backgroundColor}` : '';
    out.push(`${'  '.repeat(d)}${el.tagName.toLowerCase()} x=${f(r.left - o.left)} y=${f(r.top - o.top)} w=${f(r.width)} h=${f(r.height)}`
      + box(cs, 'padding$') + box(cs, 'border$Width') + bg + font
      + ` .${(el.getAttribute('class') || '').slice(0, 100)}`);
    for (const c of el.children) walk(c, d + 1);
  };
  walk(panel, 0);
  return out;
}"""


def panels(out_dir, only):
    out = pathlib.Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    cases = [c for c in json.loads((compare.ROOT / 'tool/visual/cases.json').read_text()) if c.get('select')]
    if only:
        cases = [c for c in cases if c['id'] in only.split(',')]
    s = compare.dify_session()
    with sync_playwright() as p:
        b = compare.Browsers(p)
        for c in cases:
            text = compare.with_viewport((compare.ROOT / c['fixture']).read_text(), *c['viewport'])
            text = re.sub(r'^(\s+)selected: true$', r'\1selected: false', text, flags=re.M)
            app_id = compare.dify_import(s, text)
            try:
                ctx = b.context(*c['window'])
                ctx.add_cookies([{'name': k.name, 'value': k.value, 'url': compare.DIFY} for k in s.cookies])
                page = ctx.new_page()
                page.goto(f'{compare.DIFY}/app/{app_id}/workflow')
                page.wait_for_selector('.react-flow__node', timeout=60000)
                page.wait_for_timeout(1500)
                node = page.locator(f'.react-flow__node[data-id="{c["select"]}"]')
                try:
                    node.click(position={'x': 16, 'y': 16}, timeout=5000)
                except Exception:
                    node.dispatch_event('click')
                # Then off the canvas: the pointer resting on the node would show its hover state (the node control, the
                # highlighted edges), which ours, selected without a pointer, does not.
                page.mouse.move(0, 0)
                page.wait_for_timeout(1200)
                (out / f'{c["id"]}.txt').write_text('\n'.join(page.evaluate(PANEL)) + '\n')
                print(c['id'])
                ctx.close()
            finally:
                s.delete(f'{compare.DIFY}/console/api/apps/{app_id}')
        b.close()


def main():
    if sys.argv[1] == '--panels':
        return panels(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    path, title = sys.argv[1], sys.argv[2]
    depth = int(sys.argv[3]) if len(sys.argv) > 3 else 6
    s = compare.dify_session()
    app_id = compare.dify_import(s, open(path).read())
    try:
        with sync_playwright() as p:
            b = p.chromium.launch()
            ctx = b.new_context(viewport={'width': 1440, 'height': 900})
            ctx.add_cookies([{'name': c.name, 'value': c.value, 'url': compare.DIFY} for c in s.cookies])
            page = ctx.new_page()
            page.goto(f'{compare.DIFY}/app/{app_id}/workflow')
            page.wait_for_selector('.react-flow__node', timeout=60000)
            page.wait_for_timeout(1500)
            print('\n'.join(page.evaluate(PROBE, [title, depth])))
            b.close()
    finally:
        s.delete(f'{compare.DIFY}/console/api/apps/{app_id}')


if __name__ == '__main__':
    main()
