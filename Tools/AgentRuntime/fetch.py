#!/usr/bin/env python3
"""Fetch ONLY the reviewed version/hash lock. Host build-stage only; no scripts run.
Original lock bootstrap used the official TLS index; APK signatures were not verified.
"""

import concurrent.futures
import hashlib
import json
import os
import pathlib
import stat
import sys
import urllib.request
import image

BASE = 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/'


def fetch(package, dest):
    name = image.legacy.safe_name(package['file'])
    if '/' in name or package['url'] != BASE + name or not 0 < package['bytes'] <= 64 * 1024 * 1024:
        raise ValueError('locked source')
    path = dest / name
    if os.path.lexists(path):
        data = image.legacy.read_source(path, package['sha256'], package['bytes'])
        if len(data) != package['bytes']:
            raise ValueError('size mismatch')
        return name
    # Exclusive open: never follows or truncates an existing destination.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    h = hashlib.sha256()
    size = 0
    with os.fdopen(fd, 'wb') as out:
        with urllib.request.urlopen(package['url'], timeout=30) as response:
            while True:
                chunk = response.read(65536)
                if not chunk:
                    break
                size += len(chunk)
                if size > package['bytes']:
                    raise ValueError('download bound')
                h.update(chunk)
                out.write(chunk)
        out.flush()
        os.fsync(out.fileno())
    if size != package['bytes'] or h.hexdigest() != package['sha256']:
        raise ValueError('download digest; partial preserved')
    return name


def main():
    dest = image.legacy.no_symlinks(sys.argv[1])
    info = dest.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError('private download directory required')
    lock = json.loads(image.read_regular(pathlib.Path(__file__).parent / 'dependencies.lock.json', 1024 * 1024))
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        names = list(pool.map(lambda p: fetch(p, dest), lock['packages']))
    print(
        json.dumps(
            {
                'verifiedPackages': len(names),
                'lockSHA256': hashlib.sha256(
                    image.read_regular(pathlib.Path(__file__).parent / 'dependencies.lock.json', 1024 * 1024)
                ).hexdigest(),
            }
        )
    )


if __name__ == '__main__':
    main()
