#!/usr/bin/env python3
"""Run the offline Python checks, isolating each directory's unittest imports."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TESTS = Path(__file__).resolve().parents[1]
ROOT = TESTS.parent
DIRECTORIES = (
    "AppAcceptance", "BetaTrial",
    "ClaudeLive", "CodexHookPromptProbe",
    "CodexLive", "CodexLocalMediaProbe", "CodexMCPPipelineProbe",
    "CodexMCPSourceProbe", "CodexPlanProbe", "CodexReviewProbe", "CodexReviewRecoveryProbe",
    "ProtectionSignedProbe", "Support", "Tooling",
)
# These unittest scripts have non-discovery filenames. Load their cases explicitly.
EXTRA_MODULES = {"Tooling": ("check-scanner-bundling.py", "check-release-policy.py")}
SEPARATE_SCRIPTS = {
    "HookHelper/test_delivery.py": "requires the compiled hook helper; CI runs this separately",
    "ClaudeLive/test-evidence.py": "requires compiled Core/GRDB products; see ClaudeLive/README.md",
    "CodexLive/test-evidence.py": "requires compiled Core/GRDB products; see CodexLive/README.md",
}
def validate_inventory(tests=TESTS):
    discovered = {p.relative_to(tests).as_posix() for pattern in ("test_*.py", "test-*.py", "check-*.py")
                  for p in tests.rglob(pattern)}
    registered = {p.relative_to(tests).as_posix() for name in DIRECTORIES
                  for p in (tests / name).glob("test_*.py")}
    registered.update(f"{directory}/{name}" for directory, names in EXTRA_MODULES.items() for name in names)
    registered.update(SEPARATE_SCRIPTS)
    missing = sorted(registered - discovered)
    unknown = sorted(discovered - registered)
    if missing or unknown:
        raise ValueError(f"Python test inventory changed. Missing: {missing}; unclassified: {unknown}. "
                         "Update run-python-tests.py so every suite has an explicit execution scope.")


def run_directory(directory):
    sys.path.insert(0, str(directory))
    loader = unittest.TestLoader()
    loaded = loader.discover(str(directory), pattern="test_*.py")
    for filename in EXTRA_MODULES.get(directory.name, ()):
        spec = importlib.util.spec_from_file_location(Path(filename).stem, directory / filename)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        loaded.addTests(loader.loadTestsFromModule(module))
    if loaded.countTestCases() == 0:
        raise ValueError(f"No offline tests found in {directory}")
    result = unittest.TextTestRunner(verbosity=1).run(loaded)
    return {"passed": result.wasSuccessful(), "tests": result.testsRun, "skipped": len(result.skipped)}


def print_scope():
    print("Separate checks, excluded from this run:", flush=True)
    for name, reason in SEPARATE_SCRIPTS.items():
        print(f"  {name}: {reason}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="List suites and separate prerequisite checks without running tests.")
    parser.add_argument("--suite", action="append", choices=DIRECTORIES, help="Run only the named directory; repeat to select more.")
    parser.add_argument("--_directory", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--_result", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args._directory:
        result = run_directory(args._directory)
        args._result.write_text(json.dumps(result))
        return 0 if result["passed"] else 1

    validate_inventory()
    directories = list(dict.fromkeys(args.suite or DIRECTORIES))
    print_scope()
    if args.list:
        print("\nOffline suites:\n  " + "\n  ".join(directories))
        return 0
    (ROOT / ".build").mkdir(exist_ok=True)
    totals = {"tests": 0, "skipped": 0}
    failures = []
    with tempfile.TemporaryDirectory(prefix="spillcheck-python-tests-") as temporary:
        for name in directories:
            print(f"\n=== {name} ===", flush=True)
            report = Path(temporary) / f"{name}.json"
            command = [sys.executable, str(Path(__file__).resolve()), "--_directory", str(TESTS / name),
                       "--_result", str(report)]
            completed = subprocess.run(command, cwd=ROOT)
            if report.is_file():
                result = json.loads(report.read_text())
                for key in totals:
                    totals[key] += result[key]
            else:
                result = {"passed": False}
            if completed.returncode or not result["passed"]:
                failures.append(name)
    print(f"\n{totals['tests']} tests run across {len(directories)} suites; "
          f"{totals['skipped']} skipped.", flush=True)
    if failures:
        print("FAILED suites: " + ", ".join(failures), file=sys.stderr)
        return 1
    print("All selected offline Python suites passed.", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError) as error:
        sys.exit(str(error))
