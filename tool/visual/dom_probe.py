"""Print the layout boxes of a node card in Dify (the specification), to compare sizes with ours.

  tool/visual/.venv/bin/python tool/visual/dom_probe.py <workflow file> <node title> [depth]

Needs the local Dify ($DIFY_URL, $DIFY_EMAIL, $DIFY_PASSWORD) running. Boxes are in canvas units (divided by zoom),
relative to the node element, one line per element down to [depth] levels, with its classes.
"""
import sys
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


def main():
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
