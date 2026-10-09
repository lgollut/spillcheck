#!/usr/bin/env python3
"""Genuine owned Claude upgrade and signed process restart against one disposable vault."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests"))
from Support.acceptance_artifacts import AcceptanceArtifacts
from Support.processes import stop_group

spec = importlib.util.spec_from_file_location("signed_claude_live", Path(__file__).with_name("run-app-claude-live.py"))
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)
fixture = live.fixture


class OwnerSmokeCompleted(Exception):
    """Enter shared exact-owned cleanup after the short signed lifetime check."""


class RecoveryGateFailure(RuntimeError):
    """A controlled code-owned gate label; never an arbitrary subprocess error string."""
    def __init__(self, gate):
        super().__init__(gate)
        self.gate = gate


def signal_control(root, name, token):
    temporary = root / (name + ".new")
    temporary.write_bytes(token)
    os.chmod(temporary, 0o600)
    temporary.replace(root / name)


def require(value, gate):
    if not value:
        raise RecoveryGateFailure(gate)


def comparison(before, after, key):
    old, new = before.get(key), after.get(key)
    return isinstance(old, list) and bool(old) and isinstance(new, list) and set(old) <= set(new)


def public_snapshot(report):
    # The challenge is private instrumentation. Keyed identity digests are used only privately
    # for comparisons; published evidence contains their controlled comparison results.
    return {key: value for key, value in report.items()
            if not key.startswith("recovery") and key != "processID"}


def fixed_rebuild_command(repository, app):
    """The migration trial rebuilds only the repository's existing Debug bundle."""
    expected = repository / ".build/app/Build/Products/Debug/Spillcheck.app"
    require(app == expected.resolve(), "migrationRequiresRepositoryDebugBundle")
    return [str(repository / "scripts/build-app.sh"), "--configuration", "Debug",
            "--derived-data", str(repository / ".build/app")]


def migration_schema_observed(report):
    return report.get("recoveryProfileSchemaMeasurementAvailable") is True \
        and type(report.get("recoveryLoadedProfileSchemaVersion")) is int \
        and report["recoveryLoadedProfileSchemaVersion"] == 2 \
        and type(report.get("recoverySavedProfileSchemaVersion")) is int \
        and report["recoverySavedProfileSchemaVersion"] == 3


def source_snapshot(repository):
    paths = [path for name in ["Sources", "Spillcheck"]
             for path in (repository / name).rglob("*.swift")]
    paths.extend(repository / name for name in ["Package.swift", "Package.resolved", "project.yml",
        "Spillcheck.xcodeproj/project.pbxproj", "scripts/build-app.sh",
        "Tests/AppAcceptance/run-app-claude-recovery.py"] if (repository / name).exists())
    require(0 < len(paths) <= 1024, "frozenSourceSnapshotBoundsExceeded")
    require(all(not path.is_symlink() and path.is_file() for path in paths), "frozenSourceHasUnexpectedFileType")
    require(sum(path.stat().st_size for path in paths) <= 32 * 1024 * 1024, "frozenSourceByteBoundExceeded")
    return {str(path.relative_to(repository)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(paths)}


def bundle_digest(app):
    """Hash bounded signed artifacts without following an external bundle symlink."""
    files = sorted(app.rglob("*"))
    require(0 < len(files) <= 2048, "signedBundleFileBoundExceeded")
    require(all(not path.is_symlink() or path.resolve().is_relative_to(app) for path in files),
            "signedBundleHasExternalSymlink")
    require(sum(path.stat().st_size for path in files if path.is_file()) <= 512 * 1024 * 1024,
            "signedBundleByteBoundExceeded")
    hashes = [(str(path.relative_to(app)), hashlib.sha256(path.read_bytes()).hexdigest())
              for path in files if path.is_file()]
    return hashlib.sha256(json.dumps(hashes, separators=(",", ":")).encode()).hexdigest()


def signature_bindings(app):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                   check=True, capture_output=True, timeout=30)
    bindings = {}
    for name, path in [("app", app), ("helper", app / "Contents/Helpers/spillcheck-hook")]:
        requirements = subprocess.run(["/usr/bin/codesign", "-d", "-r-", str(path)],
                                     check=True, capture_output=True, timeout=10)
        designated = [line for line in (requirements.stdout + requirements.stderr).decode().splitlines()
                      if line.startswith("designated => ")]
        require(len(designated) == 1, "signedDesignatedRequirementUnavailable")
        entitlements = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(path)],
                                     check=True, capture_output=True, timeout=10).stdout
        bindings[name] = {"designatedRequirement": hashlib.sha256(designated[0].encode()).hexdigest(),
                          "entitlements": plistlib.loads(entitlements) if entitlements.strip() else {}}
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    bindings["keychainAccessGroup"] = info.get("SpillcheckKeychainAccessGroup")
    require(isinstance(bindings["keychainAccessGroup"], str) and bool(bindings["keychainAccessGroup"]),
            "signedKeychainAccessGroupUnavailable")
    return bindings


