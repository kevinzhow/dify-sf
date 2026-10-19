"""Prepares the plugin daemon of stack P (dify-sf's runtime profile) and checks the model path; idempotent.

Installs the pinned openai_api_compatible plugin for a test tenant, validates the stub model's credentials and invokes
it (streaming) through the daemon exactly as a runtime would (POST /plugin/<tenant>/dispatch/llm/invoke), then checks
the chunks against llmstub's deterministic answer. With --dify it runs the same check against stack R's daemon.

  python3 -I e2e/setup_ours.py [--dify]
  env: DIFYSF_DAEMON_URL (http://127.0.0.1:15102), DIFYSF_DAEMON_KEY, E2E_TENANT; DIFYREF_DAEMON_URL, DIFYREF_DAEMON_KEY
"""
import json
import os
import sys
import time

E2E = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(E2E, "lib"))
sys.path.insert(0, os.path.join(E2E, "llmstub"))
from daemon import PluginDaemon  # noqa: E402
from dify import STUB_MODEL, stub_credentials  # noqa: E402
import llmstub  # noqa: E402
import plugins  # noqa: E402

PLUGIN_ID = "langgenius/openai_api_compatible"
PROVIDER = "openai_api_compatible"
TENANT = os.environ.get("E2E_TENANT", "00000000-0000-0000-0000-000000000001")


def check(name, url, key):
    t0 = time.time()
    d = PluginDaemon(url, key)
    uid = d.install(TENANT, plugins.package(PLUGIN_ID))
    t_inst = time.time() - t0
    creds = stub_credentials()
    valid = d.validate_model_credentials(TENANT, PLUGIN_ID, PROVIDER, STUB_MODEL, creds)
    messages = [{"role": "system", "content": "You are a probe."}, {"role": "user", "content": "probe hello"}]
    chunks = d.invoke_llm(TENANT, PLUGIN_ID, PROVIDER, STUB_MODEL, creds, messages, {"temperature": 0})
    text = "".join((c.get("delta") or {}).get("message", {}).get("content") or "" for c in chunks)
    usage = next(((c.get("delta") or {}).get("usage") for c in reversed(chunks) if (c.get("delta") or {}).get("usage")), None)
    llmstub.load_script(os.path.join(E2E, "llmstub", "script.json"))
    want = "".join(llmstub.answer_for({"messages": messages, "model": STUB_MODEL}, True)[0]["chunks"])
    ok = valid and text == want
    print(json.dumps({"daemon": name, "ok": ok, "plugin": uid, "install_s": round(t_inst), "valid": valid,
                      "chunks": len(chunks), "text": text, "want": want,
                      "usage": {k: usage.get(k) for k in ("prompt_tokens", "completion_tokens", "total_tokens")} if usage else None}))
    return ok


def main():
    ok = check("dify-sf", os.environ.get("DIFYSF_DAEMON_URL", "http://127.0.0.1:%s" % os.environ.get("DIFYSF_P_DAEMON_PORT", "15102")),
               os.environ.get("DIFYSF_DAEMON_KEY", "dify-sf-local-plugin-daemon-key"))
    if "--dify" in sys.argv:
        # Dify's documented default daemon key (docker/.env.example); the reference stack is local and throw-away.
        ok = check("dify", os.environ.get("DIFYREF_DAEMON_URL", "http://127.0.0.1:%s" % os.environ.get("DIFYREF_DAEMON_PORT", "15002")),
                   os.environ.get("DIFYREF_DAEMON_KEY", "lYkiYYT6owG+71oLerGzA7GXCgOT++6ovaezWAjpCjf+Sjc3ZtU+qUEi")) and ok
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
