"""Credential-free CLI safety regressions; never invokes a live provider."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class StructuredModelCLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = Path(__file__).resolve().parents[2] / ".build/debug/StructuredModelChecks"
        if not cls.binary.is_file():
            raise RuntimeError("Build StructuredModelChecks before running CLI checks")
        cls.scratch = os.environ.get("TMPDIR")
        if not cls.scratch:
            raise RuntimeError("A private TMPDIR is required")

    def invoke(self, args):
        # env removes the one variable without Python reading or logging its value.
        return subprocess.run(
            ["/usr/bin/env", "-u", "TEST_DEEPSEEK_KEY", str(self.binary), *args],
            capture_output=True,
            text=True,
            timeout=15,
        )

    def test_malformed_modes_refuse_before_fixtures_or_evidence(self):
        with tempfile.TemporaryDirectory(prefix="structured-cli-", dir=self.scratch) as root:
            evidence = str(Path(root) / "evidence")
            cases = [
                ["--unknown"],
                ["--live"],
                ["--evidence-dir", evidence],
                ["--live", "--evidence-dir", "relative"],
                ["--live", "--evidence-dir", evidence, "--extra"],
                ["--live", "--evidence-dir", evidence + "/../escape"],
            ]
            for args in cases:
                with self.subTest(args=args):
                    result = self.invoke(args)
                    self.assertEqual(result.returncode, 64)
                    self.assertIn("USAGE:", result.stdout)
                    self.assertNotIn("PASS", result.stdout + result.stderr)
                    self.assertEqual(list(Path(root).iterdir()), [])

    def test_missing_key_refuses_before_evidence(self):
        with tempfile.TemporaryDirectory(prefix="structured-cli-", dir=self.scratch) as root:
            result = self.invoke(["--live", "--evidence-dir", str(Path(root) / "evidence")])
            self.assertEqual(result.returncode, 2)
            self.assertIn("BLOCKED structured live: missing TEST_DEEPSEEK_KEY", result.stdout)
            self.assertNotIn("PASS", result.stdout + result.stderr)
            self.assertEqual(list(Path(root).iterdir()), [])

    def test_transport_offline_mode_rejects_mixed_modes_before_running_checks(self):
        binary = self.binary.parent / "ModelTransportChecks"
        for args in (["--offline", "--live"], ["--live", "--offline"], ["--offline", "other"]):
            with self.subTest(args=args):
                result = subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 64)
                self.assertIn("USAGE:", result.stdout)
                self.assertNotIn("PASS", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
