"""Golden traces from Dify's own engine: graphon 0.7.0 as Dify 1.17.1 drives it, with Dify's mock nodes.

Runs INSIDE the langgenius/dify-api:1.17.1 image (its virtual environment pins graphon==0.7.0), started by
e2e/traces/record.sh with no network, a memory cap and read-only mounts:
  /e2e                 this repository's e2e/ (read-only)
  /fixtures            Dify's 24 sample workflows (server/Tests/CollabTests/Fixtures/dify)
  /app/api/tests       Dify 1.17.1's api/tests (for its table runner and mock node factory)
  /out                 where the traces are written

For every case of e2e/traces/cases.json: Dify's WorkflowRunner builds the graph from the fixture with MockNodeFactory
(LLM, tool, HTTP, code, template, ... replaced by Dify's mocks; start/end/answer/if-else/aggregator/assigner/
iteration/loop/list-operator are the real graphon nodes), GraphEngine runs it with ONE worker (deterministic order),
events go through Dify's response stream filter (iter_dify_graph_engine_events, as Dify's runners do) and are written
as a normalized trace (e2e/lib/runtrace.py, schema dify-sf-trace/1) to /out/<case>.json. Each case runs --repeat times;
the run fails if the normalized traces differ between repeats.
"""
import argparse
import json
import os
import sys
import traceback

sys.path.insert(0, "/app/api")
sys.path.insert(0, "/e2e/lib")
os.environ.setdefault("OPENDAL_SCHEME", "fs")
os.environ.setdefault("OPENDAL_FS_ROOT", "/tmp/dify-storage")
os.environ.setdefault("STORAGE_TYPE", "opendal")

from unittest.mock import MagicMock, patch  # noqa: E402

import runtrace as tr  # noqa: E402  (e2e/lib/runtrace.py)

from flask import Flask  # noqa: E402

redis_mock = MagicMock()
redis_mock.get = MagicMock(return_value=None)
redis_mock.exists = MagicMock(return_value=False)
redis_mock.hgetall = MagicMock(return_value={})
redis_mock.incr = MagicMock(return_value=1)


def _patch_redis():
    from extensions import ext_redis
    patches = [patch.object(ext_redis, "redis_client", redis_mock), patch.object(ext_redis, "_pubsub_redis_client", redis_mock)]
    for p in patches:
        p.start()
    for module in list(sys.modules.values()):
        if module is None:
            continue
        for attr in ("redis_client", "_pubsub_redis_client"):
            if hasattr(module, attr):
                try:
                    setattr(module, attr, redis_mock)
                except Exception:
                    pass


def _str(v):
    return getattr(v, "value", v) if v is not None else None


