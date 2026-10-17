#!/usr/bin/env python
"""Scenario runner for the Dify workflow-editor edit-loss repro.

usage: scenarios.py <scenario> [--runs N] [--parallel P] [--tag TAG]
Each run creates a fresh workflow app (4 code nodes), drives 2-3 real Chromium contexts through the real
web UI, waits for the autosave debounce to settle, then compares: acknowledged edits vs server draft vs each tab.
One JSON record per run is appended to logs/<scenario>[-tag].jsonl
"""
import argparse, asyncio, json, os, sys, time, traceback

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from harness import *  # noqa

SCEN = {}


def scenario(name, doc):
    def deco(fn):
        fn.doc = doc
        SCEN[name] = fn
        return fn
    return deco


# ---------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------
def field_of(canvas_node, field):
    if canvas_node is None:
        return None
    if field == "title":
        return canvas_node.get("title")
    if field == "x":
        return canvas_node.get("x")
    if field == "y":
        return canvas_node.get("y")
    return None


def srv_field(sg, nid, field):
    n = sg["nodes"].get(nid)
    if n is None:
        return None
    return n.get(field if field != "pos" else "x")


async def local_ack(tab, nid, field, expected):
    c = await tab.canvas()
    v = field_of(c["nodes"].get(nid), field)
    return v == expected if field == "title" else v is not None


async def observe(app, tabs, edits, rec, settle=SETTLE_S):
    """settle, then record server draft + each live tab's canvas, and classify edits"""
    await asyncio.sleep(settle)
    sg = server_graph(app)
    rec["server_final"] = {"hash": sg["hash"][:8], "titles": {k: v["title"] for k, v in sg["nodes"].items()},
                           "pos": {k: [v["x"], v["y"]] for k, v in sg["nodes"].items()}, "edges": sg["edges"]}
    rec["tabs_final"] = {}
    for t in tabs:
        try:
            c = await t.canvas()
            rec["tabs_final"][t.name] = {"titles": {k: v["title"] for k, v in c["nodes"].items()},
                                         "pos": {k: [v["x"], v["y"]] for k, v in c["nodes"].items()}, "edges": sorted(c["edges"])}
        except Exception as e:  # tab closed
            rec["tabs_final"][t.name] = None
    # edit classification
    res = []
    for e in edits:
        nid, field, val = e["node"], e["field"], e["value"]
        if field == "title":
            on_server = sg["nodes"].get(nid, {}).get("title") == val
            on_tabs = {k: (v is not None and v["titles"].get(nid) == val) for k, v in rec["tabs_final"].items()}
        elif field == "pos":
            sx, sy = sg["nodes"].get(nid, {}).get("x"), sg["nodes"].get(nid, {}).get("y")
            on_server = sx is not None and abs(sx - val[0]) < 2 and abs(sy - val[1]) < 2
            on_tabs = {}
            for k, v in rec["tabs_final"].items():
                p = None if v is None else v["pos"].get(nid)
                on_tabs[k] = p is not None and p[0] is not None and abs(p[0] - val[0]) < 2 and abs(p[1] - val[1]) < 2
        elif field == "outputs":
            on_server = val in (sg["nodes"].get(nid, {}).get("outputs") or [])
            on_tabs = {}
        elif field == "desc":
            on_server = sg["nodes"].get(nid, {}).get("desc") == val
            on_tabs = {}
        else:
            on_server, on_tabs = None, {}
        res.append({**e, "on_server": on_server, "on_tabs": on_tabs})
    rec["edits"] = res
    # divergence: tabs vs server (titles, node set, edge set) and tabs vs each other
    div = []
    for k, v in rec["tabs_final"].items():
        if v is None:
            continue
        if set(v["titles"]) != set(rec["server_final"]["titles"]):
            div.append(f"{k}:nodeset")
        else:
            for nid, t in v["titles"].items():
                if t != rec["server_final"]["titles"][nid]:
                    div.append(f"{k}:title:{nid}")
            for nid, p in v["pos"].items():
                sp = rec["server_final"]["pos"].get(nid)
                if sp and p[0] is not None and (abs(p[0] - sp[0]) > 2 or abs(p[1] - sp[1]) > 2):
                    div.append(f"{k}:pos:{nid}")
        if set(v["edges"]) != set(f"xy-edge__{e.replace('->', 'source-')}" for e in []) and False:
            pass
    names = [k for k, v in rec["tabs_final"].items() if v is not None]
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            a, b = rec["tabs_final"][names[i]], rec["tabs_final"][names[j]]
            if a["titles"] != b["titles"]:
                div.append(f"{names[i]}!={names[j]}:titles")
    rec["divergence"] = sorted(set(div))
    return sg


def verdict(rec):
    """lost = locally-acknowledged edit missing on the server; divergence = clients/server disagree"""
    lost = [e for e in rec["edits"] if e.get("acked") and not e["on_server"] and not e.get("superseded")]
    stale_peer = [e for e in rec["edits"] if e.get("acked") and e["on_server"] and any(v is False for v in e["on_tabs"].values())]
    out = []
    if lost:
        out.append("LOST_EDIT")
    if rec.get("divergence"):
        out.append("DIVERGENCE")
    if stale_peer and not rec.get("divergence"):
        out.append("PEER_MISSING")
    rec["verdict"] = out or ["OK"]
    rec["lost_edits"] = [f'{e["by"]}:{e["node"]}.{e["field"]}' for e in lost]


async def do_edit(tab, kind, nid, value=None, edits=None, dx=0, dy=0):
    """perform one UI edit; record the locally observed (acknowledged) outcome"""
    if kind == "title":
        await tab.rename(nid, value)
        await asyncio.sleep(0.3)
        ack = (await tab.canvas())["nodes"].get(nid, {}).get("title") == value
        edits.append({"by": tab.name, "node": nid, "field": "title", "value": value, "acked": ack, "t": now()})
    elif kind == "drag":
        before = (await tab.canvas())["nodes"][nid]
        await tab.drag(nid, dx, dy)
        await asyncio.sleep(0.3)
        after = (await tab.canvas())["nodes"][nid]
        moved = abs(after["x"] - before["x"]) > 1 or abs(after["y"] - before["y"]) > 1
        edits.append({"by": tab.name, "node": nid, "field": "pos", "value": [after["x"], after["y"]], "acked": moved, "t": now()})
    elif kind == "output":
        await tab.add_output(nid, value)
        edits.append({"by": tab.name, "node": nid, "field": "outputs", "value": value, "acked": True, "t": now()})
    elif kind == "desc":
        await tab.set_desc(nid, value)
        edits.append({"by": tab.name, "node": nid, "field": "desc", "value": value, "acked": True, "t": now()})


