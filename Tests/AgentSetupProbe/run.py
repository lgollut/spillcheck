#!/usr/bin/env python3
"""Compile and run isolated app setup contracts using the already-built core package."""
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
args = parser.parse_args()
if args.products_path is not None:
    products = args.products_path.resolve()
else:
    result = subprocess.run(["swift", "build", "--show-bin-path"], cwd=root,
                            check=True, capture_output=True, text=True, timeout=30)
    products = Path(result.stdout.strip())
module_map = root / ".build" / "checkouts" / "GRDB.swift" / "Sources" / "GRDBSQLite" / "module.modulemap"
library = products / "libSpillcheckCore.a"
if not module_map.exists() or not library.exists():
    sys.exit("Build the core package first; this probe links its cached SpillcheckCore product.")

output = root / ".build" / "implementation" / "agent-setup-probe"
output.parent.mkdir(parents=True, exist_ok=True)
command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-target", "arm64-apple-macosx14.0",
           "-I", str(products), "-Xcc", "-fmodule-map-file=" + str(module_map),
           str(root / "Spillcheck/App/AppModel.swift"),
           str(root / "Spillcheck/App/Theme.swift"),
           str(root / "Spillcheck/App/InventoryDetailView.swift"),
           str(root / "Spillcheck/App/InventoryView.swift"),
           str(root / "Spillcheck/App/CoverageView.swift"),
           str(root / "Spillcheck/App/SettingsView.swift"),
           str(root / "Spillcheck/App/AgentSetupViews.swift"),
           str(root / "Spillcheck/App/OnboardingVisuals.swift"),
           str(root / "Spillcheck/App/AgentSetupController.swift"),
           str(root / "Spillcheck/App/CollectionConfiguration.swift"),
           str(root / "Tests/AgentSetupProbe/main.swift"),
           str(library), "-lsqlite3", "-framework", "Security", "-framework", "LocalAuthentication",
           "-o", str(output)]
subprocess.run(command, cwd=root, check=True, timeout=120)
probe = subprocess.run([str(output)], cwd=root, timeout=60, capture_output=True, text=True)
report = json.loads(probe.stdout)
reproduce = ["python3", "Tests/AgentSetupProbe/run.py"]
if args.products_path is not None:
    reproduce += ["--products-path", os.path.relpath(products, root)]
report["command"] = shlex.join(reproduce)
report_path = root / ".build" / "implementation" / "agent-setup-probe.json"
report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
print(json.dumps(report, sort_keys=True))
if probe.returncode or not report.get("passed"):
    sys.exit(probe.returncode or 1)
