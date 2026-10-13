#!/usr/bin/env python3
"""Constructed signed regression: a missing selected Claude source returns unchanged.

Two exact owned active sources exercise the real monitor/scanner/store. No provider,
authentication, hook registration, personal source or profile discovery is used.
"""
import argparse
import datetime
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import uuid


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


inventory = module("claude_restoration_lifetime", "run-app-codex-inventory-state.py")
claude = module("claude_restoration_live", "run-app-claude-live.py")
shared, setup, lifecycle = inventory.shared, inventory.setup, inventory.lifecycle
ROOT, require = shared.ROOT, shared.require
from Support.acceptance_journal import ClaudeRecoveryJournal

PROFILE, VERSION = "owned-claude-source-restoration", "2.1.296"
CHECKS = {"candidateBeforePassed", "freshOwnerCreatedVault", "emptySelectedCollectorReady",
    "twoInitialPromptsCommitted", "affectedOriginalParkedUnchanged", "sourceUnavailableVisible",
    "healthySourceProgressDoesNotClearOtherWarning", "unchangedOriginalRestorationClearsWarning",
    "restorationAddsNoContentReceiptOrAlert", "freshAffectedAppendCommitsExactlyOnce",
    "normalSignedWorkerShutdown", "preCleanupDiagnosticSnapshotPassed", "originalFreshCreatorCleanupPassed",
    "creatorCleanupAuthorizedOnlyAfterNormalWorkerShutdown", "ownedProcessGroupsStopped",
    "noAppDiagnosticsOrOutput", "originalSourcesContainOnlyExpectedAppendBytes", "candidateUnchanged",
    "encryptedMarkerInspectionPassed", "transportRejectionsRemainZero"}


def create_sources(root):
    for relative in ("claude", "claude/projects", "claude/projects/selected", "claude/projects/parked", "project"):
        (root / relative).mkdir(mode=0o700)
    sources = {}
    for name in ("affected", "healthy"):
        session = str(uuid.uuid4())
        path = root / "claude/projects/selected" / (session + ".jsonl")
        shared.write_new(path, b"")
        sources[name] = {"path": path, "session": session, "bytes": b"", "signature": signature(path)}
    sources["affected"]["parked"] = root / "claude/projects/parked" / (sources["affected"]["session"] + ".jsonl")
    return sources


def signature(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
        and info.st_mode & 0o077 == 0 and info.st_nlink == 1, "owned-source-file-required")
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def append_prompt(root, source, label):
    require(label in ("AFFECTED_INITIAL", "HEALTHY_INITIAL", "HEALTHY_WHILE_MISSING", "AFFECTED_AFTER_RESTORE"),
        "fixed-prompt-required")
    path = source["path"]
    require(signature(path) == source["signature"] and shared.private_bytes(path, 65536) == source["bytes"],
        "owned-source-changed-before-append")
    row = {"type": "user", "uuid": str(uuid.uuid4()), "sessionId": source["session"], "version": VERSION,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(), "cwd": str(root / "project"),
        "isSidechain": False, "message": {"role": "user", "content": [
            {"type": "text", "text": "LEAKRET_RESTORATION_" + label + " " + shared.TOKEN.decode()}]}}
    data = json.dumps(row, separators=(",", ":")).encode() + b"\n"
    require(len(source["bytes"]) + len(data) <= 65536, "owned-source-budget")
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        opened = os.fstat(descriptor)
        require((opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns) == source["signature"],
            "owned-source-replaced-before-append")
        require(os.write(descriptor, data) == len(data), "owned-source-short-append")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    source["bytes"] += data
    source["signature"] = signature(path)
    require(shared.private_bytes(path, 65536) == source["bytes"], "owned-source-append-not-exact")


def move_original(source, *, restore=False):
    start, end = (source["parked"], source["path"]) if restore else (source["path"], source["parked"])
    require(signature(start) == source["signature"] and shared.private_bytes(start, 65536) == source["bytes"]
        and not end.exists() and not end.is_symlink(), "owned-source-rename-boundary")
    start.rename(end)
    for parent in (start.parent, end.parent):
        descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    require(signature(end) == source["signature"] and shared.private_bytes(end, 65536) == source["bytes"],
        "rename-did-not-preserve-original")