def owned_registration(settings, helper, store):
    """Accept only this fresh home's exact production handler marker and argv."""
    data = json.loads(settings.read_text())
    registrations = set()
    expected = ["--socket", str(store / "capture.sock"), "--agent", "claude-code",
                "--interface", "standalone-cli", "--profile-id", "owned-signed-claude-recovery"]
    for groups in data.get("hooks", {}).values():
        for group in groups:
            for handler in group.get("hooks", []):
                marker = handler.get("statusMessage", "")
                match = re.fullmatch(r"Spillcheck hook ([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})", marker)
                if match:
                    require(handler.get("command") == str(helper) and handler.get("args") == expected,
                            "ownedRegistrationHandlerChanged")
                    registrations.add(match.group(1))
    require(len(registrations) == 1, "exactOwnedRegistrationUnavailableForRemoval")
    return registrations.pop()


RECOVERY_CHECKS = {
    "proofAndRegistrationSurviveUpgrade", "genuineRequiredTypesFromBothProducersCommitted",
    "upgradePreservesOriginalInventoryAndReceipts", "firstWorkerExitedWithEncryptedPendingWork",
    "actualCollectorProcessRestart", "sameVaultLoadedWithoutCreatingReplacementKeys",
    "savedSetupProofAndRegistrationSurviveRestart", "restartPreservesInventoryReceiptsAndAlerts",
    "restartReplayAddsNoOccurrencesReceiptsOrAlerts", "persistedCheckpointIdentitiesLoaded",
    "noPersistedCoverageGaps", "nativeRequiredContentAndFraming", "producerInstallationsUnchanged",
    "encryptedMarkerInspection", "originalNativeSourcesUnchanged", "originalFreshCreatorCleanupPassed", "ownedRegistrationRemoved",
    "temporaryAuthenticationRemoved", "ownedProcessGroupsStopped", "automaticUpgradeAndRestartAuditsSettled",
    "exactPendingCapturesSuccessfullyProcessedAfterRestart", "nativeChildPromptAndFinalCommittedForBothProducers"
}
SMOKE_CHECKS = {"freshOwnerCreatedVault", "workerLoadedExistingVault", "workerExitedBeforeCleanup",
                "originalFreshCreatorCleanupPassed", "ownedRegistrationRemoved",
                "temporaryAuthenticationRemoved", "ownedProcessGroupsStopped"}
