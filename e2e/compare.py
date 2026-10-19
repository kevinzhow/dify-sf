"""Live differential comparator: the same workflow, the same inputs, the same stub model, run on Dify (reference) and on
dify-sf; normalized traces compared by per-branch partial order (e2e/lib/runtrace.py).

For every live case of e2e/traces/cases.json:
  1. import the sample workflow into Dify, rewrite every model-using node (LLM, question classifier, parameter
     extractor) to the stub model `stub-chat` of langgenius/openai_api_compatible, save the draft;
  2. draft-run it on Dify (console SSE) with the case's inputs/query; record the SSE events and the requests llmstub
     received (the prompts the engine assembled);
  3. with --self: run it a second time on Dify and compare Dify with itself (shows the normalization is complete);
  4. with --difysf URL: import the same (rewritten) graph into dify-sf (POST /v1/apps/imports), draft-run it there
     (POST /v1/apps/{app}/workflows/draft/run, the same SSE) and compare dify vs dify-sf. Until dify-sf serves draft
     runs the case reports "dify-sf: draft run unavailable (HTTP 404)";
  5. cases with "single": [{"node", "inputs"}] also run those nodes alone (POST .../workflows/draft/nodes/{node}/run)
     on both sides and compare the node results.

Output: e2e/.out/compare/<case>.<side>.json (normalized traces, raw SSE in <case>.<side>.raw.jsonl) and
e2e/.out/compare/report.json; a text summary on stdout:
    PASS  <case>                      (every comparison empty)
    DIFF  <case>  dify~dify-sf  N differences, then one block per difference:
          exec[llm#1].outputs.text:
            dify:    "..."
            dify-sf: "..."
    REF   <case>                      (only Dify ran: nothing to compare, e.g. dify-sf has no draft run yet)
    SKIP  <case>  <reason>            (live: false in cases.json)
Exit code 0 = no differences in the comparisons that ran.

  python3 -I e2e/compare.py [--self] [--difysf http://127.0.0.1:18080] [--only <name part>] [--keep-apps]
  env: DIFYREF_URL, DIFYREF_EMAIL, DIFYREF_PASSWORD, LLMSTUB_URL (http://127.0.0.1:18000), DIFYSF_EMAIL, DIFYSF_PASSWORD
"""
import argparse
import copy
import json
import os
import sys
import time

E2E = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(E2E)
sys.path.insert(0, os.path.join(E2E, "lib"))
import runtrace as tr  # noqa: E402
from dify import STUB_MODEL, STUB_PROVIDER, DifyConsole  # noqa: E402
from e2ehttp import HTTPError, Session  # noqa: E402

FIXTURES = os.path.join(REPO, "server", "Tests", "CollabTests", "Fixtures", "dify")
MODEL_NODES = ("llm", "question-classifier", "parameter-extractor")
DIFYREF_URL = os.environ.get("DIFYREF_URL", "http://127.0.0.1:%s" % os.environ.get("DIFYREF_API_PORT", "15001"))
LLMSTUB_URL = os.environ.get("LLMSTUB_URL", "http://127.0.0.1:%s" % os.environ.get("LLMSTUB_PORT", "18000"))


def rewrite_models(graph):
    g = copy.deepcopy(graph)
    for n in g.get("nodes", []):
        d = n.get("data") or {}
        if d.get("type") in MODEL_NODES:
            old = d.get("model") or {}
            d["model"] = {"provider": STUB_PROVIDER, "name": STUB_MODEL, "mode": "chat",
                          "completion_params": old.get("completion_params") or {}}
    return g


def edges_of(graph):
    return [[e["source"], e["target"]] for e in graph.get("edges", [])]


class Stub:
    def __init__(self, url):
        self.s = Session(url, timeout=10)

    def reset(self):
        self.s.post("/stub/reset", {})

    def requests(self):
        out = []
        for r in self.s.get("/stub/log")["requests"]:
            body = {k: v for k, v in r["body"].items() if k != "user"}  # per-account id, differs by construction
            out.append({"path": r["path"], "body": tr.norm_value(body)})
        return sorted(out, key=lambda x: json.dumps(x, sort_keys=True))


