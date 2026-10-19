"""Minimal HTTP helpers for the e2e harness (standard library only; run the scripts with `python3 -I`)."""
import http.cookiejar
import json
import urllib.error
import urllib.request
import uuid


class HTTPError(Exception):
    def __init__(self, status, body, url):
        super().__init__(f"HTTP {status} from {url}: {body[:500]}")
        self.status = status
        self.body = body
        self.url = url


class Session:
    """Cookies + default headers + JSON in/out."""

    def __init__(self, base, headers=None, timeout=60):
        self.base = base.rstrip("/")
        self.headers = dict(headers or {})
        self.timeout = timeout
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))

    def cookie(self, name):
        return next((c.value for c in self.jar if c.name == name), None)

    def _request(self, method, path, body=None, headers=None, raw=False):
        url = path if path.startswith("http") else self.base + path
        h = dict(self.headers)
        h.update(headers or {})
        data = None
        if body is not None and not raw:
            data = json.dumps(body).encode("utf-8")
            h.setdefault("Content-Type", "application/json")
        elif raw:
            data = body
        return urllib.request.Request(url, data=data, headers=h, method=method)

    def call(self, method, path, body=None, headers=None, raw=False, ok=(200, 201, 202, 204)):
        req = self._request(method, path, body, headers, raw)
        try:
            with self.opener.open(req, timeout=self.timeout) as r:
                text = r.read().decode("utf-8")
                status = r.status
        except urllib.error.HTTPError as e:
            text = e.read().decode("utf-8", "replace")
            status = e.code
        if status not in ok:
            raise HTTPError(status, text, req.full_url)
        if not text:
            return None
        try:
            return json.loads(text)
        except ValueError:
            return text

    def get(self, path, **kw):
        return self.call("GET", path, **kw)

    def post(self, path, body=None, **kw):
        return self.call("POST", path, body, **kw)

    def delete(self, path, **kw):
        return self.call("DELETE", path, **kw)

    def multipart(self, path, fields, files, ok=(200, 201)):
        """fields: {name: str}, files: {name: (filename, bytes)}"""
        boundary = "----e2e" + uuid.uuid4().hex
        parts = []
        for k, v in fields.items():
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
        for k, (fn, data) in files.items():
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"; filename="{fn}"\r\n'
                         f'Content-Type: application/octet-stream\r\n\r\n'.encode() + data + b"\r\n")
        parts.append(f"--{boundary}--\r\n".encode())
        return self.call("POST", path, b"".join(parts), headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
                         raw=True, ok=ok)

    def stream(self, method, path, body=None, headers=None, timeout=None):
        """Yields the payload of every `data:` line of a server-sent event stream (or of a line stream)."""
        req = self._request(method, path, body, headers)
        try:
            r = self.opener.open(req, timeout=timeout or self.timeout)
        except urllib.error.HTTPError as e:
            raise HTTPError(e.code, e.read().decode("utf-8", "replace"), req.full_url)
        with r:
            for raw in r:
                line = raw.decode("utf-8").strip()
                if line.startswith("data:"):
                    line = line[5:].strip()
                elif line.startswith(("event:", "id:", "retry:", ":")):
                    continue
                if line:
                    yield line
