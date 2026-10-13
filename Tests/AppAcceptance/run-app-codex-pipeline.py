#!/usr/bin/env python3
"""Signed app acceptance against exact, newly owned synthetic Codex threads."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import importlib.util
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests"))
from Support.acceptance_artifacts import AcceptanceArtifacts

SECRET = b"ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
CONTENT_TYPES = {"userPrompt", "intermediateResponse", "finalResponse", "toolOutput", "toolError"}
PARENT_MARKERS = {"PROMPT", "INTERMEDIATE", "FINAL", "SHELL_OK", "SHELL_ERROR", "MCP_OK", "MCP_ERROR"}
CHILD_MARKERS = {"CHILD_PROMPT", "CHILD_INTERMEDIATE", "CHILD_FINAL", "CHILD_TOOL_OUTPUT", "CHILD_TOOL_ERROR"}


def role_coverage_passed(result):
    """Only role-separated, source-verified durable counts can pass the strict fixture gate."""
    if not all(result.get(key) is True for key in (
        "codexIndividualRoleCoverageMeasured", "codexIndividualRoleCoveragePassed",
        "codexNativeParentChildLinkVerified", "codexRoleEvidenceWithinBudget")):
        return False
    markers = result.get("codexTypedCommittedMarkersByRole")
    types = result.get("codexCommittedContentTypesByRole")
    if not isinstance(markers, dict) or not isinstance(types, dict):
        return False
    for role, expected in (("parent", PARENT_MARKERS), ("child", CHILD_MARKERS)):
        actual = markers.get(role)
        actual_types = types.get(role)
        if (not isinstance(actual, dict) or set(actual) != expected
                or any(type(count) is not int or count != 1 for count in actual.values())
                or not isinstance(actual_types, list)
                or len(actual_types) != len(CONTENT_TYPES)
                or not all(isinstance(kind, str) for kind in actual_types) or set(actual_types) != CONTENT_TYPES):
            return False
    return True


def strict_roles(args, parser):
    requested = args.expected_parent is not None or args.expected_child is not None
    if not requested:
        return False
    if args.expected_parent is None or args.expected_child is None:
        parser.error("Strict native-child acceptance requires both expected roles")
    try:
        valid = all(str(uuid.UUID(value)) == value for value in (args.expected_parent, args.expected_child))
    except (ValueError, AttributeError):
        valid = False
    if (not valid or args.expected_parent == args.expected_child or len(args.thread) != 2
            or set(args.thread) != {args.expected_parent, args.expected_child}):
        parser.error("Strict roles must be two distinct canonical IDs matching exactly the selected threads")
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--thread", action="append", required=True)
    parser.add_argument("--expected-parent", help="Exact synthetic parent already selected from original native sources")
    parser.add_argument("--expected-child", help="Its verified original native child; requires all five child types")
    parser.add_argument("--app", type=Path, default=ROOT / ".build/app/Build/Products/Debug/Spillcheck.app")
    parser.add_argument("--home", type=Path, default=Path.home() / ".codex")
    parser.add_argument("--executable", type=Path, default=Path.home() / ".local/bin/codex")
    parser.add_argument("--interface", choices=["standalone-cli", "t3", "desktop-code"], default="t3")
    parser.add_argument("--host-version", help="Observed T3 version, required for T3 evidence")
    parser.add_argument("--expect-reader-version", help="Optional strict reader baseline for this acceptance run")
    parser.add_argument("--expect-producer-version", action="append", help="Optional strict source-version set")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--private-control", type=Path,
                        help="New private file retaining the exact owned artifact directory for failed cleanup.")
    args = parser.parse_args(argv)
    strict = strict_roles(args, parser)
    if not 1 <= len(args.thread) <= 4:
        parser.error("Select between one and four exact owned synthetic threads")
    if args.interface == "t3" and not args.host_version:
        parser.error("Pass the observed --host-version for the explicitly selected T3 app")
    if args.host_version and args.interface != "t3":
        parser.error("--host-version is T3-only; retain desktop host provenance in separate source evidence")
    spec = importlib.util.spec_from_file_location("codex_fixture", ROOT / "Tests/CodexLive/run.py")
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    app = args.app.resolve()
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    os.umask(0o077)
    with AcceptanceArtifacts("spillcheck-codex-app-", args.output) as artifacts:
        root = artifacts.directory
        if args.private_control is not None:
            args.private_control.parent.mkdir(parents=True, exist_ok=True)
            descriptor = os.open(args.private_control, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, "w") as control:
                json.dump({"schemaVersion": 1, "ownedArtifactDirectory": str(root),
                           "reportPath": str(args.output.resolve())}, control)
                control.write("\n")
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
        if strict:
            command += ["--acceptance-codex-parent", args.expected_parent,
                        "--acceptance-codex-child", args.expected_child]
        if args.interface == "desktop-code":
            command += ["--codex-authorized-host", "desktop-code"]
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
        expected = CONTENT_TYPES
        individual_passed = strict and role_coverage_passed(result)
        passed = (process.returncode == 0 and not timed_out and result.get("storageReady") \
            and result.get("collectionConfigured") and result.get("queueCount") == 0 \
            and result.get("syntheticValuePresent") and result.get("syntheticSessionCount") == len(args.thread) \
            and set(result.get("syntheticOccurrencesByContentType", {})) == expected \
            and bool(result.get("observedAgentVersions"))
            and (args.expect_producer_version is None or result.get("observedAgentVersions") == sorted(set(args.expect_producer_version)))
            and result.get("gapReasons") == [] and result.get("coverageReportTruncated") is False \
            and result.get("newVaultCleanupPassed") is True and clean and not stdout and not stderr
            and (not strict or individual_passed))
        output = {"schemaVersion": 1, "signedAppExitCode": process.returncode, "timedOut": timed_out,
                  "actualReaderVersion": reader_version, "observedProducerVersions": result.get("observedAgentVersions", []),
                  "interface": args.interface, "hostVersion": args.host_version,
                  "expectedProducerVersions": args.expect_producer_version, "sourceIsOwnedSynthetic": True, "originalProviderStore": True, "passiveHistory": True,
                  "profileDiscoveryDisabled": True, "selectedThreadCount": len(args.thread),
                  "strictNativeChildAcceptanceRequired": strict,
                  "individualRoleCoveragePassed": bool(individual_passed),
                  "nativeChildAllFiveTypesEstablished": bool(passed and individual_passed),
                  "stdoutBytes": len(stdout), "diagnosticBytes": len(stderr),
                  "ciphertextMarkerInspectionPassed": clean, "result": result, "passed": bool(passed)}
        artifacts.report = output
    return 0 if artifacts.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
