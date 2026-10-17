"""Playwright harness for Dify workflow collaboration repro runs (local throwaway stack)."""
import asyncio, json, os, time, uuid, sys
sys.path.insert(0, os.path.dirname(__file__))
from difyapi import Client, BASE
from graphs import base_graph
from playwright.async_api import async_playwright

LOGDIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "logs")
SHOTDIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "shots")
DEBOUNCE_S = 5          # workflow-draft-slice.ts:37 debounce(5000)
SETTLE_S = 14           # wait after last edit: debounce + request + margin


def now():
    return time.time()



HIDDEN_INIT = """
(() => {
  const orig = window.requestAnimationFrame.bind(window);
  const origCancel = window.cancelAnimationFrame.bind(window);
  const q = new Map(); let nid = 1e9; let hidden = false;
  window.requestAnimationFrame = (cb) => { if (!hidden) return orig(cb); const id = nid++; q.set(id, cb); return id; };
  window.cancelAnimationFrame = (id) => { if (q.has(id)) q.delete(id); else origCancel(id); };
  window.__rafDelay = 0;
  window.requestAnimationFrame = ((inner) => (cb) => {
    if (window.__rafDelay > 0 && !hidden) return setTimeout(() => orig(cb), window.__rafDelay);
    return inner(cb);
  })(window.requestAnimationFrame);
  window.__setHidden = (h) => {
    hidden = h;
    Object.defineProperty(document, 'visibilityState', {configurable: true, get: () => h ? 'hidden' : 'visible'});
    Object.defineProperty(document, 'hidden', {configurable: true, get: () => h});
    document.dispatchEvent(new Event('visibilitychange'));
    if (!h) { const cbs = [...q.values()]; q.clear(); cbs.forEach(cb => orig(cb)); }
  };
})();
"""


class NetState:
    """Per-tab controllable network for the socket.io websocket (HTTP is left to context.set_offline)."""
    def __init__(self, up_ms=0, down_ms=0):
        self.up_ms, self.down_ms = up_ms, down_ms
        self.mode = "normal"      # normal | blackhole (silently drop both ways) | refuse (close new/old ws)
        self.routes = []
        self.frames = {"up": 0, "down": 0}
        self.sid = None

    async def install(self, page):
        async def handler(ws):
            if self.mode == "refuse":
                await ws.close()
                return
            server = ws.connect_to_server()
            self.routes.append((ws, server))

            def fwd(dst, direction):
                def _on(msg):
                    if direction == "down" and isinstance(msg, str) and msg.startswith("40{"):
                        try:
                            self.sid = json.loads(msg[2:])["sid"]
                        except Exception:
                            pass
                    async def go():
                        d = self.up_ms if direction == "up" else self.down_ms
                        if d:
                            await asyncio.sleep(d / 1000)
                        if self.mode != "normal":
                            return
                        self.frames[direction] += 1
                        try:
                            dst.send(msg)
                        except Exception:
                            pass
                    asyncio.ensure_future(go())
                return _on
            ws.on_message(fwd(server, "up"))
            server.on_message(fwd(ws, "down"))
        await page.route_web_socket("**/socket.io/**", handler)

    async def drop(self, mode="refuse"):
        """cut the websocket: 'refuse' = close existing + refuse reconnects; 'blackhole' = silently drop frames"""
        self.mode = mode
        if mode == "refuse":
            for ws, server in list(self.routes):
                try:
                    await ws.close()
                except Exception:
                    pass
            self.routes.clear()

    def restore(self):
        self.mode = "normal"


