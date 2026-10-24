"""Private deterministic model/audio/DSL fixture. Product requests still traverse the real signed plugin and proxy."""
import io,json,math,os,pathlib,struct,sys,threading,time,wave
from http.server import ThreadingHTTPServer
from urllib.parse import urlsplit,parse_qs
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'llmstub'))
import llmstub
mode={};lock=threading.Lock()
class Handler(llmstub.Handler):
 def _bytes(self,code,content,mime):
  self.send_response(code);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(content)));self.end_headers()
  try:self.wfile.write(content)
  except (BrokenPipeError,ConnectionResetError):pass
 def do_GET(self):
  path=urlsplit(self.path);q=parse_qs(path.query)
  if path.path=='/dsl/good.yml':return self._bytes(200,pathlib.Path(__file__).with_name('fixture.yml').read_bytes(),'application/yaml')
  if path.path=='/dsl/newer.yml':return self._bytes(200,pathlib.Path(__file__).with_name('fixture.yml').read_bytes().replace(b'version: 0.7.0',b'version: 0.8.0'),'application/yaml')
  if path.path=='/dsl/html':return self._bytes(200,b'<html>sign in</html>','text/html')
  if path.path=='/dsl/bad.yml':return self._bytes(200,b'{not: [valid','text/plain')
  if path.path=='/dsl/large':return self._bytes(200,b'x'*(10*1024*1024+1),'text/plain')
  if path.path=='/dsl/redirect':
   self.send_response(302);self.send_header('Location',q.get('to',['http://127.0.0.1/'])[0]);self.send_header('Content-Length','0');self.end_headers();return
  return super().do_GET()
 def do_POST(self):
  path=urlsplit(self.path).path
  if path=='/stub/modes':
   body=json.loads(self._body() or '{}')
   with lock:mode.clear();mode.update(body)
   return self._json(200,{'ok':True})
  if path in ['/v1/embeddings','/v1/audio/speech']:
   body=json.loads(self._body() or '{}')
   with llmstub._log_lock:llmstub._log.append({'path':path,'body':body});del llmstub._log[:-1000]
   with lock:settings=dict(mode)
   if path.endswith('/embeddings'):
    if settings.get('embeddingDelay'):time.sleep(settings['embeddingDelay'])
    if settings.get('embeddingFailure'):return self._json(503,{'error':{'message':'Controlled embedding unavailable'}})
    values=body.get('input',[]);values=[values] if isinstance(values,str) else values
    vectors=[]
    for i,text in enumerate(values):
     if 'near threshold' in text.lower():vector=[.8,.6,0.]
     elif any(s in text.lower() for s in ['fruit','same intent','changed question']):vector=[1.,0.,0.]
     elif 'other question' in text.lower():vector=[0.,1.,0.]
     else:vector=[0.,0.,1.]
     vectors.append({'object':'embedding','index':i,'embedding':vector})
    return self._json(200,{'object':'list','model':body.get('model'),'data':vectors,'usage':{'prompt_tokens':len(values),'total_tokens':len(values)}})
   if settings.get('ttsFailure'):return self._json(503,{'error':{'message':'Controlled audio unavailable'}})
   if settings.get('ttsDelay'):time.sleep(settings['ttsDelay'])
   return self._bytes(200,pathlib.Path(__file__).with_name('tone.mp3').read_bytes(),'audio/mpeg')
  return super().do_POST()
if __name__=='__main__':
 ThreadingHTTPServer(('0.0.0.0',8000),Handler).serve_forever()