def save_summary(tabs):
    out = {}
    for t in tabs:
        out[t.name] = [{"dt": round(x["t"], 2), "kind": x["kind"], "hash": (x.get("hash") or "")[:6] if x["kind"] == "req" else None,
                        "n": x.get("nodes"), "len": x.get("len"), "status": x.get("status"), "body": x.get("body", "")[:80] if x["kind"] == "resp" and x.get("status") != 200 else None}
                       for x in t.saves]
    return out


async def finish(rec, tabs, t_start):
    rec["saves"] = save_summary(tabs)
    rec["console_errors"] = {t.name: [c[2][:160] for c in t.console if c[1] in ("error", "pageerror")][:6] for t in tabs}
    rec["duration_s"] = round(now() - t_start, 1)
    verdict(rec)
    if rec["verdict"] != ["OK"]:
        os.makedirs(SHOTDIR, exist_ok=True)
        for t in tabs:
            try:
                await t.page.screenshot(path=os.path.join(SHOTDIR, f'{rec["scenario"]}-{rec["i"]}-{t.name}.png'))
            except Exception:
                pass


# ---------------------------------------------------------------------------------------------
# S1: two users edit different nodes concurrently
# ---------------------------------------------------------------------------------------------
@scenario("S1", "A: rename c1 + drag c2; B: rename c3 + drag c4 (different nodes, concurrently)")
async def s1(env, rec, lat=0):
    app = rec["app"] = env.new_app("S1")
    a = await env.open_tab("A", "alice", app, up_ms=lat, down_ms=lat)
    b = await env.open_tab("B", "bob", app, up_ms=lat, down_ms=lat)
    rec["leader_is"] = "A" if leader_sid(app) == a.net.sid else "B" if leader_sid(app) == b.net.sid else "?"
    t0 = now()
    edits = []

    async def ua():
        await do_edit(a, "title", "c1", "A-c1-%d" % rec["i"], edits)
        await do_edit(a, "drag", "c2", edits=edits, dx=0, dy=120)

    async def ub():
        await do_edit(b, "title", "c3", "B-c3-%d" % rec["i"], edits)
        await do_edit(b, "drag", "c4", edits=edits, dx=0, dy=90)

    await asyncio.gather(ua(), ub())
    await observe(app, [a, b], edits, rec)
    await finish(rec, [a, b], t0)
    for t in (a, b):
        await t.close()


@scenario("S1L", "same as S1 with 400 ms one-way websocket latency injected on both clients (real concurrency window)")
async def s1l(env, rec):
    await s1(env, rec, lat=400)


@scenario("S1N", "A edits c1.title while B edits c1.desc (same node, different fields)")
async def s1n(env, rec, lat=0):
    app = rec["app"] = env.new_app("S1N")
    a = await env.open_tab("A", "alice", app, up_ms=lat, down_ms=lat)
    b = await env.open_tab("B", "bob", app, up_ms=lat, down_ms=lat)
    t0 = now()
    edits = []
    await asyncio.gather(do_edit(a, "title", "c1", "A-c1-%d" % rec["i"], edits), do_edit(b, "desc", "c1", "B-desc-%d" % rec["i"], edits))
    await observe(app, [a, b], edits, rec)
    await finish(rec, [a, b], t0)
    for t in (a, b):
        await t.close()


@scenario("S1NR", "S1N with a 250 ms rAF delay on both tabs (stress: slow/busy main thread, big graph)")
async def s1nr(env, rec):
    app = rec["app"] = env.new_app("S1NR")
    a = await env.open_tab("A", "alice", app)
    b = await env.open_tab("B", "bob", app)
    await a.set_raf_delay(250); await b.set_raf_delay(250)
    t0 = now()
    edits = []
    await asyncio.gather(do_edit(a, "title", "c1", "A-c1-%d" % rec["i"], edits), do_edit(b, "desc", "c1", "B-desc-%d" % rec["i"], edits))
    await observe(app, [a, b], edits, rec)
    for t in (a, b):
        rec.setdefault("desc_seen", {})[t.name] = await t.read_desc("c1")
    await finish(rec, [a, b], t0)
    for t in (a, b):
        await t.close()


@scenario("S1NL", "S1N with 400 ms websocket latency")
async def s1nl(env, rec):
    await s1n(env, rec, lat=400)


# ---------------------------------------------------------------------------------------------
# S2: same node / same field
# ---------------------------------------------------------------------------------------------
@scenario("S2", "A and B rename the SAME node's title concurrently")
async def s2(env, rec, lat=0):
    app = rec["app"] = env.new_app("S2")
    a = await env.open_tab("A", "alice", app, up_ms=lat, down_ms=lat)
    b = await env.open_tab("B", "bob", app, up_ms=lat, down_ms=lat)
    t0 = now()
    edits = []
    await asyncio.gather(do_edit(a, "title", "c1", "A-same-%d" % rec["i"], edits), do_edit(b, "title", "c1", "B-same-%d" % rec["i"], edits))
    await observe(app, [a, b], edits, rec)
    # same field: exactly one value can win; the other acknowledged edit is superseded by design (LWW).
    w = rec["server_final"]["titles"]["c1"]
    rec["winner"] = w
    for e in rec["edits"]:
        e["superseded"] = True
    rec["silent_overwrite"] = sum(1 for e in rec["edits"] if e["acked"] and not e["on_server"])
    await finish(rec, [a, b], t0)
    rec["verdict"] = [v for v in rec["verdict"] if v != "LOST_EDIT"] + (["LWW_ONE_EDIT_DROPPED"] if rec["silent_overwrite"] else [])
    if not rec["verdict"]:
        rec["verdict"] = ["OK"]
    for t in (a, b):
        await t.close()