def _dump(v):
    """JSON-able form of pydantic models / segments / enums."""
    if hasattr(v, "to_object"):  # graphon Segment / Variable: its plain value, as Dify's API shows it
        return _dump(v.to_object())
    if hasattr(v, "model_dump"):
        return v.model_dump(mode="json")
    if isinstance(v, dict):
        return {str(_str(k)): _dump(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [_dump(x) for x in v]
    if hasattr(v, "value") and not isinstance(v, (str, int, float, bool)):
        return v.value
    return v


def normalize(case_name, events, edges):
    from graphon import graph_events as ge

    b = tr.Builder(case_name, "graphon-0.7.0+dify-1.17.1-mock", edges)
    for ev in events:
        container = getattr(ev, "in_iteration_id", None) or getattr(ev, "in_loop_id", None)
        if isinstance(ev, ge.GraphRunStartedEvent):
            b.add({"event": "workflow_started"})
        elif isinstance(ev, ge.NodeRunRetryEvent):
            b.add({"event": "node_retry", "node_id": ev.node_id, "retry_index": ev.retry_index, "error": ev.error})
        elif isinstance(ev, ge.NodeRunStartedEvent):
            label = b.label_start(ev.node_id, ev.id)
            e = {"event": "node_started", "exec": label, "node_id": ev.node_id, "node_type": str(_str(ev.node_type))}
            if container:
                e["in"] = container
            b.add(e)
        elif isinstance(ev, ge.NodeRunStreamChunkEvent):
            b.add({"event": "text_chunk", "selector": list(ev.selector), "text": ev.chunk})
        elif isinstance(ev, (ge.NodeRunSucceededEvent, ge.NodeRunFailedEvent, ge.NodeRunExceptionEvent)):
            r = ev.node_run_result
            status = {ge.NodeRunSucceededEvent: "succeeded", ge.NodeRunFailedEvent: "failed",
                      ge.NodeRunExceptionEvent: "exception"}[type(ev)]
            b.node_finished(b.label_of(ev.node_id, ev.id), ev.node_id, _str(ev.node_type), status, _dump(r.inputs),
                            _dump(r.process_data), _dump(r.outputs), getattr(ev, "error", None) or r.error or None,
                            _dump(r.metadata), container)
        elif isinstance(ev, (ge.NodeRunIterationStartedEvent, ge.NodeRunLoopStartedEvent)):
            kind = "iteration" if isinstance(ev, ge.NodeRunIterationStartedEvent) else "loop"
            b.add({"event": f"{kind}_started", "node_id": ev.node_id, "inputs": tr.norm_value(_dump(ev.inputs))})
        elif isinstance(ev, (ge.NodeRunIterationNextEvent, ge.NodeRunLoopNextEvent)):
            kind = "iteration" if isinstance(ev, ge.NodeRunIterationNextEvent) else "loop"
            b.add({"event": f"{kind}_next", "node_id": ev.node_id, "index": ev.index})
        elif isinstance(ev, (ge.NodeRunIterationSucceededEvent, ge.NodeRunIterationFailedEvent,
                             ge.NodeRunLoopSucceededEvent, ge.NodeRunLoopFailedEvent)):
            kind = "iteration" if "Iteration" in type(ev).__name__ else "loop"
            failed = "Failed" in type(ev).__name__
            b.add({"event": f"{kind}_completed", "node_id": ev.node_id, "status": "failed" if failed else "succeeded",
                   "outputs": tr.norm_value(_dump(ev.outputs)), "error": getattr(ev, "error", None), "steps": ev.steps})
        elif isinstance(ev, (ge.GraphEdgeTakenEvent, ge.GraphEdgeSkippedEvent)):
            b.add({"event": "edge_taken" if isinstance(ev, ge.GraphEdgeTakenEvent) else "edge_skipped",
                   "edge": [ev.source_node_id, ev.source_handle or "source", ev.target_node_id]})
        elif isinstance(ev, ge.NodeRunVariableUpdatedEvent):
            b.add({"event": "variable_updated", "node_id": ev.node_id,
                   "selector": list(getattr(ev.variable, "selector", []) or []),
                   "value": tr.norm_value(_dump(getattr(ev.variable, "value", None)))})
        elif isinstance(ev, ge.GraphRunSucceededEvent):
            b.add({"event": "workflow_finished", "status": "succeeded", "outputs": tr.norm_value(_dump(ev.outputs)),
                   "error": None, "exceptions_count": 0})
        elif isinstance(ev, ge.GraphRunPartialSucceededEvent):
            b.add({"event": "workflow_finished", "status": "partial-succeeded",
                   "outputs": tr.norm_value(_dump(ev.outputs)), "error": None,
                   "exceptions_count": ev.exceptions_count})
        elif isinstance(ev, ge.GraphRunFailedEvent):
            b.add({"event": "workflow_finished", "status": "failed", "outputs": {}, "error": ev.error,
                   "exceptions_count": ev.exceptions_count})
        elif isinstance(ev, ge.GraphRunAbortedEvent):
            b.add({"event": "workflow_finished", "status": "stopped", "outputs": tr.norm_value(_dump(ev.outputs)),
                   "error": ev.reason, "exceptions_count": 0})
        elif isinstance(ev, ge.GraphRunPausedEvent):
            b.add({"event": "workflow_paused", "status": "paused", "outputs": tr.norm_value(_dump(ev.outputs)),
                   "error": None, "exceptions_count": 0})
        else:
            name = type(ev).__name__
            b.add({"event": "engine:" + name, "node_id": getattr(ev, "node_id", None)})
    return b.result()


def run_case(runner, case):
    from core.workflow.workflow_entry import iter_dify_graph_engine_events
    from graphon.graph_engine import GraphEngine, GraphEngineConfig
    from graphon.graph_engine.command_channels import InMemoryChannel
    from tests.unit_tests.core.workflow.graph_engine.test_mock_config import MockConfigBuilder

    fixture = runner.load_fixture(case["fixture"])
    builder = MockConfigBuilder()
    for node_id, outputs in (case.get("mock") or {}).items():
        builder.with_node_output(node_id, outputs)
    graph, state = runner.create_graph_from_fixture(fixture_data=fixture, query=case.get("query", ""),
                                                    inputs=case.get("inputs") or {}, use_mock_factory=True,
                                                    mock_config=builder.build())
    engine = GraphEngine(workflow_id="test_workflow", graph=graph, graph_runtime_state=state,
                         command_channel=InMemoryChannel(),
                         config=GraphEngineConfig(min_workers=1, max_workers=1))
    events, crash = [], None
    try:
        for ev in iter_dify_graph_engine_events(engine):
            events.append(ev)
    except Exception as e:  # graphon re-raises some node errors instead of ending with GraphRunFailedEvent
        crash = f"{type(e).__name__}: {e}"
    g = fixture["workflow"]["graph"]
    edges = [[e["source"], e["target"]] for e in g.get("edges", [])]
    t = normalize(case["name"], events, edges)
    if crash:
        t["events"].append({"event": "engine_raised", "error": crash})
    return t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", default="/e2e/traces/cases.json")
    ap.add_argument("--fixtures", default="/fixtures")
    ap.add_argument("--out", default="/out")
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--only", default="")
    args = ap.parse_args()

    from tests.unit_tests.core.workflow.graph_engine.test_table_runner import WorkflowRunner

    app = Flask("graphon-recorder")
    failures = 0
    with app.app_context():
        _patch_redis()
        runner = WorkflowRunner(fixtures_dir=__import__("pathlib").Path(args.fixtures))
        cases = json.load(open(args.cases))["cases"]
        for case in cases:
            if args.only and args.only not in case["name"]:
                continue
            try:
                traces = [run_case(runner, case) for _ in range(args.repeat)]
                stable = all(tr.dumps(t) == tr.dumps(traces[0]) for t in traces[1:])
                t = traces[0]
                final = next((e for e in reversed(t["events"]) if e["event"].startswith("workflow_") or e["event"] == "engine_raised"), {})
                t["meta"] = {"fixture": case["fixture"], "inputs": case.get("inputs") or {}, "query": case.get("query", ""),
                             "mock": case.get("mock") or {}, "engine": "graphon==0.7.0 (dify-api 1.17.1 image)",
                             "workers": 1, "repeats_identical": stable}
                with open(os.path.join(args.out, case["name"] + ".json"), "w") as f:
                    f.write(tr.dumps(t) + "\n")
                print(f"{case['name']}: {final.get('status') or final.get('event')} events={len(t['events'])} stable={stable}", flush=True)
                if not stable:
                    failures += 1
            except Exception:
                failures += 1
                print(f"{case['name']}: ERROR", flush=True)
                traceback.print_exc()
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
