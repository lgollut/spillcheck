#!/usr/bin/env python3
"""Genuine disposable Claude sessions through owned hooks into the signed app.

Provider transcripts remain the sole content authority. Reports contain controlled
metadata and counts. Failed runs retain owned synthetic sources after authentication
and configuration cleanup. Successful runs remove the entire disposable root.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests"))
sys.path.insert(0, str(ROOT / "Tests/BetaTrial"))
import preflight
from Support.acceptance_artifacts import AcceptanceArtifacts
from Support.processes import stop_group
from Support.claude_native_evidence import inspect_disposable_native_sources

spec = importlib.util.spec_from_file_location("claude_live_fixture", ROOT / "Tests/ClaudeLive/run.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def candidate_arguments(parser):
    parser.add_argument("--candidate-manifest", type=Path)
    parser.add_argument("--expected-bundle-sha256")


def candidate_admission(parser, args):
    if (args.candidate_manifest is None) != (args.expected_bundle_sha256 is None):
        parser.error("--candidate-manifest and --expected-bundle-sha256 must be supplied together")
    if args.output.exists() or args.output.is_symlink():
        parser.error("--output must be a fresh path")


def candidate_snapshot(manifest_path, expected_digest, app):
    """Bind the selected candidate to stable recorded source inputs and signed bytes."""
    if manifest_path is None:
        return None
    before = preflight.hash_file(manifest_path.parent, manifest_path.name, [0])
    manifest = preflight.read_manifest(manifest_path)
    if manifest["bundleSHA256"] != preflight.digest_value(expected_digest):
        raise ValueError("candidateBundleDigestMismatch")
    checked = preflight.check(manifest, app, ROOT)
    after = preflight.hash_file(manifest_path.parent, manifest_path.name, [0])
    if before != after or checked.get("consistent") is not True:
        raise ValueError("candidatePreflightFailed")
    return {"manifestSHA256": before, "bundleSHA256": manifest["bundleSHA256"],
            "executableSHA256": manifest["executableSHA256"], "recordedCandidateConsistencyPassed": True,
            "completeBuildProvenanceVerified": False, "signatureIdentityVerified": False}


def read_report(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def wait_for_report(process, path, predicate, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        report = read_report(path)
        if predicate(report):
            return report
        if process.poll() is not None:
            return report
        time.sleep(0.2)
    return read_report(path)


def settled_report(process, path, timeout=45):
    previous = None
    stable = 0
    def settled(report):
        nonlocal previous, stable
        state = tuple(report.get(key) for key in ("occurrenceCount", "alertCount", "syntheticOccurrenceCount"))
        if report.get("queueCount") == 0 and report.get("syntheticValuePresent"):
            stable = stable + 1 if state == previous else 0
            previous = state
            return stable >= 12
        stable = 0
        return False
    return wait_for_report(process, path, settled, timeout)


def native_evidence(config):
    """Inspect this fresh disposable home's exact parents and own child files."""
    return inspect_disposable_native_sources(config / "projects", fixture.SECRET)


def remove_provider_authentication(config, env):
    """Retain only owned projects for failed-run diagnosis; never reuse them as config."""
    try:
        return fixture.remove_temporary_authentication(config)
    finally:
        env.pop("CLAUDE_CODE_OAUTH_TOKEN", None)