@scenario("S2L", "S2 with 400 ms websocket latency")
async def s2l(env, rec):
    await s2(env, rec, lat=400)


@scenario("S2O", "A and B each add a DIFFERENT output variable to the same code node (nested object value)")
async def s2o(env, rec, lat=0):
    app = rec["app"] = env.new_app("S2O")
    a = await env.open_tab("A", "alice", app, up_ms=lat, down_ms=lat)
    b = await env.open_tab("B", "bob", app, up_ms=lat, down_ms=lat)
    t0 = now()
    edits = []
    await asyncio.gather(do_edit(a, "output", "c2", "oa", edits), do_edit(b, "output", "c2", "ob", edits))
    await observe(app, [a, b], edits, rec)
    await finish(rec, [a, b], t0)
    sg = server_graph(app)
    rec["server_outputs"] = sg["nodes"]["c2"]["outputs"]
    for t in (a, b):
        await t.close()


async def s2o_stagger(env, rec, gap):
    app = rec["app"] = env.new_app("S2OS")
    a = await env.open_tab("A", "alice", app)
    b = await env.open_tab("B", "bob", app)
    t0 = now()
    edits = []

    async def late_b():
        await asyncio.sleep(gap)
        await do_edit(b, "output", "c2", "ob", edits)

    await asyncio.gather(do_edit(a, "output", "c2", "oa", edits), late_b())
    await observe(app, [a, b], edits, rec)
    await finish(rec, [a, b], t0)
    rec["server_outputs"] = server_graph(app)["nodes"]["c2"]["outputs"]
    for t in (a, b):
        await t.close()


@scenario("S2OS", "S2O but B starts 3 s after A (no concurrency; control)")
async def s2os(env, rec):
    await s2o_stagger(env, rec, 3.0)


@scenario("S2OM", "S2O but B starts 0.8 s after A (partial overlap)")
async def s2om(env, rec):
    await s2o_stagger(env, rec, 0.8)


@scenario("S2OL", "S2O with 400 ms websocket latency")
async def s2ol(env, rec):
    await s2o(env, rec, lat=400)


# ---------------------------------------------------------------------------------------------
# S3: hidden / stale tabs, stale hash after leader hand-off
# ---------------------------------------------------------------------------------------------
@scenario("S3A", "B hidden (emulated: visibilityState+rAF paused) while leader A edits; B returns and edits")
async def s3a(env, rec):
    app = rec["app"] = env.new_app("S3A")
    a = await env.open_tab("A", "alice", app)
    b = await env.open_tab("B", "bob", app)
    t0 = now()
    edits = []
    await b.hide()
    await asyncio.sleep(1)
    await do_edit(a, "title", "c1", "A-c1-%d" % rec["i"], edits)
    await asyncio.sleep(8)  # A saves
    await do_edit(a, "drag", "c2", edits=edits, dy=100)
    await asyncio.sleep(8)
    await b.show()
    await asyncio.sleep(2)
    await do_edit(b, "title", "c3", "B-c3-%d" % rec["i"], edits)
    await observe(app, [a, b], edits, rec)
    await finish(rec, [a, b], t0)
    for t in (a, b):
        await t.close()


@scenario("S3E", "2 users: A (leader) edits+autosaves, A leaves; B (never saved, stale hash) edits once and closes its tab 1 s later")
async def s3e(env, rec):
    app = rec["app"] = env.new_app("S3E")
    a = await env.open_tab("A", "alice", app)
    b = await env.open_tab("B", "bob", app)
    t0 = now()
    edits = []
    await do_edit(a, "title", "c1", "A-c1-%d" % rec["i"], edits)
    await asyncio.sleep(9)
    await a.close()
    await asyncio.sleep(3)
    rec["leader_is_B"] = leader_sid(app) == b.net.sid
    await do_edit(b, "title", "c3", "B-c3-%d" % rec["i"], edits)
    await asyncio.sleep(1)
    await b.close()                    # B is the sole collaborator: its page-close flush is allowed to run
    await asyncio.sleep(4)
    sg = server_graph(app)
    rec["server_final"] = {"titles": {k: v["title"] for k, v in sg["nodes"].items()}}
    edits[-1]["on_server"] = sg["nodes"]["c3"]["title"] == edits[-1]["value"]
    edits[0]["on_server"] = sg["nodes"]["c1"]["title"] == edits[0]["value"]
    for e in edits:
        e["on_tabs"] = {}
    rec["edits"], rec["divergence"] = edits, []
    rec["saves"] = save_summary([a, b])
    rec["console_errors"] = {}
    verdict(rec)


@scenario("S3D", "tab returns from background and the user edits within 0.2 s: the 500 ms post-show refresh cancels the pending autosave debounce")
async def s3d(env, rec):
    app = rec["app"] = env.new_app("S3D")
    a = await env.open_tab("A", "alice", app)
    b = await env.open_tab("B", "bob", app)
    t0 = now()
    edits = []
    await b.hide()
    await asyncio.sleep(3)
    await b.show()
    await asyncio.sleep(0.2)
    await do_edit(b, "title", "c3", "B-c3-%d" % rec["i"], edits)
    await observe(app, [a, b], edits, rec, settle=SETTLE_S)
    await finish(rec, [a, b], t0)
    rec["B_saved_anything"] = any(x["kind"] == "req" for x in b.saves)
    for t in (a, b):
        await t.close()


@scenario("S10", "two tabs open the whole time, edits NOT concurrent: A edits c1 (autosaved), then B (visible, opened earlier) edits c3 and later c4")
async def s10(env, rec):
    app = rec["app"] = env.new_app("S10")
    a = await env.open_tab("A", "alice", app)
    b = await env.open_tab("B", "bob", app)
    t0 = now()
    edits = []
    await do_edit(a, "title", "c1", "A-c1-%d" % rec["i"], edits)
    await asyncio.sleep(8)                       # A's autosave lands, server hash moves
    await do_edit(b, "title", "c3", "B-c3-%d" % rec["i"], edits)
    await asyncio.sleep(8)                       # B's autosave: with a stale hash (and in non-collab mode a stale canvas)
    rec["after_B_first_edit_server_has_B"] = server_graph(app)["nodes"]["c3"]["title"] == "B-c3-%d" % rec["i"]
    await b.close_panel()
    await do_edit(b, "title", "c4", "B-c4-%d" % rec["i"], edits)
    await observe(app, [a, b], edits, rec)
    await finish(rec, [a, b], t0)
    for t in (a, b):
        await t.close()


