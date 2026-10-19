"""Pinned plugin packages (e2e/plugins.lock.json), fetched once from the Dify marketplace into e2e/.cache/plugins/."""
import hashlib
import json
import os
import urllib.parse
import urllib.request

E2E = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(E2E, ".cache", "plugins")
MARKETPLACE = os.environ.get("DIFY_MARKETPLACE_URL", "https://marketplace.dify.ai")


def pinned(plugin_id):
    lock = json.load(open(os.path.join(E2E, "plugins.lock.json")))
    return next(p for p in lock["plugins"] if p["id"] == plugin_id)


def package(plugin_id):
    """Bytes of the pinned package; downloads it into the cache the first time. Raises on a checksum mismatch."""
    p = pinned(plugin_id)
    path = os.path.join(CACHE, p["file"])
    if not os.path.exists(path):
        os.makedirs(CACHE, exist_ok=True)
        q = urllib.parse.urlencode({"unique_identifier": p["unique_identifier"]})
        with urllib.request.urlopen(f"{MARKETPLACE}/api/v1/plugins/download-url?{q}", timeout=120) as r:
            data = r.read()
        if hashlib.sha256(data).hexdigest() != p["sha256"]:
            raise RuntimeError(f"{p['file']}: checksum mismatch, not cached")
        with open(path + ".part", "wb") as f:
            f.write(data)
        os.replace(path + ".part", path)
    data = open(path, "rb").read()
    if hashlib.sha256(data).hexdigest() != p["sha256"]:
        raise RuntimeError(f"{path}: checksum mismatch")
    return data
