#!/usr/bin/env python3
"""Signed constructed required-format isolation and durable health delivery receipt.

Only two owned fake sources are selected. An unknown required block stays in its
original row while its readable sibling and the healthy source commit. No provider,
profile discovery, authentication copy or hook configuration is involved. Masking
reuses the exact reviewed production contract; a delivery receipt is not an observed
macOS banner or notification-text readback. Parser-upgrade restoration is not tested.
"""
import argparse
import datetime
import json
import math
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import time
import uuid
import importlib.util

spec = importlib.util.spec_from_file_location("claude_required_health_restoration",
    Path(__file__).with_name("run-app-claude-source-restoration.py"))
restoration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(restoration)
shared, setup, inventory, lifecycle = restoration.shared, restoration.setup, restoration.inventory, restoration.lifecycle
claude, require, ROOT, VERSION = restoration.claude, restoration.require, restoration.ROOT, restoration.VERSION
from Support.claude_native_evidence import _directory

PROFILE = "owned-claude-required-format-health"
MASKED_SOURCES = {
    "Sources/SpillcheckCore/NotificationContracts.swift": "56782f3222e4695157c51efd336df28213930abd6a2d0ab569cb468918a0e16d",
    "Spillcheck/App/NotificationController.swift": "6a77454fe676483f13a617b40878faa31d5a44664602fe43077ede27dff6dd05"}
CHECKS = {"candidateBeforePassed", "reviewedMaskedProductionContractUnchanged", "freshOwnerCreatedVault",
    "initialHealthInventoryEmpty", "emptySelectedCollectorReady", "readableSiblingCommitsWithRequiredOmission",
    "healthySourceProgressPreservesOriginalOmission", "repeatedUnchangedSourcePollsPreserveInventoryAndOmission",
    "firstColdSnapshotHasOneDeliveredContentIncident", "coldRestartPreservesOriginalOmissionAndInventory",
    "healthyProgressAfterRestartPreservesOriginalOmission", "secondColdSnapshotPreservesSameDeliveredIncident",
    "twoDistinctWorkersExitedNormally", "preCleanupDiagnosticSnapshotPassed", "originalFreshCreatorCleanupPassed",
    "creatorCleanupAuthorizedOnlyAfterNormalWorkerShutdown", "ownedProcessGroupsStopped", "noAppDiagnosticsOrOutput",
    "originalSourcesContainOnlyExpectedAppendBytes", "candidateUnchanged", "encryptedMarkerInspectionPassed",
    "transportRejectionsRemainZero"}


def masking_contract(manifest_path, binding):
    before = claude.preflight.hash_file(manifest_path.parent, manifest_path.name, [0])
    require(isinstance(binding, dict) and binding.get("manifestSHA256") == before,
        "masking-manifest-not-candidate-bound")
    manifest = claude.preflight.read_manifest(manifest_path)
    after = claude.preflight.hash_file(manifest_path.parent, manifest_path.name, [0])
    require(before == after, "masking-manifest-changed")
    for relative, expected in MASKED_SOURCES.items():
        require(manifest.get("sourceSHA256", {}).get(relative) == expected
            and claude.preflight.hash_file(ROOT, relative, [0]) == expected,
            "reviewed-masked-notification-contract-changed")
    return dict(MASKED_SOURCES)


def append_fixture(root, source, label):
    require(label in ("AFFECTED_REQUIRED", "HEALTHY_INITIAL", "HEALTHY_PROGRESS", "HEALTHY_AFTER_RESTART"),
        "fixed-health-fixture-label-required")
    path = source["path"]
    require(restoration.signature(path) == source["signature"]
        and shared.private_bytes(path, 65536) == source["bytes"], "owned-source-changed-before-append")
    blocks = [{"type": "text", "text": "LEAKRET_REQUIRED_HEALTH_" + label + " " + shared.TOKEN.decode()}]
    if label == "AFFECTED_REQUIRED":
        require(not source["bytes"], "required-row-must-be-original-first-row")
        blocks.append({"type": "future_required_output", "text": "fake required content remains unsupported"})
    row = {"type": "user", "uuid": str(uuid.uuid4()), "sessionId": source["session"], "version": VERSION,
        "timestamp": (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=1)).isoformat(),
        "cwd": str(root / "project"), "isSidechain": False, "message": {"role": "user", "content": blocks}}
    data = json.dumps(row, separators=(",", ":")).encode() + b"\n"
    require(len(source["bytes"]) + len(data) <= 65536, "owned-source-budget")
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        require((info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns) == source["signature"],
            "owned-source-replaced-before-append")
        require(os.write(fd, data) == len(data), "owned-source-short-append")
        os.fsync(fd)
    finally:
        os.close(fd)
    source["bytes"] += data
    source["signature"] = restoration.signature(path)
    require(shared.private_bytes(path, 65536) == source["bytes"], "owned-source-append-not-exact")


