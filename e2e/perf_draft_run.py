"""A 20-node draft run on dify-sf (stack P): wall time and the server container's memory.

The workflow: start -> if-else -> two parallel chains of 7 nodes (LLM, template, code, LLM, template, code, LLM) ->
variable aggregator -> LLM -> template -> end; LLM nodes use the stub model (llmstub through the plugin daemon), code and
templates the sandbox. Runs it RUNS times (default 5) through `POST /v1/apps/{app}/workflows/draft/run` and prints the
client-side wall time, the server's `elapsed_time`, and the server container's memory (docker stats) before and after.

  python3 -I e2e/perf_draft_run.py [--runs N] [--difysf http://127.0.0.1:18080] [--container difysf-p-server-1]
"""
import argparse
import json
import os
import subprocess
import sys
import time

E2E = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(E2E, "lib"))
sys.path.insert(0, E2E)
from compare import DifySF  # noqa: E402
from dify import STUB_MODEL, STUB_PROVIDER  # noqa: E402


def graph():
    llm = {"type": "llm", "title": "LLM", "model": {"provider": STUB_PROVIDER, "name": STUB_MODEL, "mode": "chat",
                                                   "completion_params": {}},
           "prompt_template": [{"role": "user", "text": "{{#start.q#}}"}], "context": {"enabled": False, "variable_selector": []},
           "vision": {"enabled": False}}
    code = {"type": "code", "title": "Code", "code_language": "python3", "variables": [{"variable": "x", "value_selector": ["start", "q"]}],
            "code": "def main(x: str) -> dict:\n    return {\"result\": x.upper()}\n", "outputs": {"result": {"type": "string", "children": None}}}
    tpl = {"type": "template-transform", "title": "Template", "template": "{{ x }}!",
           "variables": [{"variable": "x", "value_selector": ["start", "q"]}]}
    nodes = [{"id": "start", "data": {"type": "start", "title": "Start", "variables": [
        {"variable": "q", "label": "q", "type": "text-input", "required": True}]}},
        {"id": "if", "data": {"type": "if-else", "title": "If", "cases": [{"case_id": "true", "logical_operator": "and", "conditions": [
            {"variable_selector": ["start", "q"], "comparison_operator": "not empty", "value": ""}]}]}}]
    edges = [("start", "if", "source")]
    for side in "ab":
        prev, handle = "if", "true"
        for i, d in enumerate([llm, tpl, code, llm, tpl, code, llm]):
            nid = f"{side}{i}"
            nodes.append({"id": nid, "data": dict(d, title=f"{d['title']} {nid}")})
            edges.append((prev, nid, handle))
            prev, handle = nid, "source"
        edges.append((prev, "agg", "source"))
    nodes.append({"id": "agg", "data": {"type": "variable-aggregator", "title": "Agg", "output_type": "string",
                                        "variables": [["a6", "text"], ["b6", "text"]]}})
    nodes.append({"id": "final", "data": dict(llm, title="Final")})
    nodes.append({"id": "tpl", "data": {"type": "template-transform", "title": "Out", "template": "{{ x }}",
                                        "variables": [{"variable": "x", "value_selector": ["final", "text"]}]}})
    nodes.append({"id": "end", "data": {"type": "end", "title": "End", "outputs": [
        {"variable": "out", "value_selector": ["tpl", "output"]}]}})
    edges += [("agg", "final", "source"), ("final", "tpl", "source"), ("tpl", "end", "source")]
    for i, n in enumerate(nodes):
        n.update({"type": "custom", "position": {"x": 300 * i, "y": 0}})
    return {"nodes": nodes, "edges": [{"id": f"{s}-{t}", "source": s, "target": t, "sourceHandle": h, "targetHandle": "target"}
                                      for s, t, h in edges]}


def mem(container):
    try:
        out = subprocess.run(["docker", "stats", "--no-stream", "--format", "{{.MemUsage}}", container], capture_output=True,
                             text=True, timeout=30).stdout.strip()
        return out.split(" / ")[0]
    except Exception as e:  # noqa: BLE001
        return f"? ({e})"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--difysf", default="http://127.0.0.1:%s" % os.environ.get("DIFYSF_P_PORT", "18080"))
    ap.add_argument("--container", default="difysf-p-server-1")
    args = ap.parse_args()
    sf = DifySF(args.difysf, os.environ.get("DIFYSF_EMAIL", "e2e-owner@example.test"), os.environ.get("DIFYSF_PASSWORD", "E2e-throwaway-1"))
    g = graph()
    assert len(g["nodes"]) == 20, len(g["nodes"])
    dsl = {"version": "0.6.0", "kind": "app", "app": {"name": "e2e perf 20 nodes", "mode": "workflow", "icon": "🤖",
                                                      "icon_background": "#FFEAD5", "description": ""},
           "workflow": {"graph": g, "features": {}, "environment_variables": [], "conversation_variables": []}}
    app = sf.import_dsl(dsl)
    print(f"perf: server memory before: {mem(args.container)}")
    try:
        for i in range(args.runs):
            t0 = time.time()
            events = list(sf.run_draft(app, "workflow", {"q": f"perf run {i}"}))
            wall = time.time() - t0
            fin = next((e for e in reversed(events) if e.get("event") == "workflow_finished"), {})
            d = fin.get("data") or {}
            finished = sum(1 for e in events if e.get("event") == "node_finished")
            print(f"perf: run {i + 1}: status={d.get('status')} nodes={finished} steps={d.get('total_steps')} "
                  f"wall={wall * 1000:.0f} ms server_elapsed={float(d.get('elapsed_time') or 0) * 1000:.0f} ms "
                  f"events={len(events)} error={d.get('error')!r} server_mem={mem(args.container)}")
            if d.get("status") != "succeeded":
                print(json.dumps([e for e in events if e.get("event") == "node_finished" and e["data"].get("status") != "succeeded"],
                                 ensure_ascii=False)[:2000])
    finally:
        sf.delete_app(app)
    print(f"perf: server memory after: {mem(args.container)}")


if __name__ == "__main__":
    main()
