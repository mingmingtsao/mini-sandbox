#!/usr/bin/env python3
"""Reproducible offline diagnostic guest builder; never runs guest binaries."""

import hashlib
import io
import pathlib
import tarfile
import os
import stat
import struct
import zlib


def decode_zboot(data, expected, size):
    if len(data) < 32 or data[:2] != b'MZ' or data[4:8] != b'zimg':
        raise ValueError('not an EFI zboot image')
    offset, length = struct.unpack_from('<II', data, 8)
    if offset < 32 or length < 18 or offset > len(data) or length > len(data) - offset:
        raise ValueError('zboot payload out of bounds')
    if data[24:32].rstrip(b'\0') != b'gzip':
        raise ValueError('unsupported zboot compression')
    try:
        decoder = zlib.decompressobj(31)
        raw = decoder.decompress(data[offset : offset + length], size + 1)
        if len(raw) != size or not decoder.eof or decoder.unconsumed_tail or decoder.unused_data:
            raise ValueError('invalid bounded gzip payload')
    except zlib.error as exc:
        raise ValueError('corrupt zboot gzip') from exc
    if len(raw) < 64 or raw[56:60] != b'ARM\x64' or struct.unpack_from('<Q', raw, 16)[0] != size:
        raise ValueError('invalid ARM64 Image header')
    return checked_hash(raw, expected)


def no_symlinks(path):
    path = pathlib.Path(os.path.abspath(path))
    for component in (*reversed(path.parents), path):
        if component.is_symlink():
            raise ValueError('symlink path rejected')
    return path


def reserve_output(path, repo):
    path = no_symlinks(path)
    repo = pathlib.Path(repo).resolve()
    if path == repo or repo in path.parents or path.exists():
        raise ValueError('output must be new and outside repository')
    if not path.parent.is_dir() or path.parent.stat().st_uid != os.getuid():
        raise ValueError('output parent must exist and be owned by caller')
    path.mkdir(mode=0o700)
    return path


def safe_name(name):
    if name.startswith('./'):
        name = name[2:]
    if not name or name.startswith('/') or '\\' in name or '\x00' in name:
        raise ValueError('unsafe archive name')
    if any(p in ('', '.', '..') for p in name.split('/')):
        raise ValueError('unsafe archive component')
    return name


def checked_hash(data, expected):
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError('source SHA256 mismatch')
    return data


def select_tar(data, selected):
    """Read only named regular entries; never extract to the host filesystem."""
    result = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:*') as archive:
            for entry in archive:
                raw = entry.name[2:] if entry.name.startswith('./') else entry.name
                if raw not in selected:
                    continue
                name = safe_name(entry.name)
                if name in result or not entry.isreg() or not 0 <= entry.size <= selected[name]:
                    raise ValueError('duplicate, nonregular or oversized selected tar entry')
                with archive.extractfile(entry) as stream:
                    value = stream.read(selected[name] + 1)
                if len(value) != entry.size:
                    raise ValueError('truncated selected tar entry')
                result[name] = value
    except (tarfile.TarError, EOFError, OSError) as exc:
        raise ValueError('invalid tar archive') from exc
    if set(result) != set(selected):
        raise ValueError('missing selected tar entries')
    return result


def module_order(text, wanted):
    dependencies = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        key, sep, value = line.partition(':')
        if not sep or key in dependencies:
            raise ValueError('invalid module dependency map')
        dependencies[safe_name(key)] = [safe_name(x) for x in value.split()]
    active, seen, order = set(), set(), []

    def visit(name):
        if name in seen:
            return
        if name in active or name not in dependencies:
            raise ValueError('missing or cyclic module dependency')
        active.add(name)
        for dependency in dependencies[name]:
            visit(dependency)
        active.remove(name)
        seen.add(name)
        order.append(name)

    for name in wanted:
        visit(name)
    return order