@scenario("S3B", "leader A hidden (tab in background) while B edits; then A returns")
async def s3b(env, rec):
    app = rec["app"] = env.new_app("S3B")
    a = await env.open_tab("A", "alice", app)
    b = await env.open_tab("B", "bob", app)
    t0 = now()
    edits = []
    rec["leader_before"] = "A" if leader_sid(app) == a.net.sid else "B"
    await a.hide()
    await asyncio.sleep(2)
    rec["leader_after_hide"] = "A" if leader_sid(app) == a.net.sid else "B" if leader_sid(app) == b.net.sid else "?"
    await do_edit(b, "title", "c3", "B-c3-%d" % rec["i"], edits)
    await asyncio.sleep(8)
    await do_edit(b, "drag", "c4", edits=edits, dy=90)
    await asyncio.sleep(8)
    await a.show()
    await asyncio.sleep(3)
    await observe(app, [a, b], edits, rec, settle=4)
    await finish(rec, [a, b], t0)
    for t in (a, b):
        await t.close()


@scenario("S3C", "stale hash after leader hand-off: A(leader),B,C open; A edits+saves; A closes; B (new leader, never saved) edits")
async def s3c(env, rec):
    app = rec["app"] = env.new_app("S3C")
    a = await env.open_tab("A", "alice", app)
    b = await env.open_tab("B", "bob", app)
    c = await env.open_tab("C", "bob2", app)
    t0 = now()
    edits = []
    await do_edit(a, "title", "c1", "A-c1-%d" % rec["i"], edits)
    await asyncio.sleep(9)           # A's debounced save lands -> server hash moves, B/C still hold the old hash
    await a.close()
    await asyncio.sleep(3)
    rec["leader_after_A_left"] = "B" if leader_sid(app) == b.net.sid else "C" if leader_sid(app) == c.net.sid else "?"
    leader = b if rec["leader_after_A_left"] == "B" else c
    await do_edit(leader, "title", "c3", "L-c3-%d" % rec["i"], edits)
    rec["saves_before_settle"] = None
    await observe(app, [b, c], edits, rec, settle=SETTLE_S)
    rec["server_after_14s_has_leader_edit"] = rec["edits"][-1]["on_server"]
    # now the tab holding the edit closes normally (user finishes work)
    await leader.close()
    await asyncio.sleep(4)
    sg = server_graph(app)
    rec["server_after_leader_closed_has_edit"] = sg["nodes"]["c3"]["title"] == "L-c3-%d" % rec["i"]
    other = c if leader is b else b
    await asyncio.sleep(2)
    sg = server_graph(app)
    rec["server_has_edit_final"] = sg["nodes"]["c3"]["title"] == "L-c3-%d" % rec["i"]
    rec["edits"][-1]["on_server"] = rec["server_has_edit_final"]
    await finish(rec, [b, c], t0)
    # the other remaining collaborator (stale hash too) also finishes work and closes its tab
    await asyncio.sleep(1)
    if leader is b:
        await c.close()
    else:
        await b.close()
    await asyncio.sleep(4)
    rec["server_has_edit_after_everyone_left"] = server_graph(app)["nodes"]["c3"]["title"] == "L-c3-%d" % rec["i"]
    if not rec["server_has_edit_after_everyone_left"]:
        rec["verdict"] = sorted(set(rec["verdict"] + ["PERMANENT_LOSS"]))


# ---------------------------------------------------------------------------------------------
# S4: network drop / reconnect
# ---------------------------------------------------------------------------------------------
@scenario("S4A", "follower B loses the websocket for 12 s while leader A edits; B reconnects, then B edits")
async def s4a(env, rec):
    app = rec["app"] = env.new_app("S4A")
    a = await env.open_tab("A", "alice", app)
    b = await env.open_tab("B", "bob", app)
    t0 = now()
    edits = []
    await b.net.drop("refuse")
    await b.ctx.set_offline(True)
    await asyncio.sleep(1.5)
    await do_edit(a, "title", "c1", "A-c1-%d" % rec["i"], edits)
    await asyncio.sleep(10)
    await b.ctx.set_offline(False)
    b.net.restore()
    await asyncio.sleep(10)  # socket.io reconnect backoff
    await do_edit(b, "title", "c3", "B-c3-%d" % rec["i"], edits)
    await observe(app, [a, b], edits, rec)
    await finish(rec, [a, b], t0)
    for t in (a, b):
        await t.close()


@scenario("S4B", "B edits (keyboard focus already in title field) AFTER its websocket dropped; then reconnects")
async def s4b(env, rec):
    app = rec["app"] = env.new_app("S4B")
    a = await env.open_tab("A", "alice", app)
    b = await env.open_tab("B", "bob", app)
    t0 = now()
    edits = []
    await b.select("c3")
    inp = b.page.locator('input[placeholder="Add title..."]')
    await inp.focus()
    await b.net.drop("refuse")
    await b.ctx.set_offline(True)
    await asyncio.sleep(1.5)
    val = "B-offline-%d" % rec["i"]
    await inp.fill(val)
    await inp.blur()
    await asyncio.sleep(0.5)
    ack = (await b.canvas())["nodes"]["c3"]["title"] == val
    rec["overlay_visible_offline"] = await b.page.locator('[data-testid="collaboration-graph-loading"]').count() > 0
    edits.append({"by": "B", "node": "c3", "field": "title", "value": val, "acked": ack, "t": now()})
    await asyncio.sleep(8)
    await b.ctx.set_offline(False)
    b.net.restore()
    await observe(app, [a, b], edits, rec, settle=18)
    await finish(rec, [a, b], t0)
    for t in (a, b):
        await t.close()


