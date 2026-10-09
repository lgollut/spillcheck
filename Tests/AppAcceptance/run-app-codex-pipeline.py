#!/usr/bin/env python3
"""Signed app acceptance against exact, newly owned synthetic Codex T3 threads."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import importlib.util

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests"))
from Support.acceptance_artifacts import AcceptanceArtifacts

SECRET = b"ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--thread", action="append", required=True)
parser.add_argument("--home", type=Path, default=Path.home() / ".codex")
parser.add_argument("--executable", type=Path, default=Path.home() / ".local/bin/codex")
parser.add_argument("--interface", choices=["standalone-cli", "t3"], default="t3")
parser.add_argument("--host-version", help="Observed T3 version, required for T3 evidence")
parser.add_argument("--expect-reader-version", help="Optional strict reader baseline for this acceptance run")
parser.add_argument("--expect-producer-version", action="append", help="Optional strict source-version set")
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
if not 1 <= len(args.thread) <= 4:
    parser.error("Select between one and four exact owned synthetic threads")
if args.interface == "t3" and not args.host_version:
    parser.error("Pass the observed --host-version for the explicitly selected T3 app")
spec = importlib.util.spec_from_file_location("codex_fixture", ROOT / "Tests/CodexLive/run.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
app = ROOT / ".build/app/Build/Products/Debug/Spillcheck.app"
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
os.umask(0o077)
with AcceptanceArtifacts("spillcheck-codex-app-", args.output) as artifacts:
    root = artifacts.directory
    store = root / "protected-store"
    report = root / "report.json"
    reader_version = fixture.observe_version(args.executable, environment=dict(os.environ, CODEX_HOME=str(args.home.resolve())),
        directory=root, expected=args.expect_reader_version)
    command = [str(app / "Contents/MacOS/Spillcheck"), "--store-directory", str(store),
               "--codex-profile", "owned-codex-acceptance", "--codex-version", reader_version,
               "--codex-home", str(args.home.resolve()), "--codex-executable", str(args.executable.resolve()),
               "--codex-interface", args.interface,
               "--codex-authority", "codex-public-native-v1", "--acceptance-no-profile-catchup",
               "--acceptance-cleanup-new-vault", "--acceptance-report", str(report), "--acceptance-seconds", "15"]
    if args.host_version:
        command += ["--codex-t3-version", args.host_version]
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
    passed = (process.returncode == 0 and not timed_out and result.get("storageReady") \
        and result.get("collectionConfigured") and result.get("queueCount") == 0 \
        and result.get("syntheticValuePresent") and result.get("syntheticSessionCount") == len(args.thread) \
        and set(result.get("syntheticOccurrencesByContentType", {})) == expected \
        and bool(result.get("observedAgentVersions"))
        and (args.expect_producer_version is None or result.get("observedAgentVersions") == sorted(set(args.expect_producer_version)))
        and not result.get("gapReasons") \
        and result.get("newVaultCleanupPassed") is True and clean and not stdout and not stderr)
    output = {"schemaVersion": 1, "signedAppExitCode": process.returncode, "timedOut": timed_out,
              "actualReaderVersion": reader_version, "observedProducerVersions": result.get("observedAgentVersions", []),
              "interface": args.interface, "hostVersion": args.host_version,
              "expectedProducerVersions": args.expect_producer_version, "sourceIsOwnedSynthetic": True, "originalProviderStore": True, "passiveHistory": True,
              "profileDiscoveryDisabled": True, "selectedThreadCount": len(args.thread),
              "stdoutBytes": len(stdout), "diagnosticBytes": len(stderr),
              "ciphertextMarkerInspectionPassed": clean, "result": result, "passed": bool(passed)}
    artifacts.report = output
raise SystemExit(0 if artifacts.passed else 1)
