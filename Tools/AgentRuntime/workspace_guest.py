#!/usr/bin/python3
"""Fixed data-only workspace fixture. Guest-only execution; no host paths."""
import base64, hashlib, json, os, pathlib, socket, stat, struct, subprocess, time, unicodedata
ROOT = pathlib.Path('/work/transfer')
MAX_FILE=4*1024*1024
MAX_TOTAL=16*1024*1024

def sha(data): return hashlib.sha256(data).hexdigest()
def treehash(files):
    return sha(''.join(p+'\0'+str(len(files[p]))+'\0'+sha(files[p])+'\n' for p in sorted(files)).encode())
def pairs(items):
    result={}
    for k,v in items:
        if k in result: raise ValueError('duplicate')
        result[k]=v
    return result
def no_float(value): raise ValueError('numeric token')
def integer(value, maximum):
    if type(value) is not int or not 0<=value<=maximum: raise ValueError('integer')
    return value
def pathcheck(path):
    if type(path) is not str or len(path.encode())>1024: raise ValueError('path')
    parts=path.split('/')
    if not 1<=len(parts)<=16: raise ValueError('depth')
    for p in parts:
        q=p.lower()
        if not p or p in ('.','..') or len(p.encode())>255 or unicodedata.normalize('NFC',p)!=p or any(ord(x)<32 or ord(x)==127 or x in '\\:' for x in p): raise ValueError('component')
        if q in ('.git','.ssh','.aws','.azure','.gnupg','.config','.npmrc','.netrc','.pypirc','credentials','id_rsa','id_ed25519','.env') or q.startswith('.env.') or q.endswith(('.pem','.key','.p12')): raise ValueError('excluded')
    return parts

def snapshot():
    files={};names={};entries=0;total=0
    for directory,dirs,leaves in os.walk(ROOT,followlinks=False):
        for name in dirs+leaves:
            p=pathlib.Path(directory)/name;rel=str(p.relative_to(ROOT));pathcheck(rel)
            entries+=1
            if entries>1000: raise ValueError('count')
            folded=rel.casefold()
            if folded in names: raise ValueError('collision')
            names[folded]=rel
            st=p.lstat()
            if stat.S_ISDIR(st.st_mode): continue
            if not stat.S_ISREG(st.st_mode) or st.st_nlink!=1 or st.st_size>MAX_FILE: raise ValueError('type')
            fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
            try:
                current=os.fstat(fd)
                if (current.st_dev,current.st_ino)!=(st.st_dev,st.st_ino): raise ValueError('mutation')
                with os.fdopen(fd,'rb',closefd=False) as f: data=f.read(MAX_FILE+1)
                if len(data)!=st.st_size or len(data)>MAX_FILE: raise ValueError('size')
            finally: os.close(fd)
            total+=len(data)
            if total>MAX_TOTAL: raise ValueError('total')
            files[rel]=data
    return files