def worker_command(binary, root, sources, name):
    require(name in ("worker1", "worker2"), "fixed-worker-required")
    command = shared.command(binary, root, name)[:-1] + ["--acceptance-recovery-worker",
        "--acceptance-no-profile-catchup", "--claude-profile", PROFILE, "--claude-version", VERSION,
        "--claude-source-root", str(root / "claude/projects/selected"),
        "--claude-interface", "standalone-cli", "--claude-authorized-host", "standalone-cli"]
    for name in ("affected", "healthy"):
        command += ["--claude-active-source", str(sources[name]["path"]), "--claude-session", sources[name]["session"]]
    return command


def omission(report):
    if (report.get("recoveryOmissionMeasurementAvailable") is not True
            or report.get("recoveryOmissionTruncated") is not False):
        return None
    rows = report.get("recoveryOmissionRecords")
    if (not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict)
            or set(rows[0]) != {"omissionDigest", "state", "reason"}
            or rows[0]["state"] != "blocked" or rows[0]["reason"] != "unsupportedContent"):
        return None
    digest = shared.digest_set({"value": [rows[0]["omissionDigest"]]}, "value")
    return next(iter(digest)) if digest is not None else None


def observed(report, count, sessions=2):
    return (restoration.ready(report) and report.get("notificationState") == "Allowed"
        and shared.exact_int(report.get("valueCount"), 1)
        and shared.exact_int(report.get("occurrenceCount"), count)
        and shared.exact_int(report.get("syntheticOccurrenceCount"), count)
        and shared.exact_int(report.get("syntheticSessionCount"), sessions)
        and report.get("syntheticValuePresent") is True
        and report.get("syntheticOccurrencesByContentType") == {"userPrompt": count}
        and type(report["syntheticOccurrencesByContentType"]["userPrompt"]) is int
        and report.get("observedAgentVersions") == [VERSION]
        and report.get("gapReasons") == ["unsupportedContent"]
        and report.get("gapCountsByOperation") == {"liveRead": {"unsupportedContent": 1}}
        and type(report["gapCountsByOperation"]["liveRead"]["unsupportedContent"]) is int
        and shared.exact_int(report.get("scopedGapCount"), 1) and omission(report) is not None
        and all(shared.digest_set(report, key, empty=key == "recoveryAlertDigests") is not None for key in shared.DIGEST_KEYS))


def stable(before, after, count):
    return (observed(before, count) and observed(after, count)
        and shared.manifest_digest(before) == shared.manifest_digest(after)
        and omission(before) == omission(after) and shared.inventory_unchanged(before, after)
        and restoration.same_alerts(before, after))


def growth(before, after, count):
    if (not observed(before, count) or not observed(after, count + 1)
            or shared.manifest_digest(before) != shared.manifest_digest(after)
            or omission(before) != omission(after) or not restoration.same_alerts(before, after)):
        return False
    for key in ("recoveryOccurrenceDigests", "recoveryReceiptDigests"):
        previous, current = shared.digest_set(before, key), shared.digest_set(after, key)
        if previous is None or current is None or len(previous) != count or len(current) != count + 1 or not previous < current:
            return False
    return True


