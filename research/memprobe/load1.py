import asyncio, sys, os, time
sys.path.insert(0, os.path.expanduser("research/repro"))
from lib.harness import Env, server_graph
async def main(n):
    async with Env() as env:
        app_id = env.new_app(f"load{n}", n_code=n)
        g = server_graph(app_id)
        print("server nodes", len(g.get("nodes", [])) if isinstance(g, dict) else type(g), flush=True)
        t0 = time.time()
        tab = await env.open_tab("t0", "alice", app_id, wait=False)
        for i in range(60):
            await asyncio.sleep(2)
            cnt = await tab.page.locator(".react-flow__node").count()
            if cnt > 0:
                print(f"first nodes after {time.time()-t0:.1f}s count={cnt}", flush=True); break
        await asyncio.sleep(5)
        cnt = await tab.page.locator(".react-flow__node").count()
        print(f"rendered nodes={cnt} at {time.time()-t0:.1f}s", flush=True)
        await tab.page.screenshot(path=f"load{n}.png")
asyncio.run(main(int(sys.argv[1])))
