#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('vm_build', ROOT / 'scripts/build-vm-probe.py')
assert spec is not None and spec.loader is not None
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)

class BuildSafety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ['TMPDIR'])
        self.root = Path(self.tmp.name)
        self.output = self.root / 'VMProbe'
    def tearDown(self): self.tmp.cleanup()
    def test_absent(self): self.assertIsNone(build.check_existing(self.output))
    def test_unmarked_preserved(self):
        self.output.mkdir()
        with self.assertRaises(RuntimeError): build.check_existing(self.output)
        self.assertTrue(self.output.is_dir())
    def test_symlink_preserved(self):
        self.output.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(RuntimeError): build.check_existing(self.output)
        self.assertTrue(self.output.is_symlink())
    def test_world_writable(self):
        self.output.mkdir(mode=0o777); self.output.chmod(0o777)
        with self.assertRaises(RuntimeError): build.safe_directory(self.output)
    def test_valid_owner(self):
        self.output.mkdir(); (self.output / build.MARKER).write_text(json.dumps(build.ownership(self.output)))
        self.assertIsNotNone(build.check_existing(self.output))
    def test_foreign_marker(self):
        self.output.mkdir(); (self.output / build.MARKER).write_text('{}')
        with self.assertRaises(RuntimeError): build.check_existing(self.output)
    def test_link_marker(self):
        self.output.mkdir(); (self.output / build.MARKER).symlink_to(self.root / 'other')
        with self.assertRaises(RuntimeError): build.check_existing(self.output)
    def test_signing_commands_avoid_deprecated_entitlement_path(self):
        bin_dir = self.root / 'bin'; bin_dir.mkdir()
        (bin_dir / 'VMProbe').write_bytes(b'probe')
        commands = []
        with mock.patch.object(build, 'ROOT', self.root), \
                mock.patch.object(build.subprocess, 'run', side_effect=lambda args, **_: commands.append(args)), \
                mock.patch.object(build.subprocess, 'check_output', return_value=str(bin_dir)), \
                mock.patch.object(sys, 'argv', ['build-vm-probe.py']), \
                contextlib.redirect_stdout(io.StringIO()):
            build.main()
        display = [args for args in commands if args[:2] == ['codesign', '--display']]
        self.assertEqual(len(display), 1)
        self.assertEqual(display[0][2:5], ['--entitlements', '-', '--xml'])
        self.assertNotIn(':-', [part for args in commands for part in args])
        self.assertTrue((self.root / 'dist/VMProbe/VMProbe').is_file())

if __name__ == '__main__': unittest.main()
