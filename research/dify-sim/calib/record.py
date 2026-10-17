#!/usr/bin/env python
"""Calibration recorder: drives REAL Chromium tabs against the local Dify (via the repro harness, imported read-only) and records
 - every websocket frame (time, direction, socket.io event name, size) per tab  -> the observed event order
 - the stored draft before/after (full JSON, hash)
 - edit trigger timestamps
One JSON line per run is appended to --out.
usage: record.py SCENARIO --runs N --out FILE [--lat MS] [--gap MS] [--raf MS] [--settle S]
Scenarios: s1n (A.title c1 | B.desc c1), s2o (A,B add different output vars to c2), s2 (A,B rename c1), s2os (S2O with B 3 s later)
"""
import argparse, asyncio, json, os, re, sys, time, uuid
REPRO = 'research/real-browser'
sys.path.insert(0, os.path.join(REPRO, 'lib'))
import harness
from harness import Env, NetState, now
from difyapi import Client


class RecNetState(NetState):
    """NetState that also logs every frame with a timestamp and decoded socket.io event name."""
    def __init__(self, up_ms=0, down_ms=0):
        super().__init__(up_ms, down_ms)
        self.rec = []
        self._pending_ev = None

    def _log(self, direction, msg):
        t = now()
        if isinstance(msg, bytes):
            self.rec.append({"t": t, "d": direction, "ev": self._pending_ev or "?bin", "bin": len(msg)})
            return
        m = re.match(r'^(4[2-5])(\d*-)?(\d*)?(\[.*)$', msg, re.S) if msg and msg[0] == '4' else None
        ev = None
        if m:
            try:
                arr = json.loads(m.group(4)) if not (m.group(2) or '').startswith(('1-', '2-')) else json.loads(re.sub(r'\{"_placeholder":true,"num":\d+\}', 'null', m.group(4)))
                ev = arr[0] if m.group(1) in ('42', '45') and isinstance(arr[0], str) else ('ack' + m.group(3))
                if ev == 'collaboration_event' and isinstance(arr[1], dict):
                    ev = 'collaboration_event:' + str(arr[1].get('type'))
                if ev == 'collaboration_update' and isinstance(arr[1], dict):
                    ev = 'collaboration_update:' + str(arr[1].get('type'))
                if ev == 'status':
                    ev = 'status:' + str(arr[1].get('isLeader'))
            except Exception:
                ev = 'unparsed'
        self._pending_ev = ev
        self.rec.append({"t": t, "d": direction, "ev": ev or msg[:12], "n": len(msg)})

    async def install(self, page):
        async def handler(ws):
            if self.mode == "refuse":
                await ws.close(); return
            server = ws.connect_to_server()
            self.routes.append((ws, server))

            def fwd(dst, direction):
                def _on(msg):
                    if direction == "down" and isinstance(msg, str) and msg.startswith("40{"):
                        try: self.sid = json.loads(msg[2:])["sid"]
                        except Exception: pass
                    self._log(direction + "_in", msg)   # arrival at the proxy (before injected delay)
                    async def go():
                        d = self.up_ms if direction == "up" else self.down_ms
                        if d: await asyncio.sleep(d / 1000)
                        if self.mode != "normal": return
                        self.frames[direction] += 1
                        self._log(direction + "_out", msg)   # forwarded (after injected delay)
                        try: dst.send(msg)
                        except Exception: pass
                    asyncio.ensure_future(go())
                return _on
            ws.on_message(fwd(server, "up"))
            server.on_message(fwd(ws, "down"))
            ws.on_close(lambda code, reason: asyncio.ensure_future(server.close()))
            server.on_close(lambda code, reason: asyncio.ensure_future(ws.close()))
        await page.route_web_socket("**/socket.io/**", handler)


harness.NetState = RecNetState

PROBE = """
(() => {
  const P = window.__probe = { origin: performance.timeOrigin, msgs: [], sends: [], raf: [], mut: [] };
  const prev = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = (cb) => prev((t) => { P.raf.push(performance.now()); return cb(t); });
  const start = () => {
    new MutationObserver((ms) => { for (const m of ms) {
      const el = m.target.nodeType === 1 ? m.target : m.target.parentElement;
      const nodeEl = el && el.closest ? el.closest('.react-flow__node') : null;
      if (nodeEl) P.mut.push([performance.now(), nodeEl.getAttribute('data-id'), (m.type === 'attributes' ? (el.getAttribute('title') || '') : (m.target.textContent || '')).slice(0, 40)]);
    } }).observe(document.documentElement, { subtree: true, attributes: true, attributeFilter: ['title'], characterData: true, childList: true });
  };
  if (document.documentElement) start(); else document.addEventListener('DOMContentLoaded', start);
})();
"""
harness.HIDDEN_INIT = harness.HIDDEN_INIT + PROBE


def draft(app):
    d = Client("alice").get_draft(app)
    return {"hash": d["hash"], "graph": d["graph"], "updated_at": d.get("updated_at")}


