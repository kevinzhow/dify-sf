#!/usr/bin/env python
"""Sanity check that the websocket latency injection really delays collaboration traffic:
A renames c1; measure how long until B's canvas shows it (0 ms vs 400 ms each way)."""
import asyncio, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from harness import *

async def one(env, lat):
    app = env.new_app("lat")
    a = await env.open_tab("A", "alice", app, up_ms=lat, down_ms=lat)
    b = await env.open_tab("B", "bob", app, up_ms=lat, down_ms=lat)
    t0 = now()
    await a.rename("c1", "LAT-x")
    t_edit = now()
    while True:
        c = await b.canvas()
        if c["nodes"]["c1"]["title"] == "LAT-x":
            break
        await asyncio.sleep(0.05)
    dt = now() - t_edit
    await a.close(); await b.close()
    return dt

async def main():
    for lat in (0, 400):
        async with Env() as env:
            xs = [await one(env, lat) for _ in range(3)]
        print(f"one-way latency {lat} ms -> B sees A's edit after {[round(x,2) for x in xs]} s", flush=True)
asyncio.run(main())