def deliver_poll(helper, root, source, helper_lifetime):
    payload = json.dumps({"hook_event_name": "SpillcheckTranscriptPoll", "session_id": source["session"],
        "transcript_path": str(source["path"]), "cwd": str(root / "project")}, separators=(",", ":")).encode()
    cleanup = {}
    helper_lifetime["stopped"] = False
    try:
        code, output, _ = shared.live.bounded([str(helper), "--socket", str(root / "protected-store/capture.sock"),
            "--agent", "claude-code", "--interface", "standalone-cli", "--profile-id", PROFILE],
            environment={"PATH": "/usr/bin:/bin", "LANG": "C"}, directory=ROOT,
            input_bytes=payload, timeout=5, maximum_bytes=1024, cleanup_report=cleanup)
    finally:
        helper_lifetime["stopped"] = cleanup.get("leaderExited") is True and cleanup.get("groupKillPermissionDenied") is False
    require(code == 0 and output.strip() == b"{}" and helper_lifetime["stopped"], "helper-lifetime-unconfirmed")


def repeat_polls(worker, helper, root, source, name, baseline, count, helper_lifetime):
    current = baseline
    for _ in range(2):
        before = current
        deliver_poll(helper, root, source, helper_lifetime)
        current = worker.wait_report(root / (name + "-report.json"), lambda value:
            stable(before, value, count) and restoration.new_processed_read(before, value),
            "unchanged-source-poll-did-not-complete-stably")
    return current


def quiet_window(worker, root, name, baseline, count):
    # Allow ordinary notification submission to settle, without treating time as a
    # delivery witness. Only the subsequent cold receipt can establish delivery.
    end = time.monotonic() + 3
    while time.monotonic() < end:
        worker.pump()
        require(worker.process.poll() is None, "worker-lost-before-health-settlement")
        current = shared.private_json(root / (name + "-report.json"))
        require(stable(baseline, current, count), "health-settlement-state-changed")
        time.sleep(0.05)


def metadata_authorizer(action, first, second, database, trigger):
    if trigger is not None or database not in (None, "main"):
        return sqlite3.SQLITE_DENY
    if action == sqlite3.SQLITE_SELECT:
        return sqlite3.SQLITE_OK
    if action == sqlite3.SQLITE_READ and first == "collection_health_incidents" and second in {
            "id", "resolved_at", "delivery", "requires_assessment"}:
        return sqlite3.SQLITE_OK
    return sqlite3.SQLITE_DENY


def health_metadata(root, cold_report):
    """Pin a closed, checkpointed owned DB; never read encoded records or live WAL.

    The caller owns this newly-created root and passes only fresh-owner readiness
    or a normally exited worker's final report. No external store path is accepted
    by the CLI. SQLite receives the open FD, not the replaceable original pathname.
    """
    require((cold_report.get("ownerReady") is True and cold_report.get("createdFreshVault") is True)
        or cold_report.get("acceptancePhase") == "shutdown-complete", "cold-store-report-required")
    store = root / "protected-store"
    require(not (store / "capture.sock").exists() and not (store / "capture.sock").is_symlink(),
        "closed-store-socket-required")
    directory = _directory(store)
    fd = None
    identity = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    try:
        require(stat.S_IMODE(os.fstat(directory).st_mode) == 0o700, "owned-private-store-required")
        for suffix in ("-wal", "-shm", "-journal"):
            try:
                info = os.stat("leakret.sqlite" + suffix, dir_fd=directory, follow_symlinks=False)
            except FileNotFoundError:
                continue
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o600 and info.st_nlink == 1,
                "unsafe-database-sidecar")
            require(suffix == "-shm" or info.st_size == 0, "checkpointed-main-database-required")
        fd = os.open("leakret.sqlite", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
            and stat.S_IMODE(before.st_mode) == 0o600 and before.st_nlink == 1
            and before.st_size <= 64 * 1024 * 1024, "private-health-database-required")
        connection = sqlite3.connect(f"file:/dev/fd/{fd}?mode=ro&immutable=1", uri=True, timeout=0.05)
        try:
            connection.execute("PRAGMA query_only=ON")
            connection.execute("PRAGMA trusted_schema=OFF")
            connection.set_authorizer(metadata_authorizer)
            deadline = time.monotonic() + 0.25
            connection.set_progress_handler(lambda: int(time.monotonic() >= deadline), 100)
            rows = connection.execute("SELECT id, resolved_at, delivery, requires_assessment FROM collection_health_incidents LIMIT 2").fetchall()
        finally:
            connection.close()
        require(len(rows) <= 1, "at-most-one-health-incident-required")
        for identifier, resolved, delivery, assessment in rows:
            require(isinstance(identifier, str) and len(identifier) == 36
                and str(uuid.UUID(identifier)).lower() == identifier.lower()
                and (resolved is None or type(resolved) in (int, float) and math.isfinite(resolved))
                and delivery in ("pending", "delivered", "permissionDenied", "cancelled")
                and type(assessment) is int and assessment in (0, 1), "health-metadata-shape")
        require(identity(before) == identity(os.fstat(fd))
            and identity(before) == identity(os.stat("leakret.sqlite", dir_fd=directory, follow_symlinks=False)),
            "health-database-changed")
        current = _directory(store)
        try:
            require((os.fstat(current).st_dev, os.fstat(current).st_ino) ==
                (os.fstat(directory).st_dev, os.fstat(directory).st_ino), "health-store-directory-changed")
        finally:
            os.close(current)
        return rows
    finally:
        if fd is not None:
            os.close(fd)
        os.close(directory)


