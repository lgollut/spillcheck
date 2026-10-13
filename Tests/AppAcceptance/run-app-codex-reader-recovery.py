#!/usr/bin/env python3
"""Signed transient reader recovery for one exact, previously owned fake T3 source."""
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import time
import uuid

spec = importlib.util.spec_from_file_location("codex_restart_helpers", Path(__file__).with_name("run-app-codex-recovery.py"))
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
ROOT = shared.ROOT
require = shared.require
GateFailure = shared.GateFailure
EXPECTED_COUNTS = {"userPrompt": 3, "intermediateResponse": 1, "finalResponse": 1, "toolOutput": 1, "toolError": 1}


def worker_command(binary, root, *, selection, reader, version, host):
    return shared.command(binary, root, "worker1", selection=selection, reader=reader, version=version, host=host, active=False)


def owned_directory(path):
    require(path == path.resolve(strict=True), "owned-directory-alias")
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == 0o700, "owned-directory-required")


def database_identity(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == 0o600 and info.st_nlink == 1
            and info.st_size <= 64 * 1024 * 1024, "private-queue-database-required")
    return info.st_dev, info.st_ino


def metadata_authorizer(action, first, second, database, trigger):
    if trigger is not None or database not in (None, "main"):
        return sqlite3.SQLITE_DENY
    if action == sqlite3.SQLITE_SELECT:
        return sqlite3.SQLITE_OK
    if action == sqlite3.SQLITE_READ and (first, second) in {
            ("captures", "id"), ("captures", "retry_count"), ("captures", "state"),
            ("capture_receipts", "id")}:
        return sqlite3.SQLITE_OK
    if action == sqlite3.SQLITE_TRANSACTION and first in ("BEGIN", "ROLLBACK"):
        return sqlite3.SQLITE_OK
    if action == sqlite3.SQLITE_FUNCTION and second == "count":
        return sqlite3.SQLITE_OK
    return sqlite3.SQLITE_DENY


def queue_metadata(store, consumed_id=None):
    """Read only queue IDs/retry counters/state and one receipt's existence; never payloads."""
    owned_directory(store)
    database = store / "leakret.sqlite"
    identity = database_identity(database)
    for suffix in ("-wal", "-shm"):
        path = Path(str(database) + suffix)
        if path.exists() or path.is_symlink():
            database_identity(path)
    # With a live WAL, require the writer-created SHM so this reader creates no sidecar.
    require(not Path(str(database) + "-wal").exists() or Path(str(database) + "-shm").exists(), "writer-shm-required")
    connection = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=0.05)
    try:
        connection.execute("PRAGMA query_only=ON")
        connection.execute("PRAGMA trusted_schema=OFF")
        connection.set_authorizer(metadata_authorizer)
        deadline = time.monotonic() + 0.25
        connection.set_progress_handler(lambda: int(time.monotonic() >= deadline), 100)
        connection.execute("BEGIN")
        rows = connection.execute("SELECT id, retry_count, state FROM captures LIMIT 2").fetchall()
        require(len(rows) <= 1, "single-capture-required")
        for identifier, retries, state in rows:
            require(isinstance(identifier, str) and len(identifier) == 36
                    and str(uuid.UUID(identifier)).lower() == identifier.lower()
                    and type(retries) is int and 0 <= retries <= 3
                    and type(state) is int and state in (0, 1), "queue-metadata-shape")
        consumed = False
        if consumed_id is not None:
            require(isinstance(consumed_id, str) and len(consumed_id) == 36, "capture-identity-shape")
            count = connection.execute("SELECT COUNT(*) FROM capture_receipts WHERE id = ?", (consumed_id,)).fetchone()[0]
            require(type(count) is int and count in (0, 1), "receipt-count-shape")
            consumed = count == 1
        connection.rollback()
        require(database_identity(database) == identity, "queue-database-replaced")
        return {"rows": rows, "consumed": consumed}
    finally:
        connection.close()


