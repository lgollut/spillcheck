#!/usr/bin/env python3
"""Reparse one selected genuine GUI session and its own children. No provider launch."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

spec = importlib.util.spec_from_file_location("claude_gui_cold", Path(__file__).with_name("run.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

def run(args):
    os.umask(0o077)
    source = args.source.resolve()
    source.relative_to(args.source_root.resolve())
    paths = probe.selected_files(source)
    directory = Path(tempfile.mkdtemp(prefix="spillcheck-claude-gui-cold-", dir="/tmp")).resolve()
    before = {path: (path.stat().st_size, path.stat().st_mtime_ns) for path in paths}
    report = {"schemaVersion": 1, "phase0Passed": False, "parserContract": "claude-transcript-5",
        "hostVersion": args.host_version, "configuredHarnessProducerVersion": args.producer_version,
        "coreHarnessInterface": "standaloneCLI", "officialGUICreatedSourceManuallySelected": True,
        "productionDesktopCollectorEnabled": False, "sourceAuthority": "nativeTranscript",
        "providerLaunchCount": 0, "globalConfigurationChanged": False,
        "freshEncryptedCatchUpStore": True, "genuinePriorStoreOmissionRecoveryMeasured": False}
    process = None
    try:
        process, lines, diagnostics, _ = probe.start_driver(args, directory, directory / "settings.json",
            args.helper_executable.resolve())
        report["coldHistoryDelivery"] = probe.history_delivery(args, directory, paths)
        report["coldCatchUpCore"] = probe.final_driver(process, lines, diagnostics, directory)
        process = None
        report["nativeSourceObservation"], _ = probe.native_summary(source, os.urandom(32))
        report.update(probe.cold_gate(report))
        report["zeroCoverageGaps"] = report["coldCatchUpCore"].get("result", {}).get("gapReasons") == []
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        report["controlledFailure"] = type(error).__name__
    finally:
        if process is not None:
            report["processGroupCleanup"] = probe.stop_group(process)
        shutil.rmtree(directory)
    report["disposableProbeRootRemoved"] = not directory.exists()
    report["originalProviderHistoryRetainedUnchanged"] = all(path.exists()
        and (path.stat().st_size, path.stat().st_mtime_ns) == status for path, status in before.items())
    report["passedAvailableCatchUpSubgate"] = bool(report.get("coldRequiredContentAndChildCommitted")
        and report.get("zeroCoverageGaps") and report["disposableProbeRootRemoved"]
        and report["originalProviderHistoryRetainedUnchanged"])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)
    return 0 if report["passedAvailableCatchUpSubgate"] else 1

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "source-root", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    for name in ("producer-version", "host-version"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--duration", type=int, default=60)
    parser.add_argument("--acceptance-executable", type=Path,
        default=probe.ROOT / ".build/out/Products/Debug/spillcheck-storage-acceptance")
    parser.add_argument("--helper-executable", type=Path, default=probe.ROOT / ".build/out/Products/Debug/spillcheck-hook")
    args = parser.parse_args()
    if not 30 <= args.duration <= 120:
        parser.error("duration must be between 30 and 120 seconds")
    return run(args)

if __name__ == "__main__":
    raise SystemExit(main())
