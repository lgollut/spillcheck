#!/usr/bin/env python3
"""Measure synthetic resources and separately check network-denied local workflow.

The acceptance executable is a separate SwiftPM product with ephemeral testing keys.
No real provider, app, hook registration, user history, or Keychain item is used.
Failed runs retain their exact disposable store and a private recovery manifest.
The resource parent is unsandboxed because macOS rejects nested sandbox-exec. Its
actual production scanner retains the production network/fork-denial profile. A
second sandboxed parent checks the local workflow with annotated fixture detections.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests"))
from Support.acceptance_artifacts import AcceptanceArtifacts


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def owned_tree_rss(process_id):
    """Inspect only PID, PPID and RSS; command arguments and environments stay unread."""
    sample = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,rss="], capture_output=True,
                            text=True, timeout=5, check=True)
    rows = []
    for line in sample.stdout.splitlines():
        fields = line.split()
        if len(fields) == 3 and all(field.isdecimal() for field in fields):
            rows.append(tuple(map(int, fields)))
    owned = {process_id}
    while True:
        next_owned = owned | {pid for pid, parent, _ in rows if parent in owned}
        if next_owned == owned:
            break
        owned = next_owned
    return sum(rss * 1024 for pid, _, rss in rows if pid in owned), len(owned)


def stop_owned_process(process):
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def inspect_transient_directory(directory, markers):
    for path in directory.rglob("*"):
        if not path.is_file():
            continue
        overlap = max(map(len, markers)) - 1
        with path.open("rb") as source:
            tail = b""
            for block in iter(lambda: source.read(65536), b""):
                combined = tail + block
                if any(marker in combined for marker in markers):
                    return False
                tail = combined[-overlap:]
    return True


def run_phase(name, command, root, private_root, environment, timeout):
    stdout = private_root / (name + "-stdout.json")
    stderr = private_root / (name + "-stderr.log")
    began = time.monotonic()
    started_at = datetime.now(timezone.utc).isoformat()
    peak_rss = 0
    max_processes = 0
    rss_samples = 0
    timed_out = False
    with stdout.open("wb") as out, stderr.open("wb") as err:
        os.chmod(stdout, 0o600)
        os.chmod(stderr, 0o600)
        process = subprocess.Popen(command, cwd=root, env=environment,
                                   stdout=out, stderr=err, start_new_session=True)
        try:
            while process.poll() is None:
                if time.monotonic() - began > timeout:
                    timed_out = True
                    break
                rss, processes = owned_tree_rss(process.pid)
                peak_rss = max(peak_rss, rss)
                max_processes = max(max_processes, processes)
                rss_samples += 1
                time.sleep(0.1)
        finally:
            stop_owned_process(process)
    child = json.loads(stdout.read_text())
    return {
        "passed": process.returncode == 0 and not timed_out and child.get("passed") is True,
        "result": child, "processExitCode": process.returncode, "timedOut": timed_out,
        "startedAt": started_at, "finishedAt": datetime.now(timezone.utc).isoformat(),
        "elapsedSeconds": time.monotonic() - began,
        "memorySampling": {"ownedProcessTreePeakRSSBytes": peak_rss, "sampleCount": rss_samples,
                           "maximumObservedProcessCount": max_processes, "nominalIntervalMilliseconds": 100,
                           "notes": "Sampled simultaneous RSS for this owned acceptance/scanner process tree; short peaks can fall between samples."},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true",
                        help="Use the already-built acceptance executable.")
    parser.add_argument("--output", type=Path, default=Path(".build/implementation/m6-resources.json"))
    parser.add_argument("--samples", type=int, default=40)
    parser.add_argument("--history-mib", type=int, default=128)
    parser.add_argument("--history-period-only", action="store_true",
                        help="Run only a fresh synthetic cold/warm/append history check with explicit date bounds.")
    parser.add_argument("--timeout", type=int, default=300)
    args = parser.parse_args()
    if not 16 <= args.samples <= 160 or not 101 <= args.history_mib <= 256 or not 30 <= args.timeout <= 600:
        parser.error("Samples must be 16–160, history MiB 101–256, timeout seconds 30–600.")
    root = ROOT
    output = args.output if args.output.is_absolute() else root / args.output
    scanner = root / ".build/scanner/betterleaks"
    rules = root / ".build/scanner/betterleaks.toml"
    corpus = root / "Tests/Fixtures/Scanner/corpus.json"
    if not args.skip_build:
        subprocess.run(["swift", "build", "--product", "spillcheck-resource-acceptance"],
                       cwd=root, check=True, timeout=180)
    executable = root / ".build/debug/spillcheck-resource-acceptance"
    if not all(path.is_file() for path in [executable, scanner, rules, corpus]):
        sys.exit("Build spillcheck-resource-acceptance and prepare the pinned scanner first.")
    with AcceptanceArtifacts("spillcheck-resource-", output) as artifacts:
        private_root = artifacts.directory
        temporary = private_root / "transient-tmp"
        temporary.mkdir(mode=0o700)
        sandbox = private_root / "deny-network.sb"
        sandbox.write_text("(version 1)\n(allow default)\n(deny network*)\n")
        os.chmod(sandbox, 0o600)
        production_directory = private_root / "production-resources"
        offline_directory = private_root / "offline-local-workflow"
        production_directory.mkdir(mode=0o700)
        offline_directory.mkdir(mode=0o700)
        command = [str(executable.resolve()),
                   "--directory", str(production_directory), "--scanner", str(scanner), "--rules", str(rules),
                   "--corpus", str(corpus), "--samples", str(args.samples),
                   "--history-mib", str(args.history_mib)]
        artifacts.report.update(
            schemaVersion=1, passed=False,
            command="python3 Tests/ResourceAcceptance/run.py --skip-build",
            syntheticOnly=True, productionKeychainItemsCreated=0,
            networkPolicy="Split component proof: production scanner network/fork denial, separate inherited deny-network local workflow with annotated fixture detections",
            integratedAcceptanceParentNetworkIsolated=False,
            priorNestedSandboxFailure=".build/implementation/m6-resources-nested-sandbox-failed-r1.json",
            scannerSHA256=sha256(scanner), rulesSHA256=sha256(rules), corpusSHA256=sha256(corpus),
        )
        began = time.monotonic()
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                       "TMPDIR": str(temporary) + "/", "LC_ALL": "C"}
        if args.history_period_only:
            command.append("--history-period-only")
            history = run_phase("history-period", command, root, private_root, environment, args.timeout)
            cleanup_confirmed = (history["result"].get("ephemeralTestingKeysOnly") is True
                                 and history["result"].get("productionKeychainItemsCreated") == 0)
            temporary_clean = inspect_transient_directory(temporary, [
                b"ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS",
                b"AIzaSy8vR4qN7dP2mL9xF3kT6sB1cH5jE0uW4zY"])
            artifacts.report.update(
                command="python3 Tests/ResourceAcceptance/run.py --skip-build --history-period-only",
                scope="Fresh isolated synthetic large-history period check; original resource measurements are not rerun or backfilled",
                networkPolicy="Production scanner network/fork denial; synthetic acceptance parent is not network-isolated",
                historyPeriod=history,
                result={"newVaultCleanupPassed": cleanup_confirmed,
                        "scope": "No persistent Keychain item was created; only ephemeral testing keys used"},
                elapsedSeconds=time.monotonic() - began,
                temporaryDirectoryMarkerInspectionPassed=temporary_clean,
                cleanupScope="Only this disposable history-period directory",
                passed=history["passed"] and cleanup_confirmed and temporary_clean,
            )
        else:
            production = run_phase("production-resources", command, root, private_root, environment, args.timeout)
            offline_command = ["/usr/bin/sandbox-exec", "-f", str(sandbox), str(executable.resolve()),
                               "--network-denial-workflow", "--directory", str(offline_directory)]
            offline = run_phase("offline-local-workflow", offline_command, root, private_root, environment, 60)
            cleanup_confirmed = all(phase["result"].get("ephemeralTestingKeysOnly") is True
                                    and phase["result"].get("productionKeychainItemsCreated") == 0
                                    for phase in [production, offline])
            markers = [b"ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS",
                       b"AIzaSy8vR4qN7dP2mL9xF3kT6sB1cH5jE0uW4zY",
                       b"-----BEGIN RSA PRIVATE KEY-----", b"SPILLCHECK_RESOURCE_QUEUE_SYNTHETIC_1D1D5880"]
            temporary_clean = inspect_transient_directory(temporary, markers)
            artifacts.report.update(
                result={"newVaultCleanupPassed": cleanup_confirmed,
                        "scope": "No persistent Keychain item was created by either ephemeral testing mode"},
                productionResources=production, offlineLocalWorkflow=offline,
                elapsedSeconds=time.monotonic() - began,
                temporaryDirectoryMarkerInspectionPassed=temporary_clean,
                cleanupScope="Only this disposable resource-probe directory; all cryptography used ephemeral testing keys",
                passed=production["passed"] and offline["passed"] and cleanup_confirmed and temporary_clean,
            )
    return 0 if artifacts.passed else 1


if __name__ == "__main__":
    sys.exit(main())