class DifySF:
    """dify-sf's API for the same steps (protocol 1.10 import; draft run as Dify's console)."""

    def __init__(self, url, email, password):
        self.s = Session(url, timeout=120)
        st = self.s.get("/v1/setup")
        if st.get("step") != "finished":
            self.s.post("/v1/setup", {"email": email, "name": "E2E Owner", "password": password})
        r = self.s.post("/v1/auth/login", {"email": email, "password": password})
        tok = r.get("access_token") or (r.get("data") or {}).get("access_token")
        self.s.headers["Authorization"] = f"Bearer {tok}"

    def import_dsl(self, dsl):
        body = self.s.call("POST", "/v1/apps/imports", {"mode": "yaml-content", "yaml_content": json.dumps(dsl, ensure_ascii=False)},
                           ok=(200, 202))
        if body.get("status") == "pending":
            body = self.s.post(f"/v1/apps/imports/{body['id']}/confirm")
        return body["app_id"]

    def run_draft(self, app_id, mode, inputs, query=""):
        if mode == "advanced-chat":
            path, body = f"/v1/apps/{app_id}/advanced-chat/workflows/draft/run", {"inputs": inputs, "query": query, "files": []}
        else:
            path, body = f"/v1/apps/{app_id}/workflows/draft/run", {"inputs": inputs, "files": []}
        for line in self.s.stream("POST", path, body, timeout=300):
            try:
                yield json.loads(line)
            except ValueError:
                continue

    def run_node(self, app_id, node_id, inputs, query=""):
        return self.s.post(f"/v1/apps/{app_id}/workflows/draft/nodes/{node_id}/run", {"inputs": inputs, "query": query})

    def delete_app(self, app_id):
        try:
            self.s.delete(f"/v1/apps/{app_id}")
        except HTTPError:
            pass


def node_result_trace(case, source, r, edges):
    b = tr.Builder(case, source, edges)
    lab = b.label_start(r.get("node_id") or "?")
    b.node_finished(lab, r.get("node_id"), r.get("node_type"), r.get("status"), r.get("inputs"), r.get("process_data"),
                    r.get("outputs"), r.get("error"))
    return b.result()


def save(outdir, name, side, trace, raw=None):
    with open(os.path.join(outdir, f"{name}.{side}.json"), "w") as f:
        f.write(tr.dumps(trace) + "\n")
    if raw is not None:
        with open(os.path.join(outdir, f"{name}.{side}.raw.jsonl"), "w") as f:
            for e in raw:
                f.write(json.dumps(e, ensure_ascii=False) + "\n")


