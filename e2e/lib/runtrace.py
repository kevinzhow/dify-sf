"""Normalized run traces ("dify-sf-trace/1") and their comparison. Standard library only, Python >= 3.9.

One schema for three sources:
  * graphon 0.7.0 engine events (golden traces recorded with Dify's mock nodes, e2e/traces/record_graphon.py),
  * Dify's console SSE of a draft run (live reference),
  * dify-sf's draft run SSE (same wire format as Dify's).

A trace is {"schema", "case", "source", "edges": [[from, to], ...], "events": [...]}. Event vocabulary (Dify's SSE
names): workflow_started, node_started, text_chunk, node_retry, node_finished, iteration_started, iteration_next,
iteration_completed, loop_started, loop_next, loop_completed, workflow_paused, workflow_finished (+ snake_case of any
other engine event). Node events carry "exec" = "<node_id>#<n>" (n-th start of that node), never execution ids.

Normalization: ids, timestamps, durations, task/run/message/conversation ids and latency fields are dropped; any string
that is a UUID becomes "<uuid>"; numbers with an integral value become ints, other floats are rounded to 12 significant
digits (Python repr vs Swift); object keys are sorted when serialized; consecutive text chunks of one selector are
merged; empty final chunks are dropped; the timings of LLM usage objects (latency, time_to_first_token, ...) are
dropped wherever a "usage" object appears; execution metadata (tokens, price) is dropped unless keep_metadata.
"""
import json
import re

SCHEMA = "dify-sf-trace/1"
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
# sys.* inputs that differ per run, account or app on any server
VOLATILE_SYS = {"sys.workflow_run_id", "sys.user_id", "sys.app_id", "sys.workflow_id", "sys.conversation_id",
                "sys.timestamp", "sys.message_id", "sys.workflow_execution_id"}
VOLATILE_USAGE = {"latency", "time_to_first_token", "time_to_generate", "created_at", "elapsed_time"}


def norm_value(v, key=None):
    if isinstance(v, bool) or v is None:
        return v
    if isinstance(v, float):
        if v != v or v in (float("inf"), float("-inf")):
            return str(v)
        if v.is_integer():
            return int(v)
        return float(f"{v:.12g}")
    if isinstance(v, int):
        return v
    if isinstance(v, str):
        return "<uuid>" if UUID_RE.match(v) else v
    if isinstance(v, dict):
        out = {}
        for k, x in v.items():
            if k in VOLATILE_SYS:
                out[k] = "<volatile>"
            elif key == "usage" and k in VOLATILE_USAGE:  # LLM usage timings (outputs.usage, process_data.usage)
                continue
            else:
                out[k] = norm_value(x, k)
        return out
    if isinstance(v, (list, tuple)):
        return [norm_value(x, key) for x in v]
    return str(v)


def _clean_process_data(pd):
    if not isinstance(pd, dict):
        return pd
    pd = dict(pd)
    u = pd.get("usage")
    if isinstance(u, dict):
        pd["usage"] = {k: x for k, x in u.items() if k not in VOLATILE_USAGE}
    return pd


class Builder:
    """Accumulates normalized events; assigns exec labels and merges text chunks."""

    def __init__(self, case, source, edges=None, keep_metadata=False):
        self.trace = {"schema": SCHEMA, "case": case, "source": source, "edges": edges or [], "events": []}
        self.keep_metadata = keep_metadata
        self._starts = {}      # node_id -> count
        self._exec = {}        # raw execution id -> label
        self._last_label = {}  # node_id -> label of its latest start (fallback when no ids)

    def label_start(self, node_id, raw_id=None):
        n = self._starts.get(node_id, 0) + 1
        self._starts[node_id] = n
        label = f"{node_id}#{n}"
        if raw_id:
            self._exec[raw_id] = label
        self._last_label[node_id] = label
        return label

    def label_of(self, node_id, raw_id=None):
        if raw_id and raw_id in self._exec:
            return self._exec[raw_id]
        return self._last_label.get(node_id) or f"{node_id}#?"

    def add(self, ev):
        evs = self.trace["events"]
        if ev["event"] == "text_chunk":
            if ev.get("text", "") == "":
                return
            if evs and evs[-1]["event"] == "text_chunk" and evs[-1].get("selector") == ev.get("selector"):
                evs[-1]["text"] += ev["text"]
                return
        evs.append(ev)

    def node_finished(self, label, node_id, node_type, status, inputs, process_data, outputs, error, metadata=None,
                      container=None):
        ev = {"event": "node_finished", "exec": label, "node_id": node_id, "node_type": str(node_type),
              "status": status, "inputs": norm_value(inputs or {}),
              "process_data": norm_value(_clean_process_data(process_data or {})),
              "outputs": norm_value(outputs or {}), "error": error or None}
        if container:
            ev["in"] = container
        if self.keep_metadata and metadata:
            ev["metadata"] = norm_value(metadata)
        self.add(ev)

    def result(self):
        return self.trace