@scenario("S4C", "single user A: edit, websocket drops 2 s later (inside the 5 s debounce window), returns 8 s later")
async def s4c(env, rec):
    app = rec["app"] = env.new_app("S4C")
    a = await env.open_tab("A", "alice", app)
    t0 = now()
    edits = []
    await do_edit(a, "title", "c1", "A-c1-%d" % rec["i"], edits)
    await asyncio.sleep(1.5)
    await a.net.drop("refuse")
    await a.ctx.set_offline(True)
    await asyncio.sleep(8)
    await a.ctx.set_offline(False)
    a.net.restore()
    await observe(app, [a], edits, rec, settle=20)
    await finish(rec, [a], t0)
    await a.close()


@scenario("S4D", "leader A drops (silently, blackhole) for 60 s right after B edited; B should take over")
async def s4d(env, rec):
    app = rec["app"] = env.new_app("S4D")
    a = await env.open_tab("A", "alice", app)
    b = await env.open_tab("B", "bob", app)
    t0 = now()
    edits = []
    await a.net.drop("blackhole")
    await a.ctx.set_offline(True)
    await asyncio.sleep(1)
    await do_edit(b, "title", "c3", "B-c3-%d" % rec["i"], edits)
    await asyncio.sleep(70)
    rec["saves_B_at_70s"] = save_summary([b])["B"]
    rec["server_has_edit_at_70s"] = server_graph(app)["nodes"]["c3"]["title"] == "B-c3-%d" % rec["i"]
    await a.ctx.set_offline(False)
    a.net.restore()
    await observe(app, [a, b], edits, rec, settle=25)
    await finish(rec, [a, b], t0)
    for t in (a, b):
        await t.close()


# ---------------------------------------------------------------------------------------------
# S5: leader / follower closes right after edits
# ---------------------------------------------------------------------------------------------
@scenario("S5A", "leader A edits then closes the tab gracefully 0.5 s later (before debounce)")
async def s5a(env, rec):
    app = rec["app"] = env.new_app("S5A")
    a = await env.open_tab("A", "alice", app)
    b = await env.open_tab("B", "bob", app)
    t0 = now()
    edits = []
    await do_edit(a, "title", "c1", "A-c1-%d" % rec["i"], edits)
    await asyncio.sleep(0.5)
    await a.close()
    await observe(app, [b], edits, rec, settle=14)
    await finish(rec, [b], t0)
    await b.close()                      # B (sole remaining tab) closes normally -> does it flush A's edit?
    await asyncio.sleep(4)
    rec["server_has_edit_after_B_closed"] = server_graph(app)["nodes"]["c1"]["title"] == "A-c1-%d" % rec["i"]


@scenario("S5B", "leader A edits then crashes (page destroyed without beforeunload) 0.5 s later; B stays open")
async def s5b(env, rec):
    app = rec["app"] = env.new_app("S5B")
    a = await env.open_tab("A", "alice", app)
    b = await env.open_tab("B", "bob", app)
    t0 = now()
    edits = []
    await do_edit(a, "title", "c1", "A-c1-%d" % rec["i"], edits)
    await asyncio.sleep(0.5)
    await a.kill()
    await observe(app, [b], edits, rec, settle=20)
    rec["B_sees_edit"] = rec["tabs_final"]["B"]["titles"].get("c1") == "A-c1-%d" % rec["i"]
    await finish(rec, [b], t0)
    await b.close()                      # B closes normally later -> does it flush A's edit?
    await asyncio.sleep(4)
    rec["server_has_edit_after_B_closed"] = server_graph(app)["nodes"]["c1"]["title"] == "A-c1-%d" % rec["i"]


@scenario("S5C", "FOLLOWER B edits and closes 0.5 s later, leader A idle & stays open")
async def s5c(env, rec):
    app = rec["app"] = env.new_app("S5C")
    a = await env.open_tab("A", "alice", app)
    b = await env.open_tab("B", "bob", app)
    t0 = now()
    edits = []
    await do_edit(b, "title", "c3", "B-c3-%d" % rec["i"], edits)
    await asyncio.sleep(0.5)
    await b.close()
    await observe(app, [a], edits, rec, settle=20)
    rec["A_sees_edit"] = rec["tabs_final"]["A"]["titles"].get("c3") == "B-c3-%d" % rec["i"]
    # then A (who has the edit in memory only) crashes without ever saving
    await a.kill()
    await asyncio.sleep(1)
    rec["server_after_A_crash_has_edit"] = server_graph(app)["nodes"]["c3"]["title"] == "B-c3-%d" % rec["i"]
    rec["edits"][-1]["on_server"] = rec["server_after_A_crash_has_edit"]
    await finish(rec, [a], t0)


@scenario("S5D", "leader A edits, crashes immediately (page destroyed) with NO other collaborator online")
async def s5d(env, rec):
    app = rec["app"] = env.new_app("S5D")
    a = await env.open_tab("A", "alice", app)
    t0 = now()
    edits = []
    await do_edit(a, "title", "c1", "A-c1-%d" % rec["i"], edits)
    await asyncio.sleep(0.5)
    await a.kill()
    await asyncio.sleep(2)
    sg = server_graph(app)
    rec["server_final"] = {"titles": {k: v["title"] for k, v in sg["nodes"].items()}}
    edits[-1]["on_server"] = sg["nodes"]["c1"]["title"] == edits[-1]["value"]
    edits[-1]["on_tabs"] = {}
    rec["edits"] = edits
    rec["divergence"] = []
    rec["saves"] = {}
    rec["console_errors"] = {}
    verdict(rec)


