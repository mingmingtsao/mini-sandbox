#!/usr/bin/env python3
"""Actual pinned CLI VM driver; no vendor execution on host."""
import base64, hashlib, json, os, pathlib, signal, subprocess, sys, time

def run(host,image,vendor,out,cancel=False,cancel_start=False,restricted=False):
    if restricted:
        manifest=json.loads((pathlib.Path(image)/'runtime.json').read_text())
        assert manifest['agentProbeProfile']['name']=='pinned-cli-local-capture-v1'
        assert manifest['agentProbeProfile']['clientProfile']=='claude-broker-restricted-v1'
        assert manifest['agentProbeProfile']['structuralMetricsV1'] is True
    out=pathlib.Path(out);out.mkdir(mode=0o700)
    with (out/'stdout.jsonl').open('xb') as stdout,(out/'stderr.txt').open('xb') as stderr:
        p=subprocess.Popen([host,image,str(out),vendor],stdout=stdout,stderr=stderr)
        end=time.monotonic()+115;sent=False
        while p.poll() is None and time.monotonic()<end:
            if (cancel or cancel_start) and not sent:
                rows=[json.loads(l) for l in (out/'stdout.jsonl').read_text().splitlines() if l.startswith('{') and l.endswith('}')]
                chunks=b''.join(base64.b64decode(r['data']) for r in rows if r['event']=='guest.stdout')
                ready=any(r['event']=='vm.start' for r in rows) if cancel_start else b'"phase":"vendorStarted"' in chunks
                if ready:p.send_signal(signal.SIGTERM);sent=True
            time.sleep(.005 if cancel_start else .02)
        if p.poll() is None:
            p.terminate()
            try:p.wait(timeout=12)
            except subprocess.TimeoutExpired:p.kill();p.wait();raise RuntimeError('unsettled outer timeout')
    rows=[json.loads(l) for l in (out/'stdout.jsonl').read_text().splitlines() if l.startswith('{')]
    kinds=[r['event'] for r in rows]
    assert 'vm.stopped' in kinds and kinds.index('vm.stopped')<kinds.index('console.released'),'unsettled stop'
    stopped=next(r for r in rows if r['event']=='vm.stopped')
    assert stopped['actualState']=='stopped' and not stopped['startPending'] and not stopped['stopPending']
    config=next(r for r in rows if r['event']=='configuration');assert (config['NIC'],config['shares'],config['RAM'],config['privateDisks'])==(0,0,1073741824,2)
    chunks=b''
    for r in rows:
        if r['event']=='guest.stdout':
            b=base64.b64decode(r['data']);assert hashlib.sha256(b).hexdigest()==r['sha256'];chunks+=b
        assert r['event']!='guest.stderr','unexpected supervisor stderr'
    metadata=[json.loads(l) for l in chunks.splitlines()]
    result={'scope':'actual vendor CLI protocol only, not model/Agent success','hostExit':p.returncode,'cancelSent':sent,'stopped':True,'metadata':metadata}
    if restricted and not cancel_start:
        assert {'phase':'clientProfile','profile':'claude-broker-restricted-v1'} in metadata
        result['profile']='claude-broker-restricted-v1'
    if cancel or cancel_start:
        assert sent and p.returncode==1
        index=kinds.index('vm.stopping');assert rows[index]['reason']=='hostCancel'
        assert not any(r['event'].startswith(('guest.','host.launch')) for r in rows[index+1:])
        if cancel_start:
            ordered=[kinds.index(e) for e in ('vm.start','vm.stopping','start.callback','stop.callback','vm.stopped','console.released')]
            assert ordered==sorted(ordered) and 'host.launch' not in kinds,'missed pending-start cancellation'
        result['vendorExit']=None # VM stopped; no vendor wait status was observed.
        result['cancellationPhase']='pending-start' if cancel_start else 'active-vendor'
    else:assert p.returncode==0,'actual probe failed; inspect metadata'
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
if __name__=='__main__':run(*sys.argv[1:5],cancel='--cancel-active' in sys.argv[5:],cancel_start='--cancel-start' in sys.argv[5:],restricted='--claude-broker-restricted-v1' in sys.argv[5:])