# ---------------------------------------------------------------- Dify / dify-sf SSE (console draft run)

def from_sse(case, source, events, edges=None, keep_metadata=False):
    """events: decoded JSON objects of the SSE stream ({"event": ..., "data": {...}})."""
    b = Builder(case, source, edges, keep_metadata)
    for e in events:
        name = e.get("event")
        d = e.get("data") or {}
        container = d.get("iteration_id") or d.get("loop_id")
        if name in (None, "ping"):
            continue
        if name == "workflow_started":
            b.add({"event": "workflow_started"})
        elif name == "node_started":
            label = b.label_start(d["node_id"], d.get("id"))
            ev = {"event": "node_started", "exec": label, "node_id": d["node_id"], "node_type": d.get("node_type")}
            if container:
                ev["in"] = container
            b.add(ev)
        elif name == "node_retry":
            b.add({"event": "node_retry", "node_id": d.get("node_id"), "retry_index": d.get("retry_index"),
                   "error": d.get("error")})
        elif name == "node_finished":
            label = b.label_of(d["node_id"], d.get("id"))
            b.node_finished(label, d["node_id"], d.get("node_type"), d.get("status"), d.get("inputs"),
                            d.get("process_data"), d.get("outputs"), d.get("error"), d.get("execution_metadata"),
                            container)
        elif name == "text_chunk":
            b.add({"event": "text_chunk", "selector": list(d.get("from_variable_selector") or []),
                   "text": d.get("text", "")})
        elif name == "message":  # chatflow answer chunks
            b.add({"event": "text_chunk", "selector": list(e.get("from_variable_selector") or d.get("from_variable_selector") or []),
                   "text": e.get("answer", d.get("answer", ""))})
        elif name in ("iteration_started", "loop_started"):
            b.add({"event": name, "node_id": d.get("node_id"), "inputs": norm_value(d.get("inputs") or {})})
        elif name in ("iteration_next", "loop_next"):
            b.add({"event": name, "node_id": d.get("node_id"), "index": d.get("index")})
        elif name in ("iteration_completed", "loop_completed"):
            b.add({"event": name, "node_id": d.get("node_id"), "status": d.get("status"),
                   "outputs": norm_value(d.get("outputs") or {}), "error": d.get("error") or None,
                   "steps": d.get("steps")})
        elif name in ("workflow_finished", "workflow_paused"):
            b.add({"event": name, "status": d.get("status"), "outputs": norm_value(d.get("outputs") or {}),
                   "error": d.get("error") or None, "exceptions_count": d.get("exceptions_count") or 0})
        elif name in ("message_end", "message_replace", "tts_message", "tts_message_end", "agent_log"):
            continue
        elif name == "error":
            b.add({"event": "error", "status": e.get("status"), "code": e.get("code"), "message": e.get("message")})
        else:
            b.add({"event": name})
    return b.result()


# ---------------------------------------------------------------- comparison

def _executions(trace):
    ex, order = {}, []
    for i, ev in enumerate(trace["events"]):
        if ev["event"] == "node_started":
            e = ex.setdefault(ev["exec"], {"node_id": ev["node_id"], "node_type": ev.get("node_type")})
            e["start"] = i
            if ev.get("in"):
                e["in"] = ev["in"]
            order.append(ev["exec"])
        elif ev["event"] == "node_finished":
            e = ex.setdefault(ev["exec"], {"node_id": ev["node_id"], "node_type": ev.get("node_type")})
            e["end"] = i
            for k in ("status", "inputs", "process_data", "outputs", "error"):
                e[k] = ev.get(k)
    return ex, order


def _streams(trace):
    per, total = {}, []
    for ev in trace["events"]:
        if ev["event"] == "text_chunk":
            key = "/".join(ev.get("selector") or []) or "-"
            per[key] = per.get(key, "") + ev["text"]
            total.append(ev["text"])
    return per, "".join(total)


CONTAINER_EVENTS = ("iteration_started", "iteration_next", "iteration_completed", "loop_started", "loop_next", "loop_completed")


def _containers(trace):
    """Per container node: its iteration / loop events in order (without node_id)."""
    out = {}
    for ev in trace["events"]:
        if ev["event"] in CONTAINER_EVENTS:
            out.setdefault(ev.get("node_id"), []).append({k: v for k, v in ev.items() if k != "node_id"})
    return out


def _final(trace):
    for ev in reversed(trace["events"]):
        if ev["event"] in ("workflow_finished", "workflow_paused"):
            return {k: ev.get(k) for k in ("event", "status", "outputs", "error", "exceptions_count")}
    return None


def _ancestors(edges):
    succ = {}
    for a, b in edges:
        succ.setdefault(a, set()).add(b)
    reach = {}
    for n in list(succ):
        seen, stack = set(), list(succ.get(n, ()))
        while stack:
            x = stack.pop()
            if x not in seen:
                seen.add(x)
                stack.extend(succ.get(x, ()))
        reach[n] = seen
    return reach


