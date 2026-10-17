import os
"""Minimal Dify console API client used by the repro scripts (local throwaway stack only)."""
import base64, json, requests

BASE = "http://localhost"
# Throwaway accounts on a local, disposable Dify instance (create them once in that instance).
# Passwords come from the environment so none is committed: REPRO_PW_ALICE, REPRO_PW_BOB.
USERS = {
    "alice": ("alice@example.test", os.environ.get("REPRO_PW_ALICE", "")),
    "bob": ("bob@example.test", os.environ.get("REPRO_PW_BOB", "")),
    "bob2": ("bob2@example.test", os.environ.get("REPRO_PW_BOB", "")),
}

def b64(s):
    return base64.b64encode(s.encode()).decode()

class Client:
    def __init__(self, user="alice", base=BASE):
        self.base = base
        self.user = user
        self.s = requests.Session()
        email, pw = USERS[user]
        r = self.s.post(base + "/console/api/login", json={"email": email, "password": b64(pw), "remember_me": True, "language": "en-US"})
        r.raise_for_status()
        self.csrf = self.s.cookies.get("csrf_token")

    def h(self):
        return {"X-CSRF-Token": self.csrf}

    def cookies(self):
        """cookies in playwright format"""
        out = []
        for c in self.s.cookies:
            out.append({"name": c.name, "value": c.value, "domain": "localhost", "path": "/"})
        return out

    def get(self, path, **kw):
        r = self.s.get(self.base + "/console/api" + path, headers=self.h(), **kw)
        return r

    def post(self, path, **kw):
        return self.s.post(self.base + "/console/api" + path, headers=self.h(), **kw)

    def delete(self, path, **kw):
        return self.s.delete(self.base + "/console/api" + path, headers=self.h(), **kw)

    def create_app(self, name, mode="workflow"):
        r = self.post("/apps", json={"name": name, "mode": mode, "icon_type": "emoji", "icon": "🤖", "icon_background": "#FFEAD5"})
        r.raise_for_status()
        return r.json()["id"]

    def get_draft(self, app_id):
        r = self.get(f"/apps/{app_id}/workflows/draft")
        r.raise_for_status()
        return r.json()

    def save_draft(self, app_id, graph, features=None, hash=None, collaborative=True, raw=False):
        body = {"graph": graph, "features": features or {}, "conversation_variables": [], "hash": hash}
        if collaborative:
            body["_is_collaborative"] = True
        r = self.post(f"/apps/{app_id}/workflows/draft", json=body)
        return r if raw else r.json()

    def list_apps(self):
        r = self.get("/apps?page=1&limit=100")
        return r.json()["data"]
