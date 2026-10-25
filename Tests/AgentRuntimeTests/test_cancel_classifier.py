import copy
import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tools/AgentRuntime'))
import verify_vm

ROWS = [
    dict(event='configuration', NIC=0, shares=0, privateDisks=1),
    dict(event='vm.start'),
    dict(event='vm.stopping', reason='hostCancel'),
    dict(event='start.callback'),
    dict(event='stop.callback'),
    dict(event='vm.stopped', actualState='stopped', startPending=False, stopPending=False),
    dict(event='console.released'),
]


class CancellationTests(unittest.TestCase):
    def drive(self, rows):
        class Child:
            def __init__(self, args, stdout, stderr):
                stdout.write(('\n'.join(json.dumps(r) for r in rows) + '\n').encode())
                stdout.flush()
                pathlib.Path(args[2], 'private.raw').write_bytes(b'fixture')

            def poll(self):
                return 1

            def wait(self, timeout):
                return 1

        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as d:
            p = pathlib.Path(d)
            binary = p / 'binary'
            binary.write_bytes(b'fixture')
            with (
                patch.object(sys, 'argv', ['verify', str(binary), 'image', str(p / 'session'), '--cancel-start']),
                patch.object(verify_vm.subprocess, 'Popen', Child),
            ):
                verify_vm.main()

    def test_classifier_negatives(self):
        variants = []
        r = copy.deepcopy(ROWS)
        r[2]['reason'] = 'startFailed'
        variants.append(('not host cancel', r))
        r = copy.deepcopy(ROWS)
        r[2], r[3] = r[3], r[2]
        variants.append(('start already settled', r))
        r = copy.deepcopy(ROWS)
        r[5]['startPending'] = True
        variants.append(('pending callback', r))
        r = copy.deepcopy(ROWS)
        r[5]['actualState'] = 'running'
        variants.append(('not stopped', r))
        r = copy.deepcopy(ROWS)
        del r[3]
        variants.append(('missing start callback', r))
        r = copy.deepcopy(ROWS)
        r[5], r[6] = r[6], r[5]
        variants.append(('release before stopped', r))
        for label, rows in variants:
            with self.subTest(label=label), self.assertRaises(AssertionError):
                self.drive(rows)

    def test_valid_pending_start_cancel(self):
        self.drive(ROWS)


if __name__ == '__main__':
    unittest.main()
