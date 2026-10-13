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
parser.add_argument("--owner-diagnostics-only", action="store_true", help="Run only pure vault-owner diagnostic assertions; no vault or Keychain access.")
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
command = ["xcrun", "swiftc", "-parse-as-library", "-D", "DEBUG", "-swift-version", "6", "-target", "arm64-apple-macosx14.0",
           "-I", str(products), "-Xcc", "-fmodule-map-file=" + str(module_map),
           str(root / "Spillcheck/App/AppModel.swift"),
           str(root / "Spillcheck/App/CoveragePresentation.swift"),
           str(root / "Spillcheck/App/CoverageReadEvidence.swift"),
           str(root / "Spillcheck/App/CoverageDiagnostics.swift"),
           str(root / "Spillcheck/App/SignedRecoveryVaultOwner.swift"),
           str(root / "Spillcheck/App/InventoryStateAcceptance.swift"),
           str(root / "Spillcheck/App/WebResultAcceptance.swift"),
           str(root / "Spillcheck/App/NativeContentAcceptance.swift"),
           str(root / "Spillcheck/App/ReviewAcceptance.swift"),
           str(root / "Spillcheck/App/DesktopBetaAcceptance.swift"),
           str(root / "Spillcheck/App/Theme.swift"),
           str(root / "Spillcheck/App/InventoryDetailView.swift"),
           str(root / "Spillcheck/App/InventoryView.swift"),
           str(root / "Spillcheck/App/CoverageView.swift"),
           str(root / "Spillcheck/App/SettingsView.swift"),
           str(root / "Spillcheck/App/AgentSetupViews.swift"),
           str(root / "Spillcheck/App/OnboardingVisuals.swift"),
           str(root / "Spillcheck/App/AgentSetupController.swift"),
           str(root / "Spillcheck/App/SourceOpeningController.swift"),
           str(root / "Spillcheck/App/CollectionConfiguration.swift"),
           str(root / "Tests/AgentSetupProbe/CoverageAssertions.swift"),
           str(root / "Tests/AgentSetupProbe/CoverageRestartAssertions.swift"),
           str(root / "Tests/AgentSetupProbe/StartupDiagnosticsAssertions.swift"),
           str(root / "Tests/AgentSetupProbe/VaultOwnerDiagnosticsAssertions.swift"),
           str(root / "Tests/AgentSetupProbe/SourceOpeningAssertions.swift"),
           str(root / "Tests/AgentSetupProbe/CollectionAssessmentAssertions.swift"),
           str(root / "Tests/AgentSetupProbe/StorageCapacityAssertions.swift"),
           str(root / "Tests/AgentSetupProbe/MigrationInventoryAssertions.swift"),
           str(root / "Tests/AgentSetupProbe/InventoryStateAcceptanceAssertions.swift"),
           str(root / "Tests/AgentSetupProbe/WebResultAcceptanceAssertions.swift"),
           str(root / "Tests/AgentSetupProbe/NativeContentAcceptanceAssertions.swift"),
           str(root / "Tests/AgentSetupProbe/ReviewAcceptanceAssertions.swift"),
           str(root / "Tests/AgentSetupProbe/DesktopBetaAcceptanceAssertions.swift"),
           str(root / "Tests/AgentSetupProbe/main.swift"),
           str(library), "-lsqlite3", "-framework", "Security", "-framework", "LocalAuthentication",
           "-o", str(output)]
subprocess.run(command, cwd=root, check=True, timeout=180)
probe_arguments = [str(output)] + (["--owner-diagnostics-only"] if args.owner_diagnostics_only else [])
probe = subprocess.run(probe_arguments, cwd=root, timeout=60, capture_output=True, text=True)
report = json.loads(probe.stdout)
reproduce = ["python3", "Tests/AgentSetupProbe/run.py"]
if args.products_path is not None:
    reproduce += ["--products-path", os.path.relpath(products, root)]
if args.owner_diagnostics_only:
    reproduce += ["--owner-diagnostics-only"]
report["command"] = shlex.join(reproduce)
report_name = "vault-owner-diagnostics-probe.json" if args.owner_diagnostics_only else "agent-setup-probe.json"
report_path = root / ".build" / "implementation" / report_name
report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
print(json.dumps(report, sort_keys=True))
if probe.returncode or not report.get("passed"):
    sys.exit(probe.returncode or 1)
