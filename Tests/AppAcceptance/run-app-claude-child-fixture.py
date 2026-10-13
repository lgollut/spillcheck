#!/usr/bin/env python3
"""Signed constructed regression for a selected Claude parent and distinct-session native child.

No provider is launched, authentication copied, or hook configuration changed.
This fixture establishes signed implementation behavior, never genuine host acceptance.
"""
import argparse
import datetime
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import uuid

SPEC = importlib.util.spec_from_file_location("claude_selected_fixture", Path(__file__).with_name("run-app-claude-selected.py"))
selected = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(selected)
live = selected.live
VERSION = "2.1.296"
EXPECTED_COUNTS = {"userPrompt": 2, "intermediateResponse": 2, "finalResponse": 2,
                   "toolOutput": 3, "toolError": 3}
COUNT_KEYS = (*selected.COUNTS, "valueCount", "syntheticNativeChildOccurrenceCount")
CHECKS = {"candidateBeforePassed", "nativeDistinctParentChildFixtureComplete", "signedCollectorReady",
    "strictIndividualRolesCommittedBeforeReplay", "canonicalReplayPreservesExactCounts",
    "strictIndividualRolesCommittedAfterReplay", "normalSignedShutdown", "ownedProcessGroupStopped",
    "originalNativeSourcesUnchanged", "candidateUnchanged", "encryptedStorageContainsNoFakePlaintext",
    "originalFreshCreatorCleanupPassed"}


class GateFailure(RuntimeError):
    pass


def require(value, gate):
    if not value:
        raise GateFailure(gate)


def create_fixture(root):
    """Write one parent and its own child, preserving two distinct native UUIDs."""
    sources, project = root / "sources", root / "project"
    sources.mkdir(mode=0o700)
    project.mkdir(mode=0o700)
    parent_session, child_session = str(uuid.uuid4()), str(uuid.uuid4())
    require(parent_session != child_session, "fixtureNativeSessionsMustDiffer")
    parent = sources / (parent_session + ".jsonl")
    child = sources / parent_session / "subagents/agent-owned-fixture.jsonl"
    child.parent.mkdir(parents=True, mode=0o700)
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()

    def rows(session, is_child):
        prefix = "CHILD_" if is_child else ""
        tools = [("CHILD_TOOL_OUTPUT", False, "Bash"), ("CHILD_TOOL_ERROR", True, "Bash")] if is_child else [
            ("SHELL_OK", False, "Bash"), ("SHELL_ERROR", True, "Bash"),
            ("MCP_OK", False, "mcp__spillcheck_synthetic__synthetic_output"),
            ("MCP_ERROR", True, "mcp__spillcheck_synthetic__synthetic_output")]

        def row(kind, content, stop_reason=None):
            message = {"role": kind, "content": content}
            if stop_reason is not None:
                message["stop_reason"] = stop_reason
            return {"type": kind, "uuid": str(uuid.uuid4()), "sessionId": session,
                "timestamp": timestamp, "version": VERSION, "cwd": str(project),
                "isSidechain": is_child, "message": message}

        def text(marker):
            return {"type": "text", "text": "LEAKRET_M3_" + marker + " " + live.fixture.SECRET}

        values = [row("user", [text(prefix + "PROMPT")]),
            row("assistant", [text(prefix + "INTERMEDIATE")] + [
                {"type": "tool_use", "id": "fixture-" + marker, "name": name, "input": {}}
                for marker, _, name in tools], "tool_use")]
        values.extend(row("user", [{"type": "tool_result", "tool_use_id": "fixture-" + marker,
            "is_error": error, "content": "LEAKRET_M3_" + marker + " " + live.fixture.SECRET}])
            for marker, error, _ in tools)
        values.append(row("assistant", [text(prefix + "FINAL")], "end_turn"))
        return values

    for path, session, is_child in ((parent, parent_session, False), (child, child_session, True)):
        with path.open("x") as stream:
            stream.write("".join(json.dumps(row) + "\n" for row in rows(session, is_child)))
        os.chmod(path, 0o600)
    return parent, parent_session, child, child_session


