from playwright.sync_api import sync_playwright
from pathlib import Path
with sync_playwright() as p:
 b=p.chromium.launch();page=b.new_page();page.add_init_script(path=str(Path(__file__).resolve().parents[1]/'app/web/semantics_scroll_compat.js'));page.goto('about:blank')
 page.set_content('''<flt-semantics id="h" style="display:block;position:relative;width:100px;height:32px;overflow:scroll"><flt-semantics-scroll-overflow style="display:block;width:500px;height:1px"></flt-semantics-scroll-overflow><button style="position:absolute;left:220px;top:0">target</button></flt-semantics><flt-semantics id="v" style="display:block;width:100px;height:100px;overflow:scroll"><flt-semantics-scroll-overflow style="display:block;height:500px;width:1px"></flt-semantics-scroll-overflow></flt-semantics><div id="plain" style="width:100px;height:100px;overflow:scroll"><div style="height:500px"></div></div>''')
 page.wait_for_timeout(50)
 actual=page.evaluate('''() => {h.scrollTop=170;v.scrollTop=130;plain.scrollTop=120;return {h:[h.scrollLeft,h.scrollTop],v:[v.scrollLeft,v.scrollTop],plain:plain.scrollTop};}''')
 assert actual=={'h':[170,0],'v':[0,130],'plain':120},actual
 box=page.get_by_role('button',name='target').bounding_box();assert box['y']>=0 and box['x']<100
 page.get_by_role('button',name='target').evaluate('(e)=>e.onclick=()=>window.clicked=true');page.mouse.click(box['x']+5,box['y']+5);assert page.evaluate('window.clicked')
 print('PASS: horizontal synchronization and actual hit target; vertical semantics and ordinary scrolling unchanged')
 b.close()
