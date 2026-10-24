"""Dify 1.17.1 console API client for the reference stack (local, throw-away; standard library only)."""
import base64
import json
import time

from e2ehttp import HTTPError, Session

STUB_PROVIDER = "langgenius/openai_api_compatible/openai_api_compatible"
STUB_MODEL = "stub-chat"


def stub_credentials(endpoint="http://llmstub:8000/v1"):
    """Credentials of the stub model, the same on both sides (openai_api_compatible, chat mode)."""
    return {
        "endpoint_url": endpoint,
        "api_key": "sk-stub-not-a-real-key",
        "mode": "chat",
        "context_size": "4096",
        "max_tokens_to_sample": "4096",
        "max_chunks": "16",
    }


class DifyConsole:
    def __init__(self, base):
        self.s = Session(base, timeout=120)

    # ---- account ----
    def ensure_setup(self, email, password, name="E2E Owner"):
        st = self.s.get("/console/api/setup")
        if st.get("step") != "finished":
            self.s.post("/console/api/setup", {"email": email, "name": name, "password": password, "language": "en-US"})
        return self.login(email, password)

    def login(self, email, password):
        pw = base64.b64encode(password.encode()).decode()
        self.s.post("/console/api/login", {"email": email, "password": pw, "remember_me": True, "language": "en-US"})
        csrf = self.s.cookie("csrf_token")
        if csrf:
            self.s.headers["X-CSRF-Token"] = csrf
        return self

    def api(self, method, path, body=None, **kw):
        return self.s.call(method, "/console/api" + path, body, **kw)

    # ---- plugins ----
    def installed_plugins(self):
        r = self.api("GET", "/workspaces/current/plugin/list?page=1&page_size=256")
        return r.get("plugins", [])

    def install_package(self, pkg_bytes, timeout=900):
        """Uploads a .difypkg and installs it (signature verified by the daemon). Returns the unique identifier."""
        up = self.s.multipart("/console/api/workspaces/current/plugin/upload/pkg", {}, {"pkg": ("plugin.difypkg", pkg_bytes)})
        uid = up["unique_identifier"]
        if any(p.get("plugin_unique_identifier") == uid for p in self.installed_plugins()):
            return uid
        task = self.api("POST", "/workspaces/current/plugin/install/pkg", {"plugin_unique_identifiers": [uid]})
        if task.get("all_installed"):
            return uid
        self.wait_task(task["task_id"], timeout)
        return uid

    def wait_task(self, task_id, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            t = self.api("GET", f"/workspaces/current/plugin/tasks/{task_id}")["task"]
            if t["status"] == "success":
                return t
            if t["status"] == "failed":
                raise RuntimeError(f"plugin install failed: {json.dumps(t)[:2000]}")
            time.sleep(3)
        raise TimeoutError(f"plugin install task {task_id} not finished after {timeout}s")

    # ---- models ----
    def add_model_credentials(self, provider, model, credentials, name="stub"):
        path = f"/workspaces/current/model-providers/{provider}/models/credentials"
        try:
            self.api("POST", path, {"model": model, "model_type": "llm", "name": name, "credentials": credentials})
        except HTTPError as e:
            if "already exists" not in e.body and "exist" not in e.body:
                raise

    def models(self, provider):
        return self.api("GET", f"/workspaces/current/model-providers/{provider}/models")

    # ---- apps ----
    def import_yaml(self, text):
        body = self.api("POST", "/apps/imports", {"mode": "yaml-content", "yaml_content": text})
        if body.get("status") == "pending":
            body = self.api("POST", f"/apps/imports/{body['id']}/confirm")
        if body.get("status") not in ("completed", "completed-with-warnings"):
            raise RuntimeError(f"Dify refused the import: {body}")
        return body["app_id"]

    def app(self, app_id):
        return self.api("GET", f"/apps/{app_id}")

    def draft(self, app_id):
        return self.api("GET", f"/apps/{app_id}/workflows/draft")

    def sync_draft(self, app_id, draft, graph):
        body = {"graph": graph, "features": draft.get("features") or {}, "hash": draft.get("hash"),
                "conversation_variables": draft.get("conversation_variables") or []}
        return self.api("POST", f"/apps/{app_id}/workflows/draft", body)

    def delete_app(self, app_id):
        self.api("DELETE", f"/apps/{app_id}")

    def run_draft(self, app_id, mode, inputs, query="", timeout=300):
        """Yields the decoded SSE events of a draft run (workflow or advanced-chat)."""
        if mode == "advanced-chat":
            path, body = f"/apps/{app_id}/advanced-chat/workflows/draft/run", {"inputs": inputs, "query": query, "files": []}
        else:
            path, body = f"/apps/{app_id}/workflows/draft/run", {"inputs": inputs, "files": []}
        for line in self.s.stream("POST", "/console/api" + path, body, timeout=timeout):
            try:
                yield json.loads(line)
            except ValueError:
                continue

    def run_container(self, app_id, kind, node_id, inputs, timeout=300):
        """Yields the decoded SSE events of an iteration / loop single run (kind: iteration | loop)."""
        path = f"/console/api/apps/{app_id}/workflows/draft/{kind}/nodes/{node_id}/run"
        for line in self.s.stream("POST", path, {"inputs": inputs}, timeout=timeout):
            try:
                yield json.loads(line)
            except ValueError:
                continue

    def run_node(self, app_id, node_id, inputs, query=""):
        return self.api("POST", f"/apps/{app_id}/workflows/draft/nodes/{node_id}/run", {"inputs": inputs, "query": query})
