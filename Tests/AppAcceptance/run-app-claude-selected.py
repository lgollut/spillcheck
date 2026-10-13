#!/usr/bin/env python3
"""Observe one explicitly mapped, original Claude host source in the signed app.

A genuine app-owned producer writes the private manifest before waiting for the
ready sentinel. This observer never launches a provider, enumerates other native
histories, changes hooks, or rewrites the original transcript. Completion is a
separate producer sentinel; the collector then verifies encrypted settlement and
replays the same native source across CLI and the selected host metadata.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests"))
from Support.acceptance_artifacts import AcceptanceArtifacts
from Support.processes import stop_group
from Support.claude_native_evidence import inspect_selected_native_source, NativeEvidenceFailure, _directory, _read

spec = importlib.util.spec_from_file_location("signed_claude_live", Path(__file__).with_name("run-app-claude-live.py"))
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)
REQUIRED = {"userPrompt", "intermediateResponse", "finalResponse", "toolOutput", "toolError"}
MARKERS = set(live.fixture.EXPECTED_MARKERS)
COUNTS = ("occurrenceCount", "alertCount", "syntheticOccurrenceCount", "syntheticSessionCount")
INTERFACES = ("t3", "desktop-code")


def private_json(path):
    """Read one bounded owned registration artifact without following symlinks."""
    path = Path(path).absolute()
    directory = _directory(path.parent)
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
    finally:
        os.close(directory)
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_mode & 0o077
                or before.st_uid != os.getuid() or before.st_size > 64 * 1024):
            raise ValueError("registrationArtifactMustBeOwnedPrivateAndBounded")
        payload = os.read(fd, 64 * 1024 + 1)
        after = os.fstat(fd)
        if (len(payload) != before.st_size or len(payload) > 64 * 1024
                or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns)):
            raise ValueError("registrationArtifactChangedDuringRead")
        def unique_object(pairs):
            value = {}
            for key, item in pairs:
                if key in value:
                    raise ValueError("duplicateRegistrationField")
                value[key] = item
            return value
        value = json.loads(payload, object_pairs_hook=unique_object)
        if not isinstance(value, dict):
            raise ValueError("registrationArtifactMustBeObject")
        return value, hashlib.sha256(payload).hexdigest()
    finally:
        os.close(fd)


def registration_snapshot(manifest_path, interface, authorized=None):
    """Bind a host declaration to its exact private runtime identity and source prefix.

    Host origin is an operator declaration. Native rows independently verify the
    runtime UUID, workspace and producer; this does not prove GUI launch or hook dispatch.
    """
    manifest, manifest_digest = private_json(manifest_path)
    if (interface not in INTERFACES or type(manifest.get("schemaVersion")) is not int or manifest["schemaVersion"] != 2
            or manifest.get("sourceInterface") != interface
            or manifest.get("identitySource") != "own-runtime-CLAUDE_CODE_SESSION_ID"
            or manifest.get("originalTranscriptPathDerivedThenVerified") is not True):
        raise ValueError("selectedHostRuntimeProvenanceRequired")
    session = str(uuid.UUID(manifest["nativeSessionId"]))
    if session != manifest["nativeSessionId"]:
        raise ValueError("canonicalNativeSessionRequired")
    source, project = Path(manifest["originalTranscriptPath"]), Path(manifest["workingDirectory"])
    identity_path = Path(manifest["runtimeIdentityPath"])
    authorized = authorized or Path.home() / ".claude/projects"
    if (not source.is_absolute() or not project.is_absolute() or project.is_symlink()
            or identity_path not in (project / "selected-session-private.json",
                Path(manifest_path).absolute().parent / "runtime-identity-private.json")
            or source.stem != session or source.suffix != ".jsonl"
            or source.is_symlink() or not source.resolve().is_relative_to(authorized.resolve())):
        raise ValueError("selectedOriginalNativeSourceRequired")
    runtime, runtime_digest = private_json(identity_path)
    if (runtime.get("schemaVersion") != 1 or runtime.get("nativeSessionID") != session
            or runtime.get("workingDirectory") != str(project)
            or runtime.get("identitySource") != manifest["identitySource"]
            or runtime_digest != manifest.get("runtimeIdentitySHA256")):
        raise ValueError("runtimeIdentityBindingMismatch")
    for field in ("producerVersion", "hostVersion"):
        value = manifest.get(field)
        if not isinstance(value, str) or not value.strip() or "\0" in value or len(value.encode()) > 256:
            raise ValueError("observedHostAndProducerVersionRequired")
    payload = _read(source, 2 * 1024 * 1024)
    registered_bytes = manifest.get("sourceRegistrationByteCount")
    if (type(registered_bytes) is not int or not 0 < registered_bytes <= len(payload)
            or payload[registered_bytes - 1:registered_bytes] != b"\n"
            or hashlib.sha256(payload[:registered_bytes]).hexdigest() != manifest.get("sourceRegistrationSHA256")):
        raise ValueError("registeredNativeSourcePrefixChanged")
    content_rows = 0
    for line in payload[:registered_bytes].splitlines():
        row = json.loads(line)
        if not isinstance(row, dict):
            raise ValueError("registeredNativeRowInvalid")
        if row.get("type") not in {"user", "assistant"}:
            continue
        content_rows += 1
        if (row.get("sessionId") != session or row.get("cwd") != str(project)
                or row.get("version") != manifest["producerVersion"]):
            raise ValueError("registeredNativeIdentityWorkspaceOrProducerMismatch")
    if not content_rows:
        raise ValueError("registeredNativeContentRequired")
    return manifest, {"manifestSHA256": manifest_digest, "runtimeIdentitySHA256": runtime_digest,
        "registeredSourceSHA256": manifest["sourceRegistrationSHA256"],
        "registeredSourceByteCount": registered_bytes, "registeredNativeContentRowCount": content_rows,
        "sourceInterface": interface, "providerProducerVersion": manifest["producerVersion"],
        "hostVersion": manifest["hostVersion"], "runtimeIdentitySourcePrefixBindingPassed": True,
        "hostOriginIndependentlyVerified": False}


def strict_selected_role_coverage(result, native, version):
    """A selected native parent and one own child must each retain every required type."""
    producer_pairs = result.get("claudeCommittedNativeParentChildPairCountByProducer", {})
    native_pairs = native.get("completeNativeParentChildPairCountByProducer", {})
    return (live.strict_role_coverage_complete(result)
        and type(producer_pairs.get(version)) is int and producer_pairs[version] > 0
        and native.get("requiredNativeFieldsValid") is True and native.get("completeJSONLFraming") is True
        and native.get("exactParentAndOwnChildFilesOnly") is True
        and native.get("individualNativeRoleCoverageComplete") is True
        and type(native_pairs.get(version)) is int and native_pairs[version] > 0
        and MARKERS <= set(native.get("typedMarkers", []))
        and {marker for marker in MARKERS if marker.startswith("CHILD_")} <= set(native.get("childTypedMarkers", []))
        and version in native.get("producerVersions", [])
        and version in result.get("observedAgentVersions", []))


def complete_selected_native_pair(native, version):
    pairs = native.get("completeNativeParentChildPairCountByProducer", {})
    return (all(native.get(key) is True for key in ("requiredNativeFieldsValid", "completeJSONLFraming",
            "exactParentAndOwnChildFilesOnly", "individualNativeRoleCoverageComplete"))
        and type(pairs.get(version)) is int and pairs[version] > 0
        and MARKERS <= set(native.get("typedMarkers", []))
        and {marker for marker in MARKERS if marker.startswith("CHILD_")} <= set(native.get("childTypedMarkers", []))
        and version in native.get("producerVersions", []))


def source_bytes_snapshot(paths):
    return {key: state[1] for key, state in source_state_snapshot(paths).items()}


def source_state_snapshot(paths):
    remaining, snapshot = 16 * 1024 * 1024, {}
    for path, session in paths:
        payload = _read(path, remaining)
        remaining -= len(payload)
        snapshot[(str(path), session)] = (len(payload), hashlib.sha256(payload).hexdigest())
    return snapshot


def native_checkpoint(source, session):
    paths, _ = inspect_selected_native_source(source, live.fixture.SECRET, session)
    before = source_state_snapshot(paths)
    paths, native = inspect_selected_native_source(source, live.fixture.SECRET, session)
    after = source_state_snapshot(paths)
    if before != after or native.get("requiredNativeFieldsValid") is not True or native.get("completeJSONLFraming") is not True:
        raise ValueError("nativeSourceChangedOrInvalidAtCheckpoint")
    return paths, native, after


def source_appended_since(baseline, paths):
    """Every earlier file must retain its exact prefix; new own children count as growth."""
    current = source_state_snapshot(paths)
    if not baseline or not set(baseline) <= set(current) or current == baseline:
        return False
    remaining = 16 * 1024 * 1024
    for (path, _), (byte_count, digest) in baseline.items():
        payload = _read(Path(path), remaining)
        remaining -= len(payload)
        if len(payload) < byte_count or hashlib.sha256(payload[:byte_count]).hexdigest() != digest:
            return False
    return True


def new_committed_native_marker(report, baseline_native, current_native):
    """A count-only inventory increase does not bind a newly produced native marker."""
    if not all(report.get(key) is True for key in ("claudeIndividualRoleCoverageMeasured",
            "claudeNativeParentChildLinkVerified", "claudeRoleEvidenceWithinBudget")):
        return False
    new_markers = set(current_native.get("typedMarkers", [])) - set(baseline_native.get("typedMarkers", []))
    roles = report.get("claudeTypedCommittedMarkersByRole", {})
    return any(type(roles.get("child" if marker.startswith("CHILD_") else "parent", {}).get(marker)) is int
        and roles["child" if marker.startswith("CHILD_") else "parent"][marker] > 0 for marker in new_markers & MARKERS)


def collector_command(app, store, report_path, finish, profile, source, session, version, interface="t3"):
    if interface not in INTERFACES:
        raise ValueError("unsupportedSelectedInterface")
    return [str(app / "Contents/MacOS/Spillcheck"), "--store-directory", str(store),
        "--claude-profile", profile, "--claude-version", version, "--claude-interface", interface,
        "--claude-authorized-host", interface, "--claude-authorized-host", "standalone-cli",
        "--claude-source-root", str(source.parent), "--claude-active-source", str(source),
        "--claude-session", session, "--acceptance-no-profile-catchup", "--acceptance-cleanup-new-vault",
        "--acceptance-claude-role-evidence", "--acceptance-hold", "--acceptance-finish-file", str(finish),
        "--acceptance-report", str(report_path), "--acceptance-seconds", "120"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--ready", type=Path)
    parser.add_argument("--producer-done", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--app", type=Path, default=ROOT / ".build/app/Build/Products/Debug/Spillcheck.app")
    parser.add_argument("--duration", type=int, default=600)
    parser.add_argument("--interface", choices=INTERFACES, default="t3")
    parser.add_argument("--observation", choices=("live", "saved-source"), default="live")
    live.candidate_arguments(parser)
    args = parser.parse_args()
    live.candidate_admission(parser, args)
    if args.candidate_manifest is None:
        parser.error("selected-source acceptance requires a candidate manifest and expected bundle digest")
    live_observation = args.observation == "live"
    if live_observation:
        if args.ready is None or args.producer_done is None:
            parser.error("live observation requires --ready and --producer-done")
        if any(path.exists() or path.is_symlink() for path in (args.ready, args.producer_done)):
            parser.error("live sentinels must be fresh paths")
    elif args.ready is not None or args.producer_done is not None:
        parser.error("saved-source observation does not accept live sentinels")
    if not 30 <= args.duration <= 1200:
        parser.error("duration must be 30 through 1200 seconds")
    os.umask(0o077)
    deadline = time.monotonic() + args.duration
    while not args.manifest.is_file() and time.monotonic() < deadline:
        time.sleep(0.2)
    if not args.manifest.is_file():
        parser.error("producer manifest unavailable")
    try:
        manifest, registration_before = registration_snapshot(args.manifest, args.interface)
    except (OSError, ValueError, KeyError, TypeError, NativeEvidenceFailure):
        parser.error("selected manifest failed its private native provenance checks")
    session = manifest["nativeSessionId"]
    source = Path(manifest["originalTranscriptPath"])
    version = manifest["producerVersion"]
    # Require the exact main native identity and owned prompt, not just matching text.
    initial_paths, initial_native = inspect_selected_native_source(source, live.fixture.SECRET, session)
    if (not initial_native["requiredNativeFieldsValid"] or not initial_native["completeJSONLFraming"]
            or "PROMPT" not in initial_native["typedMarkers"]):
        parser.error("selected source lacks a complete owned prompt under its native identity")
    initial_complete = complete_selected_native_pair(initial_native, version)
    if not live_observation and not initial_complete:
        parser.error("saved source lacks a complete current twelve-marker parent and own-child pair")
    if live_observation and initial_complete:
        parser.error("live observation requires an incomplete source; use saved-source for completed content")
    saved_source_before = source_bytes_snapshot(initial_paths) if not live_observation else None
    app = args.app.resolve()
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    candidate_before = live.candidate_snapshot(args.candidate_manifest, args.expected_bundle_sha256, app)
    if subprocess.run(["/usr/bin/pgrep", "-x", "Spillcheck"], capture_output=True).returncode == 0:
        parser.error("another Spillcheck app is running")
    with AcceptanceArtifacts("spillcheck-app-claude-selected-", args.output) as artifacts:
        artifacts.report.update(candidateBinding=candidate_before, candidateUnchanged=False,
            sourceRegistrationBinding=registration_before, sourceRegistrationUnchanged=False)
        root = artifacts.directory
        store, report_path, finish = root / "protected-store", root / "app-report.json", root / "finish"
        profile = "owned-selected-claude-" + args.interface
        command = collector_command(app, store, report_path, finish, profile, source, session, version, args.interface)
        stdout_path, stderr_path = root / "stdout.bin", root / "stderr.bin"
        replay_runs, observed_counts, native = [], set(), {}
        before, after = {}, {}
        producer_done = False
        ready_written = False
        ready_native, ready_source_state = {}, {}
        live_committed_native_growth = False
        live_checkpoint_unavailable = 0
        process = None
        try:
            with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
                process = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
                ready = live.wait_for_report(process, report_path,
                    lambda r: r.get("storageReady") and r.get("collectionConfigured"), 30)
                if ready.get("storageReady") and ready.get("collectionConfigured"):
                    if live_observation:
                        _, ready_native, ready_source_state = native_checkpoint(source, session)
                        if complete_selected_native_pair(ready_native, version):
                            raise ValueError("completedSourceAtCollectorReadinessCannotProveLiveProduction")
                        with args.ready.open("x") as ready_file:
                            ready_file.write(json.dumps({"collectorReady": True}) + "\n")
                        ready_written = True
                    while live_observation and process.poll() is None and time.monotonic() < deadline:
                        report = live.read_report(report_path)
                        if not args.producer_done.is_file():
                            observed_counts.add(report.get("syntheticOccurrenceCount", 0))
                            if not live_committed_native_growth:
                                try:
                                    current_paths, current_native, _ = native_checkpoint(source, session)
                                    live_committed_native_growth = (new_committed_native_marker(report, ready_native, current_native)
                                        and source_appended_since(ready_source_state, current_paths)
                                        and not args.producer_done.is_file())
                                except (OSError, ValueError, NativeEvidenceFailure):
                                    live_checkpoint_unavailable += 1
                        else:
                            producer_done = True
                            break
                        time.sleep(0.2)
                    before = live.settled_report(process, report_path)
                    paths, native = inspect_selected_native_source(source, live.fixture.SECRET, session)
                    helper = app / "Contents/Helpers/spillcheck-hook"
                    for interface in ["standalone-cli", args.interface]:
                        for replay_path, native_session in paths:
                            payload = json.dumps({"hook_event_name": "SpillcheckTranscriptPoll",
                                "session_id": native_session, "transcript_path": str(replay_path)}).encode()
                            replay = subprocess.run([str(helper), "--socket", str(store / "capture.sock"),
                                "--agent", "claude-code", "--interface", interface, "--profile-id", profile],
                                input=payload, capture_output=True, timeout=5)
                            replay_runs.append({"interface": interface, "exitCode": replay.returncode,
                                "sourceKind": "main" if replay_path == source else "nativeChild"})
                    after = live.settled_report(process, report_path)
                finish.touch()
                process.wait(timeout=35)
        except (OSError, ValueError, NativeEvidenceFailure, subprocess.SubprocessError) as error:
            artifacts.report["runFailureType"] = type(error).__name__
        finally:
            if process is not None and process.poll() is None:
                finish.touch()
                try:
                    process.wait(timeout=35)
                except subprocess.TimeoutExpired:
                    pass
            cleanup = stop_group(process) if process is not None else None
            if ready_written:
                args.ready.unlink(missing_ok=True)
        result = live.read_report(report_path)
        final_paths, native = inspect_selected_native_source(source, live.fixture.SECRET, session)
        native["inspectedAfterSignedCollectorFinished"] = True
        stable = (bool(replay_runs) and before.get("queueCount") == 0 and after.get("queueCount") == 0
            and all(isinstance(before.get(key), int) and before[key] == after.get(key) for key in COUNTS))
        clean = store.is_dir() and all(live.fixture.SECRET.encode() not in path.read_bytes()
                                      for path in store.rglob("*") if path.is_file())
        positive_counts = {count for count in observed_counts if isinstance(count, int) and count > 0}
        live_progress = len(positive_counts) >= 2
        child_committed = strict_selected_role_coverage(result, native, version)
        passed = ((producer_done if live_observation else initial_complete) and process is not None and process.returncode == 0
                  and result.get("storageReady") and result.get("collectionConfigured")
                  and REQUIRED <= set(result.get("syntheticOccurrencesByContentType", {}))
                  and result.get("queueCount") == 0 and result.get("gapReasons") == []
                  and result.get("coverageReportTruncated") is False and stable and all(r["exitCode"] == 0 for r in replay_runs)
                  and native["requiredNativeFieldsValid"] and native["completeJSONLFraming"]
                  and MARKERS <= set(native["typedMarkers"])
                  and {marker for marker in MARKERS if marker.startswith("CHILD_")} <= set(native["childTypedMarkers"])
                  and version in native["producerVersions"] and version in result.get("observedAgentVersions", [])
                  and child_committed
                  and (live_progress if live_observation else True) and result.get("newVaultCleanupPassed") is True and clean)
        passed = passed and cleanup is not None and not cleanup["term_permission_denied"] and not cleanup["kill_permission_denied"]
        candidate_unchanged, registration_unchanged, saved_source_unchanged = False, False, False
        live_native_growth = False
        try:
            candidate_after = live.candidate_snapshot(args.candidate_manifest, args.expected_bundle_sha256, app)
            _, registration_after = registration_snapshot(args.manifest, args.interface)
            candidate_unchanged = candidate_before is not None and candidate_after == candidate_before
            registration_unchanged = registration_after == registration_before
            if not live_observation:
                saved_source_unchanged = source_bytes_snapshot(final_paths) == saved_source_before
            else:
                live_native_growth = (bool(ready_source_state) and not complete_selected_native_pair(ready_native, version)
                    and complete_selected_native_pair(native, version) and source_appended_since(ready_source_state, final_paths))
        except (OSError, ValueError, KeyError, TypeError, NativeEvidenceFailure) as error:
            artifacts.report["finalBindingFailureType"] = type(error).__name__
        passed = passed and candidate_unchanged and registration_unchanged and (live_observation or saved_source_unchanged)
        if live_observation:
            passed = passed and live_native_growth and live_committed_native_growth
        artifacts.report.update(schemaVersion=2, passed=bool(passed), sourceHost=args.interface,
            candidateUnchanged=candidate_unchanged, sourceRegistrationUnchanged=registration_unchanged,
            hostVersion=manifest["hostVersion"], hostOriginIndependentlyVerified=False,
            observationMode=args.observation, completeNativePairBeforeLaunch=initial_complete,
            savedSourceBytesUnchanged=saved_source_unchanged if not live_observation else None,
            liveNativeSourceProgressEstablished=live_native_growth if live_observation else False,
            newNativeMarkerCommittedBeforeProducerCompletion=live_committed_native_growth if live_observation else False,
            liveCheckpointUnavailableCount=live_checkpoint_unavailable,
            providerProducerVersion=version, sourceIsGenuineProviderOutput=True, credentialsAreSynthetic=True,
            selectedOriginalSourceOnly=True, unrelatedHistoryEnumerated=False, hooksModified=False,
            ownRuntimeIdentityConfirmed=True, producerFinished=producer_done if live_observation else None,
            liveCollectionBeforeProducerCompletionEstablished=(live_progress and live_native_growth and live_committed_native_growth) if live_observation else False,
            distinctLiveOccurrenceCountSamples=len(observed_counts), distinctPositiveLiveOccurrenceCountSamples=len(positive_counts),
            nativeSourceEvidence=native, signedNativeChildCommitEstablished=child_committed,
            signedIndividualRoleCoverageEstablished=child_committed,
            replayRuns=replay_runs, replayStable=stable,
            signedAppExitCode=process.returncode if process else None, processGroupCleanup=cleanup,
            ciphertextMarkerInspectionPassed=clean, result=result,
            passScope=f"Signed {args.interface} {args.observation} observation of one runtime-mapped original Claude source, all five types separately in one parent and one own native child with twelve typed markers and exact committed revision evidence, {'live growth' if live_observation else 'completed saved-source ingestion with no live-growth claim'}, exact parent/child replay across CLI/{args.interface} metadata, encrypted storage and scoped cleanup. Host origin is operator-declared. Hook proof, side questions, history discovery, restart, upgrade and six-host concurrency require separate gates.")
    return 0 if artifacts.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
