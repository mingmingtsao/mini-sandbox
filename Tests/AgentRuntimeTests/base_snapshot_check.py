#!/usr/bin/env python3
"""Real bounded diagnostic source reads and replacement/FIFO regressions."""

import collections
import os
import pathlib
import shutil
import sys
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tools/AgentRuntime'))
import image
from RuntimeBundle import validated_base

base, out = map(pathlib.Path, sys.argv[1:])
out.mkdir(mode=0o700)
reader = image.legacy.read_regular
for case in ('snapshot-no-reread', 'mutation-reject', 'fifo-reject'):
    p = out / case
    p.mkdir(mode=0o700)
    for name in ('Image', 'initramfs.cpio.gz', 'bundle.json'):
        shutil.copyfile(base / name, p / name)
    counts = collections.Counter()

    def read(path, maximum):
        counts[path.name] += 1
        data = reader(path, maximum)
        if path.name == 'initramfs.cpio.gz':
            if case == 'mutation-reject':
                return data[:-1] + bytes([data[-1] ^ 1])
            if case == 'snapshot-no-reread':
                path.unlink()
                os.mkfifo(path)
        return data

    if case == 'fifo-reject':
        (p / 'initramfs.cpio.gz').unlink()
        os.mkfifo(p / 'initramfs.cpio.gz')
    rejected = False
    with patch.object(image.legacy, 'read_regular', side_effect=read):
        try:
            kernel, entries = validated_base(p)
        except ValueError:
            rejected = True
    assert rejected == (case != 'snapshot-no-reread'), case
    assert all(n == 1 for n in counts.values()), counts
    print('PASS', case, dict(counts))