# ---------------------------------------------------------------------------------------------
# S6: single user baseline
# ---------------------------------------------------------------------------------------------
async def s6_common(env, rec, how):
    app = rec["app"] = env.new_app("S6" + how)
    a = await env.open_tab("A", "alice", app)
    t0 = now()
    edits = []
    await do_edit(a, "title", "c1", "A-c1-%d" % rec["i"], edits)
    await do_edit(a, "title", "c2", "A-c2-%d" % rec["i"], edits)
    await do_edit(a, "drag", "c3", edits=edits, dy=110)
    await do_edit(a, "title", "c4", "A-c4-%d" % rec["i"], edits)
    await asyncio.sleep(0.3)
    tabs = []
    settle = 4
    if how == "close":          # normal tab close: pagehide / visibilitychange(hidden) handlers run
        await a.close()
    elif how == "reload":
        await a.page.reload()
        await a.wait_ready()
        tabs = [a]
    elif how == "crash":        # SIGKILL of the browser: no handlers at all
        rec["killed_pids"] = len(await a.kill())
    elif how == "nav":          # full navigation away from the editor
        await a.page.goto(BASE + "/apps")
    else:                       # wait for the autosave debounce (control)
        tabs = [a]
        settle = SETTLE_S
    await observe(app, tabs, edits, rec, settle=settle)
    rec["saves"] = save_summary([a]) if how in ("reload", "wait") else {}
    rec["console_errors"] = {}
    verdict(rec)
    if not getattr(a, "dead", False):
        await a.close()


@scenario("S6A", "single user: 4 quick edits then normal tab close after 0.3 s")
async def s6a(env, rec):
    await s6_common(env, rec, "close")


@scenario("S6B", "single user: 4 quick edits then reload after 0.3 s")
async def s6b(env, rec):
    await s6_common(env, rec, "reload")


@scenario("S6C", "single user: 4 quick edits then browser SIGKILL (no handlers run) after 0.3 s")
async def s6c(env, rec):
    await s6_common(env, rec, "crash")


@scenario("S6D", "single user: 4 quick edits then full navigation to /apps after 0.3 s")
async def s6d(env, rec):
    await s6_common(env, rec, "nav")


@scenario("S6E", "single user: 4 quick edits then wait for autosave (control)")
async def s6e(env, rec):
    await s6_common(env, rec, "wait")


@scenario("S6F", "single user, LARGE workflow (100 nodes, ~72 KB request body > 64 KB keepalive cap): edit one title, close tab 0.5 s later (keepalive body limit)")
async def s6f(env, rec, n=100, how="close"):
    app = rec["app"] = env.new_app("S6F", n_code=n)
    rec["draft_json_bytes"] = len(json.dumps(server_graph(app)["raw"]["graph"]))
    a = await env.open_tab("A", "alice", app)
    t0 = now()
    edits = []
    await do_edit(a, "title", "c1", "A-c1-%d" % rec["i"], edits)
    await asyncio.sleep(0.5)
    if how == "close":
        await a.close()
    await asyncio.sleep(4)
    sg = server_graph(app)
    edits[-1]["on_server"] = sg["nodes"]["c1"]["title"] == edits[-1]["value"]
    edits[-1]["on_tabs"] = {}
    rec["edits"], rec["divergence"], rec["saves"], rec["console_errors"] = edits, [], save_summary([a]), {}
    rec["server_final"] = {"titles": {k: v["title"] for k, v in list(sg["nodes"].items())[:3]}}
    verdict(rec)


@scenario("S6G", "single user, small workflow (30 nodes, ~23 KB body) same procedure as S6F (control)")
async def s6g(env, rec):
    await s6f(env, rec, n=30)


@scenario("S8", "draft changed out-of-band (API / other device) while leader tab open; tab then makes two edits")
async def s8(env, rec):
    app = rec["app"] = env.new_app("S8")
    a = await env.open_tab("A", "alice", app)
    t0 = now()
    edits = []
    x = Client("bob")
    d = x.get_draft(app)
    g = json.loads(json.dumps(d["graph"]))
    for n in g["nodes"]:
        if n["id"] == "c4":
            n["data"]["title"] = "EXT-%d" % rec["i"]
    x.save_draft(app, g, hash=d["hash"], collaborative=False)
    edits.append({"by": "EXT", "node": "c4", "field": "title", "value": "EXT-%d" % rec["i"], "acked": True, "t": now()})
    await asyncio.sleep(1)
    await do_edit(a, "title", "c1", "A-c1-%d" % rec["i"], edits)
    await asyncio.sleep(8)       # debounce fires -> 409 -> hash-only refresh
    sg1 = server_graph(app)
    rec["after_first_edit_server_has_A_c1"] = sg1["nodes"]["c1"]["title"] == "A-c1-%d" % rec["i"]
    rec["after_first_edit_server_has_EXT"] = sg1["nodes"]["c4"]["title"] == "EXT-%d" % rec["i"]
    await do_edit(a, "title", "c2", "A-c2-%d" % rec["i"], edits)
    await observe(app, [a], edits, rec)
    await finish(rec, [a], t0)
    await a.close()


async def s9_core(env, rec, followup=False):
    """The `workflow_update` event is what update-dsl-modal.tsx:94 / header-in-restoring.tsx:115 emit after DSL import / version
    restore. We replace the draft through the (hash-protected) API as user alice and emit the same socket event from a python
    socket.io client, i.e. exactly what a third tab does after 'import DSL'."""
    import socketio
    app = rec["app"] = env.new_app("S9")
    a = await env.open_tab("A", "alice", app)
    b = await env.open_tab("B", "bob", app)
    t0 = now()
    edits = []
    # B edits c3 and, 0.5 s later (< 5 s debounce), someone imports a DSL that replaces the draft
    await do_edit(b, "title", "c3", "B-c3-%d" % rec["i"], edits)
    await asyncio.sleep(0.5)
    x = Client("alice")
    d = x.get_draft(app)
    g = json.loads(json.dumps(d["graph"]))
    for n in g["nodes"]:
        if n["id"] == "c4":
            n["data"]["title"] = "IMPORTED-c4"
    x.save_draft(app, g, hash=d["hash"], collaborative=False)
    sio = socketio.AsyncClient()
    ck = "; ".join(f'{c["name"]}={c["value"]}' for c in x.cookies())
    await sio.connect("http://localhost", socketio_path="/socket.io", transports=["websocket"], headers={"Cookie": ck})
    await sio.call("user_connect", {"workflow_id": app})
    await sio.call("collaboration_event", {"type": "workflow_update", "data": {"appId": app, "timestamp": int(now() * 1000)}, "timestamp": int(now() * 1000)})
    await asyncio.sleep(1)
    await sio.disconnect()
    edits.append({"by": "IMPORT", "node": "c4", "field": "title", "value": "IMPORTED-c4", "acked": True, "t": now()})
    await observe(app, [a, b], edits, rec)
    if followup:
        await do_edit(a, "title", "c1", "A-late-%d" % rec["i"], edits)
        await asyncio.sleep(SETTLE_S)
        sg = server_graph(app)
        rec["after_followup_server"] = {"c1": sg["nodes"]["c1"]["title"], "c3": sg["nodes"]["c3"]["title"], "c4": sg["nodes"]["c4"]["title"]}
        rec["import_survived_followup_save"] = sg["nodes"]["c4"]["title"] == "IMPORTED-c4"
        rec["B_edit_on_server_after_followup"] = sg["nodes"]["c3"]["title"] == "B-c3-%d" % rec["i"]
        if not rec["import_survived_followup_save"]:
            rec["verdict_extra"] = "IMPORT_OVERWRITTEN"
    await finish(rec, [a, b], t0)
    if rec.get("verdict_extra"):
        rec["verdict"].append(rec["verdict_extra"])
    for t in (a, b):
        await t.close()