def complete_report(report, native):
    counts = report.get("syntheticOccurrencesByContentType")
    return (report.get("storageReady") is True and report.get("collectionConfigured") is True
        and report.get("syntheticValuePresent") is True and report.get("queueCount") == 0
        and report.get("gapReasons") == [] and report.get("coverageReportTruncated") is False
        and counts == EXPECTED_COUNTS and all(type(value) is int for value in counts.values())
        and all(type(report.get(key)) is int and report[key] == expected for key, expected in (
            ("valueCount", 1), ("occurrenceCount", 12), ("syntheticOccurrenceCount", 12),
            ("syntheticSessionCount", 2), ("syntheticNativeChildOccurrenceCount", 5)))
        and selected.strict_selected_role_coverage(report, native, VERSION))


def replay_counts_unchanged(before, after):
    return all(type(before.get(key)) is int and before[key] >= 0 and type(after.get(key)) is int
        and before[key] == after[key] for key in COUNT_KEYS)


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--app", type=Path, default=selected.ROOT / ".build/app/Build/Products/Debug/Spillcheck.app")
    live.candidate_arguments(parser)
    args = parser.parse_args(argv)
    live.candidate_admission(parser, args)
    if args.candidate_manifest is None:
        parser.error("constructed signed regression requires a candidate manifest and expected bundle digest")
    return args


