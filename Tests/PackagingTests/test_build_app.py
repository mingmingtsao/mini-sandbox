"""Regression tests for packaging path and ownership safety."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "build-app.py"


def load_build_app():
    spec = importlib.util.spec_from_file_location("build_app_under_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.build_app = load_build_app()
        self.tempdir = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.root = Path(self.tempdir.name)
        self.bin_dir = self.root / "swift-bin"
        self.bin_dir.mkdir()
        self.binary = self.bin_dir / "MiniSandbox"
        self.binary.write_bytes(b"test executable")
        self.build_app.ROOT = self.root

    def tearDown(self):
        self.tempdir.cleanup()

    def run_build(self):
        def fake_run(*args):
            if args[0] == "codesign":
                return None
            self.assertEqual(args[:2], ("swift", "build"))

        with mock.patch.object(self.build_app, "run", side_effect=fake_run), \
                mock.patch.object(self.build_app.subprocess, "check_output", return_value=str(self.bin_dir)), \
                mock.patch.object(sys, "argv", [str(SCRIPT)]), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.build_app.main()
        return json.loads(output.getvalue())

    def test_symlinked_dist_is_refused_without_touching_target(self):
        external = self.root / "external"
        external.mkdir()
        sentinel = external / "sentinel"
        sentinel.write_text("keep")
        (self.root / "dist").symlink_to(external, target_is_directory=True)

        with self.assertRaises(RuntimeError):
            self.run_build()

        self.assertEqual(sentinel.read_text(), "keep")
        self.assertTrue((self.root / "dist").is_symlink())

    def test_unowned_existing_app_is_refused_and_preserved(self):
        dist = self.root / "dist"
        app = dist / "MiniSandbox.app"
        (app / "Contents").mkdir(parents=True)
        sentinel = app / "Contents" / "unowned.txt"
        sentinel.write_text("keep")

        with self.assertRaises(RuntimeError):
            self.run_build()

        self.assertEqual(sentinel.read_text(), "keep")

    def test_symlinked_output_is_refused_without_touching_target(self):
        dist = self.root / "dist"
        dist.mkdir()
        external = self.root / "external-app"
        (external / "Contents").mkdir(parents=True)
        sentinel = external / "Contents" / "sentinel"
        sentinel.write_text("keep")
        (dist / "MiniSandbox.app").symlink_to(external, target_is_directory=True)

        with self.assertRaises(RuntimeError):
            self.run_build()

        self.assertEqual(sentinel.read_text(), "keep")
        self.assertTrue((dist / "MiniSandbox.app").is_symlink())

    def test_owned_output_can_be_rebuilt_and_previous_output_is_replaced(self):
        first = self.run_build()
        app = Path(first["app"])
        marker = app / "Contents/Resources" / ".mini-sandbox-owner"
        self.assertTrue(marker.is_file())
        self.assertEqual((app.stat().st_mode & 0o777), 0o755, "App bundle must be traversable by macOS launch services")
        self.assertEqual((app.parent.stat().st_mode & 0o777), 0o755)
        first_marker = json.loads(marker.read_text())
        self.assertEqual(first_marker["project_root"], str(self.root.resolve()))
        self.assertEqual(first_marker["output"], str(app))

        self.binary.write_bytes(b"replacement executable")
        second = self.run_build()

        self.assertEqual(second["app"], str(app))
        self.assertEqual((app / "Contents" / "MacOS" / "MiniSandbox").read_bytes(), b"replacement executable")
        self.assertEqual(json.loads(marker.read_text()), first_marker)
        previous = Path(second["previous_bundle"])
        self.assertEqual((previous / "Contents/MacOS/MiniSandbox").read_bytes(), b"test executable")

    def test_dangling_output_symlink_is_preserved(self):
        dist = self.root / "dist"
        dist.mkdir()
        output = dist / "MiniSandbox.app"
        output.symlink_to(self.root / "missing")
        with self.assertRaises(RuntimeError):
            self.run_build()
        self.assertTrue(output.is_symlink())

    def test_unexpected_output_file_is_preserved(self):
        dist = self.root / "dist"
        dist.mkdir()
        output = dist / "MiniSandbox.app"
        output.write_text("not generated")
        with self.assertRaises(RuntimeError):
            self.run_build()
        self.assertEqual(output.read_text(), "not generated")

    def test_signing_failure_preserves_previous_bundle(self):
        first = self.run_build()
        output = Path(first["app"])
        def fail_sign(*args):
            if args[0] == "codesign":
                raise subprocess.CalledProcessError(1, args)
        with mock.patch.object(self.build_app, "run", side_effect=fail_sign), \
                mock.patch.object(self.build_app.subprocess, "check_output", return_value=str(self.bin_dir)), \
                mock.patch.object(sys, "argv", [str(SCRIPT)]):
            with self.assertRaises(subprocess.CalledProcessError):
                self.build_app.main()
        self.assertEqual((output / "Contents/MacOS/MiniSandbox").read_bytes(), b"test executable")


if __name__ == "__main__":
    unittest.main()
