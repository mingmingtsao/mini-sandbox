#!/usr/bin/env python3
"""Opt-in REAL VM lifecycle regression. Run only via the local build/VM queue."""
import argparse
import hashlib
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import time


def events(path):
    if not path.exists():
        return []
    # Only complete durable JSONL records can trigger cancellation.
    lines = path.read_bytes().splitlines(keepends=True)
    return [json.loads(line) for line in lines if line.endswith(b'\n')]


def attempt(args, root, name, cancel):
    evidence = root / name  # VMProbe requires a new directory.
    result = {'name': name, 'evidence': str(evidence), 'signals': []}
    with (root / (name + '.stdout')).open('wb') as out, (root / (name + '.stderr')).open('wb') as err:
        p = subprocess.Popen([str(args.probe), '--run', '--bundle', str(args.bundle), '--evidence-dir', str(evidence)], stdout=out, stderr=err)
        result['pid'] = p.pid
        deadline = time.monotonic() + 75
        try:
            while p.poll() is None:
                seen = events(evidence / 'security-events.jsonl')
                ops = [e['operation'] for e in seen]
                if cancel and not result['signals'] and 'vm.start' in ops:
                    result['operationsAtSignal'] = ops
                    p.send_signal(signal.SIGINT)  # This runner's exact child only.
                    result['signals'].append({'signal': 'SIGINT', 'pid': p.pid})
                if time.monotonic() >= deadline:
                    result['timeout'] = True
                    p.kill()  # Exact owned PID; timeout is NEVER a clean stop.
                    break
                time.sleep(0.001)
            result['exitCode'] = p.wait(timeout=5)
        finally:
            if p.poll() is None:
                p.kill()
                p.wait(timeout=5)
    seen = events(evidence / 'security-events.jsonl')
    ops = [e['operation'] for e in seen]
    result['ordering'] = [{'operation': e['operation'], 'reason': e['reason'], 'hostSequence': e['hostSequence']} for e in seen if e['operation'] != 'vm.console']
    failures = []
    def require(ok, message):
        if not ok:
            failures.append(message)
    require(result['exitCode'] == (1 if cancel else 0), 'wrong exit (abort is not cancellation)')
    require(not result.get('timeout'), 'runner timeout')
    require('vm.stopped' in ops, 'missing actual stopped record')
    require((evidence / 'result.json').exists(), 'missing result.json')
    require(any(e['operation'] == 'vm.stopped' and e['reason'] == 'actual VZ state stopped' and e['origin'] == 'hostEnforcement' and e['outcome'] == 'completed' for e in seen), 'missing completed host VZ stopped evidence')
    if (evidence / 'result.json').exists():
        summary = json.loads((evidence / 'result.json').read_text())
        require(summary['exitCode'] == str(result['exitCode']), 'result.json exit disagrees with process')
    require('vm.console.released' in ops, 'console resources not released')
    if 'vm.console.released' in ops:
        released = ops.index('vm.console.released')
        require('vm.stopped' in ops and ops.index('vm.stopped') < released, 'console released before actual stopped')
        require('vm.start.callback' in ops and ops.index('vm.start.callback') < released, 'console released before start callback settled')
        if 'vm.stop.callback' in ops:
            require(ops.index('vm.stop.callback') < ops.index('vm.stopped'), 'stopped before stop callback settled')
    if 'vm.stopping' in ops:
        tail = seen[ops.index('vm.stopping') + 1:]
        require(not any(e['operation'] in ('vm.protocol.ping', 'vm.protocol.pong') and e['decision'] == 'allow' for e in tail), 'authorized ping/pong after stopping')
    else:
        require(False, 'missing stopping record')
    if cancel:
        require(bool(result['signals']), 'never observed vm.start/sent SIGINT')
        require('vm.start.callback' not in result.get('operationsAtSignal', []), 'signal missed pending start window')
        require(any(e['operation'] == 'vm.stopping' and e['reason'] == 'cancelled' for e in seen), 'not cancellation cleanup')
        require('vm.start.callback' in ops, 'start callback never settled')
        if all(op in ops for op in ('vm.stopping', 'vm.start.callback', 'vm.stopped')):
            require(ops.index('vm.stopping') < ops.index('vm.start.callback') < ops.index('vm.stopped'), 'not a pending-start cancellation / premature stopped')
    else:
        require('vm.protocol.pong' in ops, 'missing real pong')
        require({'type', 'uuid', 'oversized'} <= {e['reason'] for e in seen if e['operation'] == 'vm.protocol.reject' and e['decision'] == 'deny'}, 'missing host rejection cases')
    result['failures'] = failures
    result['runIDs'] = sorted({e['runID'] for e in seen})
    result['pass'] = not failures
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true', help='explicitly permit real VM launch')
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--evidence-parent', type=Path, required=True)
    parser.add_argument('--cancel-attempts', type=int, default=3)
    parser.add_argument('--normal', action='store_true')
    args = parser.parse_args()
    if not args.live:
        parser.error('--live is required; no VM launched')
    if not 1 <= args.cancel_attempts <= 10:
        parser.error('--cancel-attempts must be 1..10')
    args.probe = args.probe.resolve(strict=True)
    args.bundle = args.bundle.resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix='vm-lifecycle-', dir=args.evidence_parent.resolve(strict=True)))
    report = {'probeSHA256': hashlib.sha256(args.probe.read_bytes()).hexdigest(), 'runs': []}
    print('Evidence: ' + str(root), flush=True)
    cases = [('normal', False)] if args.normal else []
    cases += [('cancel-' + str(i + 1), True) for i in range(args.cancel_attempts)]
    for name, cancel in cases:
        run = attempt(args, root, name, cancel)
        previous_ids = {run_id for previous in report['runs'] for run_id in previous['runIDs']}
        if len(run['runIDs']) != 1 or previous_ids.intersection(run['runIDs']):
            run['failures'].append('run identity not unique')
            run['pass'] = False
        report['runs'].append(run)
        (root / 'lifecycle-report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(run), flush=True)
    return 0 if all(run['pass'] for run in report['runs']) else 1


if __name__ == '__main__':
    raise SystemExit(main())
