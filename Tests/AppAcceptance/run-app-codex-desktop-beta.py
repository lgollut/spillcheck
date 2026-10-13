#!/usr/bin/env python3
"""Signed retained Codex desktop parent/child output beta acceptance.

Reads only the immutable, previously owned fake fixture's two native sources.
No provider turn, authentication copy, provider configuration or GUI action.
The authenticated DEBUG coordinator drives production processNext manually;
live desktop dispatch, setup and full child-input coverage remain separate.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import time


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


inventory = load("desktop_beta_lifecycle", Path(__file__).with_name("run-app-codex-inventory-state.py"))
lifecycle, setup, shared = inventory.lifecycle, inventory.setup, inventory.shared
ROOT, require = shared.ROOT, shared.require
PROFILE = "owned-signed-codex-desktop-beta"
READER, PRODUCER, HOST = "0.162.1", "0.160.1", "26.930.61225"
PARSER = "codex-content-contract-v16"
DETECTOR = "betterleaks-1.9.0+stdlib-1+leakret-native-1+mapping-1"
SCANNER_SHA = "70d2103c2915aababa0e1eea121bd3db0ff0da86bee40ddc6f5982181acaf6d0"
RULES_SHA = "a8f553eb634ac3c5c1ca3f0dc95e2b8abdea7d14b622604c5af07f30ce7926ef"
TOKEN = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
PROJECT = ROOT / ".build/harness-compatibility/manual-codex-gui-beta-2026-10-10/work"
STAGES = ("scan", "replay")
MARKERS = {"PARENT_PROMPT", "PARENT_INTERMEDIATE", "PARENT_FINAL", "PARENT_TOOL_OUTPUT", "PARENT_TOOL_ERROR",
    "CHILD_INTERMEDIATE", "CHILD_FINAL", "CHILD_TOOL_OUTPUT", "CHILD_TOOL_ERROR"}
# Immutable provenance of the already authorized fake fixture, never replacement
# history supplied by a caller. Original reports retain their original candidates.
PROOF_HASHES = {
    ".build/harness-compatibility/manual-codex-gui-beta-2026-10-10/work/parent-identity.json": "984234e0630ff26b7d80ff059b60cfb77e71e2aba918b3f464e1a3cfcbac4ce9",
    ".build/harness-compatibility/manual-codex-gui-beta-2026-10-10/work/child-identity.json": "d72c3d7c625d8c7c42ca9988e2b69cef991bd848b1561791892ca845726a12d6",
    ".build/harness-compatibility/manual-codex-gui-beta-2026-10-10/work/fixture-contract.json": "c39bf9e6ef30a68c87c353af837ae735256c8c1a34e94dcb38d691695a27621f",
    ".build/harness-compatibility/manual-codex-gui-beta-2026-10-10/GUI_PROMPT.txt": "eb16daaa94ffbeeb5549cba8aba4dc4951e603845a3e6a22d0db911724f870e1",
    ".build/harness-compatibility/manual-codex-gui-beta-2026-10-10/work/fixture.py": "e378311d7f59486a01d7e3199e9f9bc9fa445c0e0551bfdb7df9326d2451301f",
    ".build/beta-readiness/codex-closure-2026-10-11/desktop-saved-partial-acceptance-r3/report.json": "86ec0f4af9f16cde665f73fe8a93ae3a446ffdb4112f35d06643de245d102a24",
    ".build/beta-readiness/codex-closure-2026-10-11/desktop-saved-source-check-r2/report.json": "a744dc74f0bbd43cdae6dff940d217093e9f27b090134aa9a3e26958abe54cd2",
}
RUNNER_INPUTS = tuple(dict.fromkeys(("Tests/AppAcceptance/run-app-codex-desktop-beta.py",
    "Spillcheck/App/DesktopBetaAcceptance.swift", "Tests/AppAcceptance/run-app-codex-inventory-state.py",
    *lifecycle.RUNNER_INPUTS)))
COMMON_CHECKS = {"originalNativeRowsBound", "nativeParentChildLinkVerified", "allOriginalSourcesHaveFullCurrentReceipts",
    "fiveParentFourChildMarkersCommitted", "onlyCanonicalChildInputLimitation", "freshAuditSuccessfullyProcessed"}
STAGE_CHECKS = {"scan": COMMON_CHECKS | {"emptyBeforeAdmission", "everyOriginalFullyScanned"},
    "replay": COMMON_CHECKS | {"coldInventoryAndGapUnchangedBeforeRead", "inventoryReceiptsAndGapUnchangedAfterReread",
        "noAdditionalDetectorScans", "exactSourceRetriesConsumedAfterFreshReads", "freshCanonicalGapObservedWithinReplay"}}
REQUIRED_CHECKS = {"historicalFakeOwnershipProofsValidated", "readerVersionObserved", "freshOwnerCreatedVault",
    "originalFiveParentFourChildMarkersHaveFullReceipts", "coldInventoryAndCanonicalGapUnchanged",
    "acceptedBetaLimitationProducesUnreadAuditSummary",
    "exactNativeRereadWithoutRescanOrDuplicates", "twoDistinctWorkersNormalShutdown", "nativeRowsUnchangedAcrossReads",
    "ciphertextVerifiedAfterNormalShutdown", "exactOwnedDescriptorUnchanged", "historicalProofsUnchanged",
    "creatorCleanupAuthorizedAfterNormalReaderShutdown", "originalFreshCreatorCleanupPassed",
    "ownedProcessGroupsStopped", "workerReaderShutdownConfirmed", "noAppDiagnosticsOrOutput", "readerExecutableUnchanged",
    "candidateAndProductionInputsUnchanged", "candidateManifestBytesUnchanged", "runnerAndLibraryBytesUnchanged"}


def proof_bytes(path):
    require(path.parent.resolve(strict=True) == path.parent, "proof-parent-not-canonical")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        first = os.fstat(fd)
        require(stat.S_ISREG(first.st_mode) and first.st_uid == os.getuid() and first.st_nlink == 1
            and 0 < first.st_size <= 2 * 1024 * 1024, "historical-proof-file-rejected")
        raw = os.read(fd, 2 * 1024 * 1024 + 1)
        last, named = os.fstat(fd), path.lstat()
        require((first.st_dev, first.st_ino, first.st_size, first.st_mtime_ns, first.st_ctime_ns)
            == (last.st_dev, last.st_ino, last.st_size, last.st_mtime_ns, last.st_ctime_ns)
            and (named.st_dev, named.st_ino, named.st_mode, named.st_nlink)
            == (first.st_dev, first.st_ino, first.st_mode, 1) and len(raw) == first.st_size,
            "historical-proof-changed")
        return raw
    finally:
        os.close(fd)


def proof_hashes():
    measured = {name: hashlib.sha256(proof_bytes(ROOT / name)).hexdigest() for name in PROOF_HASHES}
    require(measured == PROOF_HASHES, "immutable-historical-fake-proofs-required")
    return measured


def proof_digest(proofs):
    return hashlib.sha256(json.dumps(proofs, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def descriptor_bytes(value):
    require(isinstance(value, dict) and set(value) == {"schemaVersion", "parentID", "childID", "homePath",
        "projectPath", "producerVersion", "hostVersion", "ownershipProofSHA256"}, "fixed-desktop-descriptor-required")
    require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1
        and value["producerVersion"] == PRODUCER and value["hostVersion"] == HOST
        and value["ownershipProofSHA256"] == proof_digest(PROOF_HASHES), "historical-version-and-proof-required")
    require(shared.canonical_id(value["parentID"]) != shared.canonical_id(value["childID"]), "distinct-native-roles-required")
    for key in ("homePath", "projectPath"):
        path = value[key]
        require(isinstance(path, str) and path.startswith("/") and "\0" not in path
            and len(path.encode()) <= 4096 and str(Path(path)) == path, "canonical-path-required")
    require(value["projectPath"] == str(PROJECT), "original-owned-project-required")
    raw = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    require(len(raw) <= 8192, "descriptor-budget")
    return raw


def ownership_descriptor(home):
    proofs = proof_hashes()
    require(PROJECT.resolve(strict=True) == PROJECT and home.resolve(strict=True) == home, "original-canonical-store-and-project-required")
    roles = {}
    for role in ("parent", "child"):
        value = json.loads(proof_bytes(PROJECT / (role + "-identity.json")), object_pairs_hook=shared.unique_object)
        require(value.get("role") == role and value.get("nativeIdentitySource") == "own-runtime-CODEX_THREAD_ID"
            and value.get("workingDirectory") == str(PROJECT) and value.get("storeCandidate") == str(home),
            "original-owned-native-selection-required")
        roles[role] = shared.canonical_id(value.get("nativeThreadID"))
    require(os.environ.get("CODEX_THREAD_ID") not in roles.values(), "caller-source-forbidden")
    descriptor = {"schemaVersion": 1, "parentID": roles["parent"], "childID": roles["child"],
        "homePath": str(home), "projectPath": str(PROJECT), "producerVersion": PRODUCER,
        "hostVersion": HOST, "ownershipProofSHA256": proof_digest(proofs)}
    descriptor_bytes(descriptor)
    return descriptor


def worker_command(binary, root, name, *, descriptor, reader, stage):
    require(stage in STAGES and name == "worker" + str(STAGES.index(stage) + 1), "fixed-worker-stage-required")
    return shared.command(binary, root, name)[:-1] + ["--acceptance-recovery-worker", "--acceptance-no-profile-catchup",
        "--acceptance-recovery-desktop-beta", "--acceptance-desktop-beta-stage", stage,
        "--acceptance-desktop-beta-descriptor", str(root / "desktop-beta-descriptor.json"),
        "--codex-profile", PROFILE, "--codex-version", READER, "--codex-home", descriptor["homePath"],
        "--codex-executable", str(reader), "--codex-interface", "desktop-code",
        "--codex-authorized-host", "desktop-code", "--codex-authority", "codex-public-native-v1"]


def state(report):
    value = report.get("recoveryDesktopBetaState")
    return value if isinstance(value, dict) else {}


def derived_progress_gate(report, stage):
    if stage not in STAGES:
        return False
    # Initial traversal and the exact child retry remain partial. The separate
    # parent retry completes. Presentation retains both unread audits. Adapter
    # budget gaps still fail DesktopNormalizer, independently of this summary.
    audits, unread = (1, 1) if stage == "scan" else (3, 2)
    operations = report.get("gapCountsByOperation")
    if not isinstance(operations, dict) or set(operations) != {"historicalRead"}:
        return False
    reasons = operations["historicalRead"]
    return (isinstance(reasons, dict) and set(reasons) == {"budgetExhausted", "unsupportedContent"}
        and shared.exact_int(reasons.get("budgetExhausted"), unread)
        and shared.exact_int(reasons.get("unsupportedContent"), 1)
        and report.get("gapReasons") == ["budgetExhausted", "unsupportedContent"]
        and report.get("coverageReportTruncated") is False
        and report.get("historicalProgressMeasurementAvailable") is True
        and shared.exact_int(report.get("scopedGapCount"), unread + 1)
        and shared.exact_int(report.get("settledHistoricalAuditCount"), audits)
        and shared.exact_int(report.get("unreadHistoricalProgressCount"), unread)
        and shared.exact_int(report.get("queueCount"), 0)
        and shared.exact_int(report.get("recoveryQueueClaimedCount"), 0)
        and shared.exact_int(report.get("recoveryEncryptedQueueBytes"), 0))


def stage_gate(report, stage, descriptor):
    if stage not in STAGES:
        return False
    value = state(report)
    if not (report.get("storageReady") is True and report.get("collectionConfigured") is True
        and report.get("recoveryLoadedExistingManifest") is True and report.get("recoveryDesktopBetaEnabled") is True
        and report.get("recoveryCodexPollingStopped") is True and report.get("recoveryProcessingStopped") is True
        and derived_progress_gate(report, stage)
        and shared.exact_int(report.get("queueCount"), 0) and value.get("passed") is True
        and shared.exact_int(value.get("schemaVersion"), 1) and value.get("stage") == stage
        and value.get("readerShutdown") is True and value.get("readerStarted") is True and value.get("parserContract") == PARSER
        and value.get("readerVersion") == READER and value.get("producerVersion") == PRODUCER
        and value.get("hostVersion") == HOST and value.get("detectorVersion") == DETECTOR
        and value.get("upstreamScannerSHA256") == SCANNER_SHA and value.get("rulesSHA256") == RULES_SHA
        and value.get("cryptoScope") == "signed-original-owner-device-protection"
        and value.get("ownershipProofSHA256") == descriptor["ownershipProofSHA256"]
        and set(value.get("checks", {})) == STAGE_CHECKS[stage]
        and all(flag is True for flag in value["checks"].values())):
        return False
    limitations = ("applicationRouteEstablished", "liveDesktopDispatchEstablished", "sideChatCoverageEstablished",
        "nativeChildIncomingInputEstablished", "sourceOpeningEstablished", "systemNotificationDeliveryEstablished", "fullCodexAcceptance")
    if not all(value.get(key) is False for key in limitations):
        return False
    if stage == "replay" and not all(value.get(key) is True for key in
        ("inventoryEqual", "receiptsEqual", "omissionEqual", "freshCanonicalGapObservedWithinReplay")):
        return False
    counts = ("analysisReceiptCount", "sourceCount", "occurrenceCount", "valueCount", "sessionCount", "gapCount",
        "queueCount", "detectorScanCalls", "threadReadCalls", "itemReadCalls", "turnReadCalls", "threadListCalls",
        "nativeBytesRead", "productionSessionCount", "initialAdmissionCount", "createdAuditCount",
        "successfulAdmissionCount", "consumedAdmissionCount", "observedOriginalSourceCount", "expectedOriginalSourceCount",
        "canonicalGapEmissionCount", "durableOmissionCount", "pipelineFailureCount", "normalizerCallCount", "queueClaimedCount")
    if not all(type(value.get(key)) is int and 0 <= value[key] <= (32 * 1024 * 1024 if key == "nativeBytesRead" else 1024) for key in counts):
        return False
    markers = value.get("typedCommittedMarkers")
    return (isinstance(markers, dict) and set(markers) == MARKERS and all(type(count) is int and count == 1 for count in markers.values())
        and value["analysisReceiptCount"] == value["sourceCount"] >= 9 and value["occurrenceCount"] == 15
        and value["valueCount"] == value["gapCount"] == 1 and value["sessionCount"] == value["productionSessionCount"] == 2
        and value["queueCount"] == value["queueClaimedCount"] == value["threadListCalls"] == value["pipelineFailureCount"] == 0
        and value["initialAdmissionCount"] == value["createdAuditCount"] == value["successfulAdmissionCount"]
            == value["consumedAdmissionCount"] == (1 if stage == "scan" else 2)
        and value["observedOriginalSourceCount"] == value["expectedOriginalSourceCount"] == value["sourceCount"]
        and value["canonicalGapEmissionCount"] == value["durableOmissionCount"] == 1
        and value["normalizerCallCount"] >= value["initialAdmissionCount"] and value["nativeBytesRead"] > 0
        and value["threadReadCalls"] >= 2 and value["itemReadCalls"] >= 2
        and value["detectorScanCalls"] == (value["sourceCount"] if stage == "scan" else 0))


def ciphertext_files(root):
    for directory in (root / "protected-store", root / "desktop-beta-evidence/scanner"):
        require(directory.is_dir() and not directory.is_symlink(), "owned-ciphertext-directory-required")
        paths = list(directory.rglob("*"))
        require(len(paths) <= 256, "ciphertext-file-budget")
        for path in paths:
            require(not path.is_symlink(), "ciphertext-symlink")
            if path.is_file():
                require(path.stat().st_size <= 16 * 1024 * 1024, "ciphertext-file-size-budget")
                require(TOKEN.encode() not in path.read_bytes(), "plaintext-fake-value-in-protected-storage")
    return True


def worker_readers_stopped(root, count):
    # A normal app exit does not prove its separately owned passive reader stopped.
    # Missing evidence retains the original vault owner and cleanup handoff.
    for index in range(1, count + 1):
        try:
            report = shared.private_json(root / ("worker%d-report.json" % index))
        except (OSError, ValueError, RuntimeError):
            return False
        value = state(report)
        if value.get("readerShutdown") is not True or type(value.get("readerStarted")) is not bool:
            return False
    return True


def runner_hashes():
    return {name: shared.preflight.hash_file(ROOT, name, [0]) for name in RUNNER_INPUTS}


def completed_checks(checks):
    return REQUIRED_CHECKS <= checks.keys() and all(value is True for value in checks.values())


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("app", "candidate-manifest", "executable", "authorized-home", "output", "private-control"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--expected-bundle-sha256", required=True)
    return parser.parse_args(argv)


def run(args):
    os.umask(0o077)
    require(not args.output.exists() and not args.output.is_symlink() and not args.private_control.exists()
        and not args.private_control.is_symlink() and args.output.absolute() != args.private_control.absolute(), "fresh-report-paths-required")
    descriptor = ownership_descriptor(args.authorized_home.absolute())
    app, reader = args.app.resolve(strict=True), args.executable.resolve(strict=True)
    manifest_path = args.candidate_manifest.resolve(strict=True)
    manifest_hash = shared.preflight.hash_file(manifest_path.parent, manifest_path.name, [0])
    manifest = shared.preflight.read_manifest(args.candidate_manifest)
    require(manifest["bundleSHA256"] == shared.preflight.digest_value(args.expected_bundle_sha256)
        and shared.preflight.hash_file(manifest_path.parent, manifest_path.name, [0]) == manifest_hash
        and shared.preflight.check(manifest, app, ROOT)["consistent"], "frozen-signed-candidate-required")
    reader_hash, inputs = shared.preflight.hash_file(reader.parent, reader.name, [0]), runner_hashes()
    binary = app / "Contents/MacOS/Spillcheck"
    with shared.AcceptanceArtifacts("spillcheck-desktop-beta-", args.output) as artifacts:
        root, token = artifacts.directory, os.urandom(32)
        shared.write_new(root / "run-token", token); shared.write_new(root / "stop-codex-polling", token)
        shared.write_json(root / "candidate-build.json", manifest)
        shared.write_json(root / "runner-inputs-private.json", inputs)
        descriptor_path = root / "desktop-beta-descriptor.json"
        shared.write_new(descriptor_path, descriptor_bytes(descriptor))
        descriptor_hash = shared.preflight.hash_file(root, descriptor_path.name, [0])
        args.private_control.parent.mkdir(parents=True, exist_ok=True)
        shared.write_json(args.private_control, {"schemaVersion": 1, "ownedArtifactDirectory": str(root),
            "reportPath": str(args.output.absolute()), "candidateBundleSHA256": args.expected_bundle_sha256,
            "runTokenPath": str(root / "run-token"), "cleanupOwnerReport": str(root / "owner-report.json"),
            "ownerProcessHandoff": str(root / "owner-process-private.json"),
            "retainedOwnerHandoff": str(root / "owner-retained-private.json"),
            "cleanupAuthority": "original-fresh-vault-owner-only", "loadedWorkersMayDeleteKeys": False,
            "runnerNeverModifiesOrRemovesOriginalProviderHome": True,
            "passiveReaderFilesystemEffectsMeasured": False,
            "protectionCleanupReportField": "ownedProtectionCleanupPending", "cleanupPendingIncludesRetainedFailureArtifacts": True})
        report = {"schemaVersion": 1, "scope": "signed-retained-official-desktop-parent-and-readable-child-output-beta",
            "passed": False, "candidateBundleSHA256": args.expected_bundle_sha256, "candidateManifestSHA256": manifest_hash,
            "readerVersion": READER, "producerVersion": PRODUCER, "sourceHostVersion": HOST,
            "sourceHostVersionEvidence": "original-2026-10-10-official-bundle-metadata", "ownershipProofSHA256": descriptor["ownershipProofSHA256"],
            "selectedThreadCount": 2, "providerTurnsRequested": 0, "runnerAuthenticationReadOrCopied": False,
            "runnerProviderConfigurationChanged": False, "passiveReaderFilesystemEffectsMeasured": False,
            "passiveReaderAuthenticationAccessMeasured": False, "historyEnumerationPerformed": False,
            "liveDesktopDispatchEstablished": False, "sideChatCoverageEstablished": False,
            "nativeChildIncomingInputEstablished": False, "sourceOpeningEstablished": False,
            "systemNotificationDeliveryEstablished": False, "fullCodexAcceptance": False,
            "applicationRouteEstablished": False, "syntheticInitialQueueAdmission": True,
            "initialAdmissionKind": "exact-owned-parent-native-child-traversal-historical-audit",
            "acceptedBetaLimitationProducesUnreadAuditSummary": False,
            "budgetCollectionFailureAllowed": False,
            "unreadAuditSummaryExplanation": "The canonical child-input omission keeps audits that read the child partial; "
                "initial traversal and the exact child retry each retain an unread-history budgetExhausted summary. "
                "The separate exact parent retry completes. "
                "Every adapter or scanner gap except that exact omission remains a failure.",
            "replayAdmissionKind": "two-exact-public-selected-source-retries-with-distinct-audits",
            "omissionReplayComparison": "durable-record-exactly-identical-with-independent-fresh-canonical-emission",
            "startedAtUnixSeconds": time.time(), "checks": {"historicalFakeOwnershipProofsValidated": True}}
        artifacts.report = report
        checks, workers, owner = report["checks"], [], None
        owner_ready, successful, final = False, False, {}
        version_stopped, version_cleanup, phase = False, {}, "reader-version"
        try:
            try:
                version = shared.live.observe_version(reader, environment=dict(os.environ, CODEX_HOME=descriptor["homePath"]),
                    directory=root, expected=READER, cleanup_report=version_cleanup)
            finally:
                version_stopped = version_cleanup.get("leaderExited") is True and version_cleanup.get("groupKillPermissionDenied") is False
            require(version == READER and version_stopped, "reader-version-or-lifetime-unconfirmed")
            checks["readerVersionObserved"] = True
            phase = "fresh-vault-owner"
            owner = setup.ReportProcess(shared.command(binary, root, "owner"))
            lifecycle.process_handoff(root, "owner-process-private.json", owner.process, "original-fresh-vault-owner")
            owner.wait_report(root / "owner-report.json", lambda value: value.get("ownerReady") is True
                and value.get("createdFreshVault") is True, "fresh-owner-unavailable")
            owner_ready = True; checks["freshOwnerCreatedVault"] = True
            manifest_digest, stage_reports = None, []
            for index, stage in enumerate(STAGES, 1):
                require(owner.process.poll() is None, "fresh-owner-lost")
                name, phase = "worker" + str(index), "signed-" + stage
                worker = setup.ReportProcess(worker_command(binary, root, name, descriptor=descriptor, reader=reader, stage=stage))
                workers.append(worker)
                lifecycle.process_handoff(root, name + "-process-private.json", worker.process, "loaded-vault-worker")
                initial = worker.wait_report(root / (name + "-report.json"), lambda value: stage_gate(value, stage, descriptor),
                    "retained-desktop-" + stage + "-unverified", timeout=180)
                final = inventory.finish_worker(worker, root, name, lambda value: stage_gate(value, stage, descriptor))
                digest = inventory.digest_values([final.get("recoveryManifestDigest")])
                require(digest is not None and len(digest) == 1 and final.get("recoveryManifestDigest") == initial.get("recoveryManifestDigest")
                    and (manifest_digest is None or digest == manifest_digest), "manifest-changed")
                manifest_digest = digest
                stage_reports.append(state(final) | {"acceptedBetaLimitationProducesUnreadAuditSummary": True,
                    "gapCountsByOperation": final["gapCountsByOperation"], "scopedGapCount": final["scopedGapCount"],
                    "settledHistoricalAuditCount": final["settledHistoricalAuditCount"],
                    "unreadHistoricalProgressCount": final["unreadHistoricalProgressCount"]})
                require(proof_hashes() == PROOF_HASHES, "historical-source-proofs-changed")
            report["workerStages"] = stage_reports
            report["acceptedBetaLimitationProducesUnreadAuditSummary"] = True
            checks.update(originalFiveParentFourChildMarkersHaveFullReceipts=True, coldInventoryAndCanonicalGapUnchanged=True,
                acceptedBetaLimitationProducesUnreadAuditSummary=True,
                exactNativeRereadWithoutRescanOrDuplicates=True, twoDistinctWorkersNormalShutdown=len({worker.process.pid for worker in workers}) == 2,
                nativeRowsUnchangedAcrossReads=True, ciphertextVerifiedAfterNormalShutdown=ciphertext_files(root),
                exactOwnedDescriptorUnchanged=shared.preflight.hash_file(root, descriptor_path.name, [0]) == descriptor_hash)
            successful = all(checks.values())
        except (OSError, ValueError, KeyError, TypeError, RuntimeError, TimeoutError, BufferError, subprocess.SubprocessError) as error:
            report.update(unmetGate=error.gate if isinstance(error, shared.GateFailure) else phase, failureCategory="controlled-run-failure")
        finally:
            groups, shutdowns = inventory.cleanup_workers(workers, root)
            readers_stopped = worker_readers_stopped(root, len(workers))
            checks["workerReaderShutdownConfirmed"] = readers_stopped
            normal = readers_stopped and shared.safe_creator_cleanup(shutdowns, helper_stopped=version_stopped,
                socket_absent=not (root / "protected-store/capture.sock").exists())
            owner_report, retained, owner_stopped, handoff_failed = inventory.finish_creator(owner, root, token,
                ready_observed=owner_ready, authorized=normal, groups=groups)
            report.update(originalCreatorRetainedForCleanup=retained, creatorRetentionHandoffWriteFailed=handoff_failed,
                ownedProtectionCleanupPending=owner is not None and owner_report.get("cleanupPassed") is not True)
            if setup.owner_failure_summary(owner_report): report["ownerFailureDiagnostic"] = setup.owner_failure_summary(owner_report)
            checks["creatorCleanupAuthorizedAfterNormalReaderShutdown"] = normal
            checks["originalFreshCreatorCleanupPassed"] = owner_report.get("createdFreshVault") is True and owner_report.get("cleanupPassed") is True
            checks["ownedProcessGroupsStopped"] = (not retained and owner_stopped and version_stopped
                and all(row["groupStopped"] for row in shutdowns) and bool(groups)
                and all(row.get("term_permission_denied") is False and row.get("kill_permission_denied") is False for row in groups))
            checks["noAppDiagnosticsOrOutput"] = all(not any(process.counts.values()) for process in workers + ([owner] if owner else []))
            try:
                checks["historicalProofsUnchanged"] = proof_hashes() == PROOF_HASHES
                checks["readerExecutableUnchanged"] = shared.preflight.hash_file(reader.parent, reader.name, [0]) == reader_hash
                checks["candidateAndProductionInputsUnchanged"] = shared.preflight.check(manifest, app, ROOT)["consistent"]
                checks["candidateManifestBytesUnchanged"] = shared.preflight.hash_file(manifest_path.parent, manifest_path.name, [0]) == manifest_hash
                checks["runnerAndLibraryBytesUnchanged"] = runner_hashes() == inputs
            except (OSError, ValueError, RuntimeError): checks["finalBoundaryChecksPassed"] = False
            report["result"] = {"newVaultCleanupPassed": checks["originalFreshCreatorCleanupPassed"],
                "fullReceiptCount": state(final).get("analysisReceiptCount"), "occurrenceCount": state(final).get("occurrenceCount"),
                "queueCount": final.get("queueCount"), "gapReasons": final.get("gapReasons")}
            report["passed"] = successful and "unmetGate" not in report and completed_checks(checks)
            report["signedRetainedDesktopOutputBetaEstablished"] = report["passed"]
            report["finishedAtUnixSeconds"] = time.time()
    return 0 if artifacts.passed else 1


def main(argv=None):
    try: return run(arguments(argv))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError):
        print(json.dumps({"passed": False, "status": "controlled-desktop-beta-input-failure", "providerTurnsRequested": 0}))
        return 1


if __name__ == "__main__": raise SystemExit(main())
