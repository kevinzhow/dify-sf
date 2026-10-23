"""Isolated HTTP fault/capture origin; reuses the deterministic OpenAI test server."""
import json,sys,time,threading
from pathlib import Path
from urllib.parse import urlsplit,parse_qs
from http.server import ThreadingHTTPServer
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'llmstub'))
import llmstub
log=[];lock=threading.Lock()
class Handler(llmstub.Handler):
 def handle_http(self):
  path=urlsplit(self.path);q=parse_qs(path.query)
  if path.path=='/http/log':
   with lock:return self._json(200,{'requests':list(log)})
  if not path.path.startswith('/http/'):return False
  raw=self._body()
  with lock:log.append({'method':self.command,'path':self.path,'headers':dict(self.headers),'body':raw.decode('utf-8','replace')})
  if path.path in ('/http/redirect','/http/set-cookie'):
   self.send_response(int(q.get('status',['302'])[0]));self.send_header('Location',q['to'][0]);
   if path.path=='/http/set-cookie':self.send_header('Set-Cookie','from-origin=1; Path=/; HttpOnly')
   self.send_header('Content-Length','0');self.end_headers();return True
  if path.path=='/http/slow':time.sleep(float(q.get('seconds',['5'])[0]))
  if path.path=='/http/large':
   content=b'x'*int(q.get('size',['4096'])[0]);self.send_response(200);self.send_header('Content-Type','text/plain');self.send_header('Content-Length',str(len(content)));self.end_headers()
   try:self.wfile.write(content)
   except (BrokenPipeError,ConnectionResetError):pass
   return True
  status=int(q.get('status',['200'])[0]);self._json(status,{'method':self.command,'body':raw.decode('utf-8','replace'),'headers':dict(self.headers)});return True
 def do_GET(self):
  if self.handle_http() is not False:return
  return super().do_GET()
 def do_POST(self):
  if self.handle_http() is not False:return
  return super().do_POST()
 do_PUT=do_POST
 do_PATCH=do_POST
 do_DELETE=do_POST
if __name__=='__main__':
 import os
 llmstub.load_script(os.environ.get('LLMSTUB_SCRIPT'))
 if os.environ.get('RUNTIME_TEST_TLS_CERT'):
  import ssl
  secure=ThreadingHTTPServer(('0.0.0.0',443),Handler)
  context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
  context.load_cert_chain(os.environ['RUNTIME_TEST_TLS_CERT'],os.environ['RUNTIME_TEST_TLS_KEY'])
  secure.socket=context.wrap_socket(secure.socket,server_side=True)
  threading.Thread(target=secure.serve_forever,daemon=True).start()
 ThreadingHTTPServer(('0.0.0.0',int(os.environ.get('LLMSTUB_PORT','8000'))),Handler).serve_forever()
