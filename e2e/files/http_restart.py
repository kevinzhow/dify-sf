import ast,base64,hashlib,hmac,json,os,secrets,subprocess,time,urllib.request,urllib.error,urllib.parse
from pathlib import Path
from types import SimpleNamespace
from typing import Literal

import argparse
parser=argparse.ArgumentParser(description="Bounded, isolated HTTP/signature/restart acceptance against the production image.")
parser.add_argument("--image", default="dify-sf-server")
parser.add_argument("--dify-source", type=Path, required=True, help="Dify 1.17.1 checkout at 8387590ace4a094de812b7847fc6a4c3a27cd52b")
parser.add_argument("--output", type=Path, required=True, help="Private persistent evidence directory, outside the checkout")
parser.add_argument("--port", type=int, default=19098)
args=parser.parse_args()
out=args.output.resolve()
out.mkdir(parents=True,exist_ok=True)
os.chmod(out,0o700)
tag="files-http-"+str(os.getpid())
net=tag+"-net";pg=tag+"-pg";srv=tag+"-server"
base="http://127.0.0.1:"+str(args.port)
storage=out/'storage';storage.mkdir(exist_ok=True)
os.chmod(storage,0o700)
envfile=out/'private.env'
key=secrets.token_urlsafe(48)
envfile.write_text('COLLAB_FILES_SIGNING_KEY='+key+'\n')
os.chmod(envfile,0o600)
checks=[]
def check(name,condition):
    if not condition: raise AssertionError(name)
    checks.append(name)
def run(*cmd):return subprocess.check_output(cmd,stderr=subprocess.STDOUT).decode().strip()
def request(method,path,body=None,token=None,headers=None):
    h=dict(headers or {})
    if token:h['Authorization']='Bearer '+token
    if isinstance(body,dict):body=json.dumps(body).encode();h['Content-Type']='application/json'
    req=urllib.request.Request(base+path if path.startswith('/') else path,data=body,method=method,headers=h)
    try:r=urllib.request.urlopen(req,timeout=20)
    except urllib.error.HTTPError as e:r=e
    with r:return r.status,r.read(),dict(r.headers)
def js(method,path,body=None,token=None):
    status,b,h=request(method,path,body,token)
    return status,json.loads(b),h
def upload(token,name,content):
    boundary='boundary'+secrets.token_hex(16)
    payload=('--'+boundary+'\r\nContent-Disposition: form-data; name="file"; filename="'+name+'"\r\nContent-Type: application/octet-stream\r\n\r\n').encode()+content+('\r\n--'+boundary+'--\r\n').encode()
    status,b,_=request('POST','/v1/files/upload',payload,token,{'Content-Type':'multipart/form-data; boundary='+boundary})
    check('upload '+name,status==201)
    return json.loads(b)
def start():
    run('docker','run','-d','--name',srv,'--memory','1g','--cpus','1','--network',net,
        '--user',str(os.getuid())+':'+str(os.getgid()),'--env-file',str(envfile),
        '-e','HOME=/tmp','-e','COLLAB_HTTP_HOST=0.0.0.0','-e','COLLAB_HTTP_PORT=8080',
        '-e','COLLAB_DB_HOST='+pg,'-e','COLLAB_DB_USER=collab','-e','COLLAB_DB_PASSWORD=collab','-e','COLLAB_DB_NAME=collab',
        '-e','COLLAB_FILES_DIRECTORY=/uploads','-e','COLLAB_FILES_URL='+base,
        '-p','127.0.0.1:'+str(args.port)+':8080','-v',str(storage)+':/uploads',args.image)
    for _ in range(100):
        try:
            status,j,_=js('GET','/v1/setup')
            if status==200:return
        except Exception:pass
        time.sleep(.2)
    raise RuntimeError('server not ready')
