import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location(
    "presentation_driver", Path(__file__).resolve().parents[1] / "PresentationTests/run.py"
)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class PresentationDriverTests(unittest.TestCase):
    def test_zero_exit_without_every_check_is_not_success(self):
        for output in ("", "PASS all presentation checks", "\n".join(sorted(driver.EXPECTED)[:-1])):
            with self.subTest(output=output), self.assertRaises(ValueError):
                driver.validate(SimpleNamespace(returncode=0, stdout=output))

    def test_nonzero_or_blocked_cannot_become_success(self):
        output = "\n".join(sorted(driver.EXPECTED))
        for status, suffix in ((1, ""), (0, "\nBLOCKED host"), (0, "\nFAIL render")):
            with self.subTest(status=status, suffix=suffix), self.assertRaises(ValueError):
                driver.validate(SimpleNamespace(returncode=status, stdout=output + suffix))
        driver.validate(SimpleNamespace(returncode=0, stdout=output))