@scenario("S9", "A restores/imports a draft (workflow_update broadcast) while B has an edit still inside its 5 s debounce window")
async def s9(env, rec):
    await s9_core(env, rec)




@scenario("S9X", "S9, then A (leader) makes one unrelated edit: does its autosave overwrite the imported draft?")
async def s9x(env, rec):
    await s9_core(env, rec, followup=True)


@scenario("S9Y", "DSL import / restore broadcast with NO concurrent edit; 6 s later B makes two unrelated edits (8 s apart): is the import reverted?")
async def s9y(env, rec):
    import socketio
    app = rec["app"] = env.new_app("S9Y")
    a = await env.open_tab("A", "alice", app)
    b = await env.open_tab("B", "bob", app)
    t0 = now()
    edits = []
    x = Client("alice")
    d = x.get_draft(app)
    g = json.loads(json.dumps(d["graph"]))
    for n in g["nodes"]:
        if n["id"] == "c4":
            n["data"]["title"] = "IMPORTED-c4"
    x.save_draft(app, g, hash=d["hash"], collaborative=False)
    sio = socketio.AsyncClient()
    ck = "; ".join(f'{c["name"]}={c["value"]}' for c in x.cookies())
    await sio.connect("http://localhost", socketio_path="/socket.io", transports=["websocket"], headers={"Cookie": ck})
    await sio.call("user_connect", {"workflow_id": app})
    await sio.call("collaboration_event", {"type": "workflow_update", "data": {"appId": app, "timestamp": int(now() * 1000)}, "timestamp": int(now() * 1000)})
    await asyncio.sleep(6)
    await sio.disconnect()
    rec["canvas_after_import"] = {t.name: (await t.canvas())["nodes"]["c4"]["title"] for t in (a, b)}
    edits.append({"by": "IMPORT", "node": "c4", "field": "title", "value": "IMPORTED-c4", "acked": True, "t": now()})
    await do_edit(b, "title", "c1", "B-c1-%d" % rec["i"], edits)
    await asyncio.sleep(9)
    sg1 = server_graph(app)
    rec["after_B_first_edit"] = {"import_on_server": sg1["nodes"]["c4"]["title"] == "IMPORTED-c4", "B_edit_on_server": sg1["nodes"]["c1"]["title"] == "B-c1-%d" % rec["i"],
                                 "A_canvas_c4": (await a.canvas())["nodes"]["c4"]["title"]}
    await b.close_panel()
    await do_edit(b, "title", "c2", "B-c2-%d" % rec["i"], edits)      # B just keeps working
    await observe(app, [a, b], edits, rec)
    await finish(rec, [a, b], t0)
    rec["import_survived"] = rec["server_final"]["titles"]["c4"] == "IMPORTED-c4"
    if not rec["import_survived"]:
        rec["verdict"].append("IMPORT_OVERWRITTEN")
    for t in (a, b):
        await t.close()


async def s9z_core(env, rec, how):
    import socketio
    app = rec["app"] = env.new_app("S9Z" + how)
    a = await env.open_tab("A", "alice", app)
    t0 = now()
    x = Client("alice")
    d = x.get_draft(app)
    g = json.loads(json.dumps(d["graph"]))
    for n in g["nodes"]:
        if n["id"] == "c4":
            n["data"]["title"] = "IMPORTED-c4"
    x.save_draft(app, g, hash=d["hash"], collaborative=False)
    sio = socketio.AsyncClient()
    ck = "; ".join(f'{c["name"]}={c["value"]}' for c in x.cookies())
    await sio.connect("http://localhost", socketio_path="/socket.io", transports=["websocket"], headers={"Cookie": ck})
    await sio.call("user_connect", {"workflow_id": app})
    await sio.call("collaboration_event", {"type": "workflow_update", "data": {"appId": app, "timestamp": int(now() * 1000)}, "timestamp": int(now() * 1000)})
    await asyncio.sleep(5)
    await sio.disconnect()
    rec["canvas_after_import"] = (await a.canvas())["nodes"]["c4"]["title"]
    rec["server_after_import"] = server_graph(app)["nodes"]["c4"]["title"]
    if how == "close":
        await a.close()
    elif how == "reload":
        await a.page.reload()
    elif how == "hide_show":
        await a.hide(); await asyncio.sleep(2); await a.show(); await asyncio.sleep(2)
    await asyncio.sleep(6)
    rec["server_final_c4"] = server_graph(app)["nodes"]["c4"]["title"]
    if how == "hide_show":
        rec["canvas_after_show"] = (await a.canvas())["nodes"]["c4"]["title"]
    rec["import_survived"] = rec["server_final_c4"] == "IMPORTED-c4" and rec.get("canvas_after_show", "IMPORTED-c4") == "IMPORTED-c4"
    rec["edits"], rec["divergence"], rec["saves"], rec["console_errors"] = [], [], save_summary([a]), {}
    rec["verdict"] = ["OK"] if rec["import_survived"] else ["IMPORT_OVERWRITTEN"]
    if how != "close":
        await a.close()


