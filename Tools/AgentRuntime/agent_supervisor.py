"""Trusted guest-only local capture supervisor. Never emits raw vendor output."""
import ctypes, hashlib, json, os, pathlib, re, resource, selectors, signal, subprocess, time
PROFILE='pinned-cli-local-capture-v1'
COMMAND_SECONDS=55
FLAGS=('--print','--no-session-persistence','--setting-sources','--strict-mcp-config','--mcp-config','--model')
SIZE=285493120
SHA='028ad6b4c0ed304a116eb1efa6f1d752630f6691aa70004a79406026a023b332'

def help_flags(data, *, coding=False):return {f:re.search(rb'(?<![A-Za-z0-9_-])'+re.escape(f.encode())+rb'(?![A-Za-z0-9_-])',data) is not None for f in FLAGS+(('--tools',) if coding else ())}
def coding_argv_matches(argv):
    return argv==['/opt/agent-probe/claude','--print','--no-session-persistence','--setting-sources','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--model','deepseek-flash','--tools','Bash,Read,Edit,Write,Glob,Grep']
def version_match(data):return data.strip()==b'2.1.309 (Claude Code)'
def emit(value):print(json.dumps(value,separators=(',',':')),flush=True)
def hashed(path):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        while True:
            b=f.read(1048576)
            if not b:break
            h.update(b)
    return h.hexdigest()
def limits():
    resource.setrlimit(resource.RLIMIT_CPU,(20,20));resource.setrlimit(resource.RLIMIT_FSIZE,(67108864,67108864));resource.setrlimit(resource.RLIMIT_NOFILE,(64,64))
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
def cleanup(p):
    try:os.killpg(p.pid,signal.SIGTERM)
    except ProcessLookupError:pass
    end=time.monotonic()+2
    while time.monotonic()<end:
        p.poll()
        try:os.killpg(p.pid,0)
        except ProcessLookupError:break
        time.sleep(.02)
    try:os.killpg(p.pid,signal.SIGKILL)
    except ProcessLookupError:pass
    p.wait(timeout=2)
    end=time.monotonic()+2
    while True:
        try:
            while os.waitpid(-p.pid,os.WNOHANG)[0]:pass
        except ChildProcessError:pass
        try:os.killpg(p.pid,0)
        except ProcessLookupError:return True
        if time.monotonic()>=end:raise RuntimeError('cleanup failed')
        time.sleep(.01)
def bounded_output(argv,env,cwd,seconds=8):
    p=subprocess.Popen(argv,env=env,cwd=cwd,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True,preexec_fn=limits)
    data=bytearray();end=time.monotonic()+seconds;selector=selectors.DefaultSelector();selector.register(p.stdout,selectors.EVENT_READ)
    try:
        while selector.get_map() and time.monotonic()<end:
            for key,_ in selector.select(.05):
                b=os.read(key.fileobj.fileno(),4096)
                if not b:selector.unregister(key.fileobj)
                elif len(data)+len(b)>65536:raise ValueError('output bound')
                else:data.extend(b)
        if selector.get_map():raise TimeoutError('version/help timeout')
        p.wait(timeout=max(.01,end-time.monotonic()))
        return p.returncode,bytes(data)
    finally:cleanup(p);p.stdout.close();selector.close()
