"""Standard-library synthetic Responses WS. Never contacts an external model."""
import base64, hashlib, http.server, json, os, pathlib, socket, struct, threading, signal
# ServiceLifecycle blocks termination signals; fixtures must not inherit that mask.
signal.pthread_sigmask(signal.SIG_SETMASK, [])
records=pathlib.Path(os.environ['CODEX_WS_RECORDS'])
lock=threading.Lock(); connections=0; calls=0

def record(value):
    with lock:
        with records.open('a') as f: f.write(json.dumps(value)+'\n')
def frame(sock, body):
    b=json.dumps(body,separators=(',',':')).encode();n=len(b)
    sock.sendall(b'\x81'+(bytes([n]) if n<126 else b'\x7e'+struct.pack('!H',n) if n<65536 else b'\x7f'+struct.pack('!Q',n))+b)
def exact(sock,n):
    b=bytearray()
    while len(b)<n:
        part=sock.recv(n-len(b))
        if not part: raise EOFError()
        b.extend(part)
    return bytes(b)
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*a): pass
    def do_GET(self):
        global connections,calls
        if self.path!='/v1/responses' or self.headers.get('Upgrade','').lower()!='websocket':
            self.send_response(404);self.send_header('Content-Length','0');self.end_headers();return
        with lock: connections+=1;connection=connections
        key=base64.b64encode(hashlib.sha1((self.headers['Sec-WebSocket-Key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101);self.send_header('Upgrade','websocket');self.send_header('Connection','Upgrade');self.send_header('Sec-WebSocket-Accept',key);self.end_headers()
        record({'connection':connection,'authorized':self.headers.get('Authorization')=='Bearer sk-native-fixture-only','beta':self.headers.get('OpenAI-Beta'),'no_run_header':self.headers.get('X-Agent-Run-Token') is None,'no_client_identity':self.headers.get('session-id') is None})
        try:
            while True:
                a,b=exact(self.connection,2);n=b&127
                if n==126:n=struct.unpack('!H',exact(self.connection,2))[0]
                if n==127:n=struct.unpack('!Q',exact(self.connection,8))[0]
                assert n<=128<<20
                mask=exact(self.connection,4) if b&128 else b''
                data=exact(self.connection,n)
                if mask:data=bytes(v^mask[i%4] for i,v in enumerate(data))
                if a&15==8:return
                if a&15 in (9,10):continue
                body=json.loads(data)
                warm=body.get('generate') is False
                with lock:
                    if not warm:calls+=1
                    call=calls
                record({'connection':connection,'warmup':warm,'call':call,'bytes':n,'previous':body.get('previous_response_id'),'model':body['model'],'store':body.get('store'),'effort':body.get('reasoning',{}).get('effort'),'max_output_tokens':body.get('max_output_tokens'),'inputs':len(body['input']),'types':[x.get('type') for x in body['input']]})
                response='resp_ws_warm' if warm else 'resp_ws_'+str(call)
                frame(self.connection,{'type':'response.created','response':{'id':response}})
                output=[]
                if not warm:
                    if call==1:
                        item={'type':'function_call','id':'fc_ws_1','call_id':'call_ws_1','name':'exec_command','arguments':'{"cmd":"printf fixture-delta"}'}
                    else:
                        item={'type':'message','id':'msg_ws_'+str(call),'role':'assistant','status':'completed','phase':'final_answer','content':[{'type':'output_text','text':'Synthetic WebSocket complete.','annotations':[]}]}
                    output=[item]
                    frame(self.connection,{'type':'response.output_item.added','output_index':0,'item':item})
                    frame(self.connection,{'type':'response.output_item.done','output_index':0,'item':item})
                frame(self.connection,{'type':'response.completed','response':{'id':response,'status':'completed','output':output,'usage':{'input_tokens':0 if warm else 20,'output_tokens':0 if warm else 3,'total_tokens':0 if warm else 23,'input_tokens_details':{'cached_tokens':0 if warm else 12}}}})
        except (EOFError,ConnectionError,OSError): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_address[1],flush=True);server.serve_forever()
