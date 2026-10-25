"""Runtime-local bounded snapshot of the diagnostic bundle.
Mirrors diagnostic validation without changing diagnostic APIs/budgets.
Every path is read once; all later image work consumes these validated bytes.
"""

import json
import stat
import zlib
import image
from inspect_bundle import DEVICES, SYMLINKS, parse_newc

build = image.legacy


def validated_base(path):
    path = build.no_symlinks(path)
    m = json.loads(build.read_regular(path / 'bundle.json', 8192))
    expected = {
        'schemaVersion',
        'kernelFile',
        'kernelSHA256',
        'initramfsFile',
        'initramfsSHA256',
        'probeSHA256',
        'protocolVersion',
        'workloadSHA256',
        'kernelRelease',
    }
    if set(m) != expected or m['kernelFile'] != 'Image' or m['initramfsFile'] != 'initramfs.cpio.gz':
        raise ValueError('invalid fixed bundle schema')
    if m['schemaVersion'] != 1 or m['protocolVersion'] != 1 or m['kernelRelease'] != build.KERNEL_RELEASE:
        raise ValueError('unsupported bundle version')
    kernel = build.read_source(path / 'Image', m['kernelSHA256'], build.RAW_SIZE)
    build.checked_hash(kernel, build.RAW_HASH)
    compressed = build.read_source(path / 'initramfs.cpio.gz', m['initramfsSHA256'], 64 * 1024 * 1024)
    decoder = zlib.decompressobj(31)
    raw = decoder.decompress(compressed, 64 * 1024 * 1024 + 1)
    if len(raw) > 64 * 1024 * 1024 or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
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
    return kernel, entries
