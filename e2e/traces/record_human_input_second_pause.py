"""Record Dify 1.17.1's **second** human-input pause over its own HTTP API.

A workflow with two human nodes, answered in order: pause 1 -> answer -> pause 2 -> answer -> finish. The recording keeps
every frame (event, created_at, the pause's elapsed_time), the run detail and history (their created_at / elapsed_time),
and the node executions (`index`, so the numbering across the resume is visible).

Needs the local Dify ($DIFY_URL, $DIFY_EMAIL, $DIFY_PASSWORD). Prints one JSON document to stdout (or $OUT_FILE), and
writes the same under e2e/traces/human_input_second_pause/ when OUT_DIR is set.
"""
import base64
import json
import os
import pathlib
import re
import sys
import time

import requests

DIFY = os.environ.get("DIFY_URL", "http://localhost")
EMAIL = os.environ["DIFY_EMAIL"]
PASSWORD = os.environ["DIFY_PASSWORD"]
OUT_DIR = os.environ.get("OUT_DIR", "e2e/traces/human_input_second_pause")

YAML = """
app:
  mode: workflow
  name: hitl-second-pause
kind: app
version: 0.3.1
workflow:
  conversation_variables: []
  environment_variables: []
  features: {}
  graph:
    edges:
    - {id: e1, source: start, sourceHandle: source, target: h1, targetHandle: target}
    - {id: e2, source: h1, sourceHandle: approve, target: h2, targetHandle: target}
    - {id: e3, source: h2, sourceHandle: approve, target: end, targetHandle: target}
    nodes:
    - id: start
      data:
        title: Start
        type: start
        variables: []
    - id: h1
      data:
        title: First
        type: human-input
        form_content: 'First {{#$output.reply#}}?'
        inputs: [{type: paragraph, output_variable_name: reply}]
        user_actions: [{id: approve, title: Approve it, button_style: primary}]
        delivery_methods: [{type: webapp, enabled: true}]
    - id: h2
      data:
        title: Second
        type: human-input
        form_content: 'Second {{#$output.reply#}}?'
        inputs: [{type: paragraph, output_variable_name: reply}]
        user_actions: [{id: approve, title: Approve it, button_style: primary}]
        delivery_methods: [{type: webapp, enabled: true}]
    - id: end
      data:
        title: End
        type: end
        outputs: [{variable: reply, value_selector: [h2, reply]}]
"""


def login(session: requests.Session) -> dict:
    """Dify's console session is a cookie plus a CSRF token (no bearer token)."""
    res = session.post(f"{DIFY}/console/api/login", json={
        "email": EMAIL,
        "password": base64.b64encode(PASSWORD.encode()).decode(),
        "remember_me": True,
        "language": "en-US",
    })
    res.raise_for_status()
    return {"X-CSRF-Token": session.cookies.get("csrf_token") or ""}


def sse(lines):
    """The `data: ` payloads of an SSE response, each with the wall time it arrived."""
    for raw in lines:
        line = raw.decode() if isinstance(raw, bytes) else raw
        if not line.startswith("data: "):
            continue
        try:
            payload = json.loads(line[6:])
        except json.JSONDecodeError:
            continue
        yield time.time(), payload


def main() -> int:
    session = requests.Session()
    headers = login(session)

    imported = session.post(f"{DIFY}/console/api/apps/imports", headers=headers,
                            json={"mode": "yaml-content", "yaml_content": YAML})
    imported.raise_for_status()
    app = imported.json()["app_id"]

    run_id = None
    frames = []
    first_form = second_form = None
    second_pause = None
    answered_first = answered_second = None

    with session.post(f"{DIFY}/console/api/apps/{app}/workflows/draft/run", headers=headers,
                      json={"inputs": {}, "files": []}, stream=True) as run:
        run.raise_for_status()
        for at, frame in sse(run.iter_lines()):
            frames.append({"at": at, "event": frame.get("event"), "created_at": frame.get("data", {}).get("created_at"),
                           "elapsed_time": frame.get("data", {}).get("elapsed_time"),
                           "data": {k: frame.get("data", {}).get(k) for k in
                                    ("form_token", "node_id", "node_title", "status", "reasons", "paused_nodes")
                                    if k in frame.get("data", {})}})
            run_id = frame.get("workflow_run_id", run_id)
            if frame.get("event") == "human_input_required" and first_form is None:
                first_form = frame["data"]["form_token"]
            if frame.get("event") == "workflow_paused":
                break

    if not run_id or not first_form:
        print("no pause recorded", file=sys.stderr)
        return 1

    # Follow the run on its reconnect stream; answer each pause as it arrives.
    with session.get(f"{DIFY}/console/api/workflow/{run_id}/events", headers=headers,
                     params={"include_state_snapshot": "true", "continue_on_pause": "true"}, stream=True) as live:
        live.raise_for_status()
        pending_first = False
        for at, frame in sse(live.iter_lines()):
            frames.append({"at": at, "event": frame.get("event"), "created_at": frame.get("data", {}).get("created_at"),
                           "elapsed_time": frame.get("data", {}).get("elapsed_time"),
                           "data": {k: frame.get("data", {}).get(k) for k in
                                    ("form_token", "node_id", "node_title", "status", "reasons", "paused_nodes")
                                    if k in frame.get("data", {})}})
            event = frame.get("event")
            if event == "human_input_required":
                tok = frame["data"]["form_token"]
                if tok != first_form:
                    second_form = tok
                else:
                    pending_first = True
            if event == "workflow_paused":
                if answered_first is None:
                    answered_first = time.time()
                    session.post(f"{DIFY}/console/api/form/human_input/{first_form}", headers=headers,
                                 json={"inputs": {"reply": "one"}, "action": "approve"}).raise_for_status()
                    second_pause = {"at": at, "created_at": frame["data"].get("created_at"),
                                    "elapsed_time": frame["data"].get("elapsed_time"),
                                    "outputs": frame["data"].get("outputs"),
                                    "paused_nodes": frame["data"].get("paused_nodes")}
                elif second_form and answered_second is None:
                    answered_second = time.time()
                    session.post(f"{DIFY}/console/api/form/human_input/{second_form}", headers=headers,
                                 json={"inputs": {"reply": "two"}, "action": "approve"}).raise_for_status()
                    second_pause = {**(second_pause or {}), "second_pause_at": at,
                                    "second_pause_created_at": frame["data"].get("created_at"),
                                    "second_pause_elapsed_time": frame["data"].get("elapsed_time")}
            if event == "workflow_finished":
                break
        _ = pending_first

    detail = session.get(f"{DIFY}/console/api/apps/{app}/workflow-runs/{run_id}", headers=headers).json()
    history = session.get(f"{DIFY}/console/api/apps/{app}/workflow-runs", headers=headers,
                          params={"limit": 5}).json()
    executions = session.get(f"{DIFY}/console/api/apps/{app}/workflow-runs/{run_id}/node-executions",
                             headers=headers).json()

    def pick(item):
        return {k: item.get(k) for k in ("id", "status", "created_at", "finished_at", "elapsed_time", "total_steps")}

    report = {
        "app": app,
        "run": run_id,
        "frames": frames,
        "second_pause": second_pause,
        "detail": pick(detail),
        "history": [pick(h) for h in history.get("data", [])],
        "executions": [{"node_id": e.get("node_id"), "index": e.get("index"), "status": e.get("status"),
                        "created_at": e.get("created_at")} for e in executions.get("data", [])],
    }
    out = pathlib.Path(OUT_DIR)
    out.mkdir(parents=True, exist_ok=True)
    (out / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    (out / "workflow.yaml").write_text(YAML)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
