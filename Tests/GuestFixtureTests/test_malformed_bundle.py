"""Malformed archive regressions; no guest execution or external inputs."""
import gzip
import hashlib

import json
import os
import pathlib
import stat
import struct
import sys
import tempfile
import types
import unittest
from unittest import mock

TOOLS = pathlib.Path(__file__).resolve().parents[2] / 'Tools/GuestFixture'
sys.path.insert(0, str(TOOLS))
import build
import inspect_bundle


def elf():
    blob = bytearray(120)
    blob[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<H', blob, 18, 183)
    return bytes(blob)


def alter(raw, target, *, mode=None, major=None, minor=None, data=None, name=None):
    """Alter actual newc records, bypassing the production writer's checks."""
    out, offset = bytearray(), 0
    while offset + 110 <= len(raw):
        fields = [int(raw[offset+6+i*8:offset+14+i*8], 16) for i in range(13)]
        start = offset + 110
        original = raw[start:start+fields[11]-1].decode('ascii')
        start = (start + fields[11] + 3) & ~3
        payload = raw[start:start+fields[6]]
        offset = (start + fields[6] + 3) & ~3
        if original == target:
            for index, value in ((1, mode), (9, major), (10, minor)):
                if value is not None:
                    fields[index] = value
            if data is not None:
                payload = data
            record_name = name if name is not None else original
        else:
            record_name = original
        encoded = record_name.encode('ascii') + b'\0'
        fields[6], fields[11] = len(payload), len(encoded)
        out.extend(b'070701' + ''.join('%08x' % v for v in fields).encode() + encoded)
        out.extend(b'\0' * (-len(out) % 4))
        out.extend(payload)
        out.extend(b'\0' * (-len(out) % 4))
        if original == 'TRAILER!!!':
            break
    out.extend(b'\0' * (-len(out) % 512))
    return bytes(out)


class BundleInputTest(unittest.TestCase):
    def setUp(self):
        self.probe = elf()
        self.entries = {n: (stat.S_IFREG | 0o755, self.probe, 0, 0) for n in
                        ('bin/busybox', 'bin/diagnostic-probe', 'lib/ld-musl-aarch64.so.1')}
        self.entries.update({'init': (stat.S_IFREG | 0o755, b'#!/bin/sh\n', 0, 0),
                             'bin/sh': (stat.S_IFLNK | 0o777, b'busybox', 0, 0),
                             'lib/libc.musl-aarch64.so.1': (stat.S_IFLNK | 0o777, b'ld-musl-aarch64.so.1', 0, 0),
                             'dev/console': (stat.S_IFCHR | 0o600, b'', 5, 1),
                             'dev/null': (stat.S_IFCHR | 0o600, b'', 1, 3)})
        for name in ('proc', 'sys', 'dev'):
            self.entries[name] = (stat.S_IFDIR | 0o755, b'', 0, 0)
        for name in ('vsock', 'vmw_vsock_virtio_transport_common', 'vmw_vsock_virtio_transport'):
            self.entries['lib/modules/' + build.KERNEL_RELEASE + '/' + name + '.ko'] = (stat.S_IFREG | 0o644, elf(), 0, 0)
        self.raw = build.newc(self.entries)

    def inspect_raw(self, raw):
        # Only the kernel pin is substituted; all archive/manifest checks run.
        kernel = b'unit-test-kernel'
        compressed = gzip.compress(raw, mtime=0)
        manifest = build.manifest(kernel, compressed, self.probe)
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as td:
            path = pathlib.Path(td)
            (path / 'Image').write_bytes(kernel)
            (path / 'initramfs.cpio.gz').write_bytes(compressed)
            (path / 'bundle.json').write_text(json.dumps(manifest))
            with mock.patch.object(build, 'RAW_HASH', hashlib.sha256(kernel).hexdigest()), mock.patch.object(build, 'RAW_SIZE', len(kernel)):
                return inspect_bundle.inspect(path)

    def test_full_inspect_rejects_block_device_init_rehashed(self):
        self.assertFalse(self.inspect_raw(self.raw)['vmLaunched'])
        with self.assertRaises(ValueError):
            self.inspect_raw(alter(self.raw, 'init', mode=0o060755))

    def test_required_executables_are_regular_and_executable(self):
        for name in ('init', 'bin/busybox', 'bin/diagnostic-probe', 'lib/ld-musl-aarch64.so.1'):
            for mode in (stat.S_IFREG | 0o644, stat.S_IFLNK | 0o777, stat.S_IFDIR | 0o755):
                with self.subTest(name=name, mode=oct(mode)), self.assertRaises(ValueError):
                    self.inspect_raw(alter(self.raw, name, mode=mode))

    def test_cpio_types_devices_payloads_and_paths(self):
        cases = [('init', {'mode': kind | 0o755}) for kind in (0, stat.S_IFBLK, stat.S_IFIFO, stat.S_IFSOCK)]
        cases += [('dev/console', change) for change in (
            {'major': 1}, {'minor': 3}, {'name': 'dev/foreign'}, {'data': b'x'},
            {'mode': stat.S_IFREG | 0o600, 'major': 0, 'minor': 0})]
        cases += [('init', {'major': 1}), ('proc', {'data': b'x'}),
                  ('proc', {'mode': stat.S_IFREG | 0o755}),
                  ('init', {'name': '../evil'}), ('bin/sh', {'data': b'../evil'}),
                  ('bin/sh', {'mode': stat.S_IFREG | 0o755}),
                  ('bin/sh', {'data': b'other'}), ('bin/sh', {'name': 'bin/other'})]
        for name, change in cases:
            with self.subTest(name=name, change=change), self.assertRaises(ValueError):
                self.inspect_raw(alter(self.raw, name, **change))

    def test_static_elf_interpreter_and_dynamic_headers(self):
        for kind in (2, 3):
            blob = bytearray(elf())
            struct.pack_into('<Q', blob, 32, 64)
            struct.pack_into('<HH', blob, 54, 56, 1)
            struct.pack_into('<I', blob, 64, kind)
            build.validate_elf(blob)
            with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, 'dynamic/interpreter'):
                build.validate_elf(blob, static=True)

    def test_module_vermagic_and_depends_metadata(self):
        prefix = '/modules/' + build.KERNEL_RELEASE + '/'
        names = ['kernel/net/vmw_vsock/' + n + '.ko' for n in
                 ('vsock', 'vmw_vsock_virtio_transport_common', 'vmw_vsock_virtio_transport')]
        class Entry:
            mode = stat.S_IFREG | 0o644
            def __init__(self, path, data):
                self.path, self.data, self.size = path, data, len(data)
            def read_bytes(self):
                return self.data
        class Image(list):
            def __enter__(self): return self
            def __exit__(self, *args): pass
        for vermagic, depends, error in ((build.VERMAGIC, '', None), ('wrong', '', 'vermagic'),
                                         (build.VERMAGIC, 'missing', 'dependency metadata')):
            metadata = b'\0vermagic=' + vermagic.encode() + b'\0depends=' + depends.encode() + b'\0'
            image = Image([Entry(prefix + 'modules.dep', ''.join(n + ':\n' for n in names).encode())] +
                          [Entry(prefix + n, elf() + metadata) for n in names])
            library = types.SimpleNamespace(SquashFsImage=types.SimpleNamespace(from_bytes=lambda _: image))
            with mock.patch.dict(sys.modules, {'PySquashfsImage': library}), self.subTest(vermagic=vermagic, depends=depends):
                if error:
                    with self.assertRaisesRegex(ValueError, error): build.load_modules(b'hsqs' + bytes(92))
                else:
                    self.assertEqual(set(build.load_modules(b'hsqs' + bytes(92))), set(names))

    def test_regular_reader_bounds_and_symlinks(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as td:
            path = pathlib.Path(td) / 'file'
            path.write_bytes(b'abc')
            self.assertEqual(build.read_regular(path, 3), b'abc')
            with self.assertRaises(ValueError): build.read_regular(path, 2)
            with self.assertRaises(ValueError): build.read_regular(path.parent, 8192)
            link = path.parent / 'link'
            link.symlink_to(path)
            with self.assertRaises(ValueError): build.read_regular(link, 8192)
            path.write_bytes(b'')
            with self.assertRaises(ValueError): build.read_regular(path, 8192)


if __name__ == '__main__':
    unittest.main()
