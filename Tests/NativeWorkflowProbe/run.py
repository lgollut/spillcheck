#!/usr/bin/env python3
"""Build and run controller race checks without macOS prompts or provider sessions."""
from pathlib import Path
import argparse
import json
import os
import shlex
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--products-path", type=Path, help="Reuse existing core build products without invoking SwiftPM.")
parser.add_argument("--output-directory", type=Path, default=Path(".build/implementation"))
args = parser.parse_args()
if args.products_path is not None:
    products = args.products_path.resolve()
else:
    result = subprocess.run(["swift", "build", "--show-bin-path"], cwd=root,
                            check=True, capture_output=True, text=True)
    products = Path(result.stdout.strip())
output_directory = args.output_directory.resolve()
output = output_directory / "native-workflow-probe"
output.parent.mkdir(parents=True, exist_ok=True)
module_map = root / ".build" / "checkouts" / "GRDB.swift" / "Sources" / "GRDBSQLite" / "module.modulemap"
if not module_map.exists():
    sys.exit("Run swift test to build the core package first.")
command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-target", "arm64-apple-macosx14.0",
           "-I", str(products), "-Xcc", "-fmodule-map-file=" + str(module_map),
           str(root / "Spillcheck/App/ViewingController.swift"),
           str(root / "Spillcheck/App/NotificationController.swift"),
           str(root / "Spillcheck/App/SourceOpeningController.swift"),
           str(root / "Spillcheck/App/AppModel.swift"),
           str(root / "Spillcheck/App/Theme.swift"),
           str(root / "Spillcheck/App/InventoryDetailView.swift"),
           str(root / "Spillcheck/App/InventoryView.swift"),
           str(root / "Spillcheck/App/CoverageView.swift"),
           str(root / "Spillcheck/App/SettingsView.swift"),
           str(root / "Spillcheck/App/SetupView.swift"),
           str(Path(__file__).with_name("main.swift")),
           str(products / "libSpillcheckCore.a"), "-lsqlite3", "-framework", "Security",
           "-framework", "LocalAuthentication", "-framework", "UserNotifications", "-framework", "AppKit",
           "-o", str(output)]
subprocess.run(command, cwd=root, check=True)
probe = subprocess.run([str(output)], cwd=root, timeout=30, capture_output=True, text=True)
report = json.loads(probe.stdout)
reproduce = ["python3", "Tests/NativeWorkflowProbe/run.py"]
if args.products_path is not None:
    reproduce += ["--products-path", os.path.relpath(products, root)]
if output_directory != root / ".build" / "implementation":
    reproduce += ["--output-directory", os.path.relpath(output_directory, root)]
report["command"] = shlex.join(reproduce)
report["reusedCoreProducts"] = args.products_path is not None
report_path = output_directory / "native-workflow-probe.json"
report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
print(json.dumps(report, sort_keys=True))
if probe.returncode or not report.get("passed"):
    sys.exit(probe.returncode or 1)
