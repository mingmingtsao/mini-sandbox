#!/usr/bin/env python3
"""Driver failure propagation and owned-child cleanup; no credentials recorded."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

import unittest
import time
from test_loopback import child_lines, DriverFailure

ROOT = Path(__file__).resolve().parents[2]
DRIVER = ROOT / "Tests/MCPIntegrationTests/test_loopback.py"


class DriverChecks(unittest.TestCase):
    def run_child_case(self, child_body, *, overall=4.0, inactivity=1.5):
        with tempfile.TemporaryDirectory(prefix="mcp-driver-") as directory:
            directory = Path(directory)
            pidfile = directory / "owned-child.pid"
            child = directory / "child.py"
            child.write_text("#!" + sys.executable + "\nimport os, time\n"
                             + "from pathlib import Path\n"
                             + f"Path({str(pidfile)!r}).write_text(str(os.getpid()))\n"
                             + child_body)
            child.chmod(0o700)
            bootstrap = ("import faulthandler, os, runpy, sys; "
                         "faulthandler.dump_traceback_later(6); "
                         "driver = sys.argv.pop(1); "
                         "sys.path.insert(0, os.path.dirname(driver)); "
                         "runpy.run_path(driver, run_name='__main__')")
            process = subprocess.Popen([sys.executable, "-c", bootstrap, str(DRIVER), "--binary", str(child),
                                        "--overall-timeout", str(overall),
                                        "--inactivity-timeout", str(inactivity)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       start_new_session=True, text=True)
            try:
                try:
                    stdout, stderr = process.communicate(timeout=8)
                except subprocess.TimeoutExpired as error:
                    details = (error.stderr or b"").decode(errors="replace")[-6000:]
                    self.fail("driver deadline did not bound silent child\n" + details)
                self.assertNotEqual(process.returncode, 0)
                self.assertTrue(pidfile.exists(), "child did not execute: " + stdout + stderr)
                pid = int(pidfile.read_text())
                # Observe only this child's recorded PID; never signal a looked-up PID.
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
                return stdout + stderr
            finally:
                if process.poll() is None:
                    # This group was created by this test, not discovered by name.
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=2)

    def test_silent_child_inactivity_deadline_and_cleanup(self):
        output = self.run_child_case("time.sleep(60)\n")
        self.assertIn("inactivity deadline exceeded", output)

    def test_silent_child_overall_deadline_and_cleanup(self):
        output = self.run_child_case("time.sleep(60)\n", overall=1.5, inactivity=4)
        self.assertIn("overall deadline exceeded", output)

    def test_nonzero_child_propagates(self):
        output = self.run_child_case("raise SystemExit(17)\n")
        self.assertIn("executable exited 17", output)

    def test_stdout_eof_does_not_bypass_deadline(self):
        output = self.run_child_case("os.close(1)\ntime.sleep(60)\n")
        self.assertIn("inactivity deadline exceeded", output)

    def test_partial_output_cannot_extend_overall_deadline(self):
        output = self.run_child_case("for _ in range(1000):\n    os.write(1, b'x')\n    time.sleep(0.05)\n", overall=2.5)
        self.assertIn("overall deadline exceeded", output)

    def test_invalid_driver_selector(self):
        result = subprocess.run([sys.executable, str(DRIVER), "--not-a-selector"],
                                capture_output=True, timeout=3)
        self.assertEqual(result.returncode, 2)

    def test_invalid_executable_selector(self):
        result = subprocess.run([str(ROOT / ".build/debug/MCPGatewayChecks"), "invalid"],
                                capture_output=True, timeout=3)
        self.assertEqual(result.returncode, 64)

    def bounded_output(self, body):
        process = subprocess.Popen([sys.executable, "-c", body], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        assert process.stdout is not None
        try:
            with self.assertRaisesRegex(DriverFailure, "child output limit exceeded"):
                list(child_lines(process, time.monotonic() + 3, 2))
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=2)
            process.stdout.close()

    def test_direct_line_output_limit(self):
        self.bounded_output("import os; os.write(1, b'x' * 8193)")

    def test_direct_cumulative_output_limit(self):
        self.bounded_output("import os; [os.write(1, b'x\\n' * 1024) for _ in range(129)]")


if __name__ == "__main__":
    unittest.main()
