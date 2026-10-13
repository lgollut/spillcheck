#!/usr/bin/env python3
"""Fixed constructed Claude transcript: signed inventory review/removal across three workers.

No provider, authentication, hooks, real history, OS notifications or real vault is used.
This measures signed implementation behavior, not genuine CLI/Desktop/T3 acceptance.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import time
import uuid


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


inventory = module("claude_inventory_shared", "run-app-codex-inventory-state.py")
claude = module("claude_inventory_recovery", "run-app-claude-recovery.py")
shared, setup, lifecycle, live = inventory.shared, inventory.setup, inventory.lifecycle, claude.live
ROOT, require = shared.ROOT, shared.require
from Support.acceptance_journal import ClaudeRecoveryJournal
from Support.inventory_evidence import InventoryEvidence

PROFILE, VERSION = "owned-claude-inventory", "2.1.296"
COUNTS = dict(inventory.COUNTS)
REVIEW_CONTROL, REMOVE_CONTROL, REPLAY_CONTROL = inventory.REVIEW_CONTROL, inventory.REMOVE_CONTROL, inventory.REPLAY_CONTROL
DOMAINS, NUMERIC_STATE = inventory.DOMAINS, inventory.NUMERIC_STATE
finish_worker, cleanup_workers, finish_creator = inventory.finish_worker, inventory.cleanup_workers, inventory.finish_creator


class InventoryJournal(ClaudeRecoveryJournal):
    REPORT_NAMES = (*ClaudeRecoveryJournal.REPORT_NAMES, "worker3-report.json")


def worker_command(binary, root, name):
    require(name in ("worker1", "worker2", "worker3"), "fixed-worker-required")
    return shared.command(binary, root, name)[:-1] + [
        "--acceptance-recovery-worker", "--acceptance-no-profile-catchup",
        "--acceptance-recovery-inventory-state", "--acceptance-claude-inventory",
        "--claude-profile", PROFILE, "--claude-version", VERSION,
        "--claude-source-root", str(root / "claude/projects"),
        "--claude-interface", "standalone-cli", "--claude-authorized-host", "standalone-cli",
    ] + (["--acceptance-allow-history-request"] if name == "worker1" else [])


def create_fixture(root):
    """One original native file; exactly seven appearances and five content types."""
    for child in ("claude", "claude/projects", "claude/projects/inventory", "project"):
        (root / child).mkdir(mode=0o700)
    session = str(uuid.uuid4())
    source = root / "claude/projects/inventory" / (session + ".jsonl")
    timestamp = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=60)).isoformat()
    def row(kind, content, stop_reason=None):
        message = {"role": kind, "content": content}
        if stop_reason is not None:
            message["stop_reason"] = stop_reason
        return {"type": kind, "uuid": str(uuid.uuid4()), "sessionId": session,
            "timestamp": timestamp, "version": VERSION, "cwd": str(root / "project"),
            "isSidechain": False, "message": message}
    def text(label):
        return {"type": "text", "text": "LEAKRET_INVENTORY_" + label + " " + shared.TOKEN.decode()}
    rows = [row("user", [text("PROMPT_1")]), row("user", [text("PROMPT_2")]), row("user", [text("PROMPT_3")]),
        row("assistant", [text("INTERMEDIATE"),
            {"type": "tool_use", "id": "owned-output", "name": "Bash", "input": {}},
            {"type": "tool_use", "id": "owned-error", "name": "Bash", "input": {}}], "tool_use"),
        row("user", [{"type": "tool_result", "tool_use_id": "owned-output", "is_error": False,
            "content": "LEAKRET_INVENTORY_OUTPUT " + shared.TOKEN.decode()}]),
        row("user", [{"type": "tool_result", "tool_use_id": "owned-error", "is_error": True,
            "content": "LEAKRET_INVENTORY_ERROR " + shared.TOKEN.decode()}]),
        row("assistant", [text("FINAL")], "end_turn")]
    payload = b"".join(json.dumps(row, separators=(",", ":")).encode() + b"\n" for row in rows)
    require(len(payload) <= 64 * 1024, "fixed-source-budget")
    shared.write_new(source, payload)
    descriptor = {"schemaVersion": 1, "sessionID": session, "sourcePath": str(source),
        "sourceSHA256": hashlib.sha256(payload).hexdigest()}
    shared.write_json(root / "claude-inventory.json", descriptor)
    return descriptor


def source_unchanged(root, descriptor):
    """Reopen only the already constructed file; reject unsafe ancestor replacement."""
    path = Path(descriptor["sourcePath"])
    expected = root / "claude/projects/inventory" / (descriptor["sessionID"] + ".jsonl")
    return (path == expected and path.resolve(strict=True) == expected
        and shared.private_json(root / "claude-inventory.json") == descriptor
        and hashlib.sha256(shared.private_bytes(path, limit=64 * 1024)).hexdigest() == descriptor["sourceSHA256"])


def initial_history_request(root, descriptor):
    require(source_unchanged(root, descriptor), "original-owned-source-changed")
    now = time.time()
    require(type(now) in (int, float) and math.isfinite(now), "finite-audit-time-required")
    end = math.floor(now) - 978307200
    require(abs(end) + 604800 < 2 ** 53, "exact-audit-time-required")
    request = {"kind": "LeakretClaudeHistory", "version": 1,
        "audit": {"id": str(uuid.uuid4()), "reason": "resume", "start": end - 604800, "end": end},
        "directories": [], "pending": [descriptor["sourcePath"]], "deferred": [], "partial": False,
        "restartSources": [descriptor["sourcePath"]], "selectedSessionID": descriptor["sessionID"]}
    payload = json.dumps(request, separators=(",", ":"), allow_nan=False).encode()
    require(len(payload) <= 4096, "initial-history-request-budget")
    return payload


def deliver(helper, root, descriptor, helper_lifetime):
    payload = initial_history_request(root, descriptor)
    cleanup = {}
    helper_lifetime["stopped"] = False
    try:
        code, output, _ = shared.live.bounded([str(helper), "--socket", str(root / "protected-store/capture.sock"),
            "--agent", "claude-code", "--interface", "standalone-cli", "--profile-id", PROFILE],
            environment=dict(os.environ), directory=ROOT, timeout=5, maximum_bytes=1024,
            input_bytes=payload, cleanup_report=cleanup)
    finally:
        helper_lifetime["stopped"] = (cleanup.get("leaderExited") is True
            and cleanup.get("groupKillPermissionDenied") is False)
    require(code == 0 and output.strip() == b"{}" and helper_lifetime["stopped"], "helper-lifetime-unconfirmed")


def source_ready(report):
    return (report.get("storageReady") is True and report.get("collectionConfigured") is True
        and report.get("recoveryLoadedExistingManifest") is True
        and shared.manifest_digest(report) is not None
        and report.get("recoveryClaudeInventoryFixtureEnabled") is True
        and report.get("recoveryClaudePollingStopped") is True
        and report.get("recoveryInventoryControlFailure") is None
        and report.get("transportRejectionCountsByStageAndReason") == {}
        and shared.empty_unclaimed_queue(report) and report.get("coverageReportTruncated") is False)


evidence = InventoryEvidence(shared, COUNTS, source_ready)
digest_values = evidence.digest_values
counted_states = evidence.counted_states
inventory_state = evidence.inventory_state
state_unchanged = evidence.state_unchanged
retained = evidence.retained
reviewed_transition = evidence.reviewed_transition
removed = evidence.removed
removed_transition = evidence.removed_transition
fresh_ready = evidence.fresh_ready
new_single_processed_capture = evidence.new_single_processed_capture
exact_source_replayed = evidence.exact_source_replayed


def replay_source(worker, root, name, token, before, phase_predicate):
    observation = before.get("recoveryInventoryReplay")
    require(isinstance(observation, dict) and observation.get("controlConsumed") is False
        and observation.get("queued") is False and before.get("recoveryProcessingStopped") is False,
        "fresh-replay-control-required")
    shared.write_new(root / REPLAY_CONTROL, token)
    return worker.wait_report(root / (name + "-report.json"), lambda value:
        phase_predicate(value) and exact_source_replayed(before, value), "exact-whole-source-replay-unverified", timeout=75)

def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--private-control", required=True, type=Path)
    parser.add_argument("--app", required=True, type=Path)
    live.candidate_arguments(parser)
    args = parser.parse_args(argv)
    live.candidate_admission(parser, args)
    if args.candidate_manifest is None:
        parser.error("constructed signed regression requires a candidate manifest and expected bundle digest")
    return args


def run(args):
    os.umask(0o077)
    require(not args.output.exists() and not args.output.is_symlink()
        and not args.private_control.exists() and not args.private_control.is_symlink()
        and args.output.absolute() != args.private_control.absolute(), "new-report-paths-required")
    require(args.private_control.parent.is_dir()
        and args.private_control.parent.resolve() == args.private_control.absolute().parent, "private-control-parent-required")
    require(args.candidate_manifest is not None and args.expected_bundle_sha256 is not None,
        "frozen-candidate-required")
    app = args.app.resolve(strict=True)
    candidate_before = live.candidate_snapshot(args.candidate_manifest, args.expected_bundle_sha256, app)
    binary, helper = app / "Contents/MacOS/Spillcheck", app / "Contents/Helpers/spillcheck-hook"
    require(subprocess.run(["/usr/bin/pgrep", "-x", "Spillcheck"], capture_output=True).returncode == 1,
        "existing-spillcheck-or-unavailable-process-inventory")
    with shared.AcceptanceArtifacts("spillcheck-claude-inventory-", args.output,
            diagnostic_journal_factory=InventoryJournal) as artifacts:
        root, token = artifacts.directory, os.urandom(32)
        shared.write_new(root / "run-token", token)
        descriptor = create_fixture(root)
        shared.write_json(args.private_control, {"schemaVersion": 1, "ownedArtifactDirectory": str(root),
            "reportPath": str(args.output.absolute()), "candidateBundleSHA256": args.expected_bundle_sha256,
            "runTokenPath": str(root / "run-token"), "cleanupOwnerReport": str(root / "owner-report.json"),
            "ownerProcessHandoff": str(root / "owner-process-private.json"),
            "retainedOwnerHandoff": str(root / "owner-retained-private.json"),
            "persistentDiagnostics": str(artifacts.diagnostic_journal.directory),
            "cleanupAuthority": "original-fresh-vault-owner-only", "loadedWorkersMayDeleteKeys": False})
        report = {"schemaVersion": 1, "scope": "signed-constructed-Claude-inventory-state",
            "candidateBinding": candidate_before, "constructedProducerVersion": VERSION,
            "originalOccurrencesByContentType": COUNTS, "selectedThreadCount": 1,
            "syntheticInitialQueueAdmission": True, "initialAdmissionKind": "exact-owned-source-historical-audit",
            "providerHookDispatchEstablished": False, "storedDeliveryReceiptSeeded": False,
            "systemNotificationDeliveryEstablished": False, "providerSessionsCreated": 0,
            "providerConfigurationChanged": False, "sourceEnumerationPerformed": False,
            "savedProfileRecoveryEstablished": False, "schemaMigrationEstablished": False,
            "providerUpgradeEstablished": False, "crashRecoveryEstablished": False,
            "genuineProviderAcceptanceEstablished": False, "fullClaudeAcceptance": False,
            "sourceOpeningEstablished": False, "nativeChildCoverageEstablished": False,
            "checks": {}, "passed": False}
        artifacts.report = report
        checks, workers, owner = report["checks"], [], None
        owner_ready_observed = False
        helper_lifetime, final = {"stopped": True}, {}
        phase = "existing-app-admission"
        try:
            phase = "fresh-vault-owner"
            owner = setup.ReportProcess(shared.command(binary, root, "owner"))
            lifecycle.process_handoff(root, "owner-process-private.json", owner.process, "original-fresh-vault-owner")
            owner.wait_report(root / "owner-report.json", lambda value: value.get("ownerReady") is True
                and value.get("createdFreshVault") is True, "fresh-owner-unavailable")
            owner_ready_observed = True
            checks["freshOwnerCreatedVault"] = True
            artifacts.diagnostic_journal.require_manifest()

            def launch(name):
                require(owner.process.poll() is None, "fresh-owner-lost")
                worker = setup.ReportProcess(worker_command(binary, root, name))
                workers.append(worker)
                lifecycle.process_handoff(root, name + "-process-private.json", worker.process, "loaded-vault-worker")
                return worker

            phase = "baseline-worker"
            worker1 = launch("worker1")
            empty = worker1.wait_report(root / "worker1-report.json", fresh_ready, "empty-source-worker-unavailable")
            deliver(helper, root, descriptor, helper_lifetime)
            worker1.wait_report(root / "worker1-report.json", lambda value:
                shared.collected(value, COUNTS, VERSION) and new_single_processed_capture(empty, value),
                "baseline-five-types-not-collected", timeout=60)
            checks["constructedSourceCollectedExactlySevenAppearancesFiveTypes"] = True
            baseline = worker1.wait_report(root / "worker1-report.json", lambda value:
                retained(value, VERSION, "baseline") and new_single_processed_capture(empty, value),
                "baseline-pending-receipt-state-unavailable", timeout=30)
            checks["baselinePendingNotificationReceiptEstablished"] = True
            phase = "review-and-store-receipt"
            shared.write_new(root / "stop-processing", token)
            paused = worker1.wait_report(root / "worker1-report.json", lambda value:
                value.get("recoveryProcessingStopped") is True and source_ready(value) and state_unchanged(baseline, value),
                "review-processing-barrier-unavailable")
            shared.write_new(root / REVIEW_CONTROL, token)
            reviewed = worker1.wait_report(root / "worker1-report.json", lambda value:
                reviewed_transition(paused, value, VERSION), "review-or-store-receipt-not-saved")
            checks["twoDistinctReviewsAndStoreReceiptSaved"] = True
            report["storedDeliveryReceiptSeeded"] = True
            report["storedDeliveryReceiptKind"] = reviewed["recoveryInventorySeededReceiptKind"]
            reviewed = finish_worker(worker1, root, "worker1", lambda value:
                source_ready(value) and state_unchanged(reviewed, value))
            checks["reviewWorkerExitedWithExactStoredState"] = True
            (root / "stop-processing").unlink()
            (root / REVIEW_CONTROL).unlink()

            phase = "reviewed-state-restart-and-replay"
            worker2 = launch("worker2")
            restored = worker2.wait_report(root / "worker2-report.json", lambda value:
                retained(value, VERSION, "reviewed") and state_unchanged(reviewed, value),
                "reviewed-state-not-restored")
            checks["fullReviewAndDeliveryValuesSurviveColdRestart"] = True
            replayed = replay_source(worker2, root, "worker2", token, restored,
                lambda value: retained(value, VERSION, "reviewed"))
            checks["fullReviewAndDeliveryValuesSurviveExactSourceReplay"] = True
            phase = "obsolete-acknowledgement-and-content-removal"
            shared.write_new(root / "stop-processing", token)
            paused = worker2.wait_report(root / "worker2-report.json", lambda value:
                value.get("recoveryProcessingStopped") is True and source_ready(value) and state_unchanged(replayed, value),
                "removal-processing-barrier-unavailable")
            shared.write_new(root / REMOVE_CONTROL, token)
            removed_report = worker2.wait_report(root / "worker2-report.json", lambda value:
                removed_transition(paused, value, VERSION), "obsolete-content-removal-unverified")
            checks["revokedMarkerRetainedAndAllProtectedPayloadRowsRemoved"] = True
            checks["removedLocationsKeepOriginalAnalysisReceiptsAndLabels"] = True
            removed_report = finish_worker(worker2, root, "worker2", lambda value:
                removed(value) and state_unchanged(removed_report, value))
            checks["removalWorkerExitedWithExactStoredState"] = True
            (root / "stop-processing").unlink()
            (root / REMOVE_CONTROL).unlink()
            (root / REPLAY_CONTROL).unlink()

            phase = "removed-state-restart-and-replay"
            worker3 = launch("worker3")
            restored = worker3.wait_report(root / "worker3-report.json", lambda value:
                removed(value) and state_unchanged(removed_report, value), "removed-state-not-restored")
            checks["fullObsoleteAndRemovalValuesSurviveColdRestart"] = True
            replayed = replay_source(worker3, root, "worker3", token, restored, removed)
            checks["exactSourceReplayCannotResurrectContentOrAlerts"] = True
            final = finish_worker(worker3, root, "worker3", lambda value:
                removed(value) and state_unchanged(replayed, value))
            checks["threeDistinctSignedWorkersExitedNormally"] = len({worker.process.pid for worker in workers}) == 3
            checks["finalQueueEmptyWithoutGaps"] = source_ready(final) and final.get("gapReasons") == []
        except (OSError, ValueError, KeyError, TypeError, RuntimeError, TimeoutError, BufferError, subprocess.SubprocessError) as error:
            report.update(unmetGate=error.gate if isinstance(error, shared.GateFailure) else phase,
                failureCategory="controlled-run-failure")
        finally:
            groups, shutdowns = cleanup_workers(workers, root)
            checks["preCleanupDiagnosticSnapshotPassed"] = artifacts.diagnostic_journal.snapshot(final=True)
            authorized = shared.safe_creator_cleanup(shutdowns, helper_stopped=helper_lifetime["stopped"],
                socket_absent=not (root / "protected-store/capture.sock").exists())
            owner_report, retained_creator, owner_stopped, handoff_failed = finish_creator(owner, root, token,
                ready_observed=owner_ready_observed, authorized=authorized, groups=groups)
            report["originalCreatorRetainedForCleanup"] = retained_creator
            report["creatorRetentionHandoffWriteFailed"] = handoff_failed
            if setup.owner_failure_summary(owner_report):
                report["ownerFailureDiagnostic"] = setup.owner_failure_summary(owner_report)
            checks["creatorCleanupAuthorizedOnlyAfterNormalWorkerShutdown"] = authorized
            checks["originalFreshCreatorCleanupPassed"] = (owner_report.get("createdFreshVault") is True
                and owner_report.get("cleanupPassed") is True)
            report["ownedProtectionCleanupPending"] = owner is not None and owner_report.get("cleanupPassed") is not True
            checks["ownedProcessGroupsStopped"] = (not retained_creator and owner_stopped and helper_lifetime["stopped"]
                and all(row["groupStopped"] for row in shutdowns) and bool(groups)
                and all(row.get("term_permission_denied") is False and row.get("kill_permission_denied") is False for row in groups))
            checks["noAppDiagnosticsOrOutput"] = all(not any(process.counts.values()) for process in workers + ([owner] if owner else []))
            try:
                checks["encryptedMarkerInspectionPassed"] = shared.marker_free(root / "protected-store")
                checks["originalConstructedSourceAndDescriptorUnchanged"] = source_unchanged(root, descriptor)
                checks["candidateAndProductionInputsUnchanged"] = live.candidate_snapshot(
                    args.candidate_manifest, args.expected_bundle_sha256, app) == candidate_before
            except (OSError, ValueError, RuntimeError):
                checks["finalBoundaryChecksPassed"] = False
            final_state = inventory_state(final)
            report["result"] = {"newVaultCleanupPassed": checks["originalFreshCreatorCleanupPassed"],
                "originalOccurrenceCount": 7, "finalOccurrenceCount": final.get("occurrenceCount"),
                "finalValueCount": final.get("valueCount"), "queueCount": final.get("queueCount"),
                "gapReasons": final.get("gapReasons"), "finalStatePhase": final_state["phase"] if final_state else None,
                "finalProtectedPayloadRowCount": final_state["payloadRowCount"] if final_state else None}
            required = {"preCleanupDiagnosticSnapshotPassed", "freshOwnerCreatedVault", "constructedSourceCollectedExactlySevenAppearancesFiveTypes",
                "baselinePendingNotificationReceiptEstablished",
                "twoDistinctReviewsAndStoreReceiptSaved", "reviewWorkerExitedWithExactStoredState",
                "fullReviewAndDeliveryValuesSurviveColdRestart", "fullReviewAndDeliveryValuesSurviveExactSourceReplay",
                "revokedMarkerRetainedAndAllProtectedPayloadRowsRemoved", "removedLocationsKeepOriginalAnalysisReceiptsAndLabels",
                "removalWorkerExitedWithExactStoredState", "fullObsoleteAndRemovalValuesSurviveColdRestart",
                "exactSourceReplayCannotResurrectContentOrAlerts", "threeDistinctSignedWorkersExitedNormally",
                "finalQueueEmptyWithoutGaps", "creatorCleanupAuthorizedOnlyAfterNormalWorkerShutdown",
                "originalFreshCreatorCleanupPassed", "ownedProcessGroupsStopped", "noAppDiagnosticsOrOutput",
                "encryptedMarkerInspectionPassed", "originalConstructedSourceAndDescriptorUnchanged",
                "candidateAndProductionInputsUnchanged"}
            report["passed"] = "unmetGate" not in report and required <= checks.keys() and all(checks.values())
    return 0 if artifacts.passed else 1



def main(argv=None):
    try:
        return run(arguments(argv))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError):
        print(json.dumps({"schemaVersion": 1, "passed": False, "status": "controlled-failure",
            "signedAppLaunchState": "consult-retained-run-evidence"}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
