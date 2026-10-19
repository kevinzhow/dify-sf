"""llmstub: a tiny deterministic OpenAI-compatible server for the differential tests (standard library only).

Both Dify and dify-sf reach it through the same `langgenius/openai_api_compatible` plugin in a plugin daemon, with
endpoint_url `http://llmstub:8000/v1`, so a difference between the two runs is a difference of the engines, never of
the model. No real provider is ever called.

Endpoints
  GET  /health                      -> {"ok": true}
  GET  /v1/models                   -> the stub models
  POST /v1/chat/completions         -> chat answer, streaming (SSE) or not
  POST /v1/completions              -> completion answer, streaming or not
  ANY  /echo[/...]                  -> the request as JSON (a target for HTTP request nodes)
  GET  /stub/log                    -> the recorded completion requests (newest last, at most 500)
  POST /stub/reset                  -> clears the log
  POST /stub/script                 -> replaces the script (JSON body, same format as LLMSTUB_SCRIPT)

The answer is chosen by the script (env LLMSTUB_SCRIPT = path of a JSON file, optional):
  {"rules": [{"match": "<substring of the last user message>", "reply": "text"} |
             {"match": "...", "chunks": ["a", "b"]} |
             {"match": "...", "status": 500, "error": "message"}]}
The first rule whose `match` occurs in the last user message (or the prompt) wins; `"match": ""` matches everything.
Without a matching rule the answer is `stub <h8>: <first 12 words of the last user message>` where h8 = the first 8
hex digits of SHA-256 over the canonical JSON of the messages (or the prompt). Streaming splits the answer into words
(each chunk carries its leading space). Usage: prompt_tokens = whitespace-separated words of all messages,
completion_tokens = number of chunks, always reported (also in the last stream chunk, choices empty).
"""
import hashlib
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = ["stub-chat", "stub-chat-2"]
CREATED = 1700000000  # fixed, so answers are byte-identical between runs
_log_lock = threading.Lock()
_log = []
_script = {"rules": []}


def load_script(path):
    global _script
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            _script = json.load(f)


def _text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):  # multimodal parts
        return " ".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text")
    return ""


def answer_for(body, chat):
    if chat:
        messages = body.get("messages") or []
        last_user = next((_text_of(m.get("content")) for m in reversed(messages) if m.get("role") == "user"), "")
        canon = json.dumps(messages, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
        words = sum(len(_text_of(m.get("content")).split()) for m in messages)
    else:
        prompt = body.get("prompt") or ""
        prompt = prompt if isinstance(prompt, str) else json.dumps(prompt, ensure_ascii=False)
        last_user, canon, words = prompt, prompt, len(prompt.split())
    for rule in _script.get("rules", []):
        if rule.get("match", "") in last_user:
            if "status" in rule:
                return {"status": rule["status"], "error": rule.get("error", "stub error")}, words
            chunks = rule.get("chunks")
            if chunks is None:
                chunks = _split(rule.get("reply", ""))
            return {"chunks": chunks}, words
    h8 = hashlib.sha256(canon.encode("utf-8")).hexdigest()[:8]
    text = f"stub {h8}: " + " ".join(last_user.split()[:12])
    return {"chunks": _split(text.rstrip())}, words


def _split(text):
    parts = text.split(" ")
    return [p if i == 0 else " " + p for i, p in enumerate(parts)] if text else [""]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "llmstub/1"

    def log_message(self, fmt, *args):  # quiet: one line per request on stderr
        sys.stderr.write("llmstub %s %s\n" % (self.command, self.path))

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _json(self, status, obj):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            return self._json(200, {"ok": True})
        if self.path.rstrip("/") == "/v1/models":
            return self._json(200, {"object": "list", "data": [
                {"id": m, "object": "model", "created": CREATED, "owned_by": "llmstub"} for m in MODELS]})
        if self.path == "/stub/log":
            with _log_lock:
                return self._json(200, {"requests": list(_log)})
        if self.path.startswith("/echo"):
            return self._echo(b"")
        return self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        raw = self._body()
        if self.path.startswith("/echo"):
            return self._echo(raw)
        if self.path == "/stub/reset":
            with _log_lock:
                _log.clear()
            return self._json(200, {"ok": True})
        if self.path == "/stub/script":
            global _script
            _script = json.loads(raw or b"{}")
            return self._json(200, {"ok": True})
        chat = self.path.rstrip("/") == "/v1/chat/completions"
        if not chat and self.path.rstrip("/") != "/v1/completions":
            return self._json(404, {"error": {"message": "not found"}})
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            return self._json(400, {"error": {"message": "invalid JSON"}})
        with _log_lock:
            _log.append({"path": self.path, "body": body})
            del _log[:-500]
        result, prompt_tokens = answer_for(body, chat)
        if "status" in result:
            return self._json(result["status"], {"error": {"message": result["error"], "type": "stub_error"}})
        chunks = result["chunks"]
        usage = {"prompt_tokens": prompt_tokens, "completion_tokens": len(chunks),
                 "total_tokens": prompt_tokens + len(chunks)}
        model = body.get("model") or MODELS[0]
        rid = "stub-" + hashlib.sha256(raw).hexdigest()[:12]
        if not body.get("stream"):
            text = "".join(chunks)
            choice = ({"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"} if chat
                      else {"index": 0, "text": text, "finish_reason": "stop"})
            return self._json(200, {"id": rid, "object": "chat.completion" if chat else "text_completion",
                                    "created": CREATED, "model": model, "choices": [choice], "usage": usage})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        obj = "chat.completion.chunk" if chat else "text_completion"

        def send(payload):
            self.wfile.write(b"data: " + json.dumps(payload, ensure_ascii=False).encode("utf-8") + b"\n\n")
            self.wfile.flush()

        for i, c in enumerate(chunks):
            delta = {"role": "assistant", "content": c} if i == 0 else {"content": c}
            choice = {"index": 0, "delta": delta, "finish_reason": None} if chat else {"index": 0, "text": c, "finish_reason": None}
            send({"id": rid, "object": obj, "created": CREATED, "model": model, "choices": [choice]})
        last = {"index": 0, "delta": {}, "finish_reason": "stop"} if chat else {"index": 0, "text": "", "finish_reason": "stop"}
        send({"id": rid, "object": obj, "created": CREATED, "model": model, "choices": [last]})
        send({"id": rid, "object": obj, "created": CREATED, "model": model, "choices": [], "usage": usage})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True

    do_PUT = do_POST
    do_PATCH = do_POST

    def do_DELETE(self):
        if self.path.startswith("/echo"):
            return self._echo(self._body())
        return self._json(404, {"error": {"message": "not found"}})

    def _echo(self, raw):
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            body = raw.decode("utf-8", "replace")
        headers = {k.lower(): v for k, v in self.headers.items() if k.lower() not in ("host", "content-length", "user-agent", "accept-encoding", "connection")}
        return self._json(200, {"method": self.command, "path": self.path, "headers": dict(sorted(headers.items())), "body": body})


def main():
    load_script(os.environ.get("LLMSTUB_SCRIPT"))
    port = int(os.environ.get("LLMSTUB_PORT", "8000"))
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    srv.daemon_threads = True
    sys.stderr.write(f"llmstub listening on :{port}\n")
    srv.serve_forever()


if __name__ == "__main__":
    main()