def main():
    deadline=time.monotonic()+60
    s=socket.socket(socket.AF_VSOCK,socket.SOCK_STREAM);s.settimeout(5);s.connect((2,4062))
    def send(f):
        b=json.dumps(f,separators=(',',':'),sort_keys=True).encode()
        if len(b)>16384 or time.monotonic()>=deadline: raise ValueError('budget')
        s.sendall(struct.pack('>I',len(b))+b)
    def readexact(n):
        data=b''
        while len(data)<n:
            if time.monotonic()>=deadline: raise ValueError('deadline')
            b=s.recv(min(4096,n-len(data)))
            if not b: raise ValueError('EOF')
            data+=b
        return data
    def recv():
        n=struct.unpack('>I',readexact(4))[0]
        if not 0<n<=16384: raise ValueError('frame')
        return json.loads(readexact(n),object_pairs_hook=pairs,parse_float=no_float,parse_constant=no_float)
    send(dict(v=1,type='ready'))
    files={};names={};seq=0;current=None;count=None;total=None;received=0
    while True:
        f=recv()
        if type(f) is not dict or integer(f.get('v'),1)!=1 or integer(f.get('seq'),8191)!=seq: raise ValueError('sequence')
        kind=f.get('type')
        expected={'begin':{'count','total'},'file':{'path','size','sha256'},'chunk':{'offset','data'},'end':set(),'complete':{'sha256'}}
        if kind not in expected or set(f)!=expected[kind]|{'v','type','seq'}: raise ValueError('fields')
        if kind=='begin':
            if count is not None: raise ValueError('begin')
            count=integer(f['count'],1000);total=integer(f['total'],MAX_TOTAL)
        elif kind=='file':
            if count is None or current is not None or len(files)>=count: raise ValueError('file order')
            parts=pathcheck(f['path']);prefix=''
            for i,part in enumerate(parts):
                prefix=part if not prefix else prefix+'/'+part;k=prefix.casefold()
                if k in names and (names[k]!=prefix or i==len(parts)-1 or prefix in files): raise ValueError('collision')
                names[k]=prefix
            if len(names)>1000: raise ValueError('entries')
            size=integer(f['size'],MAX_FILE)
            if size>total-received: raise ValueError('total')
            current=f['path'];digest=f['sha256'];data=bytearray()
        elif kind=='chunk':
            if current is None or integer(f['offset'],MAX_FILE)!=len(data): raise ValueError('offset')
            chunk=base64.b64decode(f['data'],validate=True)
            if not 0<len(chunk)<=4096 or len(chunk)>size-len(data): raise ValueError('chunk')
            data.extend(chunk)
        elif kind=='end':
            if current is None or len(data)!=size or sha(data)!=digest: raise ValueError('digest')
            files[current]=bytes(data);received+=len(data);current=None
        elif kind=='complete':
            if current is not None or count!=len(files) or received!=total or treehash(files)!=f['sha256']: raise ValueError('complete')
        send(dict(v=1,type='ack',seq=seq));seq+=1
        if kind=='complete': break
    ROOT.mkdir(mode=0o700) # new private fixed guest root, never caller-selected
    for p,data in sorted(files.items()):
        path=ROOT/p;path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as out: out.write(data)
    env={'PATH':'/usr/bin:/bin','HOME':'/work','TMPDIR':'/work/tmp','PYTHONDONTWRITEBYTECODE':'1'}
    def test():
        return subprocess.run(['/usr/bin/python3','-B','test_logic.py'],cwd=ROOT,env=env,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=8).returncode
    red=test()
    if red!=1: raise ValueError('expected failing guest test')
    logic=ROOT/'logic.py';before=logic.read_bytes();after=before.replace(b'return a - b',b'return a + b')
    if before==after: raise ValueError('fixture edit')
    logic.write_bytes(after)
    green=test()
    if green!=0: raise ValueError('guest test failed')
    tested=snapshot()
    receipt=json.dumps({'redExit':red,'testExit':green,'testedSHA256':treehash(tested)},sort_keys=True,separators=(',',':')).encode()
    (ROOT/'guest-result.json').write_bytes(receipt)
    result=snapshot();seq=0
    def emit(kind,**kw):
        nonlocal seq
        send(dict(v=1,type=kind,seq=seq,**kw));seq+=1
    emit('begin',count=len(result),total=sum(map(len,result.values())))
    for p,data in sorted(result.items()):
        emit('file',path=p,size=len(data),sha256=sha(data))
        for offset in range(0,len(data),4096): emit('chunk',offset=offset,data=base64.b64encode(data[offset:offset+4096]).decode())
        emit('end')
    emit('complete',sha256=treehash(result))
    # Retain guest; the host revokes the connection and stops the whole VM.
    try: s.recv(1)
    except OSError: pass
    s.close()
if __name__=='__main__':
    try: main()
    except Exception: print('WORKSPACE_FIXTURE_REJECTED',flush=True)
