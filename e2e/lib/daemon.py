"""Client for Dify's plugin daemon 0.6.10 HTTP API (the calls Dify's api makes; standard library only).

Every call carries `X-Api-Key: <SERVER_KEY>`; answers are `{code, message, data}` (code 0 = ok); dispatch calls answer
with a stream of `data: {code, message, data}` lines. Paths and payloads as in Dify 1.17.1 api/core/plugin/impl/*.py.
"""
import json
import time

from e2ehttp import Session


class DaemonError(Exception):
    pass


class PluginDaemon:
    def __init__(self, base, key):
        self.s = Session(base, headers={"X-Api-Key": key}, timeout=120)

    def _data(self, r):
        if not isinstance(r, dict) or r.get("code") != 0:
            raise DaemonError(f"plugin daemon: {r}")
        return r.get("data")

    def health(self):
        return self.s.get("/health/check")

    def list_plugins(self, tenant):
        d = self._data(self.s.get(f"/plugin/{tenant}/management/list?page=1&page_size=256&response_type=paged"))
        return d.get("list", []) if isinstance(d, dict) else (d or [])

    def upload_package(self, tenant, pkg_bytes, verify_signature=True):
        r = self.s.multipart(f"/plugin/{tenant}/management/install/upload/package",
                             {"verify_signature": "true" if verify_signature else "false"},
                             {"dify_pkg": ("dify_pkg", pkg_bytes)})
        return self._data(r)  # {unique_identifier, manifest, verification}

    def install(self, tenant, pkg_bytes, timeout=900):
        """Upload + install from the package; idempotent. Returns the unique identifier."""
        uid = self.upload_package(tenant, pkg_bytes)["unique_identifier"]
        if any(p.get("plugin_unique_identifier") == uid for p in self.list_plugins(tenant)):
            return uid
        start = self._data(self.s.post(f"/plugin/{tenant}/management/install/identifiers",
                                       {"plugin_unique_identifiers": [uid], "source": "package", "metas": [{}]}))
        if start.get("all_installed"):
            return uid
        deadline = time.time() + timeout
        while time.time() < deadline:
            t = self._data(self.s.get(f"/plugin/{tenant}/management/install/tasks/{start['task_id']}"))
            if t["status"] == "success":
                return uid
            if t["status"] == "failed":
                raise DaemonError(f"install failed: {json.dumps(t)[:2000]}")
            time.sleep(3)
        raise TimeoutError(f"install task {start['task_id']} not finished after {timeout}s")

    def _dispatch(self, tenant, path, plugin_id, data, user_id="e2e-user"):
        body = {"user_id": user_id, "data": data}
        out = []
        for line in self.s.stream("POST", f"/plugin/{tenant}/dispatch/{path}", body,
                                  headers={"X-Plugin-ID": plugin_id}, timeout=300):
            msg = json.loads(line)
            if msg.get("code") != 0:
                raise DaemonError(f"dispatch {path}: {msg}")
            out.append(msg.get("data"))
        return out

    def validate_model_credentials(self, tenant, plugin_id, provider, model, credentials):
        r = self._dispatch(tenant, "model/validate_model_credentials", plugin_id,
                           {"provider": provider, "model_type": "llm", "model": model, "credentials": credentials})
        return bool(r and r[0].get("result"))

    def invoke_llm(self, tenant, plugin_id, provider, model, credentials, prompt_messages, model_parameters=None,
                   stream=True):
        """Returns the list of LLMResultChunk dicts ({model, prompt_messages, system_fingerprint, delta: {index,
        message: {role, content}, usage?, finish_reason?}})."""
        return self._dispatch(tenant, "llm/invoke", plugin_id, {
            "provider": provider, "model_type": "llm", "model": model, "credentials": credentials,
            "prompt_messages": prompt_messages, "model_parameters": model_parameters or {}, "tools": [],
            "stop": [], "stream": stream})