def deep_diff(a, b, path, out, ignore=()):
    if path in ignore:
        return
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            p = f"{path}.{k}"
            if p in ignore:
                continue
            if k not in a:
                out.append({"path": p, "a": "<absent>", "b": b[k]})
            elif k not in b:
                out.append({"path": p, "a": a[k], "b": "<absent>"})
            else:
                deep_diff(a[k], b[k], p, out, ignore)
    elif isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        for i, (x, y) in enumerate(zip(a, b)):
            deep_diff(x, y, f"{path}[{i}]", out, ignore)
    elif a != b:
        out.append({"path": path, "a": a, "b": b})


def _unordered(ex, containers):
    """Executions inside `containers` (parallel iterations: rounds start in any order) as sorted lists per node."""
    out = {}
    for lab, e in ex.items():
        if e.get("in") in containers:
            fields = {k: e.get(k) for k in ("node_type", "status", "inputs", "process_data", "outputs", "error")}
            out.setdefault(e["node_id"], []).append(fields)
    return {n: sorted(v, key=lambda f: json.dumps(f, sort_keys=True)) for n, v in out.items()}


def compare(a, b, ignore=(), unordered=()):
    """Compares two traces by per-branch partial order. Returns a list of differences
    ({"path", "a", "b"} or {"path", "note"}); empty = equivalent.

    * run result (status, outputs, error) must be equal;
    * the same node executions (labels) must exist, with equal status, inputs, process_data, outputs and error;
    * each container node's iteration / loop events (started, next, completed) must be equal, in order;
    * each text stream (per selector) and the whole streamed answer must be equal;
    * order: for executions X, Y where X's node is a graph ancestor of Y's node, "X finished before Y started" must
      agree; the total order of unrelated (parallel) executions is not compared.
    `ignore` holds paths to skip, e.g. "exec[llm#1].process_data". `unordered` holds container node ids whose inner
    executions are compared per node as multisets (parallel iterations), without labels and order.
    """
    diffs = []
    deep_diff(_final(a), _final(b), "run", diffs, ignore)
    # Request validation errors happen before workflow_started and have no final run result.
    # Comparing only executions/results would incorrectly accept two different rejected requests as equivalent.
    deep_diff([e for e in a["events"] if e["event"] == "error"],
              [e for e in b["events"] if e["event"] == "error"], "errors", diffs, ignore)
    ea, oa = _executions(a)
    eb, ob = _executions(b)
    if unordered:
        deep_diff(_unordered(ea, unordered), _unordered(eb, unordered), "unordered", diffs, ignore)
        ea = {k: v for k, v in ea.items() if v.get("in") not in unordered}
        eb = {k: v for k, v in eb.items() if v.get("in") not in unordered}
        oa = [x for x in oa if x in ea]
    deep_diff(_containers(a), _containers(b), "container", diffs, ignore)
    for lab in sorted(set(ea) | set(eb)):
        if lab not in ea:
            diffs.append({"path": f"exec[{lab}]", "a": "<not executed>", "b": eb[lab].get("status")})
        elif lab not in eb:
            diffs.append({"path": f"exec[{lab}]", "a": ea[lab].get("status"), "b": "<not executed>"})
        else:
            for k in ("node_type", "status", "inputs", "process_data", "outputs", "error"):
                deep_diff(ea[lab].get(k), eb[lab].get(k), f"exec[{lab}].{k}", diffs, ignore)
    sa, ta = _streams(a)
    sb, tb = _streams(b)
    deep_diff(sa, sb, "stream", diffs, ignore)
    if ta != tb and "stream.*" not in ignore:
        diffs.append({"path": "stream.*", "a": ta, "b": tb})
    reach = _ancestors(a.get("edges") or b.get("edges") or [])
    common = [x for x in oa if x in eb]
    for x in common:
        for y in common:
            if x == y:
                continue
            nx, ny = ea[x]["node_id"], ea[y]["node_id"]
            if ny not in reach.get(nx, ()):
                continue
            before_a = ea[x].get("end", 1 << 30) < ea[y].get("start", -1)
            before_b = eb[x].get("end", 1 << 30) < eb[y].get("start", -1)
            if before_a != before_b:
                diffs.append({"path": f"order[{x} -> {y}]", "a": before_a, "b": before_b})
    return diffs


def dumps(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, indent=1)


def format_diffs(diffs, a_name="a", b_name="b", limit=40):
    lines = []
    for d in diffs[:limit]:
        if "note" in d:
            lines.append(f"  {d['path']}: {d['note']}")
        else:
            av = json.dumps(d["a"], ensure_ascii=False, sort_keys=True)
            bv = json.dumps(d["b"], ensure_ascii=False, sort_keys=True)
            lines.append(f"  {d['path']}:\n    {a_name}: {av[:300]}\n    {b_name}: {bv[:300]}")
    if len(diffs) > limit:
        lines.append(f"  ... {len(diffs) - limit} more")
    return "\n".join(lines)
