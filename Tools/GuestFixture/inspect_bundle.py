#!/usr/bin/env python3
"""Inspect diagnostic bundles without extracting/running their Linux contents."""
import hashlib
import json
import pathlib
import stat
import sys
import zlib
import build

DEVICES = {'dev/console': (5, 1), 'dev/null': (1, 3)}
SYMLINKS = {'bin/sh': b'busybox', 'lib/libc.musl-aarch64.so.1': b'ld-musl-aarch64.so.1'}


def parse_newc(raw):
    entries, offset = {}, 0
    while offset + 110 <= len(raw):
        header = raw[offset:offset + 110]
        if header[:6] != b'070701':
            raise ValueError('invalid newc header')
        try:
            fields = [int(header[6 + i*8:14 + i*8], 16) for i in range(13)]
        except ValueError as exc:
            raise ValueError('invalid newc integer') from exc
        mode, size, namesize = fields[1], fields[6], fields[11]
        offset += 110
        if not 1 <= namesize <= 4096 or namesize > len(raw) - offset:
            raise ValueError('invalid newc name bounds')
        namebytes = raw[offset:offset + namesize]
        if namebytes[-1:] != b'\0' or b'\0' in namebytes[:-1]:
            raise ValueError('invalid newc name terminator')
        name = namebytes[:-1].decode('ascii')
        offset = (offset + namesize + 3) & ~3
        if size > len(raw) - offset:
            raise ValueError('invalid newc data bounds')
        data = raw[offset:offset + size]
        offset = (offset + size + 3) & ~3
        if name == 'TRAILER!!!':
            if size or any(raw[offset:]):
                raise ValueError('unexpected newc trailing data')
            return entries
        build.safe_name(name)
        if name in entries or fields[2] or fields[3] or fields[5]:
            raise ValueError('duplicate name or nondeterministic metadata')
        kind = stat.S_IFMT(mode)
        if kind not in (stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK, stat.S_IFCHR):
            raise ValueError('unsupported cpio entry type')
        if kind == stat.S_IFCHR or name in DEVICES:
            if kind != stat.S_IFCHR or DEVICES.get(name) != (fields[9], fields[10]) or data:
                raise ValueError('unapproved device type, number or payload')
        elif fields[9] or fields[10]:
            raise ValueError('device numbers on nondevice entry')
        if kind == stat.S_IFDIR and data:
            raise ValueError('directory payload rejected')
        if kind == stat.S_IFLNK or name in SYMLINKS:
            if kind != stat.S_IFLNK or SYMLINKS.get(name) != data:
                raise ValueError('unapproved symlink')
        entries[name] = {'mode': mode, 'data': data}
    raise ValueError('missing newc trailer')


def inspect(path):
    path = build.no_symlinks(path)
    m = json.loads(build.read_regular(path / 'bundle.json', 8192))
    expected = {'schemaVersion','kernelFile','kernelSHA256','initramfsFile','initramfsSHA256','probeSHA256','protocolVersion','workloadSHA256','kernelRelease'}
    if set(m) != expected or m['kernelFile'] != 'Image' or m['initramfsFile'] != 'initramfs.cpio.gz':
        raise ValueError('invalid fixed bundle schema')
    if m['schemaVersion'] != 1 or m['protocolVersion'] != 1 or m['kernelRelease'] != build.KERNEL_RELEASE:
        raise ValueError('unsupported bundle version')
    kernel = build.read_source(path / 'Image', m['kernelSHA256'], build.RAW_SIZE)
    build.checked_hash(kernel, build.RAW_HASH)
    compressed = build.read_source(path / 'initramfs.cpio.gz', m['initramfsSHA256'], 64*1024*1024)
    decoder = zlib.decompressobj(31)
    raw = decoder.decompress(compressed, 64*1024*1024 + 1)
    if len(raw) > 64*1024*1024 or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError('invalid bounded initramfs gzip')
    entries = parse_newc(raw)
    executable = {'init', 'bin/busybox', 'bin/diagnostic-probe', 'lib/ld-musl-aarch64.so.1'}
    required = executable | set(DEVICES) | set(SYMLINKS) | {'proc', 'sys', 'dev'}
    if not required <= entries.keys():
        raise ValueError('required boot entries missing')
    if any(not stat.S_ISREG(entries[n]['mode']) or not entries[n]['mode'] & 0o111 for n in executable):
        raise ValueError('boot executables must be executable regular entries')
    if any(not stat.S_ISDIR(entries[n]['mode']) for n in ('proc', 'sys', 'dev')):
        raise ValueError('boot mountpoints must be directories')
    probe = entries['bin/diagnostic-probe']['data']
    build.validate_elf(probe, static=True)
    if m != build.manifest(kernel, compressed, probe):
        raise ValueError('manifest/probe/identity mismatch')

    modules = [n for n in entries if n.endswith('.ko')]
    if len(modules) != 3:
        raise ValueError('unexpected module closure')
    return {'manifest': m, 'entries': [{'name': n, 'bytes': len(v['data']), 'mode': oct(v['mode']), 'sha256': hashlib.sha256(v['data']).hexdigest()} for n, v in entries.items()],
            'probeELF': 'ELF64 little-endian AArch64, no PT_INTERP/PT_DYNAMIC', 'vmLaunched': False}


def main():
    try:
        if not 2 <= len(sys.argv) <= 3:
            raise ValueError('usage: inspect_bundle.py BUNDLE [SECOND_BUNDLE]')
        first = inspect(sys.argv[1])
        if len(sys.argv) == 3:
            second = inspect(sys.argv[2])
            if first != second:
                raise ValueError('bundle builds differ')
            first['deterministicPair'] = True
        print(json.dumps(first, indent=2))
    except Exception as exc:
        print('bundle inspection failed: ' + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
