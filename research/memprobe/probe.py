"""Measure Chromium memory for N Dify workflow editor sessions on one 500-node graph."""
import asyncio, sys, time, subprocess, os
sys.path.insert(0, os.path.expanduser("research/repro"))
from lib.harness import Env

def children(pid):
    out = subprocess.run(["ps", "-o", "pid=", "--ppid", str(pid)], capture_output=True, text=True).stdout.split()
    res = []
    for c in out:
        res.append(int(c)); res += children(int(c))
    return res

def tree_mem(pid):
    rss = pss = 0
    for q in [pid] + children(pid):
        try:
            for line in open(f"/proc/{q}/smaps_rollup"):
                if line.startswith("Rss:"): rss += int(line.split()[1]) * 1024
                if line.startswith("Pss:"): pss += int(line.split()[1]) * 1024
        except Exception:
            pass
    return rss, pss

def cpu_ticks(pid):
    t = 0
    for q in [pid] + children(pid):
        try:
            f = open(f"/proc/{q}/stat").read().rsplit(")", 1)[1].split()
            t += int(f[11]) + int(f[12])
        except Exception:
            pass
    return t

async def main(counts):
    async with Env() as env:
        app_id = env.new_app("memprobe500", n_code=498)
        bpid = None
        for c in children(os.getpid()):
            try:
                if "chrom" in open(f"/proc/{c}/comm").read() or "headless" in open(f"/proc/{c}/comm").read():
                    bpid = c; break
            except Exception:
                pass
        if bpid is None:
            bpid = os.getpid()
        tabs = []
        users = ["alice"]
        for target in counts:
            while len(tabs) < target:
                t0 = time.time()
                tab = await env.open_tab(f"t{len(tabs)}", "alice", app_id, wait=False)
                for _ in range(90):
                    await asyncio.sleep(1)
                    if await tab.page.locator(".react-flow__node").count() >= 500:
                        break
                tabs.append(tab)
                print(f"opened tab {len(tabs)} in {time.time()-t0:.1f}s", flush=True)
            await asyncio.sleep(10)
            c0 = cpu_ticks(bpid); await asyncio.sleep(10); c1 = cpu_ticks(bpid)
            rss, pss = tree_mem(bpid)
            print(f"TABS={len(tabs)} rss={rss/2**20:.0f}MB pss={pss/2**20:.0f}MB per_tab_pss={pss/2**20/len(tabs):.0f}MB idle_cpu={(c1-c0)/100/10*100:.0f}%core", flush=True)

asyncio.run(main([int(x) for x in sys.argv[1:]] or [1, 5, 10]))
