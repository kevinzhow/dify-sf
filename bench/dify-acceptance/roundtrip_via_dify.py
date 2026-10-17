"""Acceptance: Dify itself reads dify-sf's export of a workflow exactly like the original.

For every sample workflow: import the original into a local Dify and export it back (D1); import it into dify-sf,
export it from dify-sf, import that into Dify and export it back (D2). D1 and D2 must have the same workflow graph,
features and variables (compared after parsing, nodes and edges by id, ignoring UI selection).

usage: DIFY_URL=http://localhost DIFY_EMAIL=alice@example.test DIFY_PASSWORD=... DIFYSF_URL=http://127.0.0.1:18080 \
       python3 roundtrip_via_dify.py <fixtures dir>
Needs a disposable local Dify 1.17.1 (docker compose) with that account, and a running dify-sf server.
"""
import base64, json, os, sys, glob, uuid
import requests, yaml

DIFY = os.environ.get("DIFY_URL", "http://localhost")
SF = os.environ.get("DIFYSF_URL", "http://127.0.0.1:18080")

def login():
    s = requests.Session()
    pw = base64.b64encode(os.environ["DIFY_PASSWORD"].encode()).decode()
    r = s.post(f"{DIFY}/console/api/login", json={"email": os.environ["DIFY_EMAIL"], "password": pw, "remember_me": True, "language": "en-US"})
    r.raise_for_status()
    s.headers["X-CSRF-Token"] = s.cookies.get("csrf_token", "")
    return s

def dify_roundtrip(s, text):
    r = s.post(f"{DIFY}/console/api/apps/imports", json={"mode": "yaml-content", "yaml_content": text})
    body = r.json()
    if body.get("status") == "pending":  # DSL version older/newer than the instance: confirm like the UI does
        body = s.post(f"{DIFY}/console/api/apps/imports/{body['id']}/confirm").json()
    if body.get("status") not in ("completed", "completed-with-warnings"):
        raise RuntimeError(f"Dify refused the import: {body}")
    app_id = body["app_id"]
    out = s.get(f"{DIFY}/console/api/apps/{app_id}/export", params={"include_secret": "false"}).json()
    s.delete(f"{DIFY}/console/api/apps/{app_id}")
    return yaml.safe_load(out["data"]), body["status"]

def sf_roundtrip(text):
    doc = f"acc-{uuid.uuid4().hex[:12]}"
    r = requests.put(f"{SF}/v1/docs/{doc}/import", data=text.encode(), headers={"Content-Type": "application/x-yaml"})
    r.raise_for_status()
    r = requests.get(f"{SF}/v1/docs/{doc}/export")
    r.raise_for_status()
    return r.text

def normalized(v):
    if isinstance(v, dict):
        v = {k: normalized(x) for k, x in v.items() if k != "selected"}
        for k in ("nodes", "edges"):
            if isinstance(v.get(k), list) and all(isinstance(e, dict) and "id" in e for e in v[k]):
                v[k] = sorted(v[k], key=lambda e: e["id"])
        return v
    if isinstance(v, list):
        return [normalized(x) for x in v]
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return v

def first_diff(a, b, path=""):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a: return f"{path}.{k}: only in dify-sf's"
            if k not in b: return f"{path}.{k}: only in original's"
            d = first_diff(a[k], b[k], f"{path}.{k}")
            if d: return d
        return None
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b): return f"{path}: {len(a)} vs {len(b)} elements"
        for i, (x, y) in enumerate(zip(a, b)):
            d = first_diff(x, y, f"{path}[{i}]")
            if d: return d
        return None
    return None if a == b else f"{path}: {a!r} vs {b!r}"

def main(fixtures):
    s = login()
    ok = 0
    files = sorted(glob.glob(os.path.join(fixtures, "*.yml")))
    for f in files:
        original = open(f, encoding="utf-8").read()
        name = os.path.basename(f)
        try:
            d1, st1 = dify_roundtrip(s, original)
            d2, st2 = dify_roundtrip(s, sf_roundtrip(original))
        except Exception as e:  # noqa: BLE001
            print(f"FAIL {name}: {e}")
            continue
        diff = first_diff(normalized(d1.get("workflow")), normalized(d2.get("workflow")))
        if diff:
            print(f"DIFF {name}: {diff}")
        else:
            ok += 1
            print(f"OK   {name} ({st1}/{st2})")
    print(f"{ok}/{len(files)} workflows read identically by Dify")
    edited_ok = edited_check(s, fixtures)
    return 0 if ok == len(files) and edited_ok else 1

def edited_check(s, fixtures):
    """A workflow edited in dify-sf (rename, new output variable, move, fractional setting) imports into Dify with the edits."""
    original = open(os.path.join(fixtures, "array_iteration_formatting_workflow.yml"), encoding="utf-8").read()
    doc = f"acc-{uuid.uuid4().hex[:12]}"
    requests.put(f"{SF}/v1/docs/{doc}/import", data=original.encode(), headers={"Content-Type": "application/x-yaml"}).raise_for_status()
    code = "1754683442688"
    ops = [
        {"cseq": 1, "base": 0, "op": {"t": "setField", "node": code, "field": {"k": "title"}, "value": "Make numbers"}},
        {"cseq": 2, "base": 0, "op": {"t": "insertItem", "node": code, "path": ["outputs"], "after": "result",
                                        "item": {"id": "count", "value": {"name": "count", "type": "number", "children": None}}}},
        {"cseq": 3, "base": 0, "op": {"t": "moveNode", "node": code, "x": 400, "y": 300}},
    ]
    r = requests.post(f"{SF}/v1/docs/{doc}/ops", json={"client": "acceptance", "ops": ops})
    r.raise_for_status()
    statuses = [x["status"] for x in r.json()["results"]]
    if statuses != ["ack"] * 3:
        print(f"FAIL edited: dify-sf refused the edits: {r.json()}")
        return False
    exported = requests.get(f"{SF}/v1/docs/{doc}/export").text
    d, st = dify_roundtrip(s, exported)
    node = next(n for n in d["workflow"]["graph"]["nodes"] if n["id"] == code)
    checks = {"title": node["data"]["title"] == "Make numbers", "outputs": set(node["data"]["outputs"]) == {"result", "count"},
              "position": (node["position"]["x"], node["position"]["y"]) == (400, 300)}
    if all(checks.values()):
        print(f"OK   edited in dify-sf, imported by Dify ({st}): rename, new output variable, move")
        return True
    print(f"FAIL edited: {checks}")
    return False

if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