def materialize():
    assert pathlib.Path('/sys/block/vdb/ro').read_text().strip()=='1'
    assert int(pathlib.Path('/sys/block/vdb/size').read_text())*512==SIZE+128
    path='/opt/agent-probe/claude';h=hashlib.sha256();left=SIZE
    with open('/dev/vdb','rb',buffering=0) as source,open(path,'xb',buffering=0) as out:
        while left:
            data=source.read(min(left,1048576))
            if not data:raise ValueError('short vendor disk')
            view=memoryview(data)
            while view:
                n=out.write(view)
                if not n:raise OSError('short materialization write')
                view=view[n:]
            h.update(data);left-=len(data)
        if source.read(128)!=bytes(128) or source.read(1) or h.hexdigest()!=SHA:raise ValueError('vendor digest')
    os.chmod(path,0o555)
    subprocess.run(['/bin/busybox','mount','-o','remount,ro','/opt/agent-probe'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
def main():
    if ctypes.CDLL(None).prctl(36,1,0,0,0)!=0:raise RuntimeError('subreaper')
    plan=json.loads(pathlib.Path('/runtime/guest-launch.json').read_text())
    profile=json.loads(pathlib.Path('/runtime/profile.json').read_text())['profile']
    assert profile in (PROFILE,'claude-broker-restricted-v1','claude-broker-coding-v1')
    coding=profile=='claude-broker-coding-v1'
    if profile in ('claude-broker-restricted-v1','claude-broker-coding-v1'):
        assert plan['profile']==profile
        emit({'phase':'clientProfile','profile':profile})
    if coding:assert coding_argv_matches(plan['argv'])
    closure=json.loads(pathlib.Path('/runtime/loader.json').read_text())
    assert all(hashed(p)==h for p,h in closure.items())
    assert hashed(plan['binary'])==SHA
    assert os.listdir('/sys/class/net')==['lo']
    assert int(pathlib.Path('/sys/class/net/lo/flags').read_text(),16)&1
    assert len(pathlib.Path('/proc/net/route').read_text().splitlines())==1
    env=plan['environment'];cwd=plan['cwd'];binary=plan['binary']
    for name in ('check-home','check-tmp','check-work'):os.mkdir('/run/agent-probe/'+name,0o700)
    check_env=dict(env,HOME='/run/agent-probe/check-home',TMPDIR='/run/agent-probe/check-tmp')
    check_cwd='/run/agent-probe/check-work'
    emit({'phase':'preflight','loaderDigestsMatch':True,'vendorDigestMatch':True,'onlyLoopbackUp':True,'noIPv4Route':True,'vendorReadOnly':True,'memAvailableKB':mem_available()})
    version_code,version=bounded_output([binary,'--version'],check_env,check_cwd)
    emit({'phase':'version','exit':version_code,'versionMatch':version_match(version)})
    if version_code or not version_match(version):return 1
    help_code,help_data=bounded_output([binary,'--help'],check_env,check_cwd)
    flags=help_flags(help_data,coding=coding);emit({'phase':'help','exit':help_code,'flags':flags})
    if help_code or not all(flags.values()):return 1
    for name in ('home','tmp','work'):os.mkdir('/run/agent-probe/'+name,0o700)
    # Independent capture process: JSON/ingress cannot delay the CLI timer.
    captureEnd=time.monotonic()+37
    cap=subprocess.Popen(['/usr/bin/python3','-B','/runtime/agent_supervisor.py','--capture'],env={'PATH':'/usr/bin:/bin','PYTHONDONTWRITEBYTECODE':'1'},cwd='/runtime',stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True,preexec_fn=limits)
    selector=selectors.DefaultSelector();selector.register(cap.stdout,selectors.EVENT_READ)
    buffer=bytearray();received=0;messages=[]
    def pump(wait=.05):
        nonlocal received
        for key,_ in selector.select(wait):
            chunk=os.read(key.fd,4096)
            if not chunk:selector.unregister(key.fileobj)
            received+=len(chunk)
            if received>16384:raise ValueError('capture output bound')
            buffer.extend(chunk)
            while b'\n' in buffer:
                line,_,rest=buffer.partition(b'\n');buffer[:]=rest
                messages.append(json.loads(line))
                if len(messages)>2:raise ValueError('capture message bound')
    p=None;reaped=False;cap_reaped=False
    try:
        readyEnd=time.monotonic()+2
        while not messages and cap.poll() is None and time.monotonic()<readyEnd:pump()
        if messages!=[{'captureReady':True}]:raise RuntimeError('capture not ready')
        p=subprocess.Popen(plan['argv'],env=env,cwd=cwd,stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True,preexec_fn=limits)
        pathlib.Path('/work/vendor-group').write_text(str(p.pid))
        pathlib.Path('/work/capture-group').write_text(str(cap.pid))
        p.stdin.write(plan['stdin_fixed_utf8'].encode());p.stdin.close()
        started={'phase':'vendorStarted','freshLaunchDirectories':True}
        if coding:started['codingArgvMatches']=coding_argv_matches(plan['argv'])
        emit(started)
        end=time.monotonic()+30;minimum=mem_available()
        while time.monotonic()<end and p.poll() is None and cap.poll() is None:
            pump(min(.05,max(0,end-time.monotonic())))
            minimum=min(minimum,mem_available())
        timed_out=p.poll() is None
        reaped=cleanup(p)
        while (cap.poll() is None or selector.get_map()) and time.monotonic()<captureEnd:pump()
        if cap.poll() is None or buffer or len(messages)!=2:raise RuntimeError('capture deadline/framing')
        cap_reaped=cleanup(cap);metadata=messages[1]
        if cap.returncode or set(metadata)!={'schema','fixture_only','records','ingress_bytes'} or metadata['schema']!=1 or metadata['fixture_only'] is not True:raise ValueError('capture result')
        emit({'phase':'capture','vendorExit':p.returncode,'probeTimeout':timed_out,'ownedGroupReaped':reaped,'captureExit':cap.returncode,'captureGroupReaped':cap_reaped,'records':metadata['records'],'ingressBytes':metadata['ingress_bytes'],'minMemAvailableKB':minimum,'vendorMaxRSSKB':resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss})
    finally:
        if p is not None and not reaped:cleanup(p)
        if not cap_reaped:cleanup(cap)
        cap.stdout.close();selector.close()
    return 0

def capture_worker():
    # Same entrypoint/lifetime; image marker explicitly opts into metrics.
    import capture
    original=capture.CaptureServer
    def ready(*args,**kwargs):
        server=original(*args,**kwargs)
        emit({'captureReady':True})
        return server
    capture.CaptureServer=ready
    __import__('sys').argv=['capture']
    if pathlib.Path('/runtime/structural-metrics-v1').is_file():
        __import__('sys').argv.append('--structural-metrics')
    if json.loads(pathlib.Path('/runtime/profile.json').read_text())['profile']=='claude-broker-restricted-v1':
        __import__('sys').argv.extend(['--restricted-profile','claude-broker-restricted-v1'])
    if json.loads(pathlib.Path('/runtime/profile.json').read_text())['profile']=='claude-broker-coding-v1':
        __import__('sys').argv.extend(['--coding-profile','claude-broker-coding-v1'])
    return capture.main()

def mem_available():
    return int(next(x.split()[1] for x in pathlib.Path('/proc/meminfo').read_text().splitlines() if x.startswith('MemAvailable:')))
if __name__=='__main__':
    try:
        if len(__import__('sys').argv)>1 and __import__('sys').argv[1]=='--materialize':materialize()
        elif len(__import__('sys').argv)>1 and __import__('sys').argv[1]=='--capture':raise SystemExit(capture_worker())
        else:raise SystemExit(main())
    except Exception:
        emit({'phase':'failure','boundedSupervisorFailure':True});raise SystemExit(1)
