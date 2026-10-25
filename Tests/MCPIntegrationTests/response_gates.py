"""Bounded actual-response gates; no sleeps, FIFO assumptions or credentials."""

import threading


def independent_phases():
    names = set()
    for cap in ('grant1', 'cap2'):
        names.add('saturation-' + cap + '-discovery')
        names.update('saturation-' + cap + '-' + end for end in ('release', 'failed', 'cancelled'))
    for position in ('intent', 'credential'):
        names.update('action-' + position + suffix for suffix in ('', '-discovery', '-recovery'))
    names.update('not-yet-valid-' + operation for operation in ('propose', 'approve', 'execute'))
    for transition in ('invalidate', 'account', 'route', 'stop'):
        names.update('stale-' + transition + suffix for suffix in ('', '-discovery', '-recovery'))
    names.add('negative-model-discovery')
    names.update(
        'negative-model-' + case
        for case in ('B', 'write', 'denied', 'unapproved', 'non-tool', 'truncated', 'provisional', 'failure')
    )
    names.update(('negative-model-write-discovery', 'negative-model-drop-write'))
    return names


class ResponseGates:
    def __init__(self, name):
        self.name = name
        self.cap = (
            (1 if '-grant1-' in name else 2)
            if name.startswith('saturation-') and not name.endswith('discovery')
            else (2 if name.startswith('stale-') and not name.endswith(('discovery', 'recovery')) else 0)
        )
        self.condition = threading.Condition()
        self.entered = 0
        self.finished = 0
        self.released = set()
        self.timed_out = False

    def hold(self):
        with self.condition:
            self.entered += 1
            ordinal = self.entered
            self.condition.notify_all()
            if ordinal <= self.cap:
                ok = self.condition.wait_for(lambda: ordinal in self.released, timeout=2.0)
                self.timed_out |= not ok
            self.finished += 1
            self.condition.notify_all()
            return self.name.endswith('-failed') and ordinal == 1

    def command(self, action, value, hits):
        with self.condition:
            if action == 'wait':
                assert self.condition.wait_for(lambda: self.entered >= int(value), timeout=2.0), (
                    'fixture did not reach response gate'
                )
            elif action == 'busy':
                assert hits == self.entered == int(value), 'busy caused ingress'
            elif action == 'zero':
                assert hits == 0, 'prestart boundary dispatched'
            elif action == 'release':
                self.released.update(range(1, self.cap + 1) if value == 'all' else [int(value)])
                self.condition.notify_all()
                if value == 'all':
                    assert self.condition.wait_for(lambda: self.finished >= self.cap, timeout=2.0), (
                        'response gates did not settle'
                    )
            else:
                raise AssertionError('unknown gate command')
            assert not self.timed_out, 'response gate timed out'

    def verify(self):
        with self.condition:
            assert not self.timed_out, 'response gate timed out'
            assert self.finished >= self.cap, 'held responses not settled'
