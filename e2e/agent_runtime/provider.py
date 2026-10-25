"""Deterministic OpenAI model behind the signed official plugin. No vendor connection or credentials."""
import http.server
import json
import pathlib
import threading

ROOT = pathlib.Path('/evidence')
LOCK = threading.Lock()

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def reply(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.reply(200, {'object': 'list', 'data': [{'id': 'stub-chat', 'object': 'model', 'owned_by': 'fixture'}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        with LOCK:
            with (ROOT / 'requests.jsonl').open('a') as output:
                output.write(json.dumps(body) + '\n')
        history = body.get('messages', [])
        answered = {m.get('tool_call_id') for m in history if m.get('role') == 'tool'}
        stages = [
            ('side-effect/once', 'shell_run', {'script': 'set -eu\nn=$(cat counter 2>/dev/null || echo 0)\nn=$((n + 1))\nprintf "%s" "$n" > counter\nprintf "owned artifact; counter=%s\\n" "$n" > artifact.txt\ncat artifact.txt', 'timeout': 10}),
            ('question/one', 'ask_human', {'question': 'Question 1?', 'fields': [{'type': 'paragraph', 'name': 'answer', 'label': 'Answer'}]}),
            ('verify/after-restart', 'shell_run', {'script': 'set -eu\ntest "$(cat counter)" = 1\ncat artifact.txt', 'timeout': 10}),
            ('question/two', 'ask_human', {'question': 'Question 2?', 'fields': [{'type': 'paragraph', 'name': 'answer', 'label': 'Answer'}]}),
            ('final/result', 'final_output', {'text': 'completed after restart', 'score': 7, 'bundle': {'artifacts': ['artifact.txt']}}),
        ]
        identity, name, arguments = next((stage for stage in stages if stage[0] not in answered), stages[-1])
        call = {'id': identity, 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(arguments)}}
        self.reply(200, {'id': 'fixture', 'object': 'chat.completion', 'created': 1, 'model': 'stub-chat',
            'choices': [{'index': 0, 'message': {'role': 'assistant', 'tool_calls': [call]}, 'finish_reason': 'tool_calls'}],
            'usage': {'prompt_tokens': 5, 'completion_tokens': 3, 'total_tokens': 8}})

http.server.ThreadingHTTPServer(('0.0.0.0', 8000), Handler).serve_forever()
