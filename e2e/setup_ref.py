"""Prepares stack R (Dify 1.17.1) for the differential tests; idempotent.

Creates the owner account (first start), installs the pinned openai_api_compatible plugin from the cached package and
adds the stub model `stub-chat` (endpoint http://llmstub:8000/v1). Then checks the whole model path once: a single-node
run of an LLM node through Dify -> plugin daemon -> plugin -> llmstub.

  python3 -I e2e/setup_ref.py        env: DIFYREF_URL (http://127.0.0.1:15001), DIFYREF_EMAIL, DIFYREF_PASSWORD
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from dify import STUB_MODEL, STUB_PROVIDER, DifyConsole, stub_credentials  # noqa: E402
import plugins  # noqa: E402

URL = os.environ.get("DIFYREF_URL", "http://127.0.0.1:%s" % os.environ.get("DIFYREF_API_PORT", "15001"))
EMAIL = os.environ.get("DIFYREF_EMAIL", "e2e-owner@example.test")
PASSWORD = os.environ.get("DIFYREF_PASSWORD", "E2e-throwaway-1")  # local throw-away stack only

PROBE_APP = """app: {mode: workflow, name: e2e-probe, icon: "x", icon_background: "#FFEAD5", description: ""}
kind: app
version: 0.6.0
workflow:
  environment_variables: []
  conversation_variables: []
  features: {}
  graph:
    edges:
    - {id: s-llm, source: start, target: llm, sourceHandle: source, targetHandle: target, data: {sourceType: start, targetType: llm}}
    - {id: llm-end, source: llm, target: end, sourceHandle: source, targetHandle: target, data: {sourceType: llm, targetType: end}}
    nodes:
    - id: start
      data: {type: start, title: Start, variables: [{variable: q, label: q, type: text-input, required: true, max_length: 256}]}
    - id: llm
      data:
        type: llm
        title: LLM
        model: {provider: %s, name: %s, mode: chat, completion_params: {temperature: 0}}
        prompt_template: [{role: system, text: "You are a probe."}, {role: user, text: "{{#start.q#}}"}]
        context: {enabled: false, variable_selector: []}
        vision: {enabled: false}
    - id: end
      data: {type: end, title: End, outputs: [{variable: text, value_selector: [llm, text], value_type: string}]}
""" % (STUB_PROVIDER, STUB_MODEL)


def main():
    t0 = time.time()
    d = DifyConsole(URL).ensure_setup(EMAIL, PASSWORD)
    pkg = plugins.package("langgenius/openai_api_compatible")
    uid = d.install_package(pkg)
    print(f"plugin installed: {uid} ({time.time() - t0:.0f}s)", flush=True)
    d.add_model_credentials(STUB_PROVIDER, STUB_MODEL, stub_credentials())
    models = [m.get("model") for m in d.models(STUB_PROVIDER).get("data", [])]
    print(f"models of {STUB_PROVIDER}: {models}")
    app_id = d.import_yaml(PROBE_APP)
    try:
        r = d.run_node(app_id, "llm", {"#start.q#": "probe hello"})
        text = (r.get("outputs") or {}).get("text")
        print(f"probe single-node run: status={r.get('status')} text={text!r} error={r.get('error')!r}")
        ok = r.get("status") == "succeeded" and isinstance(text, str) and text.startswith("stub ")
    finally:
        d.delete_app(app_id)
    print(json.dumps({"ok": ok, "plugin": uid, "seconds": round(time.time() - t0)}))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
