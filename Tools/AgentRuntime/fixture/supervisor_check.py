"""Guest-only regression after the real vendor exits; no vendor output."""
import os,pathlib,sys,subprocess
sys.path.insert(0,'/runtime')
import agent_supervisor as m
for name in ('vendor-group','capture-group'):
    group=int(pathlib.Path('/work/'+name).read_text())
    try:os.killpg(group,0)
    except ProcessLookupError:pass
    else:raise RuntimeError('owned group survived')
actual=subprocess.Popen;children=[]
def launch(*args,**kwargs):
    p=actual(*args,**kwargs);children.append(p);return p
m.subprocess.Popen=launch
try:
    try:m.bounded_output(['/usr/bin/python3','-c','print("X"*70000)'],{},'/work/project',1)
    except ValueError:pass
    else:raise AssertionError('output bound')
    try:m.bounded_output(['/usr/bin/python3','-c','import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(30)'],{},'/work/project',.5)
    except TimeoutError:pass
    else:raise AssertionError('deadline')
    assert children[-1].returncode==-9
    for child in children:
        assert child.returncode is not None
        try:os.killpg(child.pid,0)
        except ProcessLookupError:pass
        else:raise AssertionError('group survived')
    print('{"nextCommandGroupsAbsent":true,"stubbornChildKILLReaped":true,"outputBoundRejected":true}')
finally:m.subprocess.Popen=actual