@scenario("S9ZA", "SINGLE user in collab mode: draft replaced by import/restore (workflow_update), then tab closed normally")
async def s9za(env, rec):
    await s9z_core(env, rec, "close")


@scenario("S9ZB", "SINGLE user in collab mode: draft replaced by import/restore, then page reload")
async def s9zb(env, rec):
    await s9z_core(env, rec, "reload")


@scenario("S9ZC", "SINGLE user in collab mode: draft replaced by import/restore, tab hidden then shown again")
async def s9zc(env, rec):
    await s9z_core(env, rec, "hide_show")


# ---------------------------------------------------------------------------------------------
# S7: delete vs edit / reference
# ---------------------------------------------------------------------------------------------
@scenario("S7A", "A deletes c2 while B concurrently renames c2 and drags c3")
async def s7a(env, rec, lat=0):
    app = rec["app"] = env.new_app("S7A")
    a = await env.open_tab("A", "alice", app, up_ms=lat, down_ms=lat)
    b = await env.open_tab("B", "bob", app, up_ms=lat, down_ms=lat)
    t0 = now()
    edits = []

    async def ua():
        await a.delete_node("c2")

    async def ub():
        await do_edit(b, "title", "c2", "B-c2-%d" % rec["i"], edits)
        await do_edit(b, "title", "c3", "B-c3-%d" % rec["i"], edits)

    await asyncio.gather(ua(), ub())
    await observe(app, [a, b], edits, rec)
    sg = server_graph(app)
    d = sg["raw"]["graph"]
    ids = {n["id"] for n in d["nodes"]}
    rec["dangling_edges"] = [e["id"] for e in d["edges"] if e["source"] not in ids or e["target"] not in ids]
    rec["c2_deleted_on_server"] = "c2" not in ids
    # reference check: node c3 input variable selector still pointing at the deleted node?
    refs = []
    for n in d["nodes"]:
        for v in (n["data"].get("variables") or []):
            sel = v.get("value_selector") if isinstance(v, dict) else None
            if sel and sel[0] not in ids and sel[0] not in ("sys", "env", "conversation"):
                refs.append(f'{n["id"]}.{v.get("variable")}->{sel}')
        for o in (n["data"].get("outputs") or []):
            if isinstance(o, dict):
                sel = o.get("value_selector")
                if sel and sel[0] not in ids and sel[0] not in ("sys", "env", "conversation"):
                    refs.append(f'{n["id"]}.out.{o.get("variable")}->{sel}')
    rec["dangling_refs"] = refs
    await finish(rec, [a, b], t0)
    if not rec["c2_deleted_on_server"]:
        rec["verdict"].append("DELETE_REVERTED")
    if rec["dangling_edges"] or rec["dangling_refs"]:
        rec["verdict"].append("BROKEN_REFERENCE")
    for t in (a, b):
        await t.close()


@scenario("S7AL", "S7A with 400 ms websocket latency")
async def s7al(env, rec):
    await s7a(env, rec, lat=400)


@scenario("S7B", "single user baseline: delete c2 (c3 references c2? no: end node references c4.result) -> check dangling refs of deleting c4")
async def s7b(env, rec):
    app = rec["app"] = env.new_app("S7B")
    a = await env.open_tab("A", "alice", app)
    t0 = now()
    edits = []
    await a.delete_node("c4")
    await asyncio.sleep(0.5)
    await observe(app, [a], edits, rec, settle=12)
    d = server_graph(app)["raw"]["graph"]
    ids = {n["id"] for n in d["nodes"]}
    rec["c4_deleted_on_server"] = "c4" not in ids
    rec["dangling_edges"] = [e["id"] for e in d["edges"] if e["source"] not in ids or e["target"] not in ids]
    refs = []
    for n in d["nodes"]:
        for o in (n["data"].get("outputs") or []):
            if isinstance(o, dict) and o.get("value_selector") and o["value_selector"][0] not in ids and o["value_selector"][0] not in ("sys", "env", "conversation"):
                refs.append(f'{n["id"]}.out.{o.get("variable")}->{o["value_selector"]}')
    rec["dangling_refs"] = refs
    await finish(rec, [a], t0)
    if refs:
        rec["verdict"].append("BROKEN_REFERENCE")
    await a.close()


# ---------------------------------------------------------------------------------------------
# driver
# ---------------------------------------------------------------------------------------------
async def worker(name, idxs, tag, q, results, headless=True):
    """each run gets its own fresh browser process; harness failures (browser crash / load timeout) are retried up to 2x
    and never counted as product behaviour"""
    while True:
        try:
            i = q.get_nowait()
        except asyncio.QueueEmpty:
            return
        for attempt in range(3):
            rec = {"scenario": name, "i": i, "tag": tag, "attempt": attempt, "started": time.strftime("%H:%M:%S")}
            try:
                async with Env(headless=headless) as env:
                    await asyncio.wait_for(SCEN[name](env, rec), timeout=420)
            except Exception as e:
                rec["error"] = f"{type(e).__name__}: {str(e)[:300]}"
                rec["trace"] = traceback.format_exc()[-800:]
                rec["verdict"] = ["HARNESS_ERROR"]
            if rec.get("verdict") != ["HARNESS_ERROR"]:
                break
            append_log(name + (("-" + tag) if tag else "") + ".harness_errors", rec)
        append_log(name + (("-" + tag) if tag else ""), rec)
        results.append(rec)
        print(f'[{name} #{i}] {rec.get("verdict")} lost={rec.get("lost_edits")} div={rec.get("divergence")} {rec.get("error","")[:100]}', flush=True)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario")
    ap.add_argument("--runs", type=int, default=20)
    ap.add_argument("--parallel", type=int, default=3)
    ap.add_argument("--tag", default="")
    args = ap.parse_args()
    names = list(SCEN) if args.scenario == "all" else args.scenario.split(",")
    for name in names:
        q = asyncio.Queue()
        for i in range(args.runs):
            q.put_nowait(i)
        results = []
        await asyncio.gather(*[worker(name, None, args.tag, q, results) for _ in range(args.parallel)])
        from collections import Counter
        c = Counter("+".join(r.get("verdict", ["?"])) for r in results)
        print(f"== {name}: {len(results)} runs: {dict(c)}", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