async def run_once(i, scen, args):
    rec = {"scenario": scen, "i": i, "lat": args.lat, "gap": args.gap, "agap": args.agap, "fast": args.fast, "raf": args.raf, "started": time.time()}
    async with Env(headless=True) as env:
        app = env.new_app("CAL-" + scen)
        rec["app"] = app
        rec["draft_before"] = draft(app)
        a = await env.open_tab("A", "alice", app, up_ms=args.lat, down_ms=args.lat)
        b = await env.open_tab("B", "bob", app, up_ms=args.lat, down_ms=args.lat)
        if args.raf:
            await a.set_raf_delay(args.raf); await b.set_raf_delay(args.raf)
        await asyncio.sleep(1.5)
        rec["t_ready"] = now()
        for t in (a, b):
            t.net.rec.clear()
        marks = {}

        async def act(tab, kind, name, delay=0.0):
            if delay: await asyncio.sleep(delay)
            marks[name + "_start"] = now()
            if kind == "title": await tab.rename("c1", f"{name}-title-{i}")
            elif kind == "desc": await tab.set_desc("c1", f"{name}-desc-{i}")
            elif kind == "output": await tab.add_output("c2", f"o{name.lower()}")
            marks[name + "_end"] = now()

        if scen == "s2o_stale":
            # A opens the panel of c2 FIRST and keeps it open; B then adds ob (complete); after `gap` ms A adds oa from the still-open panel
            await a.select("c2")
            await asyncio.sleep(0.3)
            await b.add_output("c2", "ob")
            marks["B_done"] = now()
            await asyncio.sleep(args.gap / 1000)
            marks["A_start"] = now()
            await a.page.get_by_label("Add Output Variables").click()
            inputs = a.page.locator('input[placeholder="Variable name"]')
            n = await inputs.count()
            await inputs.nth(n - 1).fill("oa"); await inputs.nth(n - 1).blur()
            marks["A_end"] = now()
        elif args.fast:
            # pre-position both tabs (panel open, value typed) so that the two COMMITS are single quick calls (blur / click) issued together
            if scen == "s1n":
                await a.select("c1"); await b.select("c1")
                ti = a.page.locator('input[placeholder="Add title..."]'); td = b.page.locator('textarea[placeholder="Add description..."]')
                await ti.fill(f"A-title-{i}"); await td.fill(f"B-desc-{i}")
                await asyncio.sleep(0.3)
                async def commit(loc, name, delay):
                    if delay: await asyncio.sleep(delay)
                    marks[name + "_start"] = now(); await loc.blur(); marks[name + "_end"] = now()
                await asyncio.gather(commit(ti, "A", args.agap / 1000), commit(td, "B", args.gap / 1000))
            elif scen == "s2":
                await a.select("c1"); await b.select("c1")
                ti = a.page.locator('input[placeholder="Add title..."]'); tj = b.page.locator('input[placeholder="Add title..."]')
                await ti.fill(f"A-title-{i}"); await tj.fill(f"B-title-{i}")
                await asyncio.sleep(0.3)
                async def commit(loc, name, delay):
                    if delay: await asyncio.sleep(delay)
                    marks[name + "_start"] = now(); await loc.blur(); marks[name + "_end"] = now()
                await asyncio.gather(commit(ti, "A", args.agap / 1000), commit(tj, "B", args.gap / 1000))
            elif scen in ("s2o", "s2os"):
                await a.select("c2"); await b.select("c2")
                async def addout(tab, name, delay):
                    if delay: await asyncio.sleep(delay)
                    marks[name + "_start"] = now()
                    await tab.page.get_by_label("Add Output Variables").click()
                    inputs = tab.page.locator('input[placeholder="Variable name"]')
                    n = await inputs.count()
                    await inputs.nth(n - 1).fill(f"o{name.lower()}"); await inputs.nth(n - 1).blur()
                    marks[name + "_end"] = now()
                await asyncio.gather(addout(a, "A", args.agap / 1000), addout(b, "B", args.gap / 1000))
        elif scen == "s1n":
            await asyncio.gather(act(a, "title", "A"), act(b, "desc", "B", args.gap / 1000))
        elif scen == "s2":
            await asyncio.gather(act(a, "title", "A"), act(b, "title", "B", args.gap / 1000))
        elif scen in ("s2o", "s2os"):
            await asyncio.gather(act(a, "output", "A"), act(b, "output", "B", args.gap / 1000))
        await asyncio.sleep(args.settle)
        rec["marks"] = marks
        rec["draft_after"] = draft(app)
        rec["frames"] = {"A": a.net.rec, "B": b.net.rec}
        rec["saves"] = {"A": a.saves, "B": b.saves}
        rec["console"] = {n: [c[2][:160] for c in t.console if c[1] in ("error", "pageerror")][:5] for n, t in (("A", a), ("B", b))}
        rec["canvas"] = {"A": await a.canvas(), "B": await b.canvas()}
        rec["probe"] = {"A": await a.page.evaluate("window.__probe"), "B": await b.page.evaluate("window.__probe")}
        await a.close(); await b.close()
    rec["done"] = time.time()
    return rec


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario"); ap.add_argument("--runs", type=int, default=10); ap.add_argument("--out", required=True)
    ap.add_argument("--lat", type=int, default=0); ap.add_argument("--gap", type=int, default=0); ap.add_argument("--raf", type=int, default=0)
    ap.add_argument("--settle", type=float, default=14)
    ap.add_argument("--fast", action="store_true"); ap.add_argument("--agap", type=int, default=0)
    args = ap.parse_args()
    for i in range(args.runs):
        try:
            rec = await asyncio.wait_for(run_once(i, args.scenario, args), 240)
        except Exception as e:
            rec = {"scenario": args.scenario, "i": i, "error": f"{type(e).__name__}: {e}"}
        with open(args.out, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        print(i, rec.get("error", "ok"), flush=True)

asyncio.run(main())
