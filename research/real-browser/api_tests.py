#!/usr/bin/env python
"""Direct HTTP tests of the draft-save API (no browser). Isolates server-side concurrency semantics.
usage: .venv/bin/python api_tests.py [--runs N]   -> prints a table, appends JSON lines to logs/api_tests.jsonl
"""
import argparse, copy, json, os, sys, uuid
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from difyapi import Client
from graphs import base_graph

LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "api_tests.jsonl")


def log(rec):
    with open(LOG, "a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def titles(draft):
    return {n["id"]: n["data"]["title"] for n in draft["graph"]["nodes"]}


def new_app(c, tag):
    app = c.create_app(f"api-{tag}-{uuid.uuid4().hex[:6]}")
    c.save_draft(app, base_graph(4), collaborative=False)
    return app


def A1_stale_hash_rejected(a, b, i):
    """X and Y both hold h0. X saves (ok). Y saves with h0 -> must be rejected (server-side optimistic lock works)."""
    app = new_app(a, "A1")
    d0 = a.get_draft(app); h0 = d0["hash"]
    gx = copy.deepcopy(d0["graph"]); gx["nodes"][1]["data"]["title"] = "X-edit"
    gy = copy.deepcopy(d0["graph"]); gy["nodes"][2]["data"]["title"] = "Y-edit"
    rx = a.save_draft(app, gx, hash=h0, collaborative=False)
    ry = b.save_draft(app, gy, hash=h0, collaborative=False, raw=True)
    final = titles(a.get_draft(app))
    return {"X_ok": rx.get("result") == "success", "Y_status": ry.status_code, "Y_code": ry.json().get("code"),
            "final_has_X": final["c1"] == "X-edit", "final_has_Y": final["c2"] == "Y-edit",
            "verdict": "OK (stale write rejected)" if ry.status_code != 200 and final["c1"] == "X-edit" else "BAD"}


def A2_hash_adoption_overwrites(a, b, i):
    """Replays what the web client does after draft_workflow_not_sync: use-nodes-sync-draft.ts:198 ->
    handleRefreshWorkflowDraft(true) = fetch draft, adopt ONLY the new hash, keep the local (stale) canvas.
    The next autosave posts the stale canvas with the fresh hash -> server accepts -> X's edit is silently overwritten."""
    app = new_app(a, "A2")
    d0 = a.get_draft(app); h0 = d0["hash"]
    gx = copy.deepcopy(d0["graph"]); gx["nodes"][1]["data"]["title"] = "X-edit"
    a.save_draft(app, gx, hash=h0, collaborative=False)
    gy = copy.deepcopy(d0["graph"]); gy["nodes"][2]["data"]["title"] = "Y-edit"   # Y's canvas never received X's edit
    r1 = b.save_draft(app, gy, hash=h0, collaborative=False, raw=True)             # rejected
    fresh = b.get_draft(app)["hash"]                                               # hash-only refresh
    gy["nodes"][3]["data"]["title"] = "Y-edit-2"                                   # Y keeps typing -> next autosave
    r2 = b.save_draft(app, gy, hash=fresh, collaborative=False, raw=True)
    final = titles(a.get_draft(app))
    return {"first_save_status": r1.status_code, "second_save_status": r2.status_code,
            "X_edit_survived": final["c1"] == "X-edit", "final": final,
            "verdict": "STALE_OVERWRITE (X edit lost)" if final["c1"] != "X-edit" else "OK"}


def A3_features_lww(a, b, i):
    """features have no hash/etag: two clients post whole `features` objects, last writer wins, no conflict signal."""
    app = new_app(a, "A3")
    fx = {"features": {"sensitive_word_avoidance": {"enabled": True, "type": "keywords", "config": {"keywords": "x-bad-word", "inputs_config": {"enabled": True, "preset_response": "no"}}}}}
    fy = {"features": {"text_to_speech": {"enabled": True, "voice": "", "language": ""}}}
    rx = a.post(f"/apps/{app}/workflows/draft/features", json=fx)
    ry = b.post(f"/apps/{app}/workflows/draft/features", json=fy)
    feats = a.get_draft(app)["features"]
    return {"X_status": rx.status_code, "Y_status": ry.status_code, "final_features_keys": sorted(feats.keys()),
            "X_feature_survived": bool(feats.get("sensitive_word_avoidance", {}).get("enabled")), "Y_feature_present": bool(feats.get("text_to_speech", {}).get("enabled")),
            "verdict": "LOST_UPDATE (X features dropped silently, both got 200)" if not feats.get("sensitive_word_avoidance", {}).get("enabled") else "OK"}


def A4_noncollab_graph_save_clobbers_features(a, b, i):
    """Without _is_collaborative (collab mode off) a graph save also writes features+conversation_variables from the
    client cache. Y has an old features copy, X has since saved newer features; Y's next graph save (valid hash) reverts them."""
    app = new_app(a, "A4")
    d0 = a.get_draft(app)
    b_cached_features = copy.deepcopy(d0["features"])            # what Y's tab loaded
    a.post(f"/apps/{app}/workflows/draft/features", json={"features": {"sensitive_word_avoidance": {"enabled": True, "type": "keywords", "config": {"keywords": "x-bad-word", "inputs_config": {"enabled": True, "preset_response": "no"}}}}})
    d1 = a.get_draft(app)                                          # graph (hash) unchanged: features are not in the hash
    g = copy.deepcopy(d1["graph"]); g["nodes"][1]["data"]["title"] = "Y-edit"
    r = b.save_draft(app, g, features=b_cached_features, hash=d1["hash"], collaborative=False, raw=True)
    feats = a.get_draft(app)["features"]
    return {"Y_save_status": r.status_code, "features_after": feats,
            "verdict": "STALE_OVERWRITE (features reverted, hash did not protect)" if not feats.get("sensitive_word_avoidance", {}).get("enabled") else "OK"}


def A5_server_accepts_empty_or_dangling(a, b, i):
    """Server-side integrity: does the draft endpoint accept an empty graph / dangling edges / dangling variable refs?"""
    app = new_app(a, "A5")
    d = a.get_draft(app)
    # dangling edge + dangling variable selector (delete c2 node only, keep edges and c3's reference to c2.result)
    g = copy.deepcopy(d["graph"]); g["nodes"] = [n for n in g["nodes"] if n["id"] != "c2"]
    r1 = a.save_draft(app, g, hash=d["hash"], collaborative=True, raw=True)
    d1 = a.get_draft(app)
    ids = {n["id"] for n in d1["graph"]["nodes"]}
    dangling_edges = [e["id"] for e in d1["graph"]["edges"] if e["source"] not in ids or e["target"] not in ids]
    c3 = [n for n in d1["graph"]["nodes"] if n["id"] == "c3"][0]
    ref = c3["data"]["variables"][0]["value_selector"]
    # empty graph
    r2 = a.save_draft(app, {"nodes": [], "edges": [], "viewport": {"x": 0, "y": 0, "zoom": 1}}, hash=d1["hash"], collaborative=True, raw=True)
    d2 = a.get_draft(app)
    return {"dangling_save_status": r1.status_code, "dangling_edges_persisted": dangling_edges, "c3_ref_to_deleted_node": ref,
            "empty_graph_status": r2.status_code, "nodes_after_empty_save": len(d2["graph"]["nodes"]),
            "verdict": "SERVER_ACCEPTS_BROKEN_GRAPH" if r1.status_code == 200 and r2.status_code == 200 else "OK"}


TESTS = [A1_stale_hash_rejected, A2_hash_adoption_overwrites, A3_features_lww, A4_noncollab_graph_save_clobbers_features, A5_server_accepts_empty_or_dangling]

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--runs", type=int, default=20); args = ap.parse_args()
    a, b = Client("alice"), Client("bob")
    for t in TESTS:
        verdicts = {}
        for i in range(args.runs):
            r = t(a, b, i)
            r["test"] = t.__name__; r["i"] = i
            log(r)
            verdicts[r["verdict"]] = verdicts.get(r["verdict"], 0) + 1
        print(f"{t.__name__}: {args.runs} runs -> {verdicts}\n    doc: {t.__doc__.strip().splitlines()[0]}\n    sample: { {k:v for k,v in r.items() if k not in ('test','i')} }")
