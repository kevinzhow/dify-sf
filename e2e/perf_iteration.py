"""A 100-round iteration with parallel 10 on dify-sf (stack P): wall time and the server container's memory.

The workflow: start -> code (the sandbox makes a list of ROUNDS numbers) -> iteration (parallel_nums PARALLEL; per item an
LLM node on the stub model, through the plugin daemon, then a code node in the sandbox) -> end. Runs it RUNS times
(default 3) through `POST /v1/apps/{app}/workflows/draft/run` and prints the client-side wall time, the server's
`elapsed_time`, the inner node executions and the server container's memory (docker stats) before, after each run and
after all.

  python3 -I e2e/perf_iteration.py [--runs N] [--rounds 100] [--parallel 10] [--difysf http://127.0.0.1:18080]
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
from perf_draft_run import mem  # noqa: E402


def rss(container):
    """Resident / peak resident process memory; docker stats also includes other cgroup allocations."""
    result = subprocess.run(["docker", "exec", container, "cat", "/proc/1/status"],
                            capture_output=True, text=True, check=True, timeout=10)
    values = {line.split(":", 1)[0]: line.split(":", 1)[1].strip()
              for line in result.stdout.splitlines() if line.startswith(("VmRSS:", "VmHWM:"))}
    return f"RSS={values.get('VmRSS', '?')} peak_RSS={values.get('VmHWM', '?')}"


def graph(rounds, parallel):
    inner = {"isInIteration": True, "isInLoop": False, "iteration_id": "it"}
    nodes = [
        {"id": "start", "data": {"type": "start", "title": "Start", "variables": []}},
        {"id": "list", "data": {"type": "code", "title": "List", "code_language": "python3", "variables": [],
                                "code": f"def main() -> dict:\n    return {{\"items\": list(range({rounds}))}}\n",
                                "outputs": {"items": {"type": "array[number]", "children": None}}}},
        {"id": "it", "data": {"type": "iteration", "title": "Each", "start_node_id": "itstart", "iterator_selector": ["list", "items"],
                              "output_selector": ["up", "result"], "is_parallel": True, "parallel_nums": parallel,
                              "error_handle_mode": "terminated", "flatten_output": True}},
        {"id": "itstart", "parentId": "it", "type": "custom-iteration-start",
         "data": {"type": "iteration-start", "title": "", "isInIteration": True}},
        {"id": "llm", "parentId": "it", "data": dict(inner, type="llm", title="Ask", model={
            "provider": STUB_PROVIDER, "name": STUB_MODEL, "mode": "chat", "completion_params": {}},
            prompt_template=[{"role": "user", "text": "item {{#it.item#}} of {{#it.index#}}"}],
            context={"enabled": False, "variable_selector": []}, vision={"enabled": False})},
        {"id": "up", "parentId": "it", "data": dict(inner, type="code", title="Upper", code_language="python3",
                                                     variables=[{"variable": "x", "value_selector": ["llm", "text"]}],
                                                     code="def main(x: str) -> dict:\n    return {\"result\": x.upper()}\n",
                                                     outputs={"result": {"type": "string", "children": None}})},
        {"id": "end", "data": {"type": "end", "title": "End", "outputs": [{"variable": "out", "value_selector": ["it", "output"]}]}},
    ]
    edges = [("start", "list"), ("list", "it"), ("itstart", "llm"), ("llm", "up"), ("it", "end")]
    for i, n in enumerate(nodes):
        n.setdefault("type", "custom")
        n["position"] = {"x": 300 * i, "y": 0}
    return {"nodes": nodes, "edges": [{"id": f"{s}-{t}", "source": s, "target": t, "sourceHandle": "source", "targetHandle": "target"}
                                      for s, t in edges]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--rounds", type=int, default=100)
    ap.add_argument("--parallel", type=int, default=10)
    ap.add_argument("--difysf", default="http://127.0.0.1:%s" % os.environ.get("DIFYSF_P_PORT", "18080"))
    ap.add_argument("--container", default="difysf-p-server-1")
    args = ap.parse_args()
    sf = DifySF(args.difysf, os.environ.get("DIFYSF_EMAIL", "e2e-owner@example.test"), os.environ.get("DIFYSF_PASSWORD", "E2e-throwaway-1"))
    dsl = {"version": "0.6.0", "kind": "app", "app": {"name": "e2e perf iteration", "mode": "workflow", "icon": "🤖",
                                                      "icon_background": "#FFEAD5", "description": ""},
           "workflow": {"graph": graph(args.rounds, args.parallel), "features": {}, "environment_variables": [],
                        "conversation_variables": []}}
    app = sf.import_dsl(dsl)
    print(f"perf-iteration: {args.rounds} rounds, parallel {args.parallel}; server memory before: {mem(args.container)} {rss(args.container)}")
    try:
        for i in range(args.runs):
            t0 = time.time()
            events = list(sf.run_draft(app, "workflow", {}))
            wall = time.time() - t0
            fin = next((e for e in reversed(events) if e.get("event") == "workflow_finished"), {})
            d = fin.get("data") or {}
            inner = sum(1 for e in events if e.get("event") == "node_finished" and (e.get("data") or {}).get("iteration_id") == "it")
            nexts = sum(1 for e in events if e.get("event") == "iteration_next")
            out = (d.get("outputs") or {}).get("out") or []
            print(f"perf-iteration: run {i + 1}: status={d.get('status')} rounds={nexts} inner_nodes={inner} outputs={len(out)} "
                  f"tokens={d.get('total_tokens')} wall={wall * 1000:.0f} ms server_elapsed={float(d.get('elapsed_time') or 0) * 1000:.0f} ms "
                  f"events={len(events)} error={d.get('error')!r} server_mem={mem(args.container)} {rss(args.container)}")
            if (d.get("status") != "succeeded" or nexts != args.rounds
                    or inner != args.rounds * 2 or len(out) != args.rounds):
                print(json.dumps([e for e in events if e.get("event") == "node_finished" and e["data"].get("status") != "succeeded"],
                                 ensure_ascii=False)[:2000])
                raise AssertionError("iteration benchmark did not finish every round and inner node")
    finally:
        sf.delete_app(app)
    print(f"perf-iteration: server memory after: {mem(args.container)} {rss(args.container)}")


if __name__ == "__main__":
    main()
