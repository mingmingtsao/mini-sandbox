import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("swift_coverage", ROOT / "scripts/swift-coverage.py")
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)


class CoverageTests(unittest.TestCase):
    def test_drivers_always_receive_selected_instrumented_binary(self):
        binary_dir = Path("/private/instrumented/debug")
        commands = list(coverage.check_commands(binary_dir))
        self.assertEqual(len(commands), len(coverage.CHECKS))
        for command in commands:
            if "--binary" in command:
                binary = command[command.index("--binary") + 1]
            else:
                binary = command[0]
            self.assertEqual(Path(binary).parent, binary_dir)
            self.assertNotIn(".build/debug", " ".join(command))

    def test_failure_and_missing_profiles_cannot_publish_a_success_report(self):
        for failure in (True, False):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                source = root / "Sources/Module/Unit.swift"
                source.parent.mkdir(parents=True)
                source.touch()
                binary_dir = root / "build/debug"
                obj = binary_dir / "Module.build/Unit.swift.o"
                obj.parent.mkdir(parents=True)
                obj.touch()
                (binary_dir / "description.json").write_text(
                    '{"swiftCommands":{"host":{"moduleName":"SandboxHost","otherArguments":["-package-name","fixture"]}}}'
                )
                output = root / "report"
                output.mkdir()
                marker = output / "coverage.json"
                marker.write_text("previous successful report")
                args = SimpleNamespace(scratch_path=root / "build", output=output, skip_build=True)
                with (
                    patch.object(coverage, "ROOT", root),
                    patch.object(coverage.subprocess, "check_output", return_value=str(binary_dir)),
                    patch.object(
                        coverage.subprocess,
                        "run",
                        side_effect=subprocess.CalledProcessError(1, "check") if failure else None,
                    ),
                ):
                    with self.assertRaises(subprocess.CalledProcessError if failure else ValueError):
                        coverage.run(args)
                self.assertEqual(marker.read_text(), "previous successful report")
                self.assertFalse((output / "coverage.svg").exists())

    def test_invalid_counts_and_empty_denominator_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / "Sources/File.swift"
            for count, covered in [(0, 0), (10, -1), (10, 11), (True, 1), (10, False), (10.0, 1)]:
                with self.subTest(count=count, covered=covered), self.assertRaises(ValueError):
                    coverage.source_totals(
                        {
                            "data": [
                                {
                                    "files": [
                                        {
                                            "filename": str(path),
                                            "summary": {"lines": {"count": count, "covered": covered}},
                                        }
                                    ]
                                }
                            ]
                        },
                        root,
                        [path],
                    )

    def test_unexecuted_source_stays_in_denominator_and_tests_are_excluded(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = [root / "Sources/Used.swift", root / "Sources/Unused.swift"]

            def entry(path, count, covered):
                return {"filename": str(path), "summary": {"lines": {"count": count, "covered": covered}}}

            export = {
                "data": [
                    {
                        "files": [
                            entry(paths[0], 10, 8),
                            entry(paths[1], 90, 0),
                            entry(root / "Tests/Checks.swift", 1000, 1000),
                        ]
                    }
                ]
            }
            result = coverage.source_totals(export, root, paths)
            self.assertEqual((result["covered"], result["lines"], result["percent"]), (8, 100, 8.0))
            self.assertEqual(len(result["files"]), 2)
            self.assertIn("8.0%", coverage.badge(result["percent"]))

    def test_empty_baseline_keeps_nonexecutable_files_without_shrinking_denominator(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            paths = [
                root / "Sources" / name for name in ("Used.swift", "Unused.swift", "Constant.swift", "Disabled.swift")
            ]

            def entry(path, count, covered):
                return {"filename": str(path), "summary": {"lines": {"count": count, "covered": covered}}}

            export = {"data": [{"files": [entry(paths[0], 10, 8), entry(paths[1], 90, 0)]}]}
            baseline = {"data": [{"files": [entry(paths[0], 10, 0), entry(paths[1], 90, 0)]}]}
            result = coverage.source_totals(export, root, paths, baseline=baseline)
            self.assertEqual((result["covered"], result["lines"], result["percent"]), (8, 100, 8.0))
            self.assertEqual(len(result["files"]), 4)
            for row in result["files"]:
                if row["path"].endswith(("Constant.swift", "Disabled.swift")):
                    self.assertEqual((row["covered"], row["lines"]), (0, 0))

    def test_baseline_does_not_hide_missing_executable_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / "Sources/Missing.swift"
            baseline = {
                "data": [{"files": [{"filename": str(path), "summary": {"lines": {"count": 10, "covered": 0}}}]}]
            }
            with self.assertRaisesRegex(ValueError, "missing"):
                coverage.source_totals({"data": [{"files": []}]}, root, [path], baseline=baseline)

    def test_baseline_must_match_mapping_and_contain_no_execution_counts(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / "Sources/Used.swift"

            def export(count, covered):
                return {
                    "data": [
                        {"files": [{"filename": str(path), "summary": {"lines": {"count": count, "covered": covered}}}]}
                    ]
                }

            for baseline, message in [
                (export(9, 0), "differs"),
                (export(10, 1), "execution"),
                ({"data": [{"files": []}]}, "differs"),
            ]:
                with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                    coverage.source_totals(export(10, 8), root, [path], baseline=baseline)

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