def validate_elf(data, static=False):
    if len(data) < 64 or data[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', data, 18)[0] != 183:
        raise ValueError('expected little-endian ELF64 AArch64')
    offset = struct.unpack_from('<Q', data, 32)[0]
    entry_size, count = struct.unpack_from('<HH', data, 54)
    if count and (entry_size < 56 or offset > len(data) or count * entry_size > len(data) - offset):
        raise ValueError('ELF program header out of bounds')
    for i in range(count):
        kind = struct.unpack_from('<I', data, offset + i * entry_size)[0]
        if static and kind in (2, 3):
            raise ValueError('probe must have no dynamic/interpreter program header')


def newc(entries):
    entries = dict(entries)
    for name in list(entries):
        safe_name(name)
        parent = pathlib.PurePosixPath(name).parent
        while str(parent) != '.':
            key = str(parent)
            if key in entries and not stat.S_ISDIR(entries[key][0]):
                raise ValueError('nondirectory archive parent')
            entries.setdefault(key, (stat.S_IFDIR | 0o755, b'', 0, 0))
            parent = parent.parent
    out = bytearray()
    for index, name in enumerate(sorted(entries) + ['TRAILER!!!'], 1):
        mode, data, major, minor = entries.get(name, (0, b'', 0, 0))
        if len(data) > 64 * 1024 * 1024:
            raise ValueError('cpio entry too large')
        if stat.S_ISCHR(mode):
            if (name, major, minor) not in {('dev/console', 5, 1), ('dev/null', 1, 3)} or data:
                raise ValueError('unapproved guest device node')
        elif major or minor or (mode and stat.S_IFMT(mode) not in (stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK)):
            raise ValueError('unsupported cpio entry')
        if stat.S_ISLNK(mode):
            safe_name(data.decode('ascii'))
        encoded = name.encode('ascii') + b'\0'
        values = [index, mode, 0, 0, 2 if stat.S_ISDIR(mode) else 1, 0, len(data), 0, 0, major, minor, len(encoded), 0]
        out.extend(b'070701' + ''.join('%08x' % v for v in values).encode('ascii') + encoded)
        out.extend(b'\0' * (-len(out) % 4))
        out.extend(data)
        out.extend(b'\0' * (-len(out) % 4))
    out.extend(b'\0' * (-len(out) % 512))
    return bytes(out)


KERNEL_RELEASE = '6.18.58-0-virt'
RAW_HASH = '256d5fff4bb892edcb9218c1e6353e388bc3646e65f76c2bc9d958b635d1b00e'
RAW_SIZE = 36306944
ROOTFS_HASH = '4d3f80afaebd447c5591a63a73bde380a149fe8b2d85488cafabb2ff97551f50'
NETBOOT_HASH = '0ac085f19648562d33deb8bfdc339d747e40f456a49a43385d468ea46a888147'
WHEEL_HASH = 'a8ea154bf946f985c65fab7d8c08dc73da7ad47a0aebf0d13ae50ae56e369f90'
VERMAGIC = '6.18.58-0-virt SMP preempt mod_unload modversions aarch64'


def selected_squash_entry(entry, maximum):
    safe_name(entry.path.lstrip('/'))
    if not stat.S_ISREG(entry.mode) or not 0 <= entry.size <= maximum:
        raise ValueError('nonregular or oversized squashfs entry')
    data = entry.read_bytes()
    if len(data) != entry.size:
        raise ValueError('truncated squashfs entry')
    return data


def load_modules(data):
    if len(data) < 96 or data[:4] != b'hsqs':
        raise ValueError('invalid squashfs image')
    from PySquashfsImage import SquashFsImage

    prefix = '/modules/' + KERNEL_RELEASE + '/'
    with SquashFsImage.from_bytes(data) as image:
        entries = {}
        for entry in image:
            if entry.path in entries:
                raise ValueError('duplicate squashfs entry')
            entries[entry.path] = entry
        dep = selected_squash_entry(entries[prefix + 'modules.dep'], 1024 * 1024).decode('ascii')
        wanted = [
            'kernel/net/vmw_vsock/' + n + '.ko'
            for n in ('vsock', 'vmw_vsock_virtio_transport_common', 'vmw_vsock_virtio_transport')
        ]
        order = module_order(dep, wanted)
        modules = {}
        for name in order:
            blob = selected_squash_entry(entries[prefix + name], 8 * 1024 * 1024)
            validate_elf(blob)
            metadata = {}
            for item in blob.split(b'\0'):
                if item.startswith((b'vermagic=', b'depends=')):
                    key, value = item.decode('ascii').split('=', 1)
                    if key in metadata:
                        raise ValueError('duplicate module metadata')
                    metadata[key] = value
            if metadata.get('vermagic') != VERMAGIC:
                raise ValueError('module vermagic mismatch')
            actual = set(filter(None, metadata.get('depends', '').split(',')))
            declared_line = next(line for line in dep.splitlines() if line.startswith(name + ':'))
            declared = {pathlib.PurePosixPath(x).stem for x in declared_line.partition(':')[2].split()}
            if actual != declared:
                raise ValueError('module dependency metadata mismatch')
            modules[name] = blob
    return modules


def manifest(kernel, initramfs, probe):
    import json

    def digest(b):
        return hashlib.sha256(b).hexdigest()

    result = {
        'schemaVersion': 1,
        'kernelFile': 'Image',
        'kernelSHA256': digest(kernel),
        'initramfsFile': 'initramfs.cpio.gz',
        'initramfsSHA256': digest(initramfs),
        'probeSHA256': digest(probe),
        'protocolVersion': 1,
        'kernelRelease': KERNEL_RELEASE,
    }
    identity = {key: result[key] for key in ('schemaVersion', 'kernelSHA256', 'initramfsSHA256', 'protocolVersion')}
    result['workloadSHA256'] = digest(json.dumps(identity, sort_keys=True, separators=(',', ':')).encode('utf8'))
    return result


def read_regular(path, maximum):
    path = no_symlinks(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= maximum:
            raise ValueError('invalid source type or size')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            data = stream.read(maximum + 1)
    finally:
        os.close(fd)
    if len(data) > maximum:
        raise ValueError('source size exceeded')
    return data


def read_source(path, expected, maximum):
    return checked_hash(read_regular(path, maximum), expected)


def exclusive_write(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def build(args):
    import gzip
    import json
    import shutil
    import subprocess
    import sys
    import tempfile

    here = pathlib.Path(__file__).resolve().parent
    repo = here.parent.parent
    output = reserve_output(args.output, repo)
    scratch = no_symlinks(args.scratch)
    if not scratch.is_dir() or scratch.stat().st_uid != os.getuid() or scratch == repo or repo in scratch.parents:
        raise ValueError('scratch must be an owned existing directory outside repository')
    read_source(args.wheel, WHEEL_HASH, 1024 * 1024)
    sys.path.insert(0, str(no_symlinks(args.wheel)))
    source = pathlib.Path(args.source_dir)
    root = select_tar(
        read_source(source / 'alpine-minirootfs-3.24.3-aarch64.tar.gz', ROOTFS_HASH, 8 * 1024 * 1024),
        {'bin/busybox': 2 * 1024 * 1024, 'lib/ld-musl-aarch64.so.1': 2 * 1024 * 1024},
    )
    boot = select_tar(
        read_source(source / 'alpine-netboot-3.24.3-aarch64.tar.gz', NETBOOT_HASH, 512 * 1024 * 1024),
        {'boot/vmlinuz-virt': 32 * 1024 * 1024, 'boot/modloop-virt': 64 * 1024 * 1024},
    )
    kernel = decode_zboot(boot['boot/vmlinuz-virt'], RAW_HASH, RAW_SIZE)
    modules = load_modules(boot['boot/modloop-virt'])
    for blob in root.values():
        validate_elf(blob)
    go = shutil.which('go')
    if not go:
        raise ValueError('Go 1.26.5 is required, no automatic download permitted')
    with tempfile.TemporaryDirectory(prefix='guest-build-', dir=scratch) as td:
        td = pathlib.Path(td)
        env = {
            'PATH': str(pathlib.Path(go).parent) + os.pathsep + os.defpath,
            'HOME': str(td),
            'TMPDIR': str(td),
            'GOCACHE': str(scratch / 'f02-go-build-cache'),
            'GOMODCACHE': str(td / 'modcache'),
            'GOPROXY': 'off',
            'GOSUMDB': 'off',
            'GOTOOLCHAIN': 'local',
            'GOENV': 'off',
            'GOWORK': 'off',
            'CGO_ENABLED': '0',
            'GOOS': 'linux',
            'GOARCH': 'arm64',
            'GOARM64': 'v8.0',
            'SOURCE_DATE_EPOCH': '0',
        }
        version = subprocess.check_output([go, 'version'], env=env, text=True).strip()
        if not version.startswith('go version go1.26.5 '):
            raise ValueError('requires pinned Go 1.26.5')
        subprocess.run(
            [go, 'build', '-trimpath', '-buildvcs=false', '-ldflags=-buildid=', '-o', str(td / 'probe'), './cmd/probe'],
            cwd=here,
            env=env,
            check=True,
        )
        probe = (td / 'probe').read_bytes()
    validate_elf(probe, static=True)
    entries = {name: (stat.S_IFREG | 0o755, data, 0, 0) for name, data in root.items()}
    entries['bin/diagnostic-probe'] = (stat.S_IFREG | 0o755, probe, 0, 0)
    entries['bin/sh'] = (stat.S_IFLNK | 0o777, b'busybox', 0, 0)
    entries['lib/libc.musl-aarch64.so.1'] = (stat.S_IFLNK | 0o777, b'ld-musl-aarch64.so.1', 0, 0)
    for name in ('proc', 'sys', 'dev'):
        entries[name] = (stat.S_IFDIR | 0o755, b'', 0, 0)
    for name, major, minor in (('dev/console', 5, 1), ('dev/null', 1, 3)):
        entries[name] = (stat.S_IFCHR | 0o600, b'', major, minor)
    loads = []
    for name, data in modules.items():
        target = 'lib/modules/' + KERNEL_RELEASE + '/' + name
        entries[target] = (stat.S_IFREG | 0o644, data, 0, 0)
        loads.append('/bin/busybox insmod /' + target + ' || hold')
    init = (here / 'init').read_text().replace('@MODULE_LOADS@', '\n'.join(loads)).encode('utf8')
    entries['init'] = (stat.S_IFREG | 0o755, init, 0, 0)
    buffer = io.BytesIO()
    with gzip.GzipFile(filename='', fileobj=buffer, mode='wb', compresslevel=9, mtime=0) as stream:
        stream.write(newc(entries))
    initramfs = buffer.getvalue()
    result = manifest(kernel, initramfs, probe)
    exclusive_write(output / 'Image', kernel)
    exclusive_write(output / 'initramfs.cpio.gz', initramfs)
    # Completion marker is deliberately last; failures preserve partial output for inspection.
    exclusive_write(output / 'bundle.json', (json.dumps(result, indent=2, sort_keys=True) + '\n').encode('utf8'))
    return {
        'artifact_manifest': str(output / 'bundle.json'),
        'manifest': result,
        'modules': list(modules),
        'go': version,
    }


def main():
    import argparse
    import json
    import sys

    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source-dir', 'wheel', 'scratch', 'output'):
        parser.add_argument('--' + name, required=True)
    try:
        print(json.dumps(build(parser.parse_args()), indent=2))
    except Exception as exc:
        print('guest fixture build failed: ' + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
