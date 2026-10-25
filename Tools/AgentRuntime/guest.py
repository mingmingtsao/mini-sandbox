#!/usr/bin/python3
"""Guest-only runtime executor. No IP listener and no model credentials."""
import base64, ctypes, hashlib, json, os, resource, selectors, signal, socket, subprocess, time
from protocol import Parser, encode

def child_limits():
    resource.setrlimit(resource.RLIMIT_CPU,(20,20));resource.setrlimit(resource.RLIMIT_FSIZE,(64*1024*1024,64*1024*1024));resource.setrlimit(resource.RLIMIT_NOFILE,(64,64))

def finish_group(active):
    """Only the group created by our Popen(start_new_session=True).
    Subreaper adoption permits reaping orphaned group descendants; setsid escapes
    are explicitly outside this group-only boundary.
    """
    group=active.pid
    try:os.killpg(group,signal.SIGKILL)
    except ProcessLookupError:pass
    active.wait(timeout=2)
    end=time.monotonic()+2
    while True:
        try:
            while os.waitpid(-group,os.WNOHANG)[0]:pass
        except ChildProcessError:pass
        try:os.killpg(group,0)
        except ProcessLookupError:return
        if time.monotonic()>=end:raise RuntimeError('owned group did not settle')
        time.sleep(.01)

def main():
    # Linux guest only: adopt orphaned descendants before the first command.
    if ctypes.CDLL(None,use_errno=True).prctl(36,1,0,0,0)!=0:raise OSError('subreaper unavailable')
    s=socket.socket(socket.AF_VSOCK,socket.SOCK_STREAM);s.settimeout(5);s.connect((2,4060))
    parser=Parser(); active=None; selector=selectors.DefaultSelector();selector.register(s,selectors.EVENT_READ,'control')
    def send(kind,id,**kw):s.sendall(encode(dict(v=1,type=kind,id=id,**kw)))
    send('hello',0,kernel=open('/proc/sys/kernel/osrelease').read().strip(),interfaces=os.listdir('/sys/class/net'),workdir='/work/project',fresh=not os.path.exists('/work/session-marker'))
    agent_profile=os.path.exists('/runtime/profile.json')
    last=0;deadline=time.monotonic()+(75 if agent_profile else 60);total=0;cancelled=False
    try:
        while time.monotonic()<deadline:
            for key,_ in selector.select(0.05):
                if key.data=='control':
                    data=s.recv(4096)
                    if not data:return
                    for frame in parser.feed(data):
                        if frame['type']=='stop':return
                        if frame['type']=='cancel':
                            if active is None or frame['id']!=last:raise ValueError('cancel ID')
                            os.killpg(active.pid,signal.SIGKILL);cancelled=True
                        elif frame['type']=='launch':
                            if active is not None or frame['id']!=last+1:raise ValueError('launch order')
                            argv=frame.get('argv')
                            if not isinstance(argv,list) or not 1<=len(argv)<=16 or any(not isinstance(x,str) or len(x)>4096 or '\0' in x for x in argv):raise ValueError('argv')
                            if argv[0] not in ('/usr/bin/node','/usr/bin/python3','/usr/bin/git'):raise ValueError('executable')
                            if set(frame)!={'v','type','id','argv'}:raise ValueError('launch fields')
                            last=frame['id'];cancelled=False
                            active=subprocess.Popen(argv,cwd='/work/project',env={'PATH':'/usr/bin:/bin','HOME':'/work','TMPDIR':'/work/tmp','PYTHONDONTWRITEBYTECODE':'1'},stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True,preexec_fn=child_limits)
                            command_end=time.monotonic()+(55 if agent_profile else 15)
                            for stream,kind in ((active.stdout,'stdout'),(active.stderr,'stderr')):
                                os.set_blocking(stream.fileno(),False);selector.register(stream,selectors.EVENT_READ,kind)
                        else:raise ValueError('unexpected control')
                else:
                    data=os.read(key.fileobj.fileno(),4096)
                    if not data:selector.unregister(key.fileobj);key.fileobj.close()
                    else:
                        total+=len(data)
                        if total>262144:raise ValueError('output budget')
                        send(key.data,last,data=base64.b64encode(data).decode(),sha256=hashlib.sha256(data).hexdigest())
            if active:
                if time.monotonic()>=command_end:os.killpg(active.pid,signal.SIGKILL);cancelled=True
                if active.poll() is not None and len(selector.get_map())==1:
                    finish_group(active)
                    send('exit',last,code=active.returncode,cancelled=cancelled);active=None
    finally:
        if active:
            finish_group(active)
        s.close()
if __name__=='__main__':main()