def compare_traces(a, b):
    diffs = tr.compare(a, b)
    ra, rb = a.get("llm_requests"), b.get("llm_requests")
    if ra is not None and rb is not None:
        tr.deep_diff(ra, rb, "llm_requests", diffs)
        if len(ra) != len(rb):
            diffs.append({"path": "llm_requests.count", "a": len(ra), "b": len(rb)})
    return diffs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", default=os.path.join(E2E, "traces", "cases.json"))
    ap.add_argument("--only", default="")
    ap.add_argument("--self", action="store_true", help="run each case twice on Dify and compare Dify with itself")
    ap.add_argument("--difysf", default="", help="dify-sf base URL; compare Dify with dify-sf")
    ap.add_argument("--out", default=os.path.join(os.environ.get("E2E_OUT", os.path.join(E2E, ".out")), "compare"))
    ap.add_argument("--keep-apps", action="store_true")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    dify = DifyConsole(DIFYREF_URL).login(os.environ.get("DIFYREF_EMAIL", "e2e-owner@example.test"),
                                         os.environ.get("DIFYREF_PASSWORD", "E2e-throwaway-1"))
    stub = Stub(LLMSTUB_URL)
    sf = None
    sf_error = None
    if args.difysf:
        try:
            sf = DifySF(args.difysf, os.environ.get("DIFYSF_EMAIL", "e2e-owner@example.test"),
                        os.environ.get("DIFYSF_PASSWORD", "E2e-throwaway-1"))
        except Exception as e:  # noqa: BLE001
            sf_error = f"dify-sf: cannot sign in ({e})"

    report, failures = [], 0
    cases = json.load(open(args.cases))["cases"]
    for case in cases:
        name = case["name"]
        if args.only and args.only not in name:
            continue
        if case.get("live") is False:
            print(f"SKIP  {name}  {case.get('_why_not_live', 'not live')}")
            report.append({"case": name, "result": "skip", "why": case.get("_why_not_live")})
            continue
        entry = {"case": name, "comparisons": {}}
        t0 = time.time()
        text = open(os.path.join(FIXTURES, case["fixture"]), encoding="utf-8").read()
        app_id = dify.import_yaml(text)
        sf_app = None
        try:
            draft = dify.draft(app_id)
            graph = rewrite_models(draft["graph"])
            dify.sync_draft(app_id, draft, graph)
            mode = dify.app(app_id)["mode"]
            edges = edges_of(graph)
            inputs, query = case.get("inputs") or {}, case.get("query", "")

            def dify_run(side):
                stub.reset()
                raw = list(dify.run_draft(app_id, mode, inputs, query))
                t = tr.from_sse(name, side, raw, edges)
                t["llm_requests"] = stub.requests()
                save(args.out, name, side, t, raw)
                return t

            ref = dify_run("dify")
            fin = next((e for e in reversed(ref["events"]) if e["event"] == "workflow_finished"), {})
            entry["dify_status"] = fin.get("status")
            if args.self:
                again = dify_run("dify2")
                entry["comparisons"]["dify~dify"] = compare_traces(ref, again)
            if sf_error:
                entry["comparisons"]["dify~dify-sf"] = sf_error
            elif sf:
                dsl = {"version": "0.6.0", "kind": "app",
                       "app": {"name": f"e2e {name}", "mode": mode, "icon": "🤖", "icon_background": "#FFEAD5",
                               "description": ""},
                       "workflow": {"graph": graph, "features": draft.get("features") or {},
                                    "environment_variables": [],
                                    "conversation_variables": draft.get("conversation_variables") or []}}
                try:
                    sf_app = sf.import_dsl(dsl)
                except HTTPError as e:
                    sf_app = None
                    entry["comparisons"]["dify~dify-sf"] = [{"path": "import", "note": f"dify-sf refused the import: HTTP {e.status} {e.body[:300]}"}]
                try:
                    if not sf_app:
                        raise LookupError
                    stub.reset()
                    raw = list(sf.run_draft(sf_app, mode, inputs, query))
                    t = tr.from_sse(name, "dify-sf", raw, edges)
                    t["llm_requests"] = stub.requests()
                    save(args.out, name, "difysf", t, raw)
                    entry["comparisons"]["dify~dify-sf"] = compare_traces(ref, t)
                except LookupError:
                    pass
                except HTTPError as e:
                    entry["comparisons"]["dify~dify-sf"] = f"dify-sf: draft run unavailable (HTTP {e.status})"
            for single in case.get("single") or []:
                node = single["node"]
                r = dify.run_node(app_id, node, single.get("inputs") or {}, single.get("query", ""))
                a = node_result_trace(name, "dify", r, edges)
                save(args.out, f"{name}.node-{node}", "dify", a, [r])
                if sf and sf_app and not sf_error:
                    try:
                        r2 = sf.run_node(sf_app, node, single.get("inputs") or {}, single.get("query", ""))
                        b = node_result_trace(name, "dify-sf", r2, edges)
                        save(args.out, f"{name}.node-{node}", "difysf", b, [r2])
                        entry["comparisons"][f"node {node}: dify~dify-sf"] = tr.compare(a, b)
                    except HTTPError as e:
                        entry["comparisons"][f"node {node}: dify~dify-sf"] = f"dify-sf: single-node run unavailable (HTTP {e.status})"
        except Exception as e:  # noqa: BLE001
            entry["error"] = f"{type(e).__name__}: {e}"
        finally:
            if not args.keep_apps:
                dify.delete_app(app_id)
                if sf and sf_app:
                    sf.delete_app(sf_app)
        entry["seconds"] = round(time.time() - t0, 1)
        bad = [k for k, v in entry["comparisons"].items() if isinstance(v, list) and v]
        if entry.get("error"):
            failures += 1
            print(f"ERROR {name}  {entry['error']}")
        elif bad:
            failures += 1
            for k in bad:
                print(f"DIFF  {name}  {k}  {len(entry['comparisons'][k])} differences")
                sides = k.split(": ")[-1].split("~")
                print(tr.format_diffs(entry["comparisons"][k], sides[0], sides[1]))
        else:
            notes = "; ".join(f"{k}: {v}" for k, v in entry["comparisons"].items() if isinstance(v, str))
            ran = [k for k, v in entry["comparisons"].items() if isinstance(v, list)]
            print(f"{'PASS' if ran else 'REF '}  {name}  dify={entry.get('dify_status')}  compared: {', '.join(ran) or '-'}"
                  + (f"  ({notes})" if notes else ""))
        entry["result"] = "error" if entry.get("error") else ("diff" if bad else ("pass" if any(
            isinstance(v, list) for v in entry["comparisons"].values()) else "reference-only"))
        report.append(entry)
    with open(os.path.join(args.out, "report.json"), "w") as f:
        f.write(json.dumps(report, ensure_ascii=False, indent=1, sort_keys=True) + "\n")
    print(f"{sum(1 for r in report if r['result'] == 'pass')} pass, "
          f"{sum(1 for r in report if r['result'] == 'reference-only')} reference only, {failures} diff/error, "
          f"{sum(1 for r in report if r['result'] == 'skip')} skipped -> {args.out}/report.json")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