def empty_ready(report):
    return (report.get("storageReady") is True and report.get("collectionConfigured") is True
            and report.get("recoveryLoadedExistingManifest") is True and shared.manifest_digest(report) is not None
            and report.get("recoveryCaptureIdentityMeasurementAvailable") is True
            and all(shared.exact_int(report.get(key), 0) for key in ("queueCount", "valueCount", "occurrenceCount"))
            and report.get("gapReasons") == [] and report.get("coverageReportTruncated") is False
            and all(shared.digest_set(report, key, empty=True) == set() for key in
                    (*shared.DIGEST_KEYS, "recoveryPendingCaptureDigests", "recoveryConsumedCaptureDigests",
                     "recoverySuccessfullyProcessedCaptureDigests")))


def failed_pending(report, baseline, metadata):
    pending = shared.digest_set(report, "recoveryPendingCaptureDigests")
    rows = metadata["rows"]
    return (len(rows) == 1 and type(rows[0][1]) is int and 1 <= rows[0][1] <= 2
            and type(rows[0][2]) is int and rows[0][2] == 0
            and report.get("recoveryCaptureIdentityMeasurementAvailable") is True
            and shared.exact_int(report.get("queueCount"), 1)
            and shared.exact_int(report.get("recoveryQueueClaimedCount"), 0)
            and type(report.get("recoveryEncryptedQueueBytes")) is int and report["recoveryEncryptedQueueBytes"] > 0
            and pending is not None and len(pending) == 1
            and shared.manifest_digest(baseline) is not None
            and shared.manifest_digest(report) == shared.manifest_digest(baseline)
            and all(shared.exact_int(report.get(key), 0) for key in ("valueCount", "occurrenceCount"))
            and report.get("gapReasons") == [] and report.get("coverageReportTruncated") is False
            and all(shared.digest_set(report, key, empty=True) == set() for key in
                    (*shared.DIGEST_KEYS, "recoveryConsumedCaptureDigests", "recoverySuccessfullyProcessedCaptureDigests")))


def wait_failed_capture(worker, root, baseline, missing_reader, timeout=6):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        worker.pump()
        require(worker.process.poll() is None, "reader-fault-worker-exited")
        require(not missing_reader.exists() and not missing_reader.is_symlink(), "reader-restored-before-failure-proof")
        try:
            before = queue_metadata(root / "protected-store")
            report = shared.private_json(root / "worker1-report.json")
            after = queue_metadata(root / "protected-store")
        except sqlite3.OperationalError as error:
            # Apple's Python 3.9 lacks sqlite_errorcode and SQLITE_BUSY constants.
            code = getattr(error, "sqlite_errorcode", None)
            busy = type(code) is int and (code & 255) in (5, 6)
            if not busy and str(error) not in ("database is locked", "database table is locked"):
                raise
            time.sleep(0.025)
            continue
        if before["rows"] and after["rows"] and before["rows"][0][0] == after["rows"][0][0] and failed_pending(report, baseline, after):
            return report, after["rows"][0][0], after["rows"][0][1]
        time.sleep(0.025)
    raise GateFailure("reader-retry-not-witnessed-before-restoration-deadline")


def restore_owned_reader(root, path, reader):
    owned_directory(root)
    require(path == root / "reader" and not path.exists() and not path.is_symlink(), "fresh-owned-reader-path-required")
    require(reader == reader.resolve(strict=True) and reader.is_file() and os.access(reader, os.X_OK), "real-reader-required")
    # symlink is exclusive and atomic. Never replace an existing path or mutate its target.
    os.symlink(str(reader), path)
    require(path.is_symlink() and os.readlink(path) == str(reader), "owned-reader-restore-failed")


def repeated_processing(before, after):
    old = shared.digest_set(before, "recoverySuccessfullyProcessedCaptureDigests")
    new = shared.digest_set(after, "recoverySuccessfullyProcessedCaptureDigests")
    return (old is not None and new is not None and old < new
            and shared.inventory_unchanged(before, after)
            and shared.exact_int(after.get("queueCount"), 0)
            and after.get("gapReasons") == [] and after.get("coverageReportTruncated") is False)


