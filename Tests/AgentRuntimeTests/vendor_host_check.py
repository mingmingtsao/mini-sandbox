"""Actual native CLI rejection path; does not boot malformed artifacts."""

import json
import pathlib
import shutil
import subprocess
import sys

host, image, valid, root = sys.argv[1:]
root = pathlib.Path(root)
root.mkdir(mode=0o700)
cases = []
for name in ('short', 'digest', 'padding', 'writable', 'symlink'):
    folder = root / name
    folder.mkdir(mode=0o700)
    blob = folder / 'vendor.raw'
    session = folder / 'session'
    session.mkdir(mode=0o700)
    if name == 'symlink':
        blob.symlink_to(valid)
    else:
        with blob.open('xb') as f:
            if name in ('padding', 'writable'):
                with open(valid, 'rb') as source:
                    shutil.copyfileobj(source, f, 1048576)
            else:
                f.truncate(285493247 if name == 'short' else 285493248)
        if name == 'padding':
            with blob.open('r+b') as f:
                f.seek(-1, 2)
                f.write(b'X')
        blob.chmod(0o600 if name == 'writable' else 0o400)
    result = subprocess.run([host, image, str(session), str(blob)], capture_output=True, timeout=10)
    assert (
        result.returncode == 1
        and b'vm.start' not in result.stdout
        and b'runtime preparation rejected:' in result.stdout
    ), (name, result.returncode)
    cases.append({'case': name, 'exit': result.returncode, 'beforeVMStart': True})
(root / 'result.json').write_text(json.dumps(cases, indent=2) + '\n')
print(json.dumps(cases))