try:
    run('docker','network','create',net)
    run('docker','run','-d','--name',pg,'--memory','512m','--cpus','.5','--network',net,
        '-e','POSTGRES_USER=collab','-e','POSTGRES_PASSWORD=collab','-e','POSTGRES_DB=collab','postgres:15-alpine')
    for _ in range(100):
        if subprocess.run(['docker','exec',pg,'pg_isready','-U','collab','-d','collab'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:break
        time.sleep(.2)
    start()
    password=secrets.token_urlsafe(24);email='file-test@example.test'
    status,auth,_=js('POST','/v1/setup',{'email':email,'password':password,'name':'File Test Owner'})
    check('owner setup',status==201)
    token=auth['access_token']
    status,features,_=js('GET','/v1/system-features')
    check('real configured file capability',features['enable_file_upload'] is True)
    text=('🌲é中'*1002).encode()
    file=upload(token,'unicode.txt',text)
    status,body,head=request('GET',file['preview_url'])
    check('anonymous signed bytes',status==200 and body==text)
    status,b,_=js('GET','/v1/files/'+file['id']+'/preview',token=token)
    check('3000 codepoints',status==200 and b['content']==text.decode()[:3000])
    status,partial,head=request('GET',file['preview_url'],headers={'Range':'bytes=0-3'})
    check('range bytes and headers',status==206 and partial=='🌲'.encode() and head.get('Content-Range')=='bytes 0-3/'+str(len(text)))
    etag=head['ETag']
    check('etag 304',request('GET',file['preview_url'],headers={'If-None-Match':etag})[0]==304)
    status,b,_=request('GET',file['preview_url'],headers={'Range':'bytes=0-3','If-Range':'"different"'})
    check('if-range full body',status==200 and b==text)
    check('suffix bytes',request('GET',file['preview_url'],headers={'Range':'bytes=-3'})[1]==text[-3:])
    # Execute the original upstream methods, stripped only of import/decorator context.
    source=args.dify_source/'api/core/app/workflow/file_runtime.py'
    check('pinned original Dify source',hashlib.sha256(source.read_bytes()).hexdigest()=='c7f6277de20046d553409a7702e0fab315babef277ac6f04ba7b22fe016130f7')
    tree=ast.parse(source.read_text());original=next(n for n in tree.body if isinstance(n,ast.ClassDef) and n.name=='DifyWorkflowFileRuntime')
    names={'verify_preview_signature','_secret_key','_sign_query'}
    methods=[]
    for n in original.body:
        if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)) and n.name in names:
            n.decorator_list=[ast.Name(id='staticmethod',ctx=ast.Load())] if n.name=='_secret_key' else []
            methods.append(n)
    klass=ast.ClassDef(name='Oracle',bases=[],keywords=[],body=methods,decorator_list=[])
    module=ast.fix_missing_locations(ast.Module(body=[klass],type_ignores=[]))
    namespace={'os':os,'time':time,'hmac':hmac,'hashlib':hashlib,'base64':base64,'Literal':Literal,
        'dify_config':SimpleNamespace(SECRET_KEY=key,FILES_ACCESS_TIMEOUT=300)}
    exec(compile(module,str(source),'exec'),namespace)
    oracle=namespace['Oracle']()
    u=urllib.parse.urlsplit(file['preview_url']);q={k:v[0] for k,v in urllib.parse.parse_qs(u.query).items()}
    check('Dify 1.17.1 verifies Swift URL',oracle.verify_preview_signature(preview_kind='file',file_id=file['id'],**q))
    q2=oracle._sign_query(payload='file-preview|'+file['id'])
    original_url=base+'/files/'+file['id']+'/file-preview?'+urllib.parse.urlencode(q2)
    check('Swift verifies original Dify signature',request('GET',original_url)[1]==text)
    check('image kind distinct',request('GET',original_url.replace('/file-preview?','/image-preview?'))[0]==404)
    image_bytes=base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j3ioAAAAASUVORK5CYII=")
    picture=upload(token,'original.png',image_bytes)
    image_query=oracle._sign_query(payload='image-preview|'+picture['id'])
    image_url=base+'/files/'+picture['id']+'/image-preview?'+urllib.parse.urlencode(image_query)
    check('original Dify image signature delivers image bytes',request('GET',image_url)[1]==image_bytes)

    old=str(int(time.time())-301);nonce=secrets.token_hex(16)
    sig=base64.urlsafe_b64encode(hmac.new(key.encode(),('file-preview|'+file['id']+'|'+old+'|'+nonce).encode(),hashlib.sha256).digest()).decode()
    expired=base+'/files/'+file['id']+'/file-preview?'+urllib.parse.urlencode({'timestamp':old,'nonce':nonce,'sign':sig})
    check('expired signed URL',request('GET',expired)[0]==404)
    run('docker','kill','--signal','KILL',srv)
    run('docker','rm',srv)
    start()
    check('independent process restart preserves signed bytes',request('GET',original_url)[1]==text)
    run('docker','stop','--time','10',srv)
    check('production image graceful shutdown',run('docker','inspect','--format','{{.State.ExitCode}}',srv)=='0')
    run('docker','rm',srv)
    start()
    check('second fresh process keeps bytes',request('GET',original_url)[1]==text)
    (out/'result.json').write_text(json.dumps({'checks':checks,'count':len(checks)},indent=2)+'\n')
    print(json.dumps({'checksPassed':len(checks)}))
finally:
    try:(out/'server.log').write_text(run('docker','logs',srv))
    except Exception:pass
    for name in (srv,pg):subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    subprocess.run(['docker','network','rm',net],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    envfile.unlink(missing_ok=True)