def strict_role_coverage_complete(result):
    if not all(result.get(key) is True for key in ("claudeIndividualRoleCoverageMeasured", "claudeIndividualRoleCoveragePassed",
        "claudeNativeParentChildLinkVerified", "claudeRoleEvidenceWithinBudget")):
        return False
    producer_pairs = result.get("claudeCommittedNativeParentChildPairCountByProducer", {})
    if not isinstance(producer_pairs, dict) or not any(type(count) is int and count > 0 for count in producer_pairs.values()):
        return False
    markers = result.get("claudeTypedCommittedMarkersByRole", {})
    types = result.get("claudeCommittedContentTypesByRole", {})
    for role in ("parent", "child"):
        expected = {marker for marker in fixture.EXPECTED_MARKERS if marker.startswith("CHILD_") == (role == "child")}
        actual = markers.get(role, {})
        if (set(actual) != expected or not all(type(count) is int and count == 1 for count in actual.values())
            or set(types.get(role, [])) != set(fixture.EXPECTED_MARKERS.values())):
            return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--app", type=Path, default=ROOT / ".build/app/Build/Products/Debug/Spillcheck.app")
    parser.add_argument("--executable", default="claude")
    parser.add_argument("--expected-version")
    parser.add_argument("--historical-producer-executable", help="Genuine older producer, invoked as CLI before the signed reader starts.")
    parser.add_argument("--expected-historical-version")
    parser.add_argument("--configuration-executable", type=Path, default=ROOT / ".build/debug/spillcheck-storage-acceptance")
    candidate_arguments(parser)
    args = parser.parse_args()
    candidate_admission(parser, args)
    os.umask(0o077)
    app = args.app.resolve()
    helper = app / "Contents/Helpers/spillcheck-hook"
    executable = Path(shutil.which(args.executable) or args.executable).resolve()
    version = subprocess.check_output([str(executable), "--version"], text=True).split()[0]
    if args.expected_version is not None and version != args.expected_version:
        parser.error("selected executable does not match --expected-version")
    historical_executable, historical_version = None, None
    if args.historical_producer_executable:
        historical_executable = Path(shutil.which(args.historical_producer_executable) or args.historical_producer_executable).resolve()
        historical_version = subprocess.check_output([str(historical_executable), "--version"], text=True).split()[0]
        if args.expected_historical_version is not None and historical_version != args.expected_historical_version:
            parser.error("historical executable does not match --expected-historical-version")
    elif args.expected_historical_version is not None:
        parser.error("--expected-historical-version requires --historical-producer-executable")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    candidate_before = candidate_snapshot(args.candidate_manifest, args.expected_bundle_sha256, app)
    with AcceptanceArtifacts("spillcheck-app-claude-live-", args.output) as artifacts:
        artifacts.report.update(candidateBinding=candidate_before, candidateUnchanged=False)
        root = artifacts.directory
        config = root / "claude"
        (config / "projects").mkdir(parents=True)
        project = root / "project"
        project.mkdir()
        mcp = root / "mcp.json"
        mcp.write_text(json.dumps({"mcpServers": {"spillcheck_synthetic": {
            "command": "/usr/bin/python3", "args": [str(ROOT / "Tests/ClaudeLive/mcp_fixture.py")]}}}))
        env = dict(os.environ)
        env["DISABLE_AUTOUPDATER"] = "1"
        setup_args, removal = None, None
        hook_removal_attempted = False
        try:
            fixture.authentication(env, config)
            historical_runs, historical_signatures, historical_delivery = [], {}, None
            if historical_executable is not None:
                historical_runs.append(fixture.run_provider(historical_executable, fixture.PROMPT, env, project, mcp))
                _, historical_native = native_evidence(config)
                if (historical_runs[0]["exitCode"] != 0 or not historical_native["requiredNativeFieldsValid"]
                    or not historical_native["completeJSONLFraming"]
                    or historical_native.get("completeNativeParentChildPairCountByProducer", {}).get(historical_version, 0) < 1
                    or set(fixture.EXPECTED_MARKERS) - set(historical_native["typedMarkers"])):
                    artifacts.report.update(unmetGate="historicalProducerRequiredNativeContentUnavailable",
                        historicalProducerRuns=historical_runs, historicalNativeSourceEvidence=historical_native,
                        providerRuns=[], signedAppLaunched=False)
                    raise RuntimeError("historicalProducerRequiredNativeContentUnavailable")
                historical_signatures, _ = fixture.native_history_evidence(config / "projects")
            store = root / "protected-store"
            report_path = root / "app-report.json"
            finish = root / "provider-finished"
            profile = "owned-signed-claude-live"
            registration = str(uuid.uuid4())
            setup_args = [str(args.configuration_executable.resolve()), "--claude-configure-hook",
                          "--settings", str(config / "settings.json"), "--helper", str(helper),
                          "--socket", str(store / "capture.sock"), "--profile", profile,
                          "--version", version, "--registration-id", registration]
            setup_result = json.loads(subprocess.check_output(setup_args, text=True))
            command = [str(app / "Contents/MacOS/Spillcheck"), "--store-directory", str(store),
                       "--claude-profile", profile, "--claude-version", version,
                       "--claude-source-root", str(config / "projects"), "--acceptance-no-profile-catchup",
                       "--acceptance-cleanup-new-vault", "--acceptance-claude-role-evidence", "--acceptance-hold", "--acceptance-report", str(report_path),
                       "--acceptance-finish-file", str(finish), "--acceptance-seconds", "120"]
            if historical_executable is not None:
                command.append("--acceptance-allow-history-request")
            stdout_path, stderr_path = root / "stdout.bin", root / "stderr.bin"
            providers = []
            replay_runs = []
            native = {}
            replay_stable = False
            timed_out = False
            before = {}
            process = None
            try:
                # A second app instance could interfere with a user's signed app. Check before launch.
                if subprocess.run(["/usr/bin/pgrep", "-x", "Spillcheck"], capture_output=True).returncode == 0:
                    artifacts.report.update(appAlreadyRunning=True)
                else:
                    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
                        process = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
                        ready = wait_for_report(process, report_path,
                            lambda report: report.get("storageReady") and report.get("collectionConfigured"), 30)
                        if ready.get("storageReady") and ready.get("collectionConfigured"):
                            if historical_executable is not None:
                                import datetime
                                end = datetime.datetime.now(datetime.timezone.utc).timestamp() - 978307200
                                request = {"kind": "LeakretClaudeHistory", "version": 1,
                                    "audit": {"id": str(uuid.uuid4()), "reason": "firstLaunch", "start": end - 604800, "end": end},
                                    "directories": [{"path": str(config / "projects"), "depth": 0, "cookie": 0}],
                                    "pending": [], "deferred": [], "partial": False}
                                delivered = subprocess.run([str(helper), "--socket", str(store / "capture.sock"),
                                    "--agent", "claude-code", "--interface", "standalone-cli", "--profile-id", profile],
                                    input=json.dumps(request).encode(), capture_output=True, timeout=5)
                                historical_delivery = {"exitCode": delivered.returncode, "route": "productionSevenDayHistory"}
                            for prompt in (setup_result["verificationPrompt"], fixture.PROMPT,
                                           f"Respond exactly LEAKRET_M3_FINAL {fixture.SECRET}. This is synthetic test data."):
                                providers.append(fixture.run_provider(executable, prompt, env, project, mcp))
                                if providers[-1]["exitCode"] != 0:
                                    artifacts.report.update(unmetGate="providerRunFailed",
                                        providerFailureCategory=providers[-1].get("failureCategory", "providerFailed"))
                                    break
                            paths, native = native_evidence(config)
                            after_signatures, producer_evidence = fixture.native_history_evidence(config / "projects")
                            native["contentTypesByProducer"] = producer_evidence["contentTypesByProducer"]
                            native["typedMarkersByProducer"] = producer_evidence["typedMarkersByProducer"]
                            native["historicalOriginalIdentitiesAndBytesStable"] = bool(historical_signatures) and all(
                                after_signatures.get(path) == signature for path, signature in historical_signatures.items())
                            replay_paths = paths if all(run["exitCode"] == 0 for run in providers) else []
                            before = settled_report(process, report_path) if replay_paths else read_report(report_path)
                            for interface in ["standalone-cli", "t3"]:
                                for path, session in replay_paths:
                                    payload = json.dumps({"hook_event_name": "SpillcheckTranscriptPoll", "session_id": session,
                                                          "transcript_path": str(path)}).encode()
                                    replay = subprocess.run([str(helper), "--socket", str(store / "capture.sock"),
                                        "--agent", "claude-code", "--interface", interface, "--profile-id", profile],
                                        input=payload, capture_output=True, timeout=5)
                                    replay_runs.append({"interface": interface, "exitCode": replay.returncode,
                                                        "stdoutBytes": len(replay.stdout), "diagnosticBytes": len(replay.stderr)})
                            after = settled_report(process, report_path) if replay_paths else read_report(report_path)
                            replay_stable = (bool(paths) and bool(replay_runs) and before.get("queueCount") == 0
                                and after.get("queueCount") == 0 and all(isinstance(before.get(key), int)
                                    and before[key] == after.get(key) for key in
                                    ("occurrenceCount", "alertCount", "syntheticOccurrenceCount", "syntheticSessionCount")))
                        finish.touch()
                        try:
                            process.wait(timeout=35)
                        except subprocess.TimeoutExpired:
                            timed_out = True
                            stop_group(process)
            except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                artifacts.report.update(runFailureType=type(error).__name__)
            finally:
                if process is not None and process.poll() is None:
                    finish.touch()
                    try:
                        process.wait(timeout=35)
                    except subprocess.TimeoutExpired:
                        timed_out = True
                if process is not None:
                    cleanup = stop_group(process)
                else:
                    cleanup = None
                hook_removal_attempted = True
                removal = subprocess.run(setup_args + ["--remove-hook"], capture_output=True, timeout=10)
                # Failed signed runs retain only the owned vault and synthetic diagnostic sources.
                # Provider authentication is removed even when guarded vault cleanup cannot finish.
                authentication_removed = remove_provider_authentication(config, env)
            result = read_report(report_path)
            clean = store.is_dir() and all(fixture.SECRET.encode() not in path.read_bytes()
                                          for path in store.rglob("*") if path.is_file())
            required = {"userPrompt", "intermediateResponse", "finalResponse", "toolOutput", "toolError"}
            markers = set(fixture.EXPECTED_MARKERS)
            producer_pairs = result.get("claudeCommittedNativeParentChildPairCountByProducer", {})
            individual_roles = (strict_role_coverage_complete(result)
                and type(producer_pairs.get(version)) is int and producer_pairs[version] > 0)
            child_committed = individual_roles
            version_after = subprocess.check_output([str(executable), "--version"], text=True).split()[0]
            historical_version_after = (subprocess.check_output([str(historical_executable), "--version"], text=True).split()[0]
                if historical_executable is not None else None)
            process_cleanup_passed = cleanup is not None and not cleanup["term_permission_denied"] and not cleanup["kill_permission_denied"]
            passed = (process is not None and process.returncode == 0 and not timed_out and len(providers) == 3
                      and all(run["exitCode"] == 0 for run in providers) and result.get("storageReady")
                      and result.get("collectionConfigured") and result.get("queueCount") == 0
                      and result.get("gapReasons") == [] and result.get("coverageReportTruncated") is False
                      and result.get("syntheticValuePresent") and result.get("syntheticSessionCount", 0) >= 2
                      and required <= set(result.get("syntheticOccurrencesByContentType", {}))
                      and markers <= set(native.get("typedMarkers", [])) and native.get("completeJSONLFraming")
                      and native.get("requiredNativeFieldsValid") and native.get("individualNativeRoleCoverageComplete") is True
                      and native.get("completeNativeParentChildPairCountByProducer", {}).get(version, 0) > 0
                      and version in native.get("producerVersions", [])
                      and version in result.get("observedAgentVersions", []) and version_after == version
                      and child_committed and replay_stable and bool(replay_runs) and all(run["exitCode"] == 0 for run in replay_runs)
                      and result.get("newVaultCleanupPassed") is True and clean and removal.returncode == 0
                      and process_cleanup_passed and all(not run["processGroupCleanup"]["term_permission_denied"]
                          and not run["processGroupCleanup"]["kill_permission_denied"] for run in providers + historical_runs))
            committed_by_producer = result.get("syntheticOccurrencesByProducerVersionAndContentType", {})
            per_producer_commit = (historical_executable is not None
                and all(all(isinstance(committed_by_producer.get(producer, {}).get(kind), int)
                    and committed_by_producer[producer][kind] > 0 for kind in required)
                    for producer in (historical_version, version)))
            mixed_passed = historical_executable is not None and all(run["exitCode"] == 0 for run in historical_runs) \
                and historical_delivery is not None and historical_delivery["exitCode"] == 0 \
                and historical_version_after == historical_version and historical_version != version \
                and per_producer_commit \
                and all(type(producer_pairs.get(producer)) is int and producer_pairs[producer] > 0 for producer in (historical_version, version)) \
                and result.get("historicalProgressMeasurementAvailable") is True \
                and result.get("settledHistoricalAuditCount", 0) > 0 \
                and result.get("unreadHistoricalProgressCount") == 0 \
                and native.get("historicalOriginalIdentitiesAndBytesStable") is True \
                and {historical_version, version} <= set(result.get("observedAgentVersions", [])) \
                and all(native.get("completeNativeParentChildPairCountByProducer", {}).get(producer, 0) > 0
                        and markers <= set(native.get("typedMarkersByProducer", {}).get(producer, [])) \
                        and required <= set(native.get("contentTypesByProducer", {}).get(producer, [])) \
                        for producer in (historical_version, version))
            if historical_executable is not None:
                passed = passed and mixed_passed
            candidate_after = candidate_snapshot(args.candidate_manifest, args.expected_bundle_sha256, app)
            candidate_unchanged = candidate_before is not None and candidate_after == candidate_before
            if candidate_before is not None:
                passed = passed and candidate_unchanged
            artifacts.report.update(schemaVersion=1, sourceIsOwnedSynthetic=True, interface="standaloneCLI",
                candidateUnchanged=candidate_unchanged,
                agentVersion=version, versionAfterRun=version_after, expectedVersion=args.expected_version,
                executableVersionStable=version_after == version, providerRuns=providers, nativeSourceEvidence=native,
                ownedProductionHookConfigurationUsed=setup_result.get("installed") is True,
                signedNativeChildCommitEstablished=child_committed,
                signedIndividualRoleCoverageEstablished=individual_roles,
                signedCurrentCandidateIndividualRoleCoverageEstablished=bool(passed) and candidate_unchanged,
                signedSetupConnectionVerificationEstablished=False, coreChallengeVerificationMeasuredSeparately=True,
                profileDiscoveryDisabled=True, scannerIsSignedBundleChild=True, syntheticReplayAcrossRoutes=True,
                replayRuns=replay_runs, replayStable=replay_stable, restartRecoveryEstablished=False,
                signedAppExitCode=process.returncode if process else None, timedOut=timed_out,
                stdoutBytes=stdout_path.stat().st_size if stdout_path.exists() else 0,
                diagnosticBytes=stderr_path.stat().st_size if stderr_path.exists() else 0,
                ownedHookRemovalPassed=removal.returncode == 0, providerAuthenticationRemoved=authentication_removed,
                processGroupCleanup=cleanup, ciphertextMarkerInspectionPassed=clean, result=result, passed=bool(passed),
                passScope="Genuine signed-app commitment of all five content types separately in one native parent and one of its own children, with exact source revision receipts, typed fake-value occurrences and all twelve markers independently verified in original native sources, canonical replay across CLI/T3 routes, encrypted storage and owned cleanup. Saved setup proof, restart, upgrade and concurrent GUI acceptance remain separate gates.")
            if historical_executable is not None:
                artifacts.report.update(historicalProducerVersion=historical_version,
                    historicalProducerVersionAfterRun=historical_version_after,
                    historicalExecutableVersionStable=historical_version_after == historical_version,
                    historicalProducerWasInvokedAsCLI=True, historicalProducerRuns=historical_runs,
                    historicalCaptureDelivery=historical_delivery, signedMixedOriginalHistoryEstablished=bool(mixed_passed),
                    signedMixedPerProducerCommitEstablished=bool(per_producer_commit),
                    signedMixedPerProducerCommitMeasurementAvailable="syntheticOccurrencesByProducerVersionAndContentType" in result,
                    guiHostCollectionEstablished=False)
        finally:
            # Authentication cleanup also covers older-producer and setup failures.
            if setup_args is not None and not hook_removal_attempted:
                try:
                    removal = subprocess.run(setup_args + ["--remove-hook"], capture_output=True, timeout=10)
                except (OSError, subprocess.SubprocessError):
                    artifacts.report["ownedHookRemovalPassed"] = False
            if removal is not None:
                artifacts.report["ownedHookRemovalPassed"] = removal.returncode == 0
            authentication_removed = remove_provider_authentication(config, env)
            artifacts.report["providerAuthenticationRemoved"] = authentication_removed
            artifacts.report["passed"] = artifacts.report.get("passed", False) and authentication_removed \
                and artifacts.report.get("ownedHookRemovalPassed", False)

    return 0 if artifacts.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
