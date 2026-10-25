"""Regression tests for packaging path and ownership safety."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
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
        (self.root / "VERSION").write_text("0.1.0\n")
        self.build_app.ROOT = self.root
        self.commands = []

    def tearDown(self):
        self.tempdir.cleanup()

    def run_build(self, *extra):
        def fake_run(*args):
            self.commands.append(args)
            if args[0] == "codesign":
                return None
            self.assertEqual(args[:2], ("swift", "build"))

        def fake_check_output(args, **_):
            self.commands.append(tuple(args))
            return str(self.bin_dir)

        with (
            mock.patch.object(self.build_app, "run", side_effect=fake_run),
            mock.patch.object(self.build_app.subprocess, "check_output", side_effect=fake_check_output),
            mock.patch.object(sys, "argv", [str(SCRIPT), *extra]),
            contextlib.redirect_stdout(io.StringIO()) as output,
        ):
            self.build_app.main()
        return json.loads(output.getvalue())

    def plist(self, app):
        with (Path(app) / "Contents/Info.plist").open("rb") as stream:
            return plistlib.load(stream)

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

        with (
            mock.patch.object(self.build_app, "run", side_effect=fail_sign),
            mock.patch.object(self.build_app.subprocess, "check_output", return_value=str(self.bin_dir)),
            mock.patch.object(sys, "argv", [str(SCRIPT)]),
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                self.build_app.main()
        self.assertEqual((output / "Contents/MacOS/MiniSandbox").read_bytes(), b"test executable")

    def test_app_signing_grants_virtualization_to_actual_bundle(self):
        with self.build_app.ENTITLEMENTS.open("rb") as stream:
            self.assertEqual(plistlib.load(stream), {"com.apple.security.virtualization": True})
        commands = []
        with (
            mock.patch.object(self.build_app, "run", side_effect=lambda *args: commands.append(args)),
            mock.patch.object(self.build_app.subprocess, "check_output", return_value=str(self.bin_dir)),
            mock.patch.object(sys, "argv", [str(SCRIPT)]),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.build_app.main()
        signing = [args for args in commands if args[:2] == ("codesign", "--force")]
        self.assertEqual(len(signing), 1)
        self.assertEqual(signing[0][4:6], ("--entitlements", str(self.build_app.ENTITLEMENTS)))
        self.assertIn(".MiniSandbox-build-", signing[0][-1])
        self.assertIn(("codesign", "--verify", "--strict", "--verbose=2", signing[0][-1]), commands)

    def test_bundle_version_comes_from_version_file_and_build_number(self):
        (self.root / "VERSION").write_text("2.3.4\n")
        result = self.run_build("--build-number", "17")
        info = self.plist(result["app"])
        self.assertEqual(info["CFBundleShortVersionString"], "2.3.4")
        self.assertEqual(info["CFBundleVersion"], "17")
        self.assertEqual((result["version"], result["build_number"]), ("2.3.4", 17))

    def test_invalid_version_file_is_refused_before_building(self):
        for value in ("latest\n", "1.2\n", "1.2.3-beta\n"):
            (self.root / "VERSION").write_text(value)
            self.commands.clear()
            with self.assertRaises(RuntimeError):
                self.run_build()
            self.assertEqual(self.commands, [])
            self.assertFalse((self.root / "dist").exists())

    def test_symlinked_or_missing_version_file_is_refused(self):
        version = self.root / "VERSION"
        version.unlink()
        with self.assertRaises(RuntimeError):
            self.run_build()
        (self.root / "real-version").write_text("0.1.0\n")
        version.symlink_to(self.root / "real-version")
        with self.assertRaises(RuntimeError):
            self.run_build()

    def test_invalid_build_number_is_rejected(self):
        for value in ("0", "-1", "abc", "1.5", "\u00b2"):
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                self.run_build("--build-number", value)

    def test_release_build_has_no_fixture_define_or_separate_build_path(self):
        result = self.run_build()
        self.assertEqual(result["variant"], "release")
        self.assertEqual(Path(result["app"]).name, "MiniSandbox.app")
        self.assertEqual(self.plist(result["app"])["CFBundleIdentifier"], "dev.mini-sandbox.app")
        flattened = [part for command in self.commands for part in command]
        self.assertNotIn("-DSANDBOX_TEST_FIXTURES", flattened)
        self.assertNotIn("--build-path", flattened)

    def test_fixture_build_uses_separate_products_output_and_identity(self):
        release = self.run_build()
        release_executable = Path(release["app"]) / "Contents/MacOS/MiniSandbox"
        self.binary.write_bytes(b"fixture executable")
        self.commands.clear()
        fixture = self.run_build("--test-fixtures", "--configuration", "debug")

        app = Path(fixture["app"])
        self.assertEqual(app, self.root / "dist" / "MiniSandboxFixture.app")
        self.assertEqual(fixture["variant"], "local-fixture")
        info = self.plist(app)
        self.assertEqual(info["CFBundleIdentifier"], "dev.mini-sandbox.app.local-fixture")
        self.assertEqual(info["CFBundleName"], "Mini Sandbox Local Fixture")
        build = [command for command in self.commands if command[:2] == ("swift", "build") and "--product" in command]
        self.assertEqual(len(build), 1)
        self.assertIn(("-Xswiftc", "-DSANDBOX_TEST_FIXTURES"), list(zip(build[0], build[0][1:])))
        build_path = ("--build-path", str(self.root / ".build/fixtures"))
        self.assertIn(build_path, list(zip(build[0], build[0][1:])))
        show = [command for command in self.commands if "--show-bin-path" in command]
        self.assertEqual(len(show), 1)
        self.assertIn(build_path, list(zip(show[0], show[0][1:])))
        signing = [command for command in self.commands if command[:2] == ("codesign", "--force")]
        self.assertEqual(signing[0][4:6], ("--entitlements", str(self.build_app.ENTITLEMENTS)))
        self.assertEqual(release_executable.read_bytes(), b"test executable", "release bundle must stay untouched")
        marker = json.loads((app / "Contents/Resources" / ".mini-sandbox-owner").read_text())
        self.assertEqual(marker["output"], str(app))


if __name__ == "__main__":
    unittest.main()
