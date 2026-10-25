#!/usr/bin/env python3
"""Bounded runtime-only archive reader. Never extracts archives onto the host."""

import io
import pathlib
import posixpath
import stat
import sys
import tarfile
import zlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'GuestFixture'))
import build as legacy

read_regular = legacy.read_regular
MAX_RAW = 256 * 1024 * 1024
MAX_FILE = 64 * 1024 * 1024
MAX_ENTRIES = 20000


def unpack_gzip(data, maximum=MAX_RAW):
    out = bytearray()
    while data:
        d = zlib.decompressobj(31)
        out.extend(d.decompress(data, maximum - len(out) + 1))
        if len(out) > maximum or not d.eof or d.unconsumed_tail:
            raise ValueError('gzip bound')
        data = d.unused_data
    return bytes(out)


def target(name, link, hard=False):
    if not link or '\\' in link or '\x00' in link:
        raise ValueError('unsafe link')
    if link.startswith('/'):
        return legacy.safe_name(link[1:])
    result = posixpath.normpath(link if hard else posixpath.join(posixpath.dirname(name), link))
    return legacy.safe_name(result)


def safe_entries(data):
    if data[:2] == b'\x1f\x8b':
        data = unpack_gzip(data)
    if len(data) > MAX_RAW:
        raise ValueError('archive bound')
    result = {}
    total = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:', ignore_zeros=True) as archive:
        for entry in archive:
            name = legacy.safe_name(entry.name.rstrip('/'))
            if len(result) >= MAX_ENTRIES or name in result:
                raise ValueError('duplicate/count')
            if not 0 <= entry.size <= MAX_FILE:
                raise ValueError('file bound')
            total += entry.size
            if total > MAX_RAW:
                raise ValueError('total bound')
            if entry.isreg():
                payload = archive.extractfile(entry).read(MAX_FILE + 1)
                if len(payload) != entry.size:
                    raise ValueError('short tar')
                value = (stat.S_IFREG | (entry.mode & 0o755), payload, 0, 0)
            elif entry.isdir():
                value = (stat.S_IFDIR | 0o755, b'', 0, 0)
            elif entry.issym():
                resolved = target(name, entry.linkname)
                value = (
                    stat.S_IFLNK | 0o777,
                    posixpath.relpath(resolved, posixpath.dirname(name) or '.').encode('ascii'),
                    0,
                    0,
                )
            elif entry.islnk():
                value = ('hard', target(name, entry.linkname, True), 0, 0)
            else:
                raise ValueError('special entry')
            result[name] = value
    for name, value in list(result.items()):
        if value[0] == 'hard':
            found = result.get(value[1])
            seen = {name}
            while found and found[0] == 'hard':
                if found[1] in seen:
                    raise ValueError('link cycle')
                seen.add(found[1])
                found = result.get(found[1])
            if not found or not stat.S_ISREG(found[0]):
                raise ValueError('hardlink target')
            result[name] = found
    for name in result:
        parent = posixpath.dirname(name)
        while parent:
            if parent in result and not stat.S_ISDIR(result[parent][0]):
                raise ValueError('nondirectory parent')
            parent = posixpath.dirname(parent)
    return result


def finalized_entries(entries):
    entries = dict(entries)
    for name in list(entries):
        legacy.safe_name(name)
        parent = posixpath.dirname(name)
        while parent:
            entries.setdefault(parent, (stat.S_IFDIR | 0o755, b'', 0, 0))
            if not stat.S_ISDIR(entries[parent][0]):
                raise ValueError('nondirectory parent')
            parent = posixpath.dirname(parent)
    if len(entries) > MAX_ENTRIES:
        raise ValueError('entry bound')
    return entries


def newc(entries):
    entries = finalized_entries(entries)
    out = bytearray()
    for idx, name in enumerate(sorted(entries) + ['TRAILER!!!'], 1):
        mode, data, major, minor = entries.get(name, (0, b'', 0, 0))
        if len(data) > MAX_FILE:
            raise ValueError('file bound')
        if stat.S_ISLNK(mode):
            target(name, data.decode('ascii'))
        elif stat.S_ISCHR(mode):
            if (name, major, minor) not in {('dev/console', 5, 1), ('dev/null', 1, 3)} or data:
                raise ValueError('device')
        elif mode and stat.S_IFMT(mode) not in (stat.S_IFREG, stat.S_IFDIR):
            raise ValueError('type')
        n = name.encode('utf8') + b'\0'
        if len(n) > 4096:
            raise ValueError('name bound')
        v = [idx, mode, 0, 0, 2 if stat.S_ISDIR(mode) else 1, 0, len(data), 0, 0, major, minor, len(n), 0]
        out.extend(b'070701' + ''.join('%08x' % x for x in v).encode() + n)
        out.extend(b'\0' * (-len(out) % 4))
        out.extend(data)
        out.extend(b'\0' * (-len(out) % 4))
        if len(out) > MAX_RAW:
            raise ValueError('runtime cpio bound')
    out.extend(b'\0' * (-len(out) % 512))
    return bytes(out)
