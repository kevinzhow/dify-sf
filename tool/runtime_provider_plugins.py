#!/usr/bin/env python3
"""Check/install explicitly selected, pinned provider runtimes; never configure or invoke a model."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "e2e" / "lib"))
from daemon import PluginDaemon


def package(pin, cache):
    path = cache / pin["file"]
    if not path.exists():
        url = "https://marketplace.dify.ai/api/v1/plugins/download-url?" + urllib.parse.urlencode(
            {"unique_identifier": pin["unique_identifier"]})
        request = urllib.request.Request(url, headers={"User-Agent": "dify-sf-runtime-provider-installer"})
        with urllib.request.urlopen(request, timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != pin["sha256"]:
            raise ValueError("Downloaded package checksum does not match the lock")
        cache.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != pin["sha256"]:
        raise ValueError("Cached package checksum does not match the lock")
    return data


def main():
    pins = json.loads((ROOT / "e2e" / "plugins.lock.json").read_text())["plugins"]
    by_id = {p["id"]: p for p in pins}
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin", action="append", required=True, choices=sorted(by_id))
    parser.add_argument("--daemon-url", default=os.environ.get("COLLAB_PLUGIN_DAEMON_URL"))
    parser.add_argument("--install", action="store_true", help="Install missing exact packages with signature verification")
    parser.add_argument("--cache-dir", type=Path, help="Persistent package cache on a disk with sufficient space")
    args = parser.parse_args()
    key = os.environ.get("COLLAB_PLUGIN_DAEMON_KEY")
    if not args.daemon_url or not key:
        parser.error("Set COLLAB_PLUGIN_DAEMON_URL and COLLAB_PLUGIN_DAEMON_KEY (key must not be passed on the command line)")
    if args.install and args.cache_dir is None:
        parser.error("--install requires --cache-dir")
    daemon = PluginDaemon(args.daemon_url, key)
    tenant = os.environ.get("COLLAB_PLUGIN_DAEMON_TENANT", "00000000-0000-0000-0000-000000000001")
    installed = {p.get("plugin_unique_identifier") for p in daemon.list_plugins(tenant)}
    checks = []
    for plugin in dict.fromkeys(args.plugin):
        pin = by_id[plugin]
        uid = pin["unique_identifier"]
        if uid not in installed and args.install:
            # PluginDaemon.install requests verify_signature=true. Never disable daemon verification.
            actual = daemon.install(tenant, package(pin, args.cache_dir))
            if actual != uid:
                raise ValueError("Daemon package identity does not match the lock")
        installed = {p.get("plugin_unique_identifier") for p in daemon.list_plugins(tenant)}
        checks.append({"plugin": plugin, "unique_identifier": uid, "ready": uid in installed})
    ready = all(c["ready"] for c in checks)
    print(json.dumps({"ready": ready, "providers": checks, "modelInvoked": False,
                      "userCredentialsChanged": False}, indent=2))
    return 0 if ready else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        # Management responses or private URLs can contain deployment details. Keep CLI failures narrow.
        print(f"Provider runtime operation failed ({type(error).__name__}); inspect private daemon logs.", file=sys.stderr)
        sys.exit(2)
