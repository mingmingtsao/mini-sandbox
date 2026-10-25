import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("swift_coverage", ROOT / "scripts/swift-coverage.py")
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)


class CoverageTests(unittest.TestCase):
    def test_unexecuted_source_stays_in_denominator_and_tests_are_excluded(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = [root / "Sources/Used.swift", root / "Sources/Unused.swift"]
            def entry(path, count, covered):
                return {"filename": str(path), "summary": {"lines": {"count": count, "covered": covered}}}
            export = {"data": [{"files": [entry(paths[0], 10, 8), entry(paths[1], 90, 0),
                                            entry(root / "Tests/Checks.swift", 1000, 1000)]}]}
            result = coverage.source_totals(export, root, paths)
            self.assertEqual((result["covered"], result["lines"], result["percent"]), (8, 100, 8.0))
            self.assertEqual(len(result["files"]), 2)
            self.assertIn("8.0%", coverage.badge(result["percent"]))

    def test_missing_source_or_duplicate_mapping_fails_instead_of_inflating_coverage(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / "Sources/Missing.swift"
            with self.assertRaisesRegex(ValueError, "missing"):
                coverage.source_totals({"data": [{"files": []}]}, root, [path])
            entry = {"filename": str(path), "summary": {"lines": {"count": 10, "covered": 10}}}
            with self.assertRaisesRegex(ValueError, "duplicate"):
                coverage.source_totals({"data": [{"files": [entry, entry]}]}, root, [path])


if __name__ == "__main__":
    unittest.main()
