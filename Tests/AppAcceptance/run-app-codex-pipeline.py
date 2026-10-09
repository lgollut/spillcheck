#!/usr/bin/env python3
"""Signed app acceptance against exact, newly owned synthetic Codex T3 threads."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests"))
from Support.acceptance_artifacts import AcceptanceArtifacts

SECRET = b"ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--thread", action="append", required=True)
parser.add_argument("--home", type=Path, default=Path.home() / ".codex")
parser.add_argument("--executable", type=Path, default=Path.home() / ".local/bin/codex")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
if not 1 <= len(args.thread) <= 4:
    parser.error("Select between one and four exact owned synthetic threads")
app = ROOT / ".build/app/Build/Products/Debug/Spillcheck.app"
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
os.umask(0o077)
with AcceptanceArtifacts("spillcheck-codex-app-", args.output) as artifacts:
    root = artifacts.directory
    store = root / "protected-store"
    report = root / "report.json"
    command = [str(app / "Contents/MacOS/Spillcheck"), "--store-directory", str(store),
               "--codex-profile", "owned-t3-acceptance", "--codex-version", "0.161.0",
               "--codex-home", str(args.home.resolve()), "--codex-executable", str(args.executable.resolve()),
               "--codex-interface", "t3", "--codex-t3-version", "0.0.46-nightly.20261007.2761",
               "--codex-authority", "codex-public-native-v1", "--acceptance-no-profile-catchup",
               "--acceptance-cleanup-new-vault", "--acceptance-report", str(report), "--acceptance-seconds", "15"]
    for thread in args.thread:
        command += ["--codex-active-thread", thread]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=45)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
    artifacts.report.update(signedAppExitCode=process.returncode, timedOut=timed_out,
                            stdoutBytes=len(stdout), diagnosticBytes=len(stderr))
    result = json.loads(report.read_text()) if report.is_file() else {"reportMissing": True}
    clean = store.is_dir() and all(SECRET not in path.read_bytes() for path in store.rglob("*") if path.is_file())
    expected = {"userPrompt", "intermediateResponse", "finalResponse", "toolOutput", "toolError"}
    passed = process.returncode == 0 and not timed_out and result.get("storageReady") \
        and result.get("collectionConfigured") and result.get("queueCount") == 0 \
        and result.get("syntheticValuePresent") and result.get("syntheticSessionCount") == len(args.thread) \
        and set(result.get("syntheticOccurrencesByContentType", {})) == expected \
        and result.get("observedAgentVersions") == ["0.160.1"] and not result.get("gapReasons") \
        and result.get("newVaultCleanupPassed") is True and clean and not stdout and not stderr
    output = {"schemaVersion": 1, "signedAppExitCode": process.returncode, "timedOut": timed_out,
              "sourceIsOwnedSynthetic": True, "originalProviderStore": True, "passiveHistory": True,
              "profileDiscoveryDisabled": True, "selectedThreadCount": len(args.thread),
              "stdoutBytes": len(stdout), "diagnosticBytes": len(stderr),
              "ciphertextMarkerInspectionPassed": clean, "result": result, "passed": bool(passed)}
    artifacts.report = output
raise SystemExit(0 if artifacts.passed else 1)