def delivered_content_incident(rows):
    return len(rows) == 1 and rows[0][1:] == (None, "delivered", 0)


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--private-control", required=True, type=Path)
    claude.candidate_arguments(parser)
    args = parser.parse_args(argv)
    claude.candidate_admission(parser, args)
    if args.candidate_manifest is None:
        parser.error("constructed signed regression requires a candidate manifest and expected bundle digest")
    return args


def run(args):
    os.umask(0o077)
    require(args.candidate_manifest is not None and args.expected_bundle_sha256 is not None, "candidate-required")
    require(not args.output.exists() and not args.output.is_symlink()
        and not args.private_control.exists() and not args.private_control.is_symlink()
        and args.output.absolute() != args.private_control.absolute(), "fresh-report-paths-required")
    require(args.private_control.parent.is_dir()
        and args.private_control.parent.resolve() == args.private_control.absolute().parent, "private-control-parent-required")
    app = args.app.resolve(strict=True)
    binding = claude.candidate_snapshot(args.candidate_manifest, args.expected_bundle_sha256, app)
    masking = masking_contract(args.candidate_manifest, binding)
    require(subprocess.run(["/usr/bin/pgrep", "-x", "Spillcheck"], capture_output=True).returncode == 1,
        "existing-app-or-process-inventory-unavailable")
    with shared.AcceptanceArtifacts("spillcheck-claude-required-health-", args.output,
            diagnostic_journal_factory=restoration.ClaudeRecoveryJournal) as artifacts:
        root, token = artifacts.directory, os.urandom(32)
        shared.write_new(root / "run-token", token)
        sources = restoration.create_sources(root)
        shared.write_json(args.private_control, {"schemaVersion": 1, "ownedArtifactDirectory": str(root),
            "persistentDiagnostics": str(artifacts.diagnostic_journal.directory),
            "ownerProcessHandoff": str(root / "owner-process-private.json"),
            "retainedOwnerHandoff": str(root / "owner-retained-private.json"),
            "runTokenPath": str(root / "run-token"), "cleanupOwnerReport": str(root / "owner-report.json"),
            "cleanupAuthority": "original-fresh-vault-owner-only", "loadedWorkersMayDeleteKeys": False})
        checks = {"candidateBeforePassed": binding is not None, "reviewedMaskedProductionContractUnchanged": masking == MASKED_SOURCES}
        report = {"schemaVersion": 1, "scope": "signed-constructed-Claude-required-format-isolation-and-health-receipt",
            "candidateBinding": binding, "fixtureProducerVersion": VERSION, "fixtureIsConstructed": True,
            "providerLaunched": False, "authenticationCopied": False, "hooksModified": False,
            "hostAcceptanceEstablished": False, "sourceEnumerationPerformed": False, "selectedNativeSources": 2,
            "explicitActiveSourcesPrimed": False, "syntheticExactSourcePolls": 0,
            "maskedNotificationContractEvidence": "unchanged-reviewed-production-sources-and-existing-core-tests",
            "maskedNotificationSourceSHA256": masking, "notificationTextReadbackEstablished": False,
            "notificationBannerAcceptanceEstablished": False, "nativeHealthDeliveryReceiptEstablished": False,
            "signedRequiredFormatRestorationEstablished": False, "parserUpgradeRecoveryEstablished": False,
            "checks": checks, "passed": False}
        artifacts.report = report
        owner, workers, final = None, [], {}
        owner_ready, phase = False, "fresh-vault-owner"
        helper_lifetime = {"stopped": True}
        try:
            binary, helper = app / "Contents/MacOS/Spillcheck", app / "Contents/Helpers/spillcheck-hook"
            owner = setup.ReportProcess(shared.command(binary, root, "owner"))
            lifecycle.process_handoff(root, "owner-process-private.json", owner.process, "original-fresh-vault-owner")
            owner_ready_report = owner.wait_report(root / "owner-report.json", lambda value:
                value.get("ownerReady") is True and value.get("createdFreshVault") is True, "fresh-owner-unavailable")
            owner_ready = True; checks["freshOwnerCreatedVault"] = True
            artifacts.diagnostic_journal.require_manifest()
            require(health_metadata(root, owner_ready_report) == [], "initial-health-inventory-not-empty")
            checks["initialHealthInventoryEmpty"] = True
            phase = "required-format-first-worker"
            require(owner.process.poll() is None, "fresh-owner-lost")
            worker = setup.ReportProcess(worker_command(binary, root, sources, "worker1")); workers.append(worker)
            report["explicitActiveSourcesPrimed"] = True
            lifecycle.process_handoff(root, "worker1-process-private.json", worker.process, "loaded-vault-worker")
            baseline = worker.wait_report(root / "worker1-report.json", restoration.empty_ready, "empty-collector-unavailable")
            require(baseline.get("notificationState") == "Allowed", "notifications-not-allowed")
            checks["emptySelectedCollectorReady"] = True
            append_fixture(root, sources["affected"], "AFFECTED_REQUIRED")
            affected = worker.wait_report(root / "worker1-report.json", lambda value: observed(value, 1, 1),
                "readable-sibling-and-required-omission-unavailable")
            checks["readableSiblingCommitsWithRequiredOmission"] = True
            append_fixture(root, sources["healthy"], "HEALTHY_INITIAL")
            two = worker.wait_report(root / "worker1-report.json", lambda value: observed(value, 2)
                and omission(value) == omission(affected), "healthy-initial-source-unavailable")
            append_fixture(root, sources["healthy"], "HEALTHY_PROGRESS")
            three = worker.wait_report(root / "worker1-report.json", lambda value: growth(two, value, 2),
                "healthy-progress-did-not-preserve-required-omission")
            checks["healthySourceProgressPreservesOriginalOmission"] = True
            repeated = repeat_polls(worker, helper, root, sources["affected"], "worker1", three, 3, helper_lifetime)
            report["syntheticExactSourcePolls"] += 2
            quiet_window(worker, root, "worker1", repeated, 3)
            first = inventory.finish_worker(worker, root, "worker1", lambda value: stable(repeated, value, 3))
            first_health = health_metadata(root, first)
            require(delivered_content_incident(first_health), "first-cold-delivered-health-incident-unverified")
            checks["firstColdSnapshotHasOneDeliveredContentIncident"] = True
            phase = "required-format-cold-restart"
            require(owner.process.poll() is None, "fresh-owner-lost")
            worker = setup.ReportProcess(worker_command(binary, root, sources, "worker2")); workers.append(worker)
            lifecycle.process_handoff(root, "worker2-process-private.json", worker.process, "loaded-vault-worker")
            cold = worker.wait_report(root / "worker2-report.json", lambda value: stable(first, value, 3),
                "cold-restart-did-not-preserve-original-omission")
            checks["coldRestartPreservesOriginalOmissionAndInventory"] = True
            repeated_cold = repeat_polls(worker, helper, root, sources["affected"], "worker2", cold, 3, helper_lifetime)
            report["syntheticExactSourcePolls"] += 2
            checks["repeatedUnchangedSourcePollsPreserveInventoryAndOmission"] = True
            append_fixture(root, sources["healthy"], "HEALTHY_AFTER_RESTART")
            four = worker.wait_report(root / "worker2-report.json", lambda value: growth(repeated_cold, value, 3),
                "healthy-progress-after-restart-did-not-preserve-omission")
            checks["healthyProgressAfterRestartPreservesOriginalOmission"] = True
            quiet_window(worker, root, "worker2", four, 4)
            final = inventory.finish_worker(worker, root, "worker2", lambda value: stable(four, value, 4))
            final_health = health_metadata(root, final)
            require(delivered_content_incident(final_health) and final_health == first_health,
                "health-incident-or-delivery-changed-across-restart")
            checks["secondColdSnapshotPreservesSameDeliveredIncident"] = True
            report["nativeHealthDeliveryReceiptEstablished"] = True
            checks["twoDistinctWorkersExitedNormally"] = len({p.process.pid for p in workers}) == 2 and all(p.process.poll() == 0 for p in workers)
            checks["transportRejectionsRemainZero"] = all(value.get("transportRejectionCountsByStageAndReason") == {}
                for value in (baseline, affected, two, three, repeated, first, cold, repeated_cold, four, final))
        except (OSError, ValueError, TypeError, KeyError, RuntimeError, sqlite3.Error, subprocess.SubprocessError) as error:
            report.update(unmetGate=error.gate if isinstance(error, shared.GateFailure) else phase,
                failureCategory="controlled-run-failure")
        finally:
            groups, shutdowns = inventory.cleanup_workers(workers, root)
            checks["preCleanupDiagnosticSnapshotPassed"] = artifacts.diagnostic_journal.snapshot(final=True)
            authorized = shared.safe_creator_cleanup(shutdowns, helper_stopped=helper_lifetime["stopped"],
                socket_absent=not (root / "protected-store/capture.sock").exists())
            owner_report, retained, owner_stopped, handoff_failed = inventory.finish_creator(owner, root, token,
                ready_observed=owner_ready, authorized=authorized, groups=groups)
            checks["creatorCleanupAuthorizedOnlyAfterNormalWorkerShutdown"] = authorized
            checks["originalFreshCreatorCleanupPassed"] = owner_report.get("createdFreshVault") is True and owner_report.get("cleanupPassed") is True
            checks["ownedProcessGroupsStopped"] = (not retained and owner_stopped and helper_lifetime["stopped"]
                and all(value["groupStopped"] for value in shutdowns) and bool(groups)
                and all(value.get("term_permission_denied") is False and value.get("kill_permission_denied") is False for value in groups))
            checks["noAppDiagnosticsOrOutput"] = all(not any(process.counts.values()) for process in workers + ([owner] if owner else []))
            report.update(originalCreatorRetainedForCleanup=retained, creatorRetentionHandoffWriteFailed=handoff_failed,
                ownedProtectionCleanupPending=owner is not None and owner_report.get("cleanupPassed") is not True)
            if setup.owner_failure_summary(owner_report):
                report["ownerFailureDiagnostic"] = setup.owner_failure_summary(owner_report)
            try:
                checks["originalSourcesContainOnlyExpectedAppendBytes"] = all(restoration.signature(source["path"]) == source["signature"]
                    and shared.private_bytes(source["path"], 65536) == source["bytes"] for source in sources.values())
                checks["candidateUnchanged"] = claude.candidate_snapshot(args.candidate_manifest, args.expected_bundle_sha256, app) == binding
                checks["encryptedMarkerInspectionPassed"] = shared.marker_free(root / "protected-store")
            except (OSError, ValueError, RuntimeError):
                checks["finalBoundaryChecksPassed"] = False
            report["result"] = {"newVaultCleanupPassed": checks["originalFreshCreatorCleanupPassed"],
                "finalOccurrenceCount": final.get("occurrenceCount"), "finalSessionCount": final.get("syntheticSessionCount"),
                "finalValueCount": final.get("valueCount"), "queueCount": final.get("queueCount"),
                "gapReasons": final.get("gapReasons"), "scopedGapCount": final.get("scopedGapCount"),
                "requiredOmissionIntentionallyUnchanged": omission(final) is not None,
                "singleDeliveredHealthIncidentPreserved": checks.get("secondColdSnapshotPreservesSameDeliveredIncident", False)}
            report["passed"] = "unmetGate" not in report and CHECKS <= checks.keys() and all(checks.values())
    return 0 if artifacts.passed else 1


def main(argv=None):
    try:
        return run(arguments(argv))
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, sqlite3.Error, subprocess.SubprocessError):
        print(json.dumps({"schemaVersion": 1, "passed": False, "status": "preflight-or-artifact-boundary-rejected",
            "signedAppLaunchStateUnconfirmed": True}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
