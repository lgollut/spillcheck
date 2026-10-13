"""Check that the offline entrypoint cannot turn missing or failing tests green."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("run-python-tests.py")
spec = importlib.util.spec_from_file_location("offline_python_runner", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class PythonRunnerTests(unittest.TestCase):
    def run_fixture(self, directory):
        report = directory / "result.json"
        result = subprocess.run([sys.executable, str(SCRIPT), "--_directory", str(directory),
            "--_result", str(report)], capture_output=True, text=True, timeout=15)
        return result, json.loads(report.read_text()) if report.exists() else None

    def test_discovery_runs_cases_without_a_main_block_and_isolates_duplicate_module_names(self):
        with tempfile.TemporaryDirectory() as temporary:
            for name, expected in (("one", "first"), ("two", "second")):
                directory = Path(temporary) / name
                directory.mkdir()
                (directory / "helper.py").write_text(f"VALUE = {expected!r}\n")
                (directory / "test_boundary.py").write_text(
                    "import unittest\nimport helper\nclass Checks(unittest.TestCase):\n"
                    f"    def test_isolated_import(self): self.assertEqual(helper.VALUE, {expected!r})\n")
                result, report = self.run_fixture(directory)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(report["tests"], 1)
                self.assertTrue(report["passed"])

    def test_failures_and_import_errors_return_nonzero(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for source in ("import module_that_does_not_exist\n",
                    "import unittest\nclass Checks(unittest.TestCase):\n"
                    "    def test_failure(self): self.fail('expected failure')\n"):
                with self.subTest(source=source):
                    (directory / "test_boundary.py").write_text(source)
                    result, report = self.run_fixture(directory)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(report["passed"])
                    self.assertEqual(report["tests"], 1)

    def test_empty_directory_fails_instead_of_reporting_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, report = self.run_fixture(Path(temporary))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("No offline tests found", result.stderr)
            self.assertIsNone(report)

    def test_inventory_rejects_unclassified_and_missing_scripts(self):
        with tempfile.TemporaryDirectory() as temporary:
            tests = Path(temporary)
            (tests / "Registered").mkdir()
            (tests / "Registered/test_one.py").touch()
            with patch.object(runner, "DIRECTORIES", ("Registered",)), \
                    patch.object(runner, "EXTRA_MODULES", {}), patch.object(runner, "SEPARATE_SCRIPTS", {}):
                runner.validate_inventory(tests)
                (tests / "Registered/test-evidence.py").touch()
                with self.assertRaisesRegex(ValueError, "unclassified.*test-evidence"):
                    runner.validate_inventory(tests)
                (tests / "Registered/test-evidence.py").unlink()
                with patch.object(runner, "SEPARATE_SCRIPTS", {"Missing/test_two.py": "compiled"}):
                    with self.assertRaisesRegex(ValueError, "Missing.*test_two"):
                        runner.validate_inventory(tests)


if __name__ == "__main__":
    unittest.main()
