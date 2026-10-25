"""Deterministic OpenAI fixture, used only behind the signed official provider plugin. No vendor calls."""
import http.server,json,threading,time,pathlib
root=pathlib.Path('/evidence')
lock=threading.Lock()
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def send_json(self,status,value):
  data=json.dumps(value).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def do_GET(self):
  if self.path.endswith('/models'):return self.send_json(200,{'object':'list','data':[{'id':'stub-chat','object':'model','owned_by':'fixture'}]})
  if self.path=='/health':return self.send_json(200,{'status':'ok'})
  return self.send_json(404,{'error':'not_found'})
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  with lock:
   with (root/'requests.jsonl').open('a') as f:f.write(json.dumps(body)+'\n')
  text=' '.join(str(m.get('content','')) for m in body.get('messages',[]))
  tools=body.get('tools',[])
  tool_names=[t.get('function',{}).get('name') for t in tools]
  n=sum(m.get('role')=='tool' for m in body.get('messages',[]))
  if 'fixture-error' in text:return self.send_json(401,{'error':{'message':'synthetic-secret-must-not-be-reflected','type':'authentication_error'}})
  if 'fixture-two-questions' in text and n<2 and 'ask_human' in tool_names:
   delta={'tool_calls':[{'index':0,'id':'ask_human:0','type':'function','function':{'name':'ask_human','arguments':json.dumps({'question':f'Question {n+1}?','fields':[{'type':'paragraph','name':'answer','label':'Answer'}]})}}]}
   finish='tool_calls'
  elif 'final_output' in tool_names:
   delta={'tool_calls':[{'index':0,'id':'result/0','type':'function','function':{'name':'final_output','arguments':json.dumps({'text':'joint fixture answer','score':7})}}]};finish='tool_calls'
  else:delta={'content':'<think>fixture thought</think>joint fixture answer'};finish='stop'
  deltas=[delta]
  if 'fixture-interleaved' in text and n<2:
   deltas=[{'tool_calls':[{'index':0,'id':'opaque/a','type':'function','function':{'name':'a','arguments':'{"a":'}},{'index':1,'id':'opaque/b','type':'function','function':{'name':'b','arguments':'{"b":'}}]},
           {'tool_calls':[{'index':1,'function':{'arguments':'2}'}}]},
           {'tool_calls':[{'index':0,'function':{'arguments':'1}'}}]}]
   delta={'tool_calls':[{'id':'opaque/a','type':'function','function':{'name':'a','arguments':'{"a":1}'}},{'id':'opaque/b','type':'function','function':{'name':'b','arguments':'{"b":2}'}}]};finish='tool_calls'
  if not body.get('stream'):

   return self.send_json(200,{'id':'fixture','object':'chat.completion','created':1,'model':'stub-chat','choices':[{'index':0,'message':{'role':'assistant',**delta},'finish_reason':finish}],'usage':{'prompt_tokens':5,'completion_tokens':3,'total_tokens':8}})
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
  def write(delta,finish=None,usage=None):
   event={'id':'fixture','object':'chat.completion.chunk','created':1,'model':'stub-chat','choices':[{'index':0,'delta':delta,'finish_reason':finish}]}
   if usage:event['usage']=usage
   self.wfile.write(('data: '+json.dumps(event)+'\n\n').encode());self.wfile.flush()
  try:
   if 'fixture-hang' in text:
    for i in range(1000):write({'content':f'part{i} '});time.sleep(.02)
   else:
    for part in deltas:write({'role':'assistant',**part})
    write({},finish,{'prompt_tokens':5,'completion_tokens':3,'total_tokens':8})
   self.wfile.write(b'data: [DONE]\n\n');self.wfile.flush()
  except (BrokenPipeError,ConnectionResetError):
   with lock:(root/'disconnected').write_text('true')
http.server.ThreadingHTTPServer(('0.0.0.0',8000),Handler).serve_forever()