def deliver(helper, root, payload, lifecycle):
    cleanup = {}
    lifecycle["stopped"] = False
    try:
        code, output, _ = shared.live.bounded([str(helper), "--socket", str(root / "protected-store/capture.sock"),
            "--agent", "codex", "--interface", "t3", "--profile-id", shared.PROFILE],
            environment=dict(os.environ), directory=ROOT, input_bytes=payload, timeout=5, maximum_bytes=1024, cleanup_report=cleanup)
    finally:
        lifecycle["stopped"] = cleanup.get("leaderExited") is True and not cleanup.get("groupKillPermissionDenied", False)
    require(code == 0 and output.strip() == b"{}" and lifecycle["stopped"], "helper-lifetime-unconfirmed")


def run(args):
    os.umask(0o077)
    source = args.source_directory.absolute()
    owned_directory(source)
    require(not args.output.exists() and not args.output.is_symlink()
            and not args.private_control.exists() and not args.private_control.is_symlink()
            and args.output.absolute() != args.private_control.absolute(), "new-report-paths-required")
    binding = shared.load_bound_selection(args)
    selection = binding["selection"]
    require(selection["counts"] == EXPECTED_COUNTS, "exact-seven-appearance-fixture-required")
    require(selection["home"] == selection["home"].resolve(strict=True) and selection["home"].is_dir(), "canonical-original-home-required")
    app = args.app.resolve(strict=True)
    manifest = binding["manifest"]
    require(shared.preflight.check(manifest, app, ROOT)["consistent"], "frozen-candidate-required")
    binary, helper = app / "Contents/MacOS/Spillcheck", app / "Contents/Helpers/spillcheck-hook"
    reader = args.executable.resolve(strict=True)
    reader_hash = shared.preflight.hash_file(reader.parent, reader.name, [0])
    with shared.AcceptanceArtifacts("spillcheck-cx-reader-", args.output) as artifacts:
        root = artifacts.directory
        token = os.urandom(32)
        shared.write_new(root / "run-token", token)
        shared.write_json(root / "candidate-build.json", manifest)
        args.private_control.parent.mkdir(parents=True, exist_ok=True)
        shared.write_json(args.private_control, {"schemaVersion": 1, "ownedArtifactDirectory": str(root),
            "reportPath": str(args.output.absolute()), "candidateBundleSHA256": args.expected_bundle_sha256,
            "sourceDirectory": str(source), "runTokenPath": str(root / "run-token"),
            "candidateBaselineDirectory": str(binding["baseline_directory"]) if binding["baseline_directory"] else None,
            "cleanupOwnerReport": str(root / "owner-report.json"),
            "cleanupAuthority": "original-fresh-vault-owner-only",
            "protectionCleanupReportField": "ownedProtectionCleanupPending",
            "cleanupPendingIncludesRetainedFailureArtifacts": True,
            "loadedWorkersMayDeleteKeys": False})
        report = {"schemaVersion": 1, "scope": "signed-T3-exact-source-transient-reader-recovery",
            "candidateBundleSHA256": args.expected_bundle_sha256, "hostVersion": args.host_version,
            "readerVersion": args.expected_reader_version, "producerVersion": args.expected_producer_version,
            "selectedThreadCount": 1, "expectedOccurrencesByContentType": EXPECTED_COUNTS,
            "syntheticQueueAdmission": True, "providerHookDispatchEstablished": False,
            "providerSessionsCreated": 0, "providerConfigurationChanged": False, "sourceEnumerationPerformed": False,
            "durableOmissionClearingEstablished": False, "crashRecoveryEstablished": False,
            "upgradeRecoveryEstablished": False, "fullT3Acceptance": False, "sourceOpeningEstablished": False,
            "nativeChildCoverageEstablished": False, "signedIndividualMarkerReceiptsVerified": False,
            "signedLiveProviderCollectionEstablished": False, "checks": {}, "passed": False,
            **shared.evidence_lineage(binding)}
        artifacts.report = report
        checks = report["checks"]
        owner = worker = None
        helper_lifecycle = {"stopped": True}
        final = {}
        missing_reader = root / "reader"
        phase = "reader-version"
        try:
            version = shared.live.observe_version(reader, environment=dict(os.environ, CODEX_HOME=str(selection["home"])),
                directory=root, expected=args.expected_reader_version)
            checks["readerVersionObserved"] = version == args.expected_reader_version
            phase = "fresh-vault-owner"
            owner = shared.OwnedProcess(shared.command(binary, root, "owner"))
            owner.wait_report(root / "owner-report.json", lambda value: value.get("ownerReady") is True
                and value.get("createdFreshVault") is True, "fresh-owner-unavailable")
            checks["freshOwnerCreatedVault"] = True
            phase = "missing-reader-worker"
            worker = shared.OwnedProcess(worker_command(binary, root, selection=selection, reader=missing_reader,
                version=version, host=args.host_version))
            baseline = worker.wait_report(root / "worker1-report.json", empty_ready, "empty-worker-not-ready")
            require(queue_metadata(root / "protected-store")["rows"] == [], "unexpected-initial-capture")
            payload = json.dumps({"hook_event_name": "SpillcheckHistoryPoll", "session_id": selection["native"]}).encode()
            phase = "synthetic-poll-failure"
            deliver(helper, root, payload, helper_lifecycle)
            failed, capture_id, retry_count = wait_failed_capture(worker, root, baseline, missing_reader)
            shared.write_json(root / "failed-private-report.json", failed)
            checks["exactSingletonCaptureRetriedWithReaderAbsent"] = True
            report["observedRetryCountBeforeRestore"] = retry_count
            phase = "reader-restoration"
            require(owner.process.poll() is None, "fresh-owner-lost")
            restore_owned_reader(root, missing_reader, reader)
            checks["ownedReaderPathRestoredWithoutTargetChange"] = True
            recovered = worker.wait_report(root / "worker1-report.json", lambda value:
                shared.collected(value, EXPECTED_COUNTS, args.expected_producer_version)
                and shared.pending_recovered(failed, value), "same-capture-not-recovered", timeout=35)
            require(queue_metadata(root / "protected-store", capture_id)["consumed"], "failed-capture-receipt-absent")
            checks["exactFailedCaptureConsumedAndSuccessfullyProcessed"] = True
            checks["sameVaultManifestLoaded"] = shared.manifest_digest(baseline) == shared.manifest_digest(recovered)
            checks["sevenAppearancesFiveTypesOneSession"] = True
            phase = "repeat-delivery"
            deliver(helper, root, payload, helper_lifecycle)
            # The helper deliberately returns {} on failure too. Additional successful
            # native-poll completions, not this output, establish actual repeated processing.
            repeated = worker.wait_report(root / "worker1-report.json", lambda value:
                shared.collected(value, EXPECTED_COUNTS, args.expected_producer_version)
                and shared.pending_recovered(failed, value) and repeated_processing(recovered, value),
                "repeated-processing-not-observed", timeout=20)
            checks["laterSuccessfulProcessingPreservesOccurrencesReceiptsAlerts"] = True
            shared.write_new(root / "worker1-finish", b"finished\n")
            worker.wait_exit()
            final = shared.private_json(root / "worker1-report.json")
            require(shared.collected(final, EXPECTED_COUNTS, args.expected_producer_version)
                    and shared.pending_recovered(failed, final) and shared.inventory_unchanged(repeated, final)
                    and final.get("acceptancePhase") == "shutdown-complete", "final-state-changed")
            checks["finalQueueEmptyWithoutGaps"] = True
        except (OSError, ValueError, KeyError, TypeError, RuntimeError, TimeoutError, BufferError, sqlite3.Error, subprocess.SubprocessError) as error:
            report.update(unmetGate=error.gate if isinstance(error, GateFailure) else phase, failureCategory="controlled-run-failure")
        finally:
            shutdowns, groups = [], []
            if worker is not None:
                if worker.process.poll() is None:
                    try:
                        if not (root / "worker1-finish").exists():
                            shared.write_new(root / "worker1-finish", b"finished\n")
                        worker.wait_exit()
                    except (OSError, RuntimeError):
                        pass
                group_stopped = False
                try:
                    stopped = worker.stop()
                    groups.append(stopped)
                    group_stopped = worker.process.poll() is not None and stopped.get("term_permission_denied") is False and stopped.get("kill_permission_denied") is False
                except (OSError, RuntimeError):
                    pass
                shutdown = {}
                try:
                    shutdown = shared.private_json(root / "worker1-report.json")
                except (OSError, ValueError, RuntimeError):
                    pass
                shutdowns.append({"exitCode": worker.process.poll(), "shutdownPhase": shutdown.get("acceptancePhase"), "groupStopped": group_stopped})
            authorized = shared.safe_creator_cleanup(shutdowns, helper_stopped=helper_lifecycle["stopped"],
                socket_absent=not (root / "protected-store/capture.sock").exists())
            if owner is not None and authorized and owner.process.poll() is None:
                try:
                    shared.write_new(root / "owner-finish", token)
                    owner.wait_exit()
                except (OSError, RuntimeError):
                    pass
            owner_report = {}
            try:
                owner_report = shared.private_json(root / "owner-report.json")
            except (OSError, ValueError, RuntimeError):
                pass
            if owner is not None:
                try:
                    groups.append(owner.stop())
                except (OSError, RuntimeError):
                    checks["ownerGroupStopFailed"] = False
            checks["creatorCleanupAuthorizedOnlyAfterNormalShutdown"] = authorized
            checks["originalFreshCreatorCleanupPassed"] = owner_report.get("createdFreshVault") is True and owner_report.get("cleanupPassed") is True
            report["ownedProtectionCleanupPending"] = owner is not None and owner_report.get("cleanupPassed") is not True
            checks["ownedProcessGroupsStopped"] = helper_lifecycle["stopped"] and bool(groups) and all(
                value.get("term_permission_denied") is False and value.get("kill_permission_denied") is False for value in groups)
            checks["noAppDiagnosticsOrOutput"] = all(not any(value.counts.values()) for value in (owner, worker) if value is not None)
            try:
                checks["encryptedMarkerInspectionPassed"] = shared.marker_free(root / "protected-store")
                checks["sourceSelectionAndProofsUnchanged"] = shared.bound_evidence_unchanged(binding)
                checks["readerExecutableUnchanged"] = shared.preflight.hash_file(reader.parent, reader.name, [0]) == reader_hash
                checks["candidateAndProductionInputsUnchanged"] = shared.preflight.check(manifest, app, ROOT)["consistent"]
                if missing_reader.is_symlink():
                    require(os.readlink(missing_reader) == str(reader), "owned-reader-link-changed")
                    missing_reader.unlink()
                checks["ownedReaderLinkRemoved"] = not missing_reader.exists() and not missing_reader.is_symlink()
            except (OSError, ValueError, RuntimeError):
                checks["finalBoundaryChecksPassed"] = False
            report["result"] = {"newVaultCleanupPassed": checks["originalFreshCreatorCleanupPassed"],
                "syntheticOccurrencesByContentType": final.get("syntheticOccurrencesByContentType", {}),
                "syntheticOccurrenceCount": final.get("syntheticOccurrenceCount", 0),
                "syntheticSessionCount": final.get("syntheticSessionCount", 0),
                "queueCount": final.get("queueCount"), "gapReasons": final.get("gapReasons", [])}
            required = {"readerVersionObserved", "freshOwnerCreatedVault", "exactSingletonCaptureRetriedWithReaderAbsent",
                "ownedReaderPathRestoredWithoutTargetChange", "exactFailedCaptureConsumedAndSuccessfullyProcessed",
                "sameVaultManifestLoaded", "sevenAppearancesFiveTypesOneSession",
                "laterSuccessfulProcessingPreservesOccurrencesReceiptsAlerts", "finalQueueEmptyWithoutGaps",
                "creatorCleanupAuthorizedOnlyAfterNormalShutdown", "originalFreshCreatorCleanupPassed", "ownedProcessGroupsStopped",
                "noAppDiagnosticsOrOutput", "encryptedMarkerInspectionPassed", "sourceSelectionAndProofsUnchanged",
                "readerExecutableUnchanged", "candidateAndProductionInputsUnchanged", "ownedReaderLinkRemoved"}
            report["passed"] = "unmetGate" not in report and required <= checks.keys() and all(checks.values())
            report["signedTransientReaderRecoveryEstablished"] = report["passed"]
    return 0 if artifacts.passed else 1


def main(argv=None):
    try:
        return run(shared.parse_arguments(argv))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, sqlite3.Error, subprocess.SubprocessError):
        print(json.dumps({"schemaVersion": 1, "passed": False, "status": "preflight-rejected", "signedAppLaunched": False}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
