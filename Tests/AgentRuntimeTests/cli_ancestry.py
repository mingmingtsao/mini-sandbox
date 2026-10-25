#!/usr/bin/env python3
"""Exercise the actual CLI path gate, without wrapper permission repair."""

import json
import pathlib
import shutil
import subprocess
import sys

binary, source, output = map(pathlib.Path, sys.argv[1:])
output.mkdir(mode=0o700)
image = output / 'image'
image.mkdir(mode=0o700)
for name in ('Image', 'runtime.cpio.gz', 'runtime.json'):
    shutil.copyfile(source / name, image / name)
results = []
for label in ('session-public', 'session-ancestor-writable', 'image-public', 'input-writable', 'symlink-session'):
    parent = output / label
    parent.mkdir(mode=0o700)
    session = parent / 'session'
    session.mkdir(mode=0o700)
    target = session
    if label == 'session-public':
        session.chmod(0o777)
    if label == 'session-ancestor-writable':
        parent.chmod(0o777)
    if label == 'image-public':
        image.chmod(0o755)
    if label == 'input-writable':
        (image / 'runtime.json').chmod(0o666)
    if label == 'symlink-session':
        target = parent / 'link'
        target.symlink_to(session)
    with (parent / 'stdout').open('wb') as out, (parent / 'stderr').open('wb') as err:
        child = subprocess.Popen([str(binary), str(image), str(target)], stdout=out, stderr=err)
        try:
            code = child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.terminate()
            try:
                code = child.wait(timeout=12)
            except subprocess.TimeoutExpired:
                child.kill()
                code = child.wait()
    ok = (
        code == 1
        and not (session / 'private.raw').exists()
        and b'"event":"configuration"' not in (parent / 'stdout').read_bytes()
    )
    results.append(dict(case=label, passed=ok, code=code, diskCreated=(session / 'private.raw').exists()))
    image.chmod(0o700)
    (image / 'runtime.json').chmod(0o600)
print(json.dumps(results, indent=2))
raise SystemExit(0 if all(x['passed'] for x in results) else 1)