class Tab:
    """One browser tab of one user on one workflow."""

    def __init__(self, name, user, page, ctx, app_id, console):
        self.name, self.user, self.page, self.ctx, self.app_id = name, user, page, ctx, app_id
        self.console = console  # list of (ts, type, text)
        self.ws_log = []

    # ---- low-level UI primitives -------------------------------------------------
    async def wait_ready(self):
        await self.page.wait_for_selector('.react-flow__node[data-id="c1"]', timeout=90000)
        # collaboration overlay must be gone
        for _ in range(100):
            if await self.page.locator('[data-testid="collaboration-graph-loading"]').count() == 0:
                break
            await asyncio.sleep(0.2)
        await asyncio.sleep(1.0)

    async def select(self, nid):
        await self.page.click(f'.react-flow__node[data-id="{nid}"] >> nth=0', timeout=10000)
        await self.page.wait_for_selector('input[placeholder="Add title..."]', timeout=10000)

    async def rename(self, nid, text):
        await self.select(nid)
        inp = self.page.locator('input[placeholder="Add title..."]')
        await inp.fill(text)
        await inp.blur()

    async def set_desc(self, nid, text):
        await self.select(nid)
        ta = self.page.locator('textarea[placeholder="Add description..."]')
        await ta.fill(text)
        await ta.blur()

    async def close_panel(self):
        btn = self.page.get_by_role("button", name="Close", exact=True)
        if await self.page.locator('input[placeholder="Add title..."]').count() and await btn.count():
            await btn.first.click()
            await asyncio.sleep(0.4)

    async def drag(self, nid, dx, dy):
        await self.close_panel()
        node = self.page.locator(f'.react-flow__node[data-id="{nid}"] >> nth=0')
        box = await node.bounding_box()
        x, y = box["x"] + box["width"] / 2, box["y"] + 10
        await self.page.mouse.move(x, y)
        await self.page.mouse.down()
        await self.page.mouse.move(x + dx / 2, y + dy / 2, steps=5)
        await self.page.mouse.move(x + dx, y + dy, steps=5)
        await self.page.mouse.up()

    async def add_output(self, nid, name):
        """click '+' (aria-label 'Add Output Variables') in the code node panel and name the new output"""
        await self.select(nid)
        await self.page.get_by_label("Add Output Variables").click()
        inputs = self.page.locator('input[placeholder="Variable name"]')
        n = await inputs.count()
        await inputs.nth(n - 1).fill(name)
        await inputs.nth(n - 1).blur()

    async def delete_node(self, nid):
        await self.select(nid)
        await self.page.keyboard.press("Delete")

    # ---- observation --------------------------------------------------------------
    async def canvas(self):
        """Return {node_id: {title, x, y}} as rendered in this tab's canvas + edges list."""
        js = """() => {
          const out = {nodes:{}, edges:[]};
          document.querySelectorAll('.react-flow__node').forEach(n => {
            const id = n.getAttribute('data-id');
            const m = /translate\\(([-0-9.]+)px, *([-0-9.]+)px\\)/.exec(n.style.transform||'');
            const t = n.querySelector('div.truncate[title]');
            out.nodes[id] = {title: t ? t.getAttribute('title') : null, x: m?parseFloat(m[1]):null, y: m?parseFloat(m[2]):null};
          });
          document.querySelectorAll('.react-flow__edge').forEach(e => out.edges.push((e.getAttribute('data-testid')||'').replace('rf__edge-','')));
          return out;
        }"""
        return await self.page.evaluate(js)

    async def set_raf_delay(self, ms):
        """stress emulation of a slow/busy main thread: every rAF callback is delayed by `ms`"""
        await self.page.evaluate(f"window.__rafDelay = {ms}")

    async def read_desc(self, nid):
        await self.select(nid)
        v = await self.page.locator('textarea[placeholder="Add description..."]').input_value()
        return v

    async def hide(self):
        await self.page.evaluate("window.__setHidden(true)")

    async def show(self):
        await self.page.evaluate("window.__setHidden(false)")

    async def kill(self):
        """hard-kill this tab's whole browser process tree (SIGKILL): no pagehide/visibilitychange/unload handlers run,
        like a browser crash / OS kill / power loss. Returns the pids killed."""
        import os, signal
        pids = []
        try:
            cdp = await asyncio.wait_for(self.browser.new_browser_cdp_session(), 5)
            info = await asyncio.wait_for(cdp.send("SystemInfo.getProcessInfo"), 5)
            pids = [p["id"] for p in info["processInfo"]]
        except Exception:
            pass
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except Exception:
                pass
        self.dead = True
        return pids

    async def close(self, graceful=True):
        """graceful: normal tab close (pagehide/visibility handlers run)."""
        if getattr(self, "dead", False):
            return
        try:
            await asyncio.wait_for(self.page.close(), 10)
        except Exception:
            pass
        try:
            await asyncio.wait_for(self.ctx.close(), 10)
        except Exception:
            pass