MIGRATION_CHECKS = {"oldSignedCreatorRetainedThroughBuild", "buildOccurredBetweenWorkerLifetimes",
                   "fixedSignedBundleRebuilt", "appAndHelperSigningBindingsPreserved",
                   "productionSourcesFrozenThroughMigration", "encryptedProfileSchema2MigratedTo3"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--app", type=Path, default=ROOT / ".build/app/Build/Products/Debug/Spillcheck.app")
    parser.add_argument("--starting-executable", required=True)
    parser.add_argument("--upgraded-executable", default="claude")
    parser.add_argument("--expected-starting-version", default="2.1.293")
    parser.add_argument("--expected-upgraded-version", default="2.1.295")
    parser.add_argument("--configuration-executable", type=Path, default=ROOT / ".build/debug/spillcheck-storage-acceptance")
    parser.add_argument("--owner-smoke", action="store_true", help="Only validate fresh creator / signed worker / exact cleanup lifetime.")
    parser.add_argument("--rebuild-app-between-workers", action="store_true",
                        help="Build the fixed repository Debug bundle after worker1 exits; require encrypted profile schema 2 to migrate to 3.")
    args = parser.parse_args()
    os.umask(0o077)
    app = args.app.resolve()
    rebuild_command = fixed_rebuild_command(ROOT, app) if args.rebuild_app_between_workers else None
    require(not (args.owner_smoke and args.rebuild_app_between_workers), "migrationRequiresFullGenuineRun")
    binary = app / "Contents/MacOS/Spillcheck"
    helper = app / "Contents/Helpers/spillcheck-hook"
    starting = Path(shutil.which(args.starting_executable) or args.starting_executable).resolve()
    upgraded = Path(shutil.which(args.upgraded_executable) or args.upgraded_executable).resolve()
    version = lambda executable: subprocess.check_output([str(executable), "--version"], text=True).split()[0]
    old_version, new_version = version(starting), version(upgraded)
    require(old_version == args.expected_starting_version and new_version == args.expected_upgraded_version
            and old_version != new_version, "genuineDistinctProducerVersionsUnavailable")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    with AcceptanceArtifacts("spillcheck-app-claude-recovery-", args.output) as artifacts:
        root = artifacts.directory
        token = os.urandom(32)
        (root / "run-token").write_bytes(token)
        config, project = root / "claude", root / "project"
        (config / "projects").mkdir(parents=True)
        project.mkdir()
        selected = root / "selected-claude"
        selected.symlink_to(starting)
        mcp = root / "mcp.json"
        mcp.write_text(json.dumps({"mcpServers": {"spillcheck_synthetic": {"command": "/usr/bin/python3",
            "args": [str(ROOT / "Tests/ClaudeLive/mcp_fixture.py")]}}}))
        env = dict(os.environ, DISABLE_AUTOUPDATER="1")
        store = root / "protected-store"
        processes, streams, provider_runs, process_cleanups = [], [], [], []
        owner = worker1 = worker2 = None
        removal_passed = False
        checks = {}
        final = {}
        native = {}
        before_restart = {}
        owner_report = {}
        transition = {"requested": args.rebuild_app_between_workers, "buildStarted": False}
        sources_before = None
        bindings_before = None
        owner_binary = binary
        phase = "start"

        def command(report, finish):
            return [str(binary), "--store-directory", str(store), "--acceptance-recovery-root", str(root),
                "--acceptance-recovery-token", str(root / "run-token"), "--acceptance-report", str(root / report),
                "--acceptance-finish-file", str(root / finish), "--acceptance-seconds", "120", "--acceptance-hold"]

        def launch(arguments, name, cwd=None):
            out = (root / (name + "-stdout.bin")).open("wb")
            err = (root / (name + "-stderr.bin")).open("wb")
            streams.extend([out, err])
            process = subprocess.Popen(arguments, stdout=out, stderr=err, start_new_session=True, cwd=cwd)
            processes.append(process)
            return process

        def wait(process, report, predicate, gate, timeout=45):
            result = live.wait_for_report(process, root / report, predicate, timeout)
            require(predicate(result), gate)
            return result

        try:
            phase = "existing-app-admission"
            require(subprocess.run(["/usr/bin/pgrep", "-x", "Spillcheck"], capture_output=True).returncode != 0,
                    "existingSpillcheckProcessPreventsOwnedRun")
            if args.rebuild_app_between_workers:
                phase = "retain-old-signed-creator"
                sources_before = source_snapshot(ROOT)
                bindings_before = signature_bindings(app)
                transition.update(frozenSourceFileCount=len(sources_before),
                                  frozenSwiftSourceFileCount=sum(path.endswith(".swift") for path in sources_before),
                                  oldSignedBundleDigest=bundle_digest(app))
                (root / "migration-source-hashes-before.json").write_text(json.dumps(sources_before, sort_keys=True))
                owner_app = root / "original-owner.app"
                shutil.copytree(app, owner_app, symlinks=True)
                require(signature_bindings(owner_app) == bindings_before
                        and bundle_digest(owner_app) == transition["oldSignedBundleDigest"], "oldCreatorCopyChangedSignedArtifacts")
                owner_binary = owner_app / "Contents/MacOS/Spillcheck"
            phase = "fresh-vault-owner"
            owner_arguments = command("owner-report.json", "owner-finish") + ["--acceptance-vault-owner"]
            owner_arguments[0] = str(owner_binary)
            owner = launch(owner_arguments, "owner")
            wait(owner, "owner-report.json", lambda r: r.get("ownerReady") and r.get("createdFreshVault"), "freshVaultOwnerUnavailable")
            if args.owner_smoke:
                checks["freshOwnerCreatedVault"] = True
                worker1 = launch(command("worker1-report.json", "worker1-finish") + ["--acceptance-recovery-worker",
                    "--acceptance-no-profile-catchup"], "worker1")
                loaded = wait(worker1, "worker1-report.json", lambda r: r.get("storageReady")
                    and r.get("recoveryLoadedExistingManifest") is True and bool(r.get("recoveryManifestDigest")),
                    "signedWorkerCannotLoadFreshOwnerVault")
                checks["workerLoadedExistingVault"] = loaded.get("recoveryLoadedExistingManifest") is True
                (root / "worker1-finish").touch()
                worker1.wait(timeout=35)
                checks["workerExitedBeforeCleanup"] = worker1.returncode == 0
                final = live.read_report(root / "worker1-report.json")
                return_after_smoke = True
            else:
                return_after_smoke = False
                fixture.authentication(env, config)
            if return_after_smoke:
                # A local control-flow sentinel enters the common lifetime cleanup below.
                raise OwnerSmokeCompleted()
            phase = "first-signed-worker"
            worker1 = launch(command("worker1-report.json", "worker1-finish") + ["--acceptance-recovery-worker",
                "--acceptance-recovery-install-profile", "--acceptance-recovery-home", str(config),
                "--acceptance-recovery-executable", str(selected), "--acceptance-recovery-version", old_version], "worker1")
            ready = wait(worker1, "worker1-report.json", lambda r: r.get("storageReady") and r.get("collectionConfigured")
                         and isinstance(r.get("recoveryVerificationPrompt"), str), "ownedSetupChallengeUnavailable")
            provider_runs.append(fixture.run_provider(selected, ready["recoveryVerificationPrompt"], env, project, mcp))
            require(provider_runs[-1]["exitCode"] == 0, "genuineSetupChallengeFailed")
            wait(worker1, "worker1-report.json", lambda r: r.get("recoverySavedSetupConnected") is True,
                 "durableSignedConnectionProofUnavailable")
            provider_runs.append(fixture.run_provider(selected, fixture.PROMPT, env, project, mcp))
            require(provider_runs[-1]["exitCode"] == 0, "startingGenuineContentFailed")
            baseline = live.settled_report(worker1, root / "worker1-report.json")
            require(baseline.get("queueCount") == 0 and baseline.get("syntheticValuePresent")
                    and baseline.get("unreadHistoricalProgressCount") == 0
                    and baseline.get("settledHistoricalAuditCount", 0) > 0, "startingInventoryUnsettled")
            original_paths, original_native = live.native_evidence(config)
            require(bool(original_paths) and original_native.get("requiredNativeFieldsValid") is True,
                    "startingNativeSourcesUnavailable")
            original_signatures = {str(path): (session, hashlib.sha256(path.read_bytes()).digest())
                                   for path, session in original_paths}
            phase = "in-place-owned-executable-upgrade"
            replacement = root / "replacement-claude"
            replacement.symlink_to(upgraded)
            replacement.replace(selected)
            upgraded_state = wait(worker1, "worker1-report.json", lambda r: r.get("recoveryObservedExecutableVersion") == new_version
                                  and r.get("recoverySavedSetupConnected") is True, "automaticUpgradeAssessmentUnavailable")
            checks["proofAndRegistrationSurviveUpgrade"] = all(baseline.get(k) and baseline[k] == upgraded_state.get(k)
                for k in ["recoveryConnectionProofDigest", "recoveryRegistrationDigest"])
            provider_runs.append(fixture.run_provider(selected, fixture.PROMPT, env, project, mcp))
            require(provider_runs[-1]["exitCode"] == 0, "upgradedGenuineContentFailed")
            before_restart = live.settled_report(worker1, root / "worker1-report.json")
            before_restart = wait(worker1, "worker1-report.json", lambda r: r.get("queueCount") == 0
                and r.get("unreadHistoricalProgressCount") == 0
                and r.get("settledHistoricalAuditCount", 0) > baseline["settledHistoricalAuditCount"],
                "automaticUpgradeAuditUnsettled")
            required = {"userPrompt", "intermediateResponse", "finalResponse", "toolOutput", "toolError"}
            committed = before_restart.get("syntheticOccurrencesByProducerVersionAndContentType", {})
            checks["genuineRequiredTypesFromBothProducersCommitted"] = all(
                isinstance(committed.get(v, {}).get(kind), int) and committed[v][kind] > 0
                for v in [old_version, new_version] for kind in required)
            children = before_restart.get("recoveryNativeChildTypesByProducer", {})
            checks["nativeChildPromptAndFinalCommittedForBothProducers"] = all(
                isinstance(children.get(version, {}).get(kind), int) and children[version][kind] > 0
                for version in [old_version, new_version] for kind in ["userPrompt", "finalResponse"])
            checks["upgradePreservesOriginalInventoryAndReceipts"] = all(comparison(baseline, before_restart, k)
                for k in ["recoveryOccurrenceDigests", "recoveryReceiptDigests", "recoveryAlertDigests"])
            phase = "preserve-encrypted-pending-work"
            signal_control(root, "stop-processing", token)
            wait(worker1, "worker1-report.json", lambda r: r.get("recoveryProcessingStopped") is True
                 and r.get("queueCount") == 0, "collectorBarrierUnavailable")
            provider_runs.append(fixture.run_provider(selected, f"Respond exactly LEAKRET_M3_FINAL {fixture.SECRET}. Synthetic test data.", env, project, mcp))
            require(provider_runs[-1]["exitCode"] == 0, "genuinePendingCaptureFailed")
            pending = wait(worker1, "worker1-report.json", lambda r: r.get("queueCount", 0) > 0
                           and r.get("recoveryEncryptedQueueBytes", 0) > 0 and r.get("recoveryQueueClaimedCount") == 0,
                           "durableUnclaimedEncryptedCaptureUnavailable")
            signal_control(root, "exit-with-pending", token)
            worker1.wait(timeout=35)
            require(worker1.returncode == 0, "firstWorkerShutdownFailed")
            stopped = live.read_report(root / "worker1-report.json")
            checks["firstWorkerExitedWithEncryptedPendingWork"] = stopped.get("queueCount", 0) >= pending["queueCount"] \
                and stopped.get("recoveryEncryptedQueueBytes", 0) > 0 and stopped.get("recoveryQueueClaimedCount") == 0
            require(stopped.get("recoveryCaptureIdentityMeasurementAvailable") is True
                    and bool(stopped.get("recoveryPendingCaptureDigests")), "exactPendingQueueIdentityUnavailable")
            (root / "stop-processing").unlink()
            (root / "exit-with-pending").unlink()
            if args.rebuild_app_between_workers:
                phase = "signed-app-schema-migration-build"
                require(worker1.poll() == 0 and owner.poll() is None, "workerOrCreatorLifetimeInvalidBeforeBuild")
                require(source_snapshot(ROOT) == sources_before, "sourceChangedBeforeMigrationBuild")
                transition["buildStarted"] = True
                build_start = time.monotonic()
                # No provider environment or configurable shell command enters the build.
                # All diagnostics stay in this run's exact private root.
                built = launch(rebuild_command, "between-workers-build", cwd=ROOT)
                built.wait(timeout=300)
                transition.update(buildExitCode=built.returncode,
                                  buildElapsedMilliseconds=round((time.monotonic() - build_start) * 1000))
                require(built.returncode == 0, "betweenWorkersSignedBuildFailed")
                require(owner.poll() is None and worker1.poll() == 0, "originalCreatorLostDuringBuild")
                checks["oldSignedCreatorRetainedThroughBuild"] = signature_bindings(owner_app) == bindings_before
                checks["buildOccurredBetweenWorkerLifetimes"] = worker1.poll() == 0 and worker2 is None
                checks["appAndHelperSigningBindingsPreserved"] = signature_bindings(app) == bindings_before
                transition["newSignedBundleDigest"] = bundle_digest(app)
                checks["fixedSignedBundleRebuilt"] = transition["newSignedBundleDigest"] != transition["oldSignedBundleDigest"]
                sources_after = source_snapshot(ROOT)
                (root / "migration-source-hashes-after.json").write_text(json.dumps(sources_after, sort_keys=True))
                checks["productionSourcesFrozenThroughMigration"] = sources_after == sources_before
                require(all(checks[key] for key in MIGRATION_CHECKS - {"encryptedProfileSchema2MigratedTo3"}),
                        "signedBuildTransitionEvidenceFailed")
            phase = "cold-signed-process-restart"
            worker2 = launch(command("worker2-report.json", "worker2-finish") + ["--acceptance-recovery-worker"], "worker2")
            recovered = wait(worker2, "worker2-report.json", lambda r: r.get("storageReady") and r.get("collectionConfigured")
                             and r.get("queueCount") == 0 and r.get("unreadHistoricalProgressCount") == 0
                             and r.get("settledHistoricalAuditCount", 0) > before_restart.get("settledHistoricalAuditCount", 0)
                             and r.get("syntheticOccurrenceCount", 0) > before_restart.get("syntheticOccurrenceCount", 0)
                             and r.get("recoveryCaptureIdentityMeasurementAvailable") is True
                             and (not args.rebuild_app_between_workers or migration_schema_observed(r))
                             and all(comparison(stopped, {"recoveryPendingCaptureDigests": r.get(key)},
                                                "recoveryPendingCaptureDigests") for key in
                                     ["recoveryConsumedCaptureDigests", "recoverySuccessfullyProcessedCaptureDigests"]),
                             "coldRestartPendingWorkRecoveryUnavailable", timeout=60)
            if args.rebuild_app_between_workers:
                checks["encryptedProfileSchema2MigratedTo3"] = migration_schema_observed(recovered)
                transition.update(loadedProfileSchemaVersion=recovered["recoveryLoadedProfileSchemaVersion"],
                                  savedProfileSchemaVersion=recovered["recoverySavedProfileSchemaVersion"],
                                  profileSchemaMeasurementAvailable=True)
            checks["automaticUpgradeAndRestartAuditsSettled"] = True
            checks["exactPendingCapturesSuccessfullyProcessedAfterRestart"] = all(comparison(stopped,
                {"recoveryPendingCaptureDigests": recovered.get(key)}, "recoveryPendingCaptureDigests")
                for key in ["recoveryConsumedCaptureDigests", "recoverySuccessfullyProcessedCaptureDigests"])
            checks["actualCollectorProcessRestart"] = worker1.pid != worker2.pid and worker1.poll() is not None
            checks["sameVaultLoadedWithoutCreatingReplacementKeys"] = recovered.get("recoveryLoadedExistingManifest") is True \
                and before_restart.get("recoveryManifestDigest") == recovered.get("recoveryManifestDigest")
            checks["savedSetupProofAndRegistrationSurviveRestart"] = recovered.get("recoverySavedSetupConnected") is True \
                and all(before_restart.get(k) and before_restart[k] == recovered.get(k)
                        for k in ["recoveryConnectionProofDigest", "recoveryRegistrationDigest"])
            checks["restartPreservesInventoryReceiptsAndAlerts"] = all(comparison(before_restart, recovered, k)
                for k in ["recoveryOccurrenceDigests", "recoveryReceiptDigests", "recoveryAlertDigests"])
            paths, native = live.native_evidence(config)
            after_signatures = {str(path): (session, hashlib.sha256(path.read_bytes()).digest()) for path, session in paths}
            checks["originalNativeSourcesUnchanged"] = bool(original_signatures) and all(
                after_signatures.get(path) == signature for path, signature in original_signatures.items())
            replay_before = live.settled_report(worker2, root / "worker2-report.json")
            replay_codes = []
            for interface in ["standalone-cli", "t3"]:
                for path, session in paths:
                    payload = json.dumps({"hook_event_name": "SpillcheckTranscriptPoll", "session_id": session,
                                          "transcript_path": str(path)}).encode()
                    replay = subprocess.run([str(helper), "--socket", str(store / "capture.sock"), "--agent", "claude-code",
                        "--interface", interface, "--profile-id", "owned-signed-claude-recovery"], input=payload,
                        capture_output=True, timeout=5)
                    replay_codes.append(replay.returncode)
            replay_after = live.settled_report(worker2, root / "worker2-report.json")
            checks["restartReplayAddsNoOccurrencesReceiptsOrAlerts"] = bool(replay_codes) and all(c == 0 for c in replay_codes) \
                and replay_after.get("queueCount") == 0 and all(replay_before.get(k) == replay_after.get(k)
                    for k in ["recoveryOccurrenceDigests", "recoveryReceiptDigests", "recoveryAlertDigests"])
            checks["persistedCheckpointIdentitiesLoaded"] = comparison(before_restart,
                {"recoveryCheckpointDigests": replay_after.get("recoveryLoadedCheckpointDigests")}, "recoveryCheckpointDigests")
            checks["noPersistedCoverageGaps"] = before_restart.get("gapReasons") == [] and replay_after.get("gapReasons") == []
            checks["nativeRequiredContentAndFraming"] = native.get("requiredNativeFieldsValid") is True \
                and native.get("completeJSONLFraming") is True and all(
                    set(fixture.EXPECTED_MARKERS) <= set(native.get("typedMarkersByProducer", {}).get(producer, []))
                    for producer in [old_version, new_version])
            (root / "worker2-finish").touch()
            worker2.wait(timeout=35)
            require(worker2.returncode == 0, "restartedWorkerShutdownFailed")
            final = live.read_report(root / "worker2-report.json")
            if args.rebuild_app_between_workers:
                checks["productionSourcesFrozenThroughMigration"] = source_snapshot(ROOT) == sources_before
            checks["producerInstallationsUnchanged"] = version(starting) == old_version and version(upgraded) == new_version
            checks["encryptedMarkerInspection"] = all(fixture.SECRET.encode() not in path.read_bytes()
                for path in store.rglob("*") if path.is_file())
        except OwnerSmokeCompleted:
            pass
        except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
            artifacts.report.update(unmetGate=phase, failureCategory=type(error).__name__)
            if isinstance(error, RecoveryGateFailure):
                artifacts.report["unmetCheck"] = error.gate
        finally:
            # Stop only process groups launched by this run before authorizing exact creator cleanup.
            collectors_stopped = True
            for process in processes:
                if process is not owner:
                    try:
                        process_cleanups.append(stop_group(process))
                        collectors_stopped = collectors_stopped and process.poll() is not None
                    except RuntimeError:
                        collectors_stopped = False
            settings = config / "settings.json"
            try:
                if not settings.exists():
                    removal_passed = True
                else:
                    registration = owned_registration(settings, helper, store)
                    removed = subprocess.run([str(args.configuration_executable.resolve()), "--claude-configure-hook",
                        "--remove-hook", "--settings", str(settings), "--helper", str(helper), "--socket", str(store / "capture.sock"),
                        "--profile", "owned-signed-claude-recovery", "--version", new_version, "--registration-id", registration],
                        capture_output=True, timeout=10)
                    remaining = json.loads(settings.read_text()).get("hooks", {})
                    removal_passed = removed.returncode == 0 and not remaining
            except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError):
                removal_passed = not settings.exists()
            if collectors_stopped and removal_passed and owner is not None and owner.poll() is None:
                signal_control(root, "owner-finish", token)
                try:
                    owner.wait(timeout=35)
                except subprocess.TimeoutExpired:
                    stop_group(owner)
            if owner is not None:
                try:
                    process_cleanups.append(stop_group(owner))
                except RuntimeError:
                    collectors_stopped = False
            owner_report = live.read_report(root / "owner-report.json")
            for stream in streams:
                stream.close()
            shutil.rmtree(config, ignore_errors=True)
            env.pop("CLAUDE_CODE_OAUTH_TOKEN", None)
        checks["originalFreshCreatorCleanupPassed"] = owner is None or owner_report.get("cleanupPassed") is True
        checks["ownedRegistrationRemoved"] = removal_passed
        checks["temporaryAuthenticationRemoved"] = not config.exists()
        cleanups = process_cleanups + [run.get("processGroupCleanup", {}) for run in provider_runs]
        checks["ownedProcessGroupsStopped"] = collectors_stopped and all(
            cleanup.get("term_permission_denied") is False and cleanup.get("kill_permission_denied") is False
            for cleanup in cleanups)
        required_checks = SMOKE_CHECKS if args.owner_smoke else RECOVERY_CHECKS
        if args.rebuild_app_between_workers:
            required_checks = required_checks | MIGRATION_CHECKS
        passed = required_checks <= set(checks) and all(checks.values()) and "unmetGate" not in artifacts.report
        artifacts.report.update(schemaVersion=1, startingProducerVersion=old_version, upgradedProducerVersion=new_version,
            checks=checks, providerRuns=provider_runs, nativeSourceEvidence=native, result={**public_snapshot(final),
                "newVaultCleanupPassed": owner_report.get("cleanupPassed") is True},
            committedContentBeforeRestart=before_restart.get("syntheticOccurrencesByProducerVersionAndContentType", {}),
            committedNativeChildContentBeforeRestart=before_restart.get("recoveryNativeChildTypesByProducer", {}),
            passed=passed, ownerLifetimeSmokeOnly=args.owner_smoke,
            appBuildTransition=transition,
            freshCreatorLaunched=owner is not None,
            signedAppSchema2To3MigrationEstablished=passed and args.rebuild_app_between_workers,
            diagnosticArtifactsRetained=not passed,
            ownedProtectionCleanupPending=owner is not None and owner_report.get("cleanupPassed") is not True,
            signedCLIUpgradeAndRestartEstablished=passed and not args.owner_smoke,
            genuineGUIOrT3ConcurrencyEstablished=False, requiredFormatFailureRestorationEstablished=False,
            reviewAndObsoleteStateRecoveryEstablished=False,
            actualHealthNotificationDeliveryEstablished=False)
    return 0 if artifacts.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
