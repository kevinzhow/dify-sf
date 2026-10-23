"""Runtime-file receiver and deterministic model host. Isolated fixture only, no external provider calls."""
import base64
import email
import email.policy
import hashlib
import json
import os
import sys
import threading
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from runtime_services.origin import Handler as RuntimeHandler
import llmstub

PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a4x8AAAAASUVORK5CYII=')
PDF = b'%PDF-1.4\nRuntime fixture raw document\n%%EOF\n'
LOCK = threading.Lock()
REQUESTS = []

class Handler(RuntimeHandler):
    def handle_http(self):
        path = urlsplit(self.path)
        if path.path == '/files/log':
            with LOCK:
                return self._json(200, {'requests': list(REQUESTS)})
        if not path.path.startswith('/files/'):
            return super().handle_http()
        query = parse_qs(path.query)
        raw = self._body()
        record = {'method': self.command, 'path': self.path, 'mime': self.headers.get('Content-Type'),
                  'sha256': hashlib.sha256(raw).hexdigest(), 'base64': base64.b64encode(raw).decode(), 'parts': []}
        if 'multipart/form-data' in (record['mime'] or ''):
            message = email.message_from_bytes(('Content-Type: ' + record['mime'] + '\r\nMIME-Version: 1.0\r\n\r\n').encode() + raw,
                                               policy=email.policy.default)
            for part in message.iter_parts():
                content = part.get_payload(decode=True) or b''
                record['parts'].append({'name': part.get_param('name', header='Content-Disposition'),
                    'filename': part.get_filename(), 'mime': part.get_content_type(),
                    'base64': base64.b64encode(content).decode(), 'sha256': hashlib.sha256(content).hexdigest()})
        with LOCK:
            REQUESTS.append(record)
            del REQUESTS[:-500]
        if path.path == '/files/echo':
            return self._json(200, record)
        if path.path == '/files/redirect':
            self.send_response(302); self.send_header('Location', query['to'][0]); self.send_header('Content-Length', '0'); self.end_headers()
            return True
        payload, mime, name = (PNG, 'image/png', "filename*=UTF-8''%E5%9B%BE.png") if path.path.endswith('.png') else (PDF, 'application/pdf', 'filename="fixture.pdf"')
        if path.path == '/files/large':
            payload, mime, name = b'x' * min(int(query.get('size', ['11000000'])[0]), 16000000), 'application/pdf', 'filename="large.pdf"'
        self.send_response(int(query.get('status', ['200'])[0])); self.send_header('Content-Type', mime)
        self.send_header('Content-Disposition', 'attachment; ' + name); self.send_header('Content-Length', str(len(payload))); self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass
        return True

if __name__ == '__main__':
    llmstub.load_script(os.environ.get('LLMSTUB_SCRIPT'))
    if os.environ.get('RUNTIME_TEST_TLS_CERT'):
        import ssl
        secure = ThreadingHTTPServer(('0.0.0.0', 443), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(os.environ['RUNTIME_TEST_TLS_CERT'], os.environ['RUNTIME_TEST_TLS_KEY'])
        secure.socket = context.wrap_socket(secure.socket, server_side=True)
        threading.Thread(target=secure.serve_forever, daemon=True).start()
    ThreadingHTTPServer(('0.0.0.0', int(os.environ.get('LLMSTUB_PORT', '8000'))), Handler).serve_forever()
