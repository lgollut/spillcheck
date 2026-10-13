#!/usr/bin/env python3
"""Signed review, receipt and obsolete-content persistence over one exact owned T3 source."""
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import time
import uuid

spec = importlib.util.spec_from_file_location("inventory_lifecycle", Path(__file__).with_name("run-app-codex-upgrade.py"))
lifecycle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lifecycle)
setup, shared = lifecycle.setup, lifecycle.shared
ROOT, require = shared.ROOT, shared.require
from Support.inventory_evidence import (
    InventoryEvidence, DOMAINS, NUMERIC_STATE, REVIEW_STATES, DELIVERY_STATES,
)
COUNTS = {"userPrompt": 3, "intermediateResponse": 1, "finalResponse": 1, "toolOutput": 1, "toolError": 1}
REVIEW_CONTROL = "inventory-review-and-receipt"
REMOVE_CONTROL = "inventory-obsolete-and-remove"
REPLAY_CONTROL = "inventory-replay-source"
SWIFT_REFERENCE_UNIX_SECONDS = 978307200
AUDIT_LOOKBACK_SECONDS = 7 * 24 * 60 * 60


def worker_command(binary, root, name, *, selection, reader, version, host):
    require(name in ("worker1", "worker2", "worker3"), "fixed-worker-required")
    command = shared.command(binary, root, name, selection=selection, reader=reader,
        version=version, host=host, active=False) + ["--acceptance-recovery-inventory-state"]
    return command + (["--acceptance-allow-history-request"] if name == "worker1" else [])