def worker_command(binary, root, sources):
    command = shared.command(binary, root, "worker1")[:-1] + ["--acceptance-recovery-worker",
        "--acceptance-no-profile-catchup", "--claude-profile", PROFILE, "--claude-version", VERSION,
        "--claude-source-root", str(root / "claude/projects/selected"),
        "--claude-interface", "standalone-cli", "--claude-authorized-host", "standalone-cli"]
    for name in ("affected", "healthy"):
        source = sources[name]
        command += ["--claude-active-source", str(source["path"]), "--claude-session", source["session"]]
    return command


def ready(report):
    return (report.get("storageReady") is True and report.get("collectionConfigured") is True
        and report.get("recoveryLoadedExistingManifest") is True
        and shared.manifest_digest(report) is not None and shared.empty_unclaimed_queue(report)
        and report.get("coverageReportTruncated") is False
        and report.get("transportRejectionCountsByStageAndReason") == {})


def empty_ready(report):
    return (ready(report) and report.get("gapReasons") == []
        and all(shared.exact_int(report.get(key), 0) for key in
            ("valueCount", "occurrenceCount", "alertCount", "syntheticOccurrenceCount", "syntheticSessionCount"))
        and report.get("syntheticValuePresent") is False
        and report.get("syntheticOccurrencesByContentType") == {}
        and all(shared.digest_set(report, key, empty=True) == set() for key in shared.DIGEST_KEYS))


def observed(report, occurrences, *, missing=False):
    return (ready(report) and shared.exact_int(report.get("valueCount"), 1)
        and shared.exact_int(report.get("occurrenceCount"), occurrences)
        and shared.exact_int(report.get("syntheticOccurrenceCount"), occurrences)
        and shared.exact_int(report.get("syntheticSessionCount"), 2)
        and report.get("syntheticValuePresent") is True
        and report.get("syntheticOccurrencesByContentType") == {"userPrompt": occurrences}
        and all(type(value) is int for value in report["syntheticOccurrencesByContentType"].values())
        and report.get("observedAgentVersions") == [VERSION]
        and report.get("gapReasons") == (["sourceUnavailable"] if missing else [])
        and all(shared.digest_set(report, key, empty=key == "recoveryAlertDigests") is not None for key in shared.DIGEST_KEYS))


def same_alerts(before, after):
    old = shared.digest_set(before, "recoveryAlertDigests", empty=True)
    return (old is not None and old == shared.digest_set(after, "recoveryAlertDigests", empty=True)
        and type(before.get("alertCount")) is int and type(after.get("alertCount")) is int
        and 0 <= before["alertCount"] <= 2 and before["alertCount"] == after["alertCount"])


def prompt_growth(before, after, before_occurrences, *, missing=False):
    if (not observed(before, before_occurrences, missing=missing)
            or not observed(after, before_occurrences + 1, missing=missing)
            or shared.manifest_digest(before) != shared.manifest_digest(after)
            or not same_alerts(before, after)):
        return False
    for key in ("recoveryOccurrenceDigests", "recoveryReceiptDigests"):
        old, current = shared.digest_set(before, key), shared.digest_set(after, key)
        if (old is None or current is None or len(old) != before_occurrences
                or len(current) != before_occurrences + 1 or not old < current):
            return False
    return True


def new_processed_read(before, after):
    old, current = [], []
    for key in ("recoveryConsumedCaptureDigests", "recoverySuccessfullyProcessedCaptureDigests"):
        old.append(shared.digest_set(before, key, empty=True))
        current.append(shared.digest_set(after, key, empty=True))
    return (all(value is not None for value in old + current)
        and all(left <= right for left, right in zip(old, current))
        and len(current[0] - old[0]) == 1 and current[0] - old[0] == current[1] - old[1])


