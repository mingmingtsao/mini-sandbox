#!/usr/bin/env python3
"""Build/sign only the diagnostic executable. Never launch a VM or delete outputs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MARKER = '.vm-probe-owner'


def safe_directory(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise RuntimeError('Unsafe directory preserved: ' + str(path))
    return info.st_dev, info.st_ino


def ownership(output):
    return {'format': 1, 'project_root': str(ROOT.resolve()), 'output': str(output), 'product': 'VMProbe'}


def check_existing(output):
    if not os.path.lexists(output):
        return None
    identity = safe_directory(output)
    try:
        marker = output / MARKER
        info = marker.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_size > 4096:
            raise RuntimeError('Unsafe marker preserved')
        if json.loads(marker.read_text()) != ownership(output):
            raise RuntimeError('Foreign output preserved')
    except (OSError, ValueError) as error:
        raise RuntimeError('Unmarked output preserved') from error
    return identity


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--configuration', choices=['debug', 'release'], default='release')
    args = parser.parse_args()
    root_id = safe_directory(ROOT)
    dist = ROOT / 'dist'
    if not os.path.lexists(dist): dist.mkdir(mode=0o755)
    dist_id = safe_directory(dist)
    output = dist / 'VMProbe'
    old_id = check_existing(output)
    subprocess.run(['swift', 'build', '-c', args.configuration, '--product', 'VMProbe'], cwd=ROOT, check=True)
    binary_dir = Path(subprocess.check_output(['swift', 'build', '-c', args.configuration, '--show-bin-path'], cwd=ROOT, text=True).strip())
    binary = binary_dir / 'VMProbe'
    if binary.is_symlink() or not binary.is_file(): raise RuntimeError('Unsafe build binary')
    if safe_directory(ROOT) != root_id or safe_directory(dist) != dist_id: raise RuntimeError('Directory changed')
    staging = Path(tempfile.mkdtemp(prefix='.VMProbe-build-', dir=dist))
    stage_id = safe_directory(staging)
    executable = staging / 'VMProbe'
    shutil.copy2(binary, executable); executable.chmod(0o755)
    (staging / MARKER).write_text(json.dumps(ownership(output), sort_keys=True))
    subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(ROOT / 'scripts/vm-probe.entitlements'), str(executable)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', '--verbose=2', str(executable)], check=True)
    subprocess.run(['codesign', '--display', '--entitlements', ':-', str(executable)], check=True)
    if safe_directory(ROOT) != root_id or safe_directory(dist) != dist_id or safe_directory(staging) != stage_id or check_existing(output) != old_id:
        raise RuntimeError('Output changed; staging preserved')
    backup = None
    if old_id is not None:
        backup = Path(tempfile.mkdtemp(prefix='.VMProbe-backup-', dir=dist)) / 'VMProbe'
        output.rename(backup)
    try:
        if os.path.lexists(output): raise RuntimeError('Output appeared; preserved')
        staging.rename(output)
    except Exception:
        if backup is not None and not os.path.lexists(output): backup.rename(output)
        raise
    print(json.dumps({'executable': str(output / 'VMProbe'), 'sha256': hashlib.sha256((output / 'VMProbe').read_bytes()).hexdigest(), 'signing': 'ad-hoc-local-only', 'vmBoot': 'NOT_RUN', 'previous': str(backup) if backup else None}, sort_keys=True))

if __name__ == '__main__': main()
