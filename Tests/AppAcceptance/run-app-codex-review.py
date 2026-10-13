#!/usr/bin/env python3
"""Signed fake native review/null-phase receipts and durable inspection recovery.

The authenticated DEBUG coordinator drives production processNext manually.
This proves signed receipt/restart/recovery behavior, not normal app routing.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import time


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


native = load("review_signed_lifecycle", Path(__file__).with_name("run-app-codex-native-content.py"))
inventory, lifecycle, setup, shared = native.inventory, native.lifecycle, native.setup, native.shared
ROOT, require = shared.ROOT, shared.require
recovery = load("signed_review_recovery_producer", ROOT / "Tests/CodexReviewRecoveryProbe/run.py")
producer = recovery.producer
PARSER, DETECTOR = native.PARSER, native.DETECTOR
PROFILE = "owned-signed-codex-review"
STAGES = ("queue", "resume", "replay")
RUNNER_INPUTS = tuple(dict.fromkeys(("Tests/AppAcceptance/run-app-codex-review.py",
    "Tests/AppAcceptance/test_codex_review_boundary.py", "Tests/CodexReviewRecoveryProbe/run.py",
    *producer.SOURCE_INPUTS, *native.RUNNER_INPUTS)))
REQUIRED_CHECKS = {"readerVersionObservedBeforeProvider", "freshOwnerCreatedVault", "oneOwnedNativeReviewCompleted",
    "temporaryAuthRemovedBeforeSignedReads", "sourcePinnedBeforeSignedRead", "exactOwnedDescriptorUnchanged",
    "persistedOriginalDescriptorDiscovered", "descriptorDiscoveryReaderStopped", "discoveryTestArtifactsUnchanged",
    "pendingNativeInspectionDurable", "coldPendingIdentityCiphertextAndInventoryUnchanged",
    "originalNativeInputAndNullPhaseReplyFullReceipts", "bothPresentationWarningsResolved",
    "coldInventoryAndConsumedReceiptsUnchanged", "coldActualRereadWithoutDetectorRescanOrDuplicates",
    "threeDistinctWorkersNormalShutdown", "allWorkerReadersConfirmedStopped", "sourceUnchangedAfterAllWorkers", "ciphertextVerifiedAfterNormalShutdown",
    "temporaryAuthenticationRemoved", "ownedProviderHomeRemoved", "creatorCleanupAuthorizedAfterNormalSourceShutdown",
    "originalFreshCreatorCleanupPassed", "ownedProcessGroupsStopped", "noAppDiagnosticsOrOutput",
    "readerExecutableUnchanged", "candidateAndProductionInputsUnchanged", "candidateManifestBytesUnchanged",
    "runnerAndLibraryBytesUnchanged", "originalAuthenticationFileUnchanged"}
owned_home, remove_auth = native.owned_home, native.remove_auth


def source_snapshot(home, identity, selected):
    """Pin this fake review's root and metadata-proven review child only.

    The child's content is hashed for source stability, never parsed or admitted
    as a selected source. Signed workers still read only the root descriptor.
    """
    require(owned_home(home, identity) and not (home / "auth.json").exists()
        and not (home / "auth.json").is_symlink(), "owned-authless-review-home-required")
    selected = shared.canonical_id(selected)
    directory = home / "sessions"
    require(directory.is_dir() and not directory.is_symlink(), "owned-review-sources-unavailable")
    names = shared.preflight.tree_files(directory)
    require(len(names) == 2, "exact-root-and-review-child-rollouts-required")
    records, identities = [], set()
    for name in names:
        descriptor = shared.preflight.opened_file(directory, name)
        with os.fdopen(descriptor, "rb") as handle:
            before = os.fstat(handle.fileno())
            require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid() and before.st_nlink == 1
                and before.st_mode & 0o077 == 0 and 0 < before.st_size <= 8 * 1024 * 1024,
                "private-owned-review-rollout-required")
            # Only the first session metadata row is decoded. Hash the rest as
            # opaque bytes after that row establishes the allowed relationship.
            first = handle.readline(256 * 1024 + 1)
            require(first.endswith(b"\n") and len(first) <= 256 * 1024, "bounded-original-review-metadata-required")
            row = producer.decode(first)
            metadata = row.get("payload")
            require(row.get("type") == "session_meta" and isinstance(metadata, dict)
                and producer.native_id(metadata.get("id"))
                and metadata.get("cwd") == str(home.parent / "work")
                and metadata.get("cli_version") == producer.VERSION
                and metadata.get("originator") == "spillcheck-fake-review-probe"
                and metadata.get("history_mode") == "paginated", "owned-native-review-metadata-required")
            item_id = metadata["id"]
            require(item_id not in identities and name.endswith("-" + item_id + ".jsonl")
                and len(Path(name).parts) == 4, "unique-original-review-rollout-required")
            identities.add(item_id)
            if item_id == selected:
                require(metadata.get("source") == "vscode" and metadata.get("parent_thread_id") is None
                    and metadata.get("forked_from_id") is None, "original-selected-review-root-required")
                role = "selected-root"
            else:
                require(metadata.get("source") == {"subagent": "review"}
                    and metadata.get("parent_thread_id") == selected and metadata.get("forked_from_id") is None,
                    "exact-owned-review-child-required")
                role = "review-child-stability-only"
            digest, read = hashlib.sha256(first), len(first)
            while chunk := handle.read(1024 * 1024):
                read += len(chunk)
                require(read <= before.st_size, "review-rollout-changed-during-snapshot")
                digest.update(chunk)
            after = os.fstat(handle.fileno())
            require(read == before.st_size and shared.preflight.fingerprint(before) == shared.preflight.fingerprint(after)
                and after.st_nlink == 1, "review-rollout-changed-during-snapshot")
        # Reopen through the same no-follow directory walk to reject replacement
        # of the pathname while the first descriptor was being read.
        descriptor = shared.preflight.opened_file(directory, name)
        try:
            require(shared.preflight.fingerprint(os.fstat(descriptor)) == shared.preflight.fingerprint(before),
                "review-rollout-path-replaced")
        finally:
            os.close(descriptor)
        records.append({"relativePath": name, "nativeID": item_id, "role": role, "sha256": digest.hexdigest(),
            "bytes": read, "device": before.st_dev, "inode": before.st_ino,
            "mtimeNs": before.st_mtime_ns, "ctimeNs": before.st_ctime_ns})
    require(selected in identities and sum(row["role"] == "selected-root" for row in records) == 1
        and sum(row["role"] == "review-child-stability-only" for row in records) == 1,
        "one-root-and-one-linked-review-child-required")
    require(owned_home(home, identity) and shared.preflight.tree_files(directory) == names,
        "owned-review-source-inventory-changed")
    return {"schemaVersion": 1, "rollouts": records}


def runner_hashes():
    return {name: shared.preflight.hash_file(ROOT, name, [0]) for name in RUNNER_INPUTS}


def descriptor_bytes(value):
    require(isinstance(value, dict) and set(value) == {"schemaVersion", "threadID", "turnID", "inputID", "outputID",
        "inputSHA256", "outputSHA256", "inputBytes", "outputBytes", "producerVersion"}, "fixed-review-descriptor-required")
    require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1
        and producer.native_id(value["threadID"]) and producer.opaque_id(value["turnID"])
        and producer.opaque_id(value["inputID"]) and producer.opaque_id(value["outputID"])
        and value["inputID"] != value["outputID"] and value["producerVersion"] == producer.VERSION,
        "observed-review-identities-required")
    for kind in ("input", "output"):
        require(isinstance(value[kind + "SHA256"], str) and re.fullmatch(r"[0-9a-f]{64}", value[kind + "SHA256"])
            and type(value[kind + "Bytes"]) is int and 0 < value[kind + "Bytes"] <= 16384, "original-review-bytes-required")
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    require(len(encoded) <= 4096, "descriptor-budget")
    return encoded


def discover_descriptor(executable, home, root, control, observed, scratch_path, lifetime):
    require(home == root / "home" and lifetime.get("producerStopped") is True
        and lifetime.get("descriptorReaderStopped") is True
        and not (home / "auth.json").exists() and not (home / "auth.json").is_symlink(),
        "auth-removed-and-producer-stopped-required-before-discovery")
    report_path, descriptor_path = control / "passive-report.json", root / "review-descriptor.json"
    require(all(not path.exists() and not path.is_symlink() for path in (report_path, descriptor_path)),
        "fresh-descriptor-discovery-required")
    env = {key: value for key, value in os.environ.items() if not key.startswith("SPILLCHECK_")}
    env.update(producer.environment(root, home))
    for key, value in {"HOME": str(home), "THREAD": observed.thread, "TURN": observed.turn,
        "ITEM": observed.message["itemID"], "INPUT_ITEM": observed.input_message["itemID"],
        "EXECUTABLE": str(executable), "REPORT": str(report_path), "DESCRIPTOR": str(descriptor_path),
        "SHA256": observed.message["textSHA256"], "BYTES": str(observed.message["textBytes"]),
        "INPUT_SHA256": observed.input_message["textSHA256"], "INPUT_BYTES": str(observed.input_message["textBytes"])}.items():
        env["SPILLCHECK_REVIEW_PROBE_" + key] = value
    stopped, public = {}, {}
    lifetime["descriptorReaderStopped"] = False
    try:
        code, _, _ = recovery.bounded(["/usr/bin/swift", "test", "--scratch-path", str(scratch_path),
            "--skip-build", "--no-parallel", "--filter", "CodexReviewLiveTests.exactOwnedReviewIsReadTwiceThroughProductionClient"],
            environment=env, directory=ROOT, timeout=90, maximum_bytes=producer.MAXIMUM, cleanup_report=stopped)
    finally:
        try:
            public = producer.decode(producer.private_bytes(report_path))
        except (OSError, ValueError, RuntimeError, producer.ProbeFailure):
            public = {}
        # The test process group and the client's separate reader group both
        # need affirmative shutdown proof, including on a failed discovery.
        lifetime["descriptorReaderStopped"] = (recovery.stopped(stopped) and isinstance(public, dict)
            and public.get("readerShutdownCompletedWithinDeadline") is True)
    require(code == 0 and lifetime["descriptorReaderStopped"], "descriptor-reader-shutdown-unconfirmed")
    require(producer.passive_gate(public, observed.message, observed.input_message)
        and public.get("persistedOriginalDescriptorExported") is True
        and type(public.get("liveInputItemIDEqualsPersistedItemID")) is bool,
        "genuine-original-review-descriptor-discovery-unverified")
    raw = producer.private_bytes(descriptor_path, 4096)
    descriptor = producer.decode(raw)
    require(raw == descriptor_bytes(descriptor) and descriptor["threadID"] == observed.thread
        and descriptor["turnID"] == observed.turn, "exact-owned-native-review-descriptor-required")
    for kind, message in (("input", observed.input_message), ("output", observed.message)):
        require(descriptor[kind + "SHA256"] == message["textSHA256"]
            and descriptor[kind + "Bytes"] == message["textBytes"], "descriptor-original-bytes-mismatch")
    require(public["liveInputItemIDEqualsPersistedItemID"] == (descriptor["inputID"] == observed.input_message["itemID"])
        and public["liveItemIDEqualsPersistedItemID"] == (descriptor["outputID"] == observed.message["itemID"]),
        "descriptor-native-identity-observation-mismatch")
    projected = producer.public_passive(public)
    projected.update(persistedOriginalDescriptorExported=True,
        liveInputItemIDEqualsPersistedItemID=public["liveInputItemIDEqualsPersistedItemID"])
    return descriptor, projected


def worker_command(binary, root, name, *, home, descriptor, reader, version, stage):
    require(name == "worker" + str(STAGES.index(stage) + 1)
        and home == root / "home" and descriptor == root / "review-descriptor.json", "fixed-owned-review-worker-required")
    return shared.command(binary, root, name)[:-1] + ["--acceptance-recovery-worker",
        "--acceptance-no-profile-catchup", "--acceptance-recovery-review", "--acceptance-review-stage", stage,
        "--acceptance-review-descriptor", str(descriptor), "--codex-profile", PROFILE,
        "--codex-version", version, "--codex-home", str(home), "--codex-executable", str(reader),
        "--codex-interface", "standalone-cli", "--codex-authorized-host", "standalone-cli",
        "--codex-authority", "codex-public-native-v1"]


def state(report):
    value = report.get("recoveryReviewState")
    return value if isinstance(value, dict) else {}


def stage_gate(report, stage, descriptor):
    value = state(report)
    required_common = recovery.COMMON_CHECKS - {"scannerArtifactsVerified", "storeClosed", "ciphertextVerified"}
    limits = {"applicationRouteEstablished", "desktopAcceptance", "t3Acceptance", "nativeChildCoverage",
        "providerUpgradeAcceptance", "systemNotificationDeliveryEstablished"}
    if not (report.get("storageReady") is True and report.get("collectionConfigured") is True
        and report.get("recoveryLoadedExistingManifest") is True and report.get("recoveryReviewEnabled") is True
        and report.get("recoveryCodexPollingStopped") is True and report.get("recoveryProcessingStopped") is True
        and report.get("coverageReportTruncated") is False
        and value.get("passed") is True and type(value.get("schemaVersion")) is int and value["schemaVersion"] == 1
        and value.get("stage") == stage and all(value.get(key) is True for key in required_common)
        and value.get("bundledScannerSelected") is True and all(value.get(key) is False for key in limits)
        and all(value.get("checks", {}).get(key) is True for key in recovery.STAGE_CHECKS[stage])
        and value.get("parserContract") == PARSER and value.get("readerVersion") == value.get("producerVersion") == producer.VERSION
        and value.get("detectorVersion") == DETECTOR and value.get("upstreamScannerSHA256") == recovery.SCANNER_SHA
        and value.get("rulesSHA256") == recovery.RULES_SHA
        and value.get("cryptoScope") == "signed-original-owner-device-protection"
        and all(type(value.get(key)) is int and 0 <= value[key] <= 10000 for key in recovery.COUNTS)
        and value["threadListCalls"] == 0 and value["threadReadCalls"] >= 1 and value["itemReadCalls"] >= 1):
        return False
    for kind in ("input", "output"):
        if value.get(kind + "TextSHA256") != descriptor[kind + "SHA256"] or value.get(kind + "TextBytes") != descriptor[kind + "Bytes"]:
            return False
    if stage == "queue":
        inspected = ((value.get("queueInspectionKind") == "entry" and value["turnReadCalls"] >= 1)
            or (value.get("queueInspectionKind") == "exit" and value["itemReadCalls"] >= 2))
        return (inspected
            and value["queueCount"] == report.get("queueCount") == 1
            and 1 <= value["gapCount"] <= 2 and value["detectorScanCalls"] <= 2
            and all(value[key] <= 2 for key in ("analysisReceiptCount", "occurrenceCount", "sourceCount"))
            and value["valueCount"] <= 1)
    return (all(value[key] == expected for key, expected in {"analysisReceiptCount": 2, "occurrenceCount": 2,
        "sourceCount": 2, "valueCount": 1, "queueCount": 0, "gapCount": 0}.items())
        and report.get("queueCount") == 0 and report.get("gapReasons") == []
        and value["itemReadCalls"] >= 2 and value["turnReadCalls"] >= 1
        and value["cursorCalls"] > 0 and value["exactTurnCalls"] > 0
        and (stage != "replay" or value["detectorScanCalls"] == 0))


def worker_readers_stopped(root, count):
    # A normal app exit does not prove the coordinator's separately launched
    # reader group stopped. Missing or false evidence retains the original owner.
    for index in range(1, count + 1):
        try:
            report = shared.private_json(root / ("worker%d-report.json" % index))
        except (OSError, ValueError, RuntimeError):
            return False
        value = state(report)
        if value.get("readerShutdown") is not True or type(value.get("readerStarted")) is not bool:
            return False
    return True


def ciphertext_files(root):
    for directory in (root / "protected-store", root / "review-evidence/scanner"):
        require(directory.is_dir() and not directory.is_symlink(), "owned-ciphertext-directory-required")
        paths = list(directory.rglob("*"))
        require(len(paths) <= 128, "ciphertext-file-budget")
        for path in paths:
            require(not path.is_symlink(), "ciphertext-symlink")
            if path.is_file():
                require(path.stat().st_size <= 16 * 1024 * 1024, "ciphertext-file-size-budget")
                require(recovery.FAKE_TOKEN.encode() not in path.read_bytes(), "plaintext-fake-value-in-protected-storage")
    return True


def completed_checks(checks):
    return REQUIRED_CHECKS <= checks.keys() and all(value is True for value in checks.values())


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("app", "candidate-manifest", "executable", "auth-file", "output", "private-control"):
        parser.add_argument("--" + name, type=Path, required=True)
    for name in ("expected-bundle-sha256", "expected-version", "model"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--scratch-path", type=Path, default=ROOT / ".build")
    return parser.parse_args(argv)


def run(args):
    os.umask(0o077)
    require(not args.output.exists() and not args.output.is_symlink() and not args.private_control.exists()
        and not args.private_control.is_symlink() and args.output.absolute() != args.private_control.absolute(), "fresh-report-paths-required")
    require(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}", args.model) is not None, "explicit-model-required")
    require(args.expected_version == producer.VERSION, "pinned-native-fixture-required")
    app, reader = args.app.resolve(strict=True), args.executable.resolve(strict=True)
    manifest_path = args.candidate_manifest.resolve(strict=True)
    manifest_hash = shared.preflight.hash_file(manifest_path.parent, manifest_path.name, [0])
    manifest = shared.preflight.read_manifest(args.candidate_manifest)
    require(manifest["bundleSHA256"] == shared.preflight.digest_value(args.expected_bundle_sha256)
        and shared.preflight.hash_file(manifest_path.parent, manifest_path.name, [0]) == manifest_hash
        and shared.preflight.check(manifest, app, ROOT)["consistent"], "frozen-signed-candidate-required")
    reader_hash = shared.preflight.hash_file(reader.parent, reader.name, [0])
    inputs = runner_hashes()
    test_artifacts = recovery.artifact_hashes(args.scratch_path)
    auth_hash = None
    binary, helper = app / "Contents/MacOS/Spillcheck", app / "Contents/Helpers/spillcheck-hook"
    # The signed worker independently enforces this owned-root prefix.
    with shared.AcceptanceArtifacts("spillcheck-signed-review-", args.output) as artifacts:
        root, token = artifacts.directory, os.urandom(32)
        home, work = root / "home", root / "work"
        home.mkdir(mode=0o700)
        work.mkdir(mode=0o700)
        home_identity = (home.stat().st_dev, home.stat().st_ino)
        shared.write_new(root / "run-token", token)
        shared.write_new(root / "stop-codex-polling", token)
        shared.write_json(root / "candidate-build.json", manifest)
        shared.write_json(root / "runner-inputs-private.json", inputs)
        shared.write_json(root / "discovery-test-artifacts-private.json", test_artifacts)
        args.private_control.parent.mkdir(parents=True, exist_ok=True)
        shared.write_json(args.private_control, {"schemaVersion": 1, "ownedArtifactDirectory": str(root),
            "reportPath": str(args.output.absolute()), "candidateBundleSHA256": args.expected_bundle_sha256,
            "runTokenPath": str(root / "run-token"), "cleanupOwnerReport": str(root / "owner-report.json"),
            "ownerProcessHandoff": str(root / "owner-process-private.json"),
            "producerProcessHandoff": str(root / "producer-control/producer-process.json"),
            "reviewDescriptor": str(root / "review-descriptor.json"),
            "retainedOwnerHandoff": str(root / "owner-retained-private.json"),
            "cleanupAuthority": "original-fresh-vault-owner-only", "loadedWorkersMayDeleteKeys": False,
            "fixtureKind": "review-null-phase", "independentChildren": "none-expected",
            "protectionCleanupReportField": "ownedProtectionCleanupPending", "cleanupPendingIncludesRetainedFailureArtifacts": True})
        report = {"schemaVersion": 1, "scope": "signed-one-owned-review-inspection-restart-receipts-and-replay", "passed": False,
            "startedAtUnixSeconds": time.time(),
            "candidateBundleSHA256": args.expected_bundle_sha256, "readerVersion": args.expected_version,
            "candidateManifestSHA256": manifest_hash,
            "discoveryTestArtifactsSHA256": hashlib.sha256(json.dumps(test_artifacts, sort_keys=True,
                separators=(",", ":")).encode()).hexdigest(), "discoveryTestArtifactCount": len(test_artifacts),
            "producerVersion": args.expected_version, "fixtureKind": "review-null-phase",
            "applicationRouteEstablished": False,
            "model": args.model, "providerLaunchCount": 0,
            "selectedThreadCount": 0, "syntheticInitialQueueAdmission": True,
            "initialAdmissionKind": "exact-selected-source-historical-audit", "providerHookDispatchEstablished": False,
            "personalHistoryRead": False, "personalConfigurationChanged": False, "rawProviderOutputRetained": False,
            "webCallsExpected": 0, "toolCallsExpected": 0, "receiptSeedingUsed": False, "knownSecretRecallEstablished": False,
            "secondDetectorScanEstablished": False, "systemNotificationDeliveryEstablished": False,
            "fullCodexAcceptance": False, "T3Acceptance": False, "desktopAcceptance": False,
            "sideChatCoverageEstablished": False, "nativeChildCoverageEstablished": False,
            "sourceOpeningEstablished": False, "savedProfileRecoveryEstablished": False,
            "schemaMigrationEstablished": False, "providerUpgradeEstablished": False, "crashRecoveryEstablished": False,
            "checks": {}}
        artifacts.report = report
        checks, workers, owner = report["checks"], [], None
        owner_ready, auth_removed, successful, final = False, True, False, {}
        source_lifetime, helper_lifetime, version_cleanup = {
            "producerStopped": True, "providerLaunchCount": 0, "descriptorReaderStopped": True}, {"stopped": True}, {}
        source, native, descriptor_hash, phase = None, None, None, "reader-version"
        descriptor_path = root / "review-descriptor.json"
        control = root / "producer-control"
        version_stopped = False
        try:
            try:
                version = shared.live.observe_version(reader, environment=producer.environment(root, home),
                    directory=work, expected=args.expected_version, cleanup_report=version_cleanup)
            finally:
                version_stopped = (version_cleanup.get("leaderExited") is True
                    and version_cleanup.get("groupKillPermissionDenied") is False)
            checks["readerVersionObservedBeforeProvider"] = version == args.expected_version
            require(version_stopped, "version-process-lifetime-unconfirmed")
            # Protection availability is a prerequisite for spending a provider turn.
            # Keep this original creator alive through production and all three signed workers.
            phase = "fresh-vault-owner"
            owner = setup.ReportProcess(shared.command(binary, root, "owner"))
            lifecycle.process_handoff(root, "owner-process-private.json", owner.process, "original-fresh-vault-owner")
            owner.wait_report(root / "owner-report.json", lambda value: value.get("ownerReady") is True
                and value.get("createdFreshVault") is True, "fresh-owner-unavailable")
            owner_ready = True
            checks["freshOwnerCreatedVault"] = True
            require(owner.process.poll() is None, "fresh-owner-lost")
            authentication = shared.private_bytes(args.auth_file)
            auth_hash = hashlib.sha256(authentication).hexdigest()
            shared.write_new(home / "auth.json", authentication)
            del authentication
            auth_removed = False
            control.mkdir(mode=0o700)
            shared.write_new(home / "config.toml", (f'model = "{args.model}"\nreview_model = "{args.model}"\nweb_search = "disabled"\n'
                '[features]\nshell_tool = false\n[analytics]\nenabled = false\n[otel]\nexporter = "none"\n').encode())
            phase = "one-fake-native-review"
            require(owner.process.poll() is None, "fresh-owner-lost")
            try:
                observed, producer_report = producer.produce(reader, args.model, root, home, work, source_lifetime, control)
            finally:
                if source_lifetime["producerStopped"]:
                    auth_removed = remove_auth(home, home_identity)
            require(source_lifetime["producerStopped"] and auth_removed, "producer-or-auth-cleanup-unconfirmed")
            phase = "persisted-original-descriptor-discovery"
            descriptor, discovery = discover_descriptor(reader, home, root, control, observed,
                args.scratch_path, source_lifetime)
            require(recovery.artifact_hashes(args.scratch_path) == test_artifacts, "discovery-test-artifacts-changed")
            report["descriptorDiscovery"] = discovery
            native = descriptor["threadID"]
            descriptor_hash = shared.preflight.hash_file(root, descriptor_path.name, [0])
            report.update(selectedThreadCount=1, producer=producer_report)
            source = source_snapshot(home, home_identity, native)
            report.update(sourceRolloutCount=len(source["rollouts"]), reviewChildRolloutCount=1,
                reviewChildSnapshotScope="metadata-relationship-and-opaque-byte-stability-only")
            shared.write_json(root / "owned-source-private.json", {"nativeIdentitySource": "own-saved-native-originals-after-two-authless-passive-reads",
                "nativeID": native, "home": str(home), "source": source, "descriptorSHA256": descriptor_hash})
            checks["oneOwnedNativeReviewCompleted"] = True
            checks["temporaryAuthRemovedBeforeSignedReads"] = auth_removed
            checks["persistedOriginalDescriptorDiscovered"] = True
            checks["descriptorDiscoveryReaderStopped"] = source_lifetime["descriptorReaderStopped"]
            checks["sourcePinnedBeforeSignedRead"] = True
            stage_reports = []
            manifest_digest = None
            for index, stage in enumerate(STAGES, 1):
                phase = "signed-" + stage
                require(owner.process.poll() is None and source_lifetime["producerStopped"], "fresh-owner-or-source-lost")
                name = "worker" + str(index)
                worker = setup.ReportProcess(worker_command(binary, root, name, home=home, descriptor=descriptor_path,
                    reader=reader, version=version, stage=stage))
                workers.append(worker)
                lifecycle.process_handoff(root, name + "-process-private.json", worker.process, "loaded-vault-worker")
                result = worker.wait_report(root / (name + "-report.json"), lambda value: stage_gate(value, stage, descriptor),
                    "native-review-" + stage + "-unverified", timeout=180)
                if stage == "queue":
                    shared.write_new(root / "exit-with-pending", token)
                final = inventory.finish_worker(worker, root, name, lambda value: stage_gate(value, stage, descriptor))
                if stage == "queue":
                    (root / "exit-with-pending").unlink()
                observed_manifest = inventory.digest_values([final.get("recoveryManifestDigest")])
                require(observed_manifest is not None and len(observed_manifest) == 1
                    and final.get("recoveryManifestDigest") == result.get("recoveryManifestDigest")
                    and (manifest_digest is None or observed_manifest == manifest_digest), "manifest-changed")
                manifest_digest = observed_manifest
                stage_reports.append(state(final))
                require(source_snapshot(home, home_identity, native) == source, "owned-native-source-changed")
            report["workerStages"] = stage_reports
            require(sum(value["detectorScanCalls"] for value in stage_reports) == 2, "original-detector-scans-required")
            checks.update(pendingNativeInspectionDurable=True, coldPendingIdentityCiphertextAndInventoryUnchanged=True,
                originalNativeInputAndNullPhaseReplyFullReceipts=True, bothPresentationWarningsResolved=True,
                coldInventoryAndConsumedReceiptsUnchanged=True, coldActualRereadWithoutDetectorRescanOrDuplicates=True,
                threeDistinctWorkersNormalShutdown=len({worker.process.pid for worker in workers}) == 3,
                sourceUnchangedAfterAllWorkers=source_snapshot(home, home_identity, native) == source,
                ciphertextVerifiedAfterNormalShutdown=ciphertext_files(root),
                exactOwnedDescriptorUnchanged=shared.preflight.hash_file(root, descriptor_path.name, [0]) == descriptor_hash)
            successful = all(checks.values())
        except (OSError, ValueError, KeyError, TypeError, RuntimeError, TimeoutError, BufferError,
                subprocess.SubprocessError, producer.ProbeFailure) as error:
            report.update(unmetGate=error.gate if isinstance(error, shared.GateFailure) else phase,
                failureCategory="controlled-run-failure")
        finally:
            report["providerLaunchCount"] = source_lifetime["providerLaunchCount"]
            groups, shutdowns = inventory.cleanup_workers(workers, root)
            if source_lifetime["producerStopped"] and owned_home(home, home_identity):
                try:
                    auth_removed = remove_auth(home, home_identity)
                except (OSError, RuntimeError):
                    auth_removed = False
            readers_stopped = worker_readers_stopped(root, len(workers))
            checks["allWorkerReadersConfirmedStopped"] = readers_stopped
            checks["descriptorDiscoveryReaderStopped"] = source_lifetime["descriptorReaderStopped"]
            normal = readers_stopped and source_lifetime["descriptorReaderStopped"] and shared.safe_creator_cleanup(shutdowns,
                helper_stopped=helper_lifetime["stopped"] and source_lifetime["producerStopped"] and version_stopped,
                socket_absent=not (root / "protected-store/capture.sock").exists())
            home_removed = False
            if successful and normal and auth_removed:
                try:
                    require(owned_home(home, home_identity), "owned-home-replaced")
                    shutil.rmtree(home)
                    home_removed = setup.provider_home_absent(home)
                except (OSError, RuntimeError):
                    pass
            authorized = normal and auth_removed
            owner_report, retained, owner_stopped, handoff_failed = inventory.finish_creator(owner, root, token,
                ready_observed=owner_ready, authorized=authorized, groups=groups)
            report.update(originalCreatorRetainedForCleanup=retained, creatorRetentionHandoffWriteFailed=handoff_failed,
                ownedProtectionCleanupPending=owner is not None and owner_report.get("cleanupPassed") is not True,
                ownedSourceRetainedPrivately=not setup.provider_home_absent(home), temporaryAuthenticationRemoved=auth_removed)
            if setup.owner_failure_summary(owner_report):
                report["ownerFailureDiagnostic"] = setup.owner_failure_summary(owner_report)
            checks["temporaryAuthenticationRemoved"] = auth_removed
            checks["ownedProviderHomeRemoved"] = home_removed
            checks["creatorCleanupAuthorizedAfterNormalSourceShutdown"] = authorized
            checks["originalFreshCreatorCleanupPassed"] = (owner_report.get("createdFreshVault") is True
                and owner_report.get("cleanupPassed") is True)
            checks["ownedProcessGroupsStopped"] = (not retained and owner_stopped and source_lifetime["producerStopped"]
                and source_lifetime["descriptorReaderStopped"]
                and helper_lifetime["stopped"] and version_stopped and all(row["groupStopped"] for row in shutdowns) and bool(groups)
                and all(row.get("term_permission_denied") is False and row.get("kill_permission_denied") is False for row in groups))
            checks["noAppDiagnosticsOrOutput"] = all(not any(process.counts.values()) for process in workers + ([owner] if owner else []))
            try:
                checks["readerExecutableUnchanged"] = shared.preflight.hash_file(reader.parent, reader.name, [0]) == reader_hash
                checks["candidateAndProductionInputsUnchanged"] = shared.preflight.check(manifest, app, ROOT)["consistent"]
                checks["candidateManifestBytesUnchanged"] = shared.preflight.hash_file(manifest_path.parent, manifest_path.name, [0]) == manifest_hash
                checks["runnerAndLibraryBytesUnchanged"] = runner_hashes() == inputs
                checks["discoveryTestArtifactsUnchanged"] = recovery.artifact_hashes(args.scratch_path) == test_artifacts
                checks["originalAuthenticationFileUnchanged"] = (auth_hash is not None
                    and hashlib.sha256(shared.private_bytes(args.auth_file)).hexdigest() == auth_hash)
            except (OSError, ValueError, RuntimeError, producer.ProbeFailure):
                checks["finalBoundaryChecksPassed"] = False
            report["result"] = {"newVaultCleanupPassed": checks["originalFreshCreatorCleanupPassed"],
                "fullReceiptCount": state(final).get("analysisReceiptCount"), "occurrenceCount": state(final).get("occurrenceCount"),
                "queueCount": final.get("queueCount"), "gapReasons": final.get("gapReasons")}
            report["passed"] = successful and "unmetGate" not in report and completed_checks(checks)
            report["signedReviewReceiptInspectionRestartAndReplayEstablished"] = report["passed"]
            report["knownSecretRecallEstablished"] = report["passed"]
            report["finishedAtUnixSeconds"] = time.time()
    return 0 if artifacts.passed else 1


def main(argv=None):
    try:
        return run(arguments(argv))
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError, producer.ProbeFailure):
        # Unexpected finalization failures can also reach here after a launch.
        # The retained run artifacts, not this fallback, describe exact cleanup.
        print(json.dumps({"schemaVersion": 1, "passed": False, "status": "runner-unavailable", "cleanupEstablished": False}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