def source_ready(report):
    return (report.get("storageReady") is True and report.get("collectionConfigured") is True
        and report.get("recoveryLoadedExistingManifest") is True
        and shared.manifest_digest(report) is not None
        and report.get("recoveryCodexPollingStopped") is True
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


def initial_history_request(native):
    """Serialize only an initial, exact-source Codex audit, using Swift's Date epoch."""
    native = shared.canonical_id(native)
    now = time.time()
    require(type(now) in (int, float) and math.isfinite(now), "finite-audit-time-required")
    # Integral seconds avoid floating-rounding differences in Swift's exact 7-day check.
    end = math.floor(now) - SWIFT_REFERENCE_UNIX_SECONDS
    require(abs(end) + AUDIT_LOOKBACK_SECONDS < 2 ** 53, "exact-audit-time-required")
    request = {"kind": "leakret-codex-history-v1",
        "audit": {"id": str(uuid.uuid4()), "reason": "restart",
            "start": end - AUDIT_LOOKBACK_SECONDS, "end": end},
        "threads": [native], "discovering": False, "selectedSourceOnly": True,
        "children": [], "visited": [], "archived": False}
    payload = json.dumps(request, separators=(",", ":"), allow_nan=False).encode()
    require(len(payload) <= 4096, "initial-history-request-budget")
    return payload


def deliver(helper, root, native, helper_lifetime):
    payload = initial_history_request(native)
    cleanup = {}
    helper_lifetime["stopped"] = False
    try:
        code, output, _ = shared.live.bounded([str(helper), "--socket", str(root / "protected-store/capture.sock"),
            "--agent", "codex", "--interface", "t3", "--profile-id", shared.PROFILE],
            environment=dict(os.environ), directory=ROOT, timeout=5, maximum_bytes=1024,
            input_bytes=payload,
            cleanup_report=cleanup)
    finally:
        helper_lifetime["stopped"] = (cleanup.get("leaderExited") is True
            and cleanup.get("groupKillPermissionDenied") is False)
    # A successful helper intentionally returns {} even if transport delivery fails.
    # Only a new consumed AND successfully processed digest proves admission here.
    require(code == 0 and output.strip() == b"{}" and helper_lifetime["stopped"], "helper-lifetime-unconfirmed")


def finish_worker(worker, root, name, predicate):
    shared.write_new(root / (name + "-finish"), b"finished\n")
    worker.wait_exit()
    report = shared.private_json(root / (name + "-report.json"))
    require(report.get("acceptancePhase") == "shutdown-complete" and predicate(report)
        and not (root / "protected-store/capture.sock").exists(), "worker-shutdown-state-changed")
    return report


def cleanup_workers(workers, root):
    groups, shutdowns = [], []
    for index, worker in enumerate(workers, 1):
        name = "worker%d" % index
        if worker.process.poll() is None:
            try:
                finish = root / (name + "-finish")
                if not finish.exists():
                    shared.write_new(finish, b"finished\n")
                worker.wait_exit()
            except (OSError, RuntimeError, subprocess.SubprocessError):
                pass
        stopped = False
        try:
            result = worker.stop()
            groups.append(result)
            stopped = (worker.process.poll() is not None and result.get("term_permission_denied") is False
                and result.get("kill_permission_denied") is False)
        except (OSError, RuntimeError, subprocess.SubprocessError):
            pass
        report = {}
        try:
            report = shared.private_json(root / (name + "-report.json"))
        except (OSError, ValueError, RuntimeError):
            pass
        shutdowns.append({"exitCode": worker.process.poll(), "shutdownPhase": report.get("acceptancePhase"),
            "groupStopped": stopped})
    return groups, shutdowns


def finish_creator(owner, root, token, *, ready_observed, authorized, groups):
    if owner is not None and authorized and owner.process.poll() is None:
        try:
            shared.write_new(root / "owner-finish", token)
            owner.wait_exit()
        except (OSError, RuntimeError, subprocess.SubprocessError):
            pass
    owner_report = {}
    try:
        owner_report = shared.private_json(root / "owner-report.json")
    except (OSError, ValueError, RuntimeError):
        pass
    retained = lifecycle.preserve_creator(owner, ready_observed=ready_observed, report=owner_report)
    handoff_failed = False
    stopped = owner is None
    if retained:
        try:
            shared.write_json(root / "owner-retained-private.json", {"schemaVersion": 1,
                "pid": owner.process.pid, "expectedProcessGroupID": owner.process.pid,
                "ownerProcessHandoff": str(root / "owner-process-private.json"),
                "ownerFinishControl": str(root / "owner-finish"), "runTokenPath": str(root / "run-token"),
                "creatorLifetimeLimitSeconds": 900, "cleanupStillRequiresAllOwnedSourcesStopped": True,
                "loadedWorkerCleanupAuthorized": False})
        except (OSError, RuntimeError):
            handoff_failed = True
    elif owner is not None:
        try:
            result = owner.stop()
            groups.append(result)
            stopped = (owner.process.poll() is not None and result.get("term_permission_denied") is False
                and result.get("kill_permission_denied") is False)
        except (OSError, RuntimeError, subprocess.SubprocessError):
            pass
    return owner_report, retained, stopped, handoff_failed


def arguments(argv=None):
    args = shared.parse_arguments(argv)
    require(args.candidate_baseline_directory is not None, "fresh-current-candidate-baseline-required")
    return args


def run(args):
    os.umask(0o077)
    require(args.candidate_baseline_directory is not None, "fresh-current-candidate-baseline-required")
    require(not args.output.exists() and not args.output.is_symlink()
        and not args.private_control.exists() and not args.private_control.is_symlink()
        and args.output.absolute() != args.private_control.absolute(), "new-report-paths-required")
    binding = shared.load_bound_selection(args)
    selection = binding["selection"]
    require(selection["counts"] == COUNTS, "exact-seven-appearance-fixture-required")
    app, manifest = args.app.resolve(strict=True), binding["manifest"]
    require(shared.preflight.check(manifest, app, ROOT)["consistent"], "frozen-candidate-required")
    binary, helper = app / "Contents/MacOS/Spillcheck", app / "Contents/Helpers/spillcheck-hook"
    reader = args.executable.resolve(strict=True)
    reader_hash = shared.preflight.hash_file(reader.parent, reader.name, [0])
    with shared.AcceptanceArtifacts("spillcheck-cx-state-", args.output) as artifacts:
        root, token = artifacts.directory, os.urandom(32)
        shared.write_new(root / "run-token", token)
        shared.write_new(root / "stop-codex-polling", token)
        shared.write_json(root / "candidate-build.json", manifest)
        args.private_control.parent.mkdir(parents=True, exist_ok=True)
        shared.write_json(args.private_control, {"schemaVersion": 1, "ownedArtifactDirectory": str(root),
            "reportPath": str(args.output.absolute()), "candidateBundleSHA256": args.expected_bundle_sha256,
            "sourceDirectory": str(binding["source_directory"]), "candidateBaselineDirectory": str(binding["baseline_directory"]),
            "runTokenPath": str(root / "run-token"), "cleanupOwnerReport": str(root / "owner-report.json"),
            "ownerProcessHandoff": str(root / "owner-process-private.json"),
            "retainedOwnerHandoff": str(root / "owner-retained-private.json"),
            "cleanupAuthority": "original-fresh-vault-owner-only", "loadedWorkersMayDeleteKeys": False,
            "protectionCleanupReportField": "ownedProtectionCleanupPending",
            "cleanupPendingIncludesRetainedFailureArtifacts": True})
        report = {"schemaVersion": 1, "scope": "signed-T3-exact-source-retained-inventory-state",
            "candidateBundleSHA256": args.expected_bundle_sha256, "hostVersion": args.host_version,
            "readerVersion": args.expected_reader_version, "producerVersion": args.expected_producer_version,
            "selectedThreadCount": 1, "originalOccurrencesByContentType": COUNTS,
            "syntheticInitialQueueAdmission": True, "initialAdmissionKind": "exact-selected-source-historical-audit",
            "providerHookDispatchEstablished": False,
            "storedDeliveryReceiptSeeded": False, "systemNotificationDeliveryEstablished": False,
            "providerSessionsCreated": 0, "providerConfigurationChanged": False, "sourceEnumerationPerformed": False,
            "savedProfileRecoveryEstablished": False, "schemaMigrationEstablished": False,
            "providerUpgradeEstablished": False, "crashRecoveryEstablished": False,
            "fullT3Acceptance": False, "fullCodexAcceptance": False, "nativeChildCoverageEstablished": False,
            "sourceOpeningEstablished": False, "signedIndividualMarkerReceiptsVerified": False,
            "checks": {}, "passed": False, **shared.evidence_lineage(binding)}
        artifacts.report = report
        checks, workers, owner = report["checks"], [], None
        owner_ready_observed = False
        helper_lifetime, final = {"stopped": True}, {}
        phase = "reader-version"
        try:
            version = shared.live.observe_version(reader, environment=dict(os.environ, CODEX_HOME=str(selection["home"])),
                directory=root, expected=args.expected_reader_version)
            checks["readerVersionObserved"] = version == args.expected_reader_version
            phase = "fresh-vault-owner"
            owner = setup.ReportProcess(shared.command(binary, root, "owner"))
            lifecycle.process_handoff(root, "owner-process-private.json", owner.process, "original-fresh-vault-owner")
            owner.wait_report(root / "owner-report.json", lambda value: value.get("ownerReady") is True
                and value.get("createdFreshVault") is True, "fresh-owner-unavailable")
            owner_ready_observed = True
            checks["freshOwnerCreatedVault"] = True

            def launch(name):
                require(owner.process.poll() is None, "fresh-owner-lost")
                worker = setup.ReportProcess(worker_command(binary, root, name, selection=selection,
                    reader=reader, version=version, host=args.host_version))
                workers.append(worker)
                lifecycle.process_handoff(root, name + "-process-private.json", worker.process, "loaded-vault-worker")
                return worker

            phase = "baseline-worker"
            worker1 = launch("worker1")
            empty = worker1.wait_report(root / "worker1-report.json", fresh_ready, "empty-source-worker-unavailable")
            deliver(helper, root, selection["native"], helper_lifetime)
            worker1.wait_report(root / "worker1-report.json", lambda value:
                shared.collected(value, COUNTS, args.expected_producer_version) and new_single_processed_capture(empty, value),
                "baseline-five-types-not-collected", timeout=60)
            checks["genuineSourceCollectedExactlySevenAppearancesFiveTypes"] = True
            baseline = worker1.wait_report(root / "worker1-report.json", lambda value:
                retained(value, args.expected_producer_version, "baseline") and new_single_processed_capture(empty, value),
                "baseline-pending-receipt-state-unavailable", timeout=30)
            checks["baselinePendingNotificationReceiptEstablished"] = True
            phase = "review-and-store-receipt"
            shared.write_new(root / "stop-processing", token)
            paused = worker1.wait_report(root / "worker1-report.json", lambda value:
                value.get("recoveryProcessingStopped") is True and source_ready(value) and state_unchanged(baseline, value),
                "review-processing-barrier-unavailable")
            shared.write_new(root / REVIEW_CONTROL, token)
            reviewed = worker1.wait_report(root / "worker1-report.json", lambda value:
                reviewed_transition(paused, value, args.expected_producer_version), "review-or-store-receipt-not-saved")
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
                retained(value, args.expected_producer_version, "reviewed") and state_unchanged(reviewed, value),
                "reviewed-state-not-restored")
            checks["fullReviewAndDeliveryValuesSurviveColdRestart"] = True
            replayed = replay_source(worker2, root, "worker2", token, restored,
                lambda value: retained(value, args.expected_producer_version, "reviewed"))
            checks["fullReviewAndDeliveryValuesSurviveExactSourceReplay"] = True
            phase = "obsolete-acknowledgement-and-content-removal"
            shared.write_new(root / "stop-processing", token)
            paused = worker2.wait_report(root / "worker2-report.json", lambda value:
                value.get("recoveryProcessingStopped") is True and source_ready(value) and state_unchanged(replayed, value),
                "removal-processing-barrier-unavailable")
            shared.write_new(root / REMOVE_CONTROL, token)
            removed_report = worker2.wait_report(root / "worker2-report.json", lambda value:
                removed_transition(paused, value, args.expected_producer_version), "obsolete-content-removal-unverified")
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
                checks["sourceSelectionAndAllProofBytesUnchanged"] = shared.bound_evidence_unchanged(binding)
                checks["readerExecutableUnchanged"] = shared.preflight.hash_file(reader.parent, reader.name, [0]) == reader_hash
                checks["candidateAndProductionInputsUnchanged"] = shared.preflight.check(manifest, app, ROOT)["consistent"]
            except (OSError, ValueError, RuntimeError):
                checks["finalBoundaryChecksPassed"] = False
            final_state = inventory_state(final)
            report["result"] = {"newVaultCleanupPassed": checks["originalFreshCreatorCleanupPassed"],
                "originalOccurrenceCount": 7, "finalOccurrenceCount": final.get("occurrenceCount"),
                "finalValueCount": final.get("valueCount"), "queueCount": final.get("queueCount"),
                "gapReasons": final.get("gapReasons"), "finalStatePhase": final_state["phase"] if final_state else None,
                "finalProtectedPayloadRowCount": final_state["payloadRowCount"] if final_state else None}
            required = {"readerVersionObserved", "freshOwnerCreatedVault", "genuineSourceCollectedExactlySevenAppearancesFiveTypes",
                "baselinePendingNotificationReceiptEstablished",
                "twoDistinctReviewsAndStoreReceiptSaved", "reviewWorkerExitedWithExactStoredState",
                "fullReviewAndDeliveryValuesSurviveColdRestart", "fullReviewAndDeliveryValuesSurviveExactSourceReplay",
                "revokedMarkerRetainedAndAllProtectedPayloadRowsRemoved", "removedLocationsKeepOriginalAnalysisReceiptsAndLabels",
                "removalWorkerExitedWithExactStoredState", "fullObsoleteAndRemovalValuesSurviveColdRestart",
                "exactSourceReplayCannotResurrectContentOrAlerts", "threeDistinctSignedWorkersExitedNormally",
                "finalQueueEmptyWithoutGaps", "creatorCleanupAuthorizedOnlyAfterNormalWorkerShutdown",
                "originalFreshCreatorCleanupPassed", "ownedProcessGroupsStopped", "noAppDiagnosticsOrOutput",
                "encryptedMarkerInspectionPassed", "sourceSelectionAndAllProofBytesUnchanged", "readerExecutableUnchanged",
                "candidateAndProductionInputsUnchanged"}
            report["passed"] = "unmetGate" not in report and required <= checks.keys() and all(checks.values())
            report["signedRetainedInventoryStateRestartAndReplayEstablished"] = report["passed"]
    return 0 if artifacts.passed else 1


def main(argv=None):
    try:
        return run(arguments(argv))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError):
        print(json.dumps({"schemaVersion": 1, "passed": False, "status": "preflight-rejected", "signedAppLaunched": False}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