def main():
    args = parse_arguments()
    os.umask(0o077)
    app = args.app.resolve()
    candidate_before = live.candidate_snapshot(args.candidate_manifest, args.expected_bundle_sha256, app)
    require(subprocess.run(["/usr/bin/pgrep", "-x", "Spillcheck"], capture_output=True).returncode == 1,
        "existingAppOrUnavailableProcessInventory")
    with selected.AcceptanceArtifacts("spillcheck-app-claude-child-fixture-", args.output) as artifacts:
        artifacts.report.update(schemaVersion=1, fixtureIsConstructed=True, sourceIsGenuineProviderOutput=False,
            providerLaunched=False, authenticationCopied=False, hooksModified=False, hostAcceptanceEstablished=False,
            genuineCLICollectionEstablished=False, genuineT3CollectionEstablished=False,
            signedConstructedChildRegressionEstablished=False, candidateBinding=candidate_before,
            fixtureProducerVersion=VERSION)
        root = artifacts.directory
        store, report_path, finish = root / "protected-store", root / "app-report.json", root / "finish"
        stdout_path, stderr_path = root / "stdout.bin", root / "stderr.bin"
        checks = {"candidateBeforePassed": candidate_before is not None}
        process, cleanup = None, None
        before, after, native = {}, {}, {}
        replay_runs = []
        original = None
        source = session = None
        timed_out = False
        try:
            source, session, child, child_session = create_fixture(root)
            paths, native = selected.inspect_selected_native_source(source, live.fixture.SECRET, session)
            original = selected.source_state_snapshot(paths)
            checks["nativeDistinctParentChildFixtureComplete"] = (paths == [(source, session), (child, child_session)]
                and session != child_session and native.get("nativeSessionCount") == 2
                and native.get("nativeTranscriptCount") == 2 and selected.complete_selected_native_pair(native, VERSION))
            require(checks["nativeDistinctParentChildFixtureComplete"], "constructedNativeFixtureIncomplete")
            profile = "owned-constructed-claude-child"
            command = selected.collector_command(app, store, report_path, finish, profile, source, session, VERSION)
            with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
                process = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
                ready = live.wait_for_report(process, report_path,
                    lambda value: value.get("storageReady") is True and value.get("collectionConfigured") is True, 30)
                checks["signedCollectorReady"] = ready.get("storageReady") is True and ready.get("collectionConfigured") is True
                require(checks["signedCollectorReady"], "signedCollectorUnavailable")
                before = live.wait_for_report(process, report_path, lambda value: complete_report(value, native), 45)
                checks["strictIndividualRolesCommittedBeforeReplay"] = complete_report(before, native)
                require(checks["strictIndividualRolesCommittedBeforeReplay"], "distinctChildStrictCommitUnavailable")
                helper = app / "Contents/Helpers/spillcheck-hook"
                for interface in ("standalone-cli", "t3"):
                    for path, native_session in paths:
                        payload = json.dumps({"hook_event_name": "SpillcheckTranscriptPoll", "session_id": native_session,
                            "transcript_path": str(path)}).encode()
                        replay = subprocess.run([str(helper), "--socket", str(store / "capture.sock"),
                            "--agent", "claude-code", "--interface", interface, "--profile-id", profile],
                            input=payload, capture_output=True, timeout=5)
                        replay_runs.append({"interface": interface, "sourceKind": "parent" if path == source else "child",
                            "exitCode": replay.returncode})
                after = live.settled_report(process, report_path)
                checks["strictIndividualRolesCommittedAfterReplay"] = complete_report(after, native)
                checks["canonicalReplayPreservesExactCounts"] = (len(replay_runs) == 4
                    and all(run["exitCode"] == 0 for run in replay_runs) and replay_counts_unchanged(before, after))
                finish.touch()
                process.wait(timeout=35)
        except (OSError, ValueError, RuntimeError, selected.NativeEvidenceFailure, subprocess.SubprocessError) as error:
            artifacts.report["unmetGate"] = str(error) if isinstance(error, GateFailure) else "constructedSignedRunFailed"
            artifacts.report["failureCategory"] = type(error).__name__
        finally:
            if process is not None:
                if process.poll() is None:
                    try:
                        finish.touch()
                        process.wait(timeout=35)
                    except (OSError, subprocess.SubprocessError):
                        timed_out = True
                try:
                    cleanup = selected.stop_group(process)
                except (OSError, RuntimeError):
                    artifacts.report["processCleanupFailed"] = True
        result = live.read_report(report_path)
        checks["normalSignedShutdown"] = process is not None and process.returncode == 0 and not timed_out
        checks["ownedProcessGroupStopped"] = cleanup is not None and cleanup.get("term_permission_denied") is False \
            and cleanup.get("kill_permission_denied") is False
        checks["originalFreshCreatorCleanupPassed"] = result.get("newVaultCleanupPassed") is True
        try:
            final_paths, final_native = selected.inspect_selected_native_source(source, live.fixture.SECRET, session) if source is not None else ([], {})
            checks["originalNativeSourcesUnchanged"] = bool(original) and selected.source_state_snapshot(final_paths) == original \
                and selected.complete_selected_native_pair(final_native, VERSION)
            checks["candidateUnchanged"] = live.candidate_snapshot(args.candidate_manifest, args.expected_bundle_sha256, app) == candidate_before
            checks["encryptedStorageContainsNoFakePlaintext"] = store.is_dir() and all(live.fixture.SECRET.encode() not in path.read_bytes()
                for path in store.rglob("*") if path.is_file())
        except (OSError, ValueError, selected.NativeEvidenceFailure):
            artifacts.report["finalBindingCheckFailed"] = True
        passed = CHECKS <= set(checks) and all(checks.values()) and complete_report(result, native) \
            and replay_counts_unchanged(after, result) and "unmetGate" not in artifacts.report
        artifacts.report.update(passed=passed, checks=checks, signedConstructedChildRegressionEstablished=passed,
            candidateUnchanged=checks.get("candidateUnchanged", False), nativeSourceEvidence=native,
            parentAndChildNativeSessionsDistinct=True if original and len({session for _, session in original}) == 2 else False,
            replayRuns=replay_runs, replayStable=checks.get("canonicalReplayPreservesExactCounts", False),
            signedAppExitCode=process.returncode if process else None, timedOut=timed_out, processGroupCleanup=cleanup,
            ownedProtectionCleanupPending=process is not None and result.get("newVaultCleanupPassed") is not True,
            stdoutBytes=stdout_path.stat().st_size if stdout_path.exists() else 0,
            diagnosticBytes=stderr_path.stat().st_size if stderr_path.exists() else 0, result=result,
            passScope="Constructed signed regression only: selected parent and distinct-native-session own child, twelve exact typed markers with committed receipts, unchanged canonical replay, encrypted storage and creator cleanup. No genuine provider output, host dispatch, live production, restart or upgrade acceptance.")
    return 0 if artifacts.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
