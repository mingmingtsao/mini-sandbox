#!/usr/bin/env python3
"""Real signed VZ probe acceptance. Invoke through the repository build queue."""

import argparse
import base64
import hashlib
import json
import pathlib
import signal
import subprocess
import time
import image


def main():
    p = argparse.ArgumentParser()
    p.add_argument('binary')
    p.add_argument('image')
    p.add_argument('output')
    p.add_argument('--cancel-start', action='store_true')
    a = p.parse_args()
    out = image.legacy.reserve_output(a.output, pathlib.Path(__file__).resolve().parents[2])
    fixture = pathlib.Path(__file__).parent / 'fixture'
    before = {
        x.name: hashlib.sha256(image.read_regular(x, 65536)).hexdigest() for x in fixture.iterdir() if x.is_file()
    }
    with (out / 'stdout.jsonl').open('xb') as stdout, (out / 'stderr.txt').open('xb') as stderr:
        child = subprocess.Popen([a.binary, a.image, str(out)], stdout=stdout, stderr=stderr)
        if a.cancel_start:
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline and child.poll() is None:
                if b'"event":"vm.start"' in (out / 'stdout.jsonl').read_bytes():
                    child.send_signal(signal.SIGTERM)
                    break
                time.sleep(0.005)
        try:
            code = child.wait(timeout=85)
        except subprocess.TimeoutExpired:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            raise RuntimeError('outer timeout; owned child killed')
    rows = [json.loads(x) for x in (out / 'stdout.jsonl').read_text().splitlines() if x.startswith('{')]
    after = {x.name: hashlib.sha256(image.read_regular(x, 65536)).hexdigest() for x in fixture.iterdir() if x.is_file()}
    assert before == after, 'host fixture mutated'
    types = [r['event'] for r in rows]
    assert 'vm.stopped' in types and types.index('vm.stopped') < types.index('console.released'), 'unsettled teardown'
    config = next(r for r in rows if r['event'] == 'configuration')
    assert (config['NIC'], config['shares'], config['privateDisks']) == (0, 0, 1)
    if a.cancel_start:
        assert code == 1 and 'host.launch' not in types
        for required in (
            'vm.start',
            'vm.stopping',
            'start.callback',
            'stop.callback',
            'vm.stopped',
            'console.released',
        ):
            assert types.count(required) == 1, ('missing/duplicate lifecycle', required)
        start, stop, started, callback, stopped, released = (
            types.index(x)
            for x in ('vm.start', 'vm.stopping', 'start.callback', 'stop.callback', 'vm.stopped', 'console.released')
        )
        assert start < stop < started < callback < stopped < released, (
            'not pending-start cancellation with settled callbacks'
        )
        assert rows[stop].get('reason') == 'hostCancel', 'not actual host cancellation'
        assert (
            rows[stopped].get('actualState') == 'stopped'
            and rows[stopped].get('startPending') is False
            and rows[stopped].get('stopPending') is False
        ), 'unsettled state'
        assert not any(r['event'].startswith(('guest.', 'host.launch', 'accepted')) for r in rows[stop + 1 :]), (
            'post-stop protocol acceptance'
        )
        result = {'status': 'PASS', 'scope': 'startup cancellation', 'hostOriginalUnchanged': True, 'exit': code}
    else:
        assert code == 0, ('probe failed', code)
        chunks = {i: b'' for i in range(1, 9)}
        for row in rows:
            if row['event'] == 'guest.stdout':
                chunks[row['id']] += base64.b64decode(row['data'])
        stderr_chunks = b''.join(base64.b64decode(r['data']) for r in rows if r['event'] == 'guest.stderr')
        assert stderr_chunks == b'synthetic-stderr-channel\n', 'stderr channel not exercised'
        assert chunks[7] == b'descendant-ready\n' and chunks[8] == b'owned-group-reaped\n', 'owned group survived'
        task = json.loads(chunks[4])
        assert task['redExit'] == 1 and task['testExit'] == 0
        expected = hashlib.sha256(b'def add(a, b):\n    return a + b\n').hexdigest()
        assert task['afterSHA256'] == expected and expected.encode() in chunks[6]
        assert task['beforeSHA256'] == before['logic.py']
        assert any(r['event'] == 'host.cancel' for r in rows)
        assert any(r['event'] == 'guest.exit' and r['id'] == 5 and r['code'] == -9 and r['cancelled'] for r in rows)
        result = {
            'status': 'PASS',
            'scope': 'real no-NIC VM runtime fixture, not Agent',
            'versions': {str(i): chunks[i].decode().strip() for i in (1, 2, 3)},
            'task': task,
            'hostOriginalUnchanged': before == after,
            'commandCancellation': True,
            'ownedGroupReaped': True,
            'sameVMWriteRead': True,
            'freshPrivateDisk': True,
            'exit': code,
        }
    result['binarySHA256'] = hashlib.sha256(image.read_regular(a.binary, 16 * 1024 * 1024)).hexdigest()
    result['diskSHA256'] = hashlib.sha256(image.read_regular(out / 'private.raw', 67108864)).hexdigest()
    image.legacy.exclusive_write(out / 'result.json', (json.dumps(result, indent=2) + '\n').encode())
    print(json.dumps(result))


if __name__ == '__main__':
    main()