class Env:
    def __init__(self, headless=True):
        self.headless = headless
        self.pw = None
        self.browser = None
        self.extra = []

    async def __aenter__(self):
        self.pw = await async_playwright().start()
        self.browser = await self.pw.chromium.launch(headless=self.headless)
        return self

    async def __aexit__(self, *a):
        for b in [self.browser] + self.extra:
            try:
                await asyncio.wait_for(b.close(), 15)
            except Exception:
                pass
        try:
            await asyncio.wait_for(self.pw.stop(), 15)
        except Exception:
            pass

    def new_app(self, tag, n_code=4, collaborative=True):
        c = Client("alice")
        app_id = c.create_app(f"{tag}-{uuid.uuid4().hex[:6]}")
        c.save_draft(app_id, base_graph(n_code), collaborative=False)
        return app_id

    async def open_tab(self, name, user, app_id, viewport=(1500, 900), cookies_client=None, wait=True, up_ms=0, down_ms=0):
        c = cookies_client or Client(user)
        browser = await self.pw.chromium.launch(headless=self.headless)   # one browser PROCESS per tab so a tab can be SIGKILLed
        self.extra.append(browser)
        ctx = await browser.new_context(viewport={"width": viewport[0], "height": viewport[1]})
        await ctx.add_cookies(c.cookies())
        await ctx.add_init_script(HIDDEN_INIT)
        page = await ctx.new_page()
        net = NetState(up_ms, down_ms)
        await net.install(page)
        console = []
        page.on("console", lambda m: console.append((now(), m.type, m.text[:300])))
        page.on("pageerror", lambda e: console.append((now(), "pageerror", str(e)[:300])))
        tab = Tab(name, user, page, ctx, app_id, console)
        tab.browser = browser
        tab.net = net
        # record draft saves
        tab.saves = []
        async def on_route(route):
            req = route.request
            if req.method == "POST":
                raw = req.post_data or ""
                try:
                    body = json.loads(raw)
                except Exception:
                    body = {}
                tab.saves.append({"t": now(), "kind": "req", "hash": body.get("hash"), "len": len(raw), "keys": sorted(body.keys()),
                                   "nodes": len(body.get("graph", {}).get("nodes", [])),
                                   "titles": {n["id"]: n["data"].get("title") for n in body.get("graph", {}).get("nodes", [])}})
            await route.continue_()
        await page.route(f"**/apps/{app_id}/workflows/draft", on_route)
        async def on_resp(resp):
            req = resp.request
            if req.method == "POST" and resp.url.endswith(f"/apps/{app_id}/workflows/draft"):
                try:
                    txt = await resp.text()
                except Exception:
                    txt = "<unreadable>"
                tab.saves.append({"t": now(), "kind": "resp", "status": resp.status, "body": txt[:200]})
        page.on("response", lambda r: asyncio.ensure_future(on_resp(r)))
        await page.goto(f"{BASE}/app/{app_id}/workflow")
        if wait:
            await tab.wait_ready()
        return tab


def server_graph(app_id):
    """truth: what the server would give to a fresh joiner"""
    d = Client("alice").get_draft(app_id)
    nodes = {n["id"]: {"title": n["data"].get("title"), "desc": n["data"].get("desc"),
                        "x": n["position"]["x"], "y": n["position"]["y"],
                        "outputs": sorted((n["data"].get("outputs") or {}).keys()) if isinstance(n["data"].get("outputs"), dict) else None,
                        "type": n["data"].get("type")} for n in d["graph"]["nodes"]}
    edges = sorted(f'{e["source"]}->{e["target"]}' for e in d["graph"]["edges"])
    return {"hash": d["hash"], "updated_at": d.get("updated_at"), "nodes": nodes, "edges": edges, "raw": d}


def append_log(name, rec):
    os.makedirs(LOGDIR, exist_ok=True)
    with open(os.path.join(LOGDIR, name + ".jsonl"), "a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


import subprocess

def redis_cli(*args):
    out = subprocess.run(["docker", "exec", "docker-redis-1", "redis-cli", "-a", "difyai123456", "--no-auth-warning", *args],
                         capture_output=True, text=True, timeout=20)
    return out.stdout.strip()

def leader_sid(app_id):
    keys = redis_cli("keys", f"*leader*{app_id}*")
    if not keys:
        return None
    return redis_cli("get", keys.splitlines()[0])