def unchanged_restoration(before, after):
    return (observed(before, 3, missing=True) and observed(after, 3)
        and shared.inventory_unchanged(before, after) and same_alerts(before, after)
        and new_processed_read(before, after))


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
    require(subprocess.run(["/usr/bin/pgrep", "-x", "Spillcheck"], capture_output=True).returncode == 1,
        "existing-app-or-process-inventory-unavailable")
    with shared.AcceptanceArtifacts("spillcheck-claude-restoration-", args.output,
            diagnostic_journal_factory=ClaudeRecoveryJournal) as artifacts:
        root, token = artifacts.directory, os.urandom(32)
        shared.write_new(root / "run-token", token)
        sources = create_sources(root)
        shared.write_json(args.private_control, {"schemaVersion": 1, "ownedArtifactDirectory": str(root),
            "persistentDiagnostics": str(artifacts.diagnostic_journal.directory),
            "ownerProcessHandoff": str(root / "owner-process-private.json"),
            "retainedOwnerHandoff": str(root / "owner-retained-private.json"),
            "runTokenPath": str(root / "run-token"), "cleanupOwnerReport": str(root / "owner-report.json"),
            "cleanupAuthority": "original-fresh-vault-owner-only", "loadedWorkersMayDeleteKeys": False})
        checks = {"candidateBeforePassed": binding is not None}
        report = {"schemaVersion": 1, "scope": "signed-constructed-Claude-source-availability-restoration",
            "candidateBinding": binding, "fixtureProducerVersion": VERSION, "fixtureIsConstructed": True,
            "providerLaunched": False, "authenticationCopied": False, "hooksModified": False,
            "hostAcceptanceEstablished": False, "genuineProviderAcceptanceEstablished": False,
            "sourceEnumerationPerformed": False, "selectedNativeSources": 2, "explicitActiveSourcesPrimed": False,
            "notificationBannerAcceptanceEstablished": False, "checks": checks, "passed": False}
        artifacts.report = report
        owner, workers, final = None, [], {}
        owner_ready, phase = False, "fresh-vault-owner"
        try:
            binary = app / "Contents/MacOS/Spillcheck"
            owner = setup.ReportProcess(shared.command(binary, root, "owner"))
            lifecycle.process_handoff(root, "owner-process-private.json", owner.process, "original-fresh-vault-owner")
            owner.wait_report(root / "owner-report.json", lambda value: value.get("ownerReady") is True
                and value.get("createdFreshVault") is True, "fresh-owner-unavailable")
            owner_ready = True
            checks["freshOwnerCreatedVault"] = True
            artifacts.diagnostic_journal.require_manifest()
            phase = "selected-active-worker"
            require(owner.process.poll() is None, "fresh-owner-lost")
            worker = setup.ReportProcess(worker_command(binary, root, sources))
            workers.append(worker)
            lifecycle.process_handoff(root, "worker1-process-private.json", worker.process, "loaded-vault-worker")
            worker.wait_report(root / "worker1-report.json", empty_ready, "empty-collector-unavailable")
            checks["emptySelectedCollectorReady"] = True
            append_prompt(root, sources["affected"], "AFFECTED_INITIAL")
            append_prompt(root, sources["healthy"], "HEALTHY_INITIAL")
            baseline = worker.wait_report(root / "worker1-report.json", lambda value: observed(value, 2), "initial-two-prompts-unavailable")
            checks["twoInitialPromptsCommitted"] = True
            report["explicitActiveSourcesPrimed"] = True
            phase = "source-temporarily-unavailable"
            move_original(sources["affected"])
            checks["affectedOriginalParkedUnchanged"] = True
            missing = worker.wait_report(root / "worker1-report.json", lambda value: observed(value, 2, missing=True)
                and same_alerts(baseline, value), "availability-warning-unavailable")
            checks["sourceUnavailableVisible"] = True
            append_prompt(root, sources["healthy"], "HEALTHY_WHILE_MISSING")
            healthy = worker.wait_report(root / "worker1-report.json", lambda value: prompt_growth(missing, value, 2, missing=True),
                "healthy-progress-must-retain-other-warning")
            checks["healthySourceProgressDoesNotClearOtherWarning"] = True
            phase = "unchanged-original-restoration"
            move_original(sources["affected"], restore=True)
            restored = worker.wait_report(root / "worker1-report.json", lambda value: unchanged_restoration(healthy, value),
                "unchanged-restoration-unverified", timeout=30)
            checks["unchangedOriginalRestorationClearsWarning"] = True
            checks["restorationAddsNoContentReceiptOrAlert"] = True
            append_prompt(root, sources["affected"], "AFFECTED_AFTER_RESTORE")
            appended = worker.wait_report(root / "worker1-report.json", lambda value: prompt_growth(restored, value, 3),
                "restored-source-append-unverified")
            checks["freshAffectedAppendCommitsExactlyOnce"] = True
            final = inventory.finish_worker(worker, root, "worker1", lambda value: observed(value, 4)
                and shared.inventory_unchanged(appended, value) and same_alerts(appended, value))
            checks["normalSignedWorkerShutdown"] = True
            checks["transportRejectionsRemainZero"] = all(value.get("transportRejectionCountsByStageAndReason") == {}
                for value in (baseline, missing, healthy, restored, appended, final))
        except (OSError, ValueError, TypeError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
            report.update(unmetGate=error.gate if isinstance(error, shared.GateFailure) else phase,
                failureCategory="controlled-run-failure")
        finally:
            groups, shutdowns = inventory.cleanup_workers(workers, root)
            checks["preCleanupDiagnosticSnapshotPassed"] = artifacts.diagnostic_journal.snapshot(final=True)
            authorized = shared.safe_creator_cleanup(shutdowns, helper_stopped=True,
                socket_absent=not (root / "protected-store/capture.sock").exists())
            owner_report, retained, owner_stopped, handoff_failed = inventory.finish_creator(owner, root, token,
                ready_observed=owner_ready, authorized=authorized, groups=groups)
            checks["creatorCleanupAuthorizedOnlyAfterNormalWorkerShutdown"] = authorized
            checks["originalFreshCreatorCleanupPassed"] = (owner_report.get("createdFreshVault") is True
                and owner_report.get("cleanupPassed") is True)
            checks["ownedProcessGroupsStopped"] = (not retained and owner_stopped
                and all(value["groupStopped"] for value in shutdowns) and bool(groups)
                and all(value.get("term_permission_denied") is False and value.get("kill_permission_denied") is False for value in groups))
            checks["noAppDiagnosticsOrOutput"] = all(not any(process.counts.values()) for process in workers + ([owner] if owner else []))
            report.update(originalCreatorRetainedForCleanup=retained, creatorRetentionHandoffWriteFailed=handoff_failed,
                ownedProtectionCleanupPending=owner is not None and owner_report.get("cleanupPassed") is not True)
            if setup.owner_failure_summary(owner_report):
                report["ownerFailureDiagnostic"] = setup.owner_failure_summary(owner_report)
            try:
                checks["originalSourcesContainOnlyExpectedAppendBytes"] = all(signature(source["path"]) == source["signature"]
                    and shared.private_bytes(source["path"], 65536) == source["bytes"] for source in sources.values())
                checks["candidateUnchanged"] = claude.candidate_snapshot(args.candidate_manifest, args.expected_bundle_sha256, app) == binding
                checks["encryptedMarkerInspectionPassed"] = shared.marker_free(root / "protected-store")
            except (OSError, ValueError, RuntimeError):
                checks["finalBoundaryChecksPassed"] = False
            report["result"] = {"newVaultCleanupPassed": checks["originalFreshCreatorCleanupPassed"],
                "finalOccurrenceCount": final.get("occurrenceCount"), "finalSessionCount": final.get("syntheticSessionCount"),
                "finalValueCount": final.get("valueCount"), "queueCount": final.get("queueCount"),
                "gapReasons": final.get("gapReasons"), "finalAlertCount": final.get("alertCount")}
            report["passed"] = "unmetGate" not in report and CHECKS <= checks.keys() and all(checks.values())
    return 0 if artifacts.passed else 1


def main(argv=None):
    try:
        return run(arguments(argv))
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, subprocess.SubprocessError):
        print(json.dumps({"schemaVersion": 1, "passed": False, "status": "controlled-failure",
            "signedAppLaunchState": "consult-retained-run-evidence"}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
