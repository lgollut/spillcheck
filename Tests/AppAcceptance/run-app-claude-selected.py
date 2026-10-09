#!/usr/bin/env python3
"""Observe one explicitly mapped, original Claude T3 source in the signed app.

A genuine app-owned producer writes the private manifest before waiting for the
ready sentinel. This observer never launches a provider, enumerates other native
histories, changes hooks, or rewrites the original transcript. Completion is a
separate producer sentinel; the collector then verifies encrypted settlement and
replays the same native source across CLI and T3 metadata.
"""
import argparse
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
from Support.claude_native_evidence import inspect_selected_native_source

spec = importlib.util.spec_from_file_location("signed_claude_live", Path(__file__).with_name("run-app-claude-live.py"))
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)
REQUIRED = {"userPrompt", "intermediateResponse", "finalResponse", "toolOutput", "toolError"}
MARKERS = {"PROMPT", "INTERMEDIATE", "FINAL", "SHELL_OK", "SHELL_ERROR", "CHILD_PROMPT", "CHILD_FINAL"}
COUNTS = ("occurrenceCount", "alertCount", "syntheticOccurrenceCount", "syntheticSessionCount")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--ready", required=True, type=Path)
    parser.add_argument("--producer-done", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--app", type=Path, default=ROOT / ".build/app/Build/Products/Debug/Spillcheck.app")
    parser.add_argument("--duration", type=int, default=600)
    args = parser.parse_args()
    if not 30 <= args.duration <= 1200:
        parser.error("duration must be 30 through 1200 seconds")
    os.umask(0o077)
    deadline = time.monotonic() + args.duration
    while not args.manifest.is_file() and time.monotonic() < deadline:
        time.sleep(0.2)
    if not args.manifest.is_file():
        parser.error("producer manifest unavailable")
    manifest_info = args.manifest.lstat()
    if (not stat.S_ISREG(manifest_info.st_mode) or manifest_info.st_mode & 0o077
            or manifest_info.st_uid != os.getuid()):
        parser.error("producer manifest must be owned and private")
    if args.manifest.stat().st_size > 64 * 1024:
        parser.error("producer manifest exceeds its bound")
    manifest = json.loads(args.manifest.read_text())
    session = str(uuid.UUID(manifest["nativeSessionId"]))
    source = Path(manifest["originalTranscriptPath"])
    authorized = Path.home() / ".claude/projects"
    if (source.is_symlink() or not source.is_file() or source.stem.lower() != session.lower()
            or not source.resolve().is_relative_to(authorized.resolve())):
        parser.error("manifest does not select an original native source")
    version = manifest["producerVersion"]
    if not isinstance(version, str) or not version or len(version.encode()) > 256:
        parser.error("producer version unavailable")
    # Require the exact main native identity and owned prompt, not just matching text.
    _, initial_native = inspect_selected_native_source(source, live.fixture.SECRET, session)
    if (not initial_native["requiredNativeFieldsValid"] or not initial_native["completeJSONLFraming"]
            or "PROMPT" not in initial_native["typedMarkers"]):
        parser.error("selected source lacks a complete owned prompt under its native identity")
    if args.ready.exists():
        parser.error("ready sentinel already exists")
    app = args.app.resolve()
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    if subprocess.run(["/usr/bin/pgrep", "-x", "Spillcheck"], capture_output=True).returncode == 0:
        parser.error("another Spillcheck app is running")
    with AcceptanceArtifacts("spillcheck-app-claude-selected-", args.output) as artifacts:
        root = artifacts.directory
        store, report_path, finish = root / "protected-store", root / "app-report.json", root / "finish"
        profile = "owned-selected-claude-t3"
        command = [str(app / "Contents/MacOS/Spillcheck"), "--store-directory", str(store),
                   "--claude-profile", profile, "--claude-version", version, "--claude-interface", "t3",
                   "--claude-source-root", str(source.parent), "--claude-active-source", str(source),
                   "--claude-session", session, "--acceptance-no-profile-catchup", "--acceptance-cleanup-new-vault",
                   "--acceptance-hold", "--acceptance-finish-file", str(finish),
                   "--acceptance-report", str(report_path), "--acceptance-seconds", "120"]
        stdout_path, stderr_path = root / "stdout.bin", root / "stderr.bin"
        replay_runs, observed_counts, native = [], set(), {}
        before, after = {}, {}
        producer_done = False
        ready_written = False
        process = None
        try:
            with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
                process = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
                ready = live.wait_for_report(process, report_path,
                    lambda r: r.get("storageReady") and r.get("collectionConfigured"), 30)
                if ready.get("storageReady") and ready.get("collectionConfigured"):
                    args.ready.write_text(json.dumps({"collectorReady": True}) + "\n")
                    ready_written = True
                    while process.poll() is None and time.monotonic() < deadline:
                        report = live.read_report(report_path)
                        if not args.producer_done.is_file():
                            observed_counts.add(report.get("syntheticOccurrenceCount", 0))
                        else:
                            producer_done = True
                            break
                        time.sleep(0.2)
                    before = live.settled_report(process, report_path)
                    paths, native = inspect_selected_native_source(source, live.fixture.SECRET, session)
                    helper = app / "Contents/Helpers/spillcheck-hook"
                    for interface in ["standalone-cli", "t3"]:
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
        except (OSError, ValueError, subprocess.SubprocessError) as error:
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
        _, native = inspect_selected_native_source(source, live.fixture.SECRET, session)
        native["inspectedAfterSignedCollectorFinished"] = True
        stable = (bool(replay_runs) and before.get("queueCount") == 0 and after.get("queueCount") == 0
            and all(isinstance(before.get(key), int) and before[key] == after.get(key) for key in COUNTS))
        clean = store.is_dir() and all(live.fixture.SECRET.encode() not in path.read_bytes()
                                      for path in store.rglob("*") if path.is_file())
        positive_counts = {count for count in observed_counts if isinstance(count, int) and count > 0}
        live_progress = len(positive_counts) >= 2
        child_committed = (result.get("syntheticNativeChildOccurrenceCount", 0) >= 2
            and {"userPrompt", "finalResponse"} <= set(result.get("syntheticNativeChildContentTypes", [])))
        passed = (producer_done and process is not None and process.returncode == 0
                  and result.get("storageReady") and result.get("collectionConfigured")
                  and REQUIRED <= set(result.get("syntheticOccurrencesByContentType", {}))
                  and result.get("queueCount") == 0 and stable and all(r["exitCode"] == 0 for r in replay_runs)
                  and native["requiredNativeFieldsValid"] and native["completeJSONLFraming"]
                  and MARKERS <= set(native["typedMarkers"]) and {"CHILD_PROMPT", "CHILD_FINAL"} <= set(native["childTypedMarkers"])
                  and version in native["producerVersions"] and version in result.get("observedAgentVersions", [])
                  and child_committed
                  and live_progress and result.get("newVaultCleanupPassed") is True and clean)
        passed = passed and cleanup is not None and not cleanup["term_permission_denied"] and not cleanup["kill_permission_denied"]
        artifacts.report.update(schemaVersion=1, passed=bool(passed), sourceHost="T3-owned-Claude-child",
            providerProducerVersion=version, sourceIsGenuineProviderOutput=True, credentialsAreSynthetic=True,
            selectedOriginalSourceOnly=True, unrelatedHistoryEnumerated=False, hooksModified=False,
            ownRuntimeIdentityConfirmed=True, producerFinished=producer_done,
            liveCollectionBeforeProducerCompletionEstablished=live_progress,
            distinctLiveOccurrenceCountSamples=len(observed_counts), distinctPositiveLiveOccurrenceCountSamples=len(positive_counts),
            nativeSourceEvidence=native, signedNativeChildCommitEstablished=child_committed,
            replayRuns=replay_runs, replayStable=stable,
            signedAppExitCode=process.returncode if process else None, processGroupCleanup=cleanup,
            ciphertextMarkerInspectionPassed=clean, result=result,
            passScope="Signed observation of one genuinely T3-created original Claude source, all five types, native child prompt/final, live growth, exact parent/child replay across CLI/T3 metadata, encrypted storage and scoped cleanup. Hook proof, history discovery, restart, upgrade and six-host concurrency require separate gates.")
    return 0 if artifacts.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
