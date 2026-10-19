"""Single node run over HTTP against a running dify-sf server with a plugin daemon and the e2e stub LLM (protocol 1.13).

Used by server/run-runtime-e2e.sh (standard library only):  python3 -I runtime_e2e_http.py http://server:8080
Sets up the owner on a fresh database, a credential for the stub model (openai_api_compatible, endpoint
http://llmstub:8000/v1), imports a workflow with an LLM node, runs the node twice (the stub's fixed answer and its
deterministic default answer), and checks the answers, the last run, and that the document did not change.
"""
import json
import sys
import time
import urllib.error
import urllib.request

BASE = sys.argv[1].rstrip("/")
TOKEN = None

YAML = """app:
  mode: workflow
  name: runtime-e2e
kind: app
version: 0.3.1
workflow:
  conversation_variables: []
  environment_variables: []
  features: {}
  graph:
    edges:
    - id: start-llm
      source: start
      sourceHandle: source
      target: llm
      targetHandle: target
    nodes:
    - id: start
      data:
        title: Start
        type: start
        variables:
        - label: q
          required: true
          type: text-input
          variable: q
    - id: llm
      data:
        title: Ask
        type: llm
        model:
          provider: langgenius/openai_api_compatible/openai_api_compatible
          name: stub-chat
          mode: chat
          completion_params:
            temperature: 0
        prompt_template:
        - role: system
          text: You are terse.
        - role: user
          text: 'Q: {{#start.q#}}'
        context:
          enabled: false
          variable_selector: []
        vision:
          enabled: false
"""


def call(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if TOKEN:
        req.add_header("Authorization", "Bearer " + TOKEN)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


def need(cond, what):
    if not cond:
        print("FAIL:", what)
        sys.exit(1)


def main():
    global TOKEN
    for _ in range(120):
        try:
            # Ready when the schema is migrated (healthz only pings the database).
            if call("GET", "/healthz")[0] == 200 and call("GET", "/v1/setup")[0] == 200:
                break
        except OSError:
            pass
        time.sleep(1)
    st, r = call("POST", "/v1/setup", {"email": "owner@example.com", "name": "Owner", "password": "owner-pass-1"})
    need(st == 201, f"setup {st} {r}")
    TOKEN = r["access_token"]
    st, features = call("GET", "/v1/system-features")
    need(features.get("workflow_runtime") == {"protocol_version": "1.13", "single_node_run": ["llm"]}, f"system-features {features}")
    st, r = call("POST", "/v1/workspace/model-providers/langgenius/openai_api_compatible/openai_api_compatible/models/credentials",
                 {"model": "stub-chat", "model_type": "llm", "credentials": {
                     "endpoint_url": "http://llmstub:8000/v1", "api_key": "sk-stub-not-a-real-key", "mode": "chat",
                     "context_size": "4096", "max_tokens_to_sample": "4096"}})
    need(st == 201, f"credential {st} {r}")
    st, r = call("POST", "/v1/apps/imports", {"mode": "yaml-content", "yaml_content": YAML})
    need(st == 200 and r.get("app_id"), f"import {st} {r}")
    app = r["app_id"]
    st, before = call("GET", f"/v1/docs/{app}")
    st, fixed = call("POST", f"/v1/apps/{app}/workflows/draft/nodes/llm/run", {"inputs": {"#start.q#": "[[stub:fixed]]"}})
    need(st == 200 and fixed["status"] == "succeeded", f"run {st} {fixed}")
    need(fixed["outputs"]["text"] == "This is the fixed stub answer.", f"text {fixed['outputs']}")
    need(fixed["outputs"]["finish_reason"] == "stop" and fixed["outputs"]["usage"]["total_tokens"] > 0, f"usage {fixed['outputs']}")
    need(fixed["process_data"]["prompts"] == [{"role": "system", "text": "You are terse.", "files": []},
                                              {"role": "user", "text": "Q: [[stub:fixed]]", "files": []}], "prompts")
    st, echo = call("POST", f"/v1/apps/{app}/workflows/draft/nodes/llm/run", {"inputs": {"#start.q#": "hello daemon"}})
    need(st == 200 and echo["outputs"]["text"].endswith(": Q: hello daemon"), f"echo {st} {echo}")
    st, last = call("GET", f"/v1/apps/{app}/workflows/draft/nodes/llm/last-run")
    need(st == 200 and last["id"] == echo["id"] and last["outputs"] == echo["outputs"], f"last-run {st} {last}")
    st, after = call("GET", f"/v1/docs/{app}")
    need(after["head"] == before["head"], f"the run changed the document: {before} -> {after}")
    print(json.dumps({"fixed": {k: fixed[k] for k in ("status", "elapsed_time", "execution_metadata")} | {"text": fixed["outputs"]["text"]},
                      "echo": echo["outputs"]["text"], "doc_head": after["head"]}))


main()
