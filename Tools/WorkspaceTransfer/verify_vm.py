#!/usr/bin/env python3
"""Verify final signed fixture: normal, partial receive cancellation, fresh VM."""

import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time


def digest(p):
    h = hashlib.sha256()
    with p.open('rb') as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def main():
    binary, image, out = map(pathlib.Path, sys.argv[1:])
    os.umask(0o077)
    out.mkdir(mode=0o700)
    subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)
    results = []
    disks = []
    for name, mode in [
        ('normal', 'normal'),
        ('cancel', 'cancel'),
        ('fresh', 'normal'),
        ('after-vm', 'cancel-after-vm'),
        ('before-rename', 'cancel-before-rename'),
        ('after-rename', 'cancel-after-rename'),
    ]:
        session = out / name
        session.mkdir(mode=0o700)
        with (session / 'events.jsonl').open('xb') as log:
            child = subprocess.Popen(
                [str(binary), str(image), str(session), mode], stdout=log, stderr=subprocess.STDOUT
            )
            try:
                if mode.startswith('cancel-'):
                    deadline = time.monotonic() + 75
                    signalled = False
                    while child.poll() is None and time.monotonic() < deadline:
                        complete = (session / 'events.jsonl').read_text().splitlines()
                        if any('"event":"workspace.awaitCancel"' in line for line in complete):
                            child.terminate()  # only the owned Popen child
                            signalled = True
                            break
                        time.sleep(0.005)
                    assert signalled, ('cancellation barrier missing', name)
                code = child.wait(timeout=85)
            except (subprocess.TimeoutExpired, AssertionError):
                if child.poll() is None:
                    child.terminate()
                try:
                    child.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
                raise
        assert code == 0, ('fixture failed', name, code)
        rows = [json.loads(x) for x in (session / 'events.jsonl').read_text().splitlines()]
        events = [r['event'] for r in rows]
        assert events.count('workspace.quota') == 1
        quota = rows[events.index('workspace.quota')]
        assert (
            quota['installedF03']
            and quota['snapshotMatched']
            and quota['fixtureOnly']
            and quota['messageBytes'] == 16384
        )
        assert quota['hostTask'] is True
        assert events.index('workspace.quota') < events.index('configuration')
        config = rows[events.index('configuration')]
        assert (config['NIC'], config['shares'], config['privateDisks'], config['controlPort']) == (0, 0, 1, 4062)
        for event in [
            'vm.start',
            'start.callback',
            'accepted',
            'vm.stopping',
            'stop.callback',
            'vm.stopped',
            'console.released',
            'result',
            'workspace.fixture',
        ]:
            assert events.count(event) == 1, (name, event)
        stopping, callback, stopped, released, result = [
            events.index(x) for x in ['vm.stopping', 'stop.callback', 'vm.stopped', 'console.released', 'result']
        ]
        assert stopping < callback < stopped < released < result
        assert (
            rows[stopped]['actualState'] == 'stopped'
            and not rows[stopped]['startPending']
            and not rows[stopped]['stopPending']
        )
        assert not any(
            x in events[stopping + 1 :] for x in ['accepted', 'workspace.sealed', 'workspace.midTransferCancel']
        )
        fixture = rows[-1]
        assert events.count('workspace.taskMetrics') == 1
        metrics = rows[events.index('workspace.taskMetrics')]
        assert (
            metrics['payloadReserved']
            == metrics['diskReserved']
            == metrics['diskCurrent']
            == metrics['diskOrphaned']
            == 0
        )
        assert metrics['input'] > 0 and metrics['input'] <= 4 * 1024 * 1024
        assert metrics['diskPeak'] <= metrics['diskReservedPeak'] <= 1024 * 1024
        if mode == 'cancel':
            assert (
                metrics['input'] == 4096
                and metrics['payloadCurrent'] == metrics['diskCommitted'] == metrics['diskWritten'] == 0
            )
        elif mode == 'cancel-after-vm':
            assert metrics['diskCommitted'] == metrics['diskWritten'] == 0
        elif mode == 'cancel-before-rename':
            assert (
                metrics['diskCommitted'] == metrics['input']
                and metrics['diskWritten'] == 2 * metrics['input']
                and metrics['diskReleased'] == metrics['input']
            )
        else:
            assert (
                metrics['diskCommitted'] == metrics['diskWritten'] == 2 * metrics['input']
                and metrics['diskReleased'] == 0
            )
        if mode == 'cancel':
            assert events.count('workspace.midTransferCancel') == 1 and 'workspace.sealed' not in events
            assert rows[events.index('workspace.midTransferCancel')]['acceptedBytes'] == 4096
            assert (
                rows[result]['exitCode'] == 1
                and fixture['cancelled']
                and not fixture['exported']
                and fixture['originalUnchanged']
            )
            assert not (session / 'export').exists() and not (session / 'stale-export').exists()
            assert not any(p.name.startswith('quarantine-') for p in (session / 'store').iterdir())
        elif mode.startswith('cancel-'):
            assert events.count('workspace.sealed') == 1 and rows[result]['exitCode'] == 0
            assert events.count('workspace.awaitCancel') == 1
            assert fixture['cancelled'] and fixture['originalUnchanged']
            if mode == 'cancel-after-rename':
                assert fixture['committed'] and fixture['exported'] and fixture['oldWorkflowRejected']
                assert (session / 'export' / 'logic.py').is_file() and not (session / 'retry').exists()
            else:
                assert not fixture['exported'] and not (session / 'export').exists()
                if mode == 'cancel-after-vm':
                    assert fixture['writtenBytes'] == 0
                    assert not any(p.name.startswith('quarantine-') for p in (session / 'store').iterdir())
                else:
                    assert fixture['writtenBytes'] > 0 and fixture['diskReleased'] == fixture['writtenBytes']
                    assert not any(p.name.startswith('.workspace-stage-') for p in session.iterdir())
        else:
            assert events.count('workspace.sealed') == 1 and rows[result]['exitCode'] == 0
            assert fixture['guestRedExit'] == 1 and fixture['guestTestExit'] == 0
            assert (
                fixture['originalUnchanged'] and fixture['exportMatchesTestedBytes'] and fixture['staleReviewRejected']
            )
            assert not (session / 'stale-export').exists()
        disks.append((session / 'private.raw').stat().st_ino)
        results.append(
            {'session': name, **fixture, 'taskMetrics': metrics, 'eventsSHA256': digest(session / 'events.jsonl')}
        )
    assert len(set(disks)) == 6
    assert results[0]['sha256'] == results[2]['sha256']
    report = {
        'scope': 'actual VM workspace transport + trusted synthetic fixture only',
        'sessions': results,
        'distinctFreshDisks': True,
        'binarySHA256': digest(binary),
        'imageSHA256': digest(image / 'runtime.cpio.gz'),
        'manifestSHA256': digest(image / 'runtime.json'),
    }
    with (out / 'result.json').open('x') as f:
        json.dump(report, f, indent=2)
        f.write('\n')
    print(json.dumps(report, sort_keys=True))


if __name__ == '__main__':
    main()
