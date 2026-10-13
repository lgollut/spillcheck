#!/usr/bin/env python3
"""Coordinate one attended Desktop Local Code run through production owned hooks.

Preparation creates only a fresh fake project/configuration. Observe launches the
selected signed collector, never a provider. No poll or historical request is
injected: ordinary Desktop hook delivery must discover the source first.
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
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests"))
from Support import claude_desktop
from Support.processes import stop_group


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


selected = module("desktop_hook_selected", Path(__file__).with_name("run-app-claude-selected.py"))
live = selected.live
EVENTS = {"SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "PostToolBatch",
          "MessageDisplay", "SubagentStart", "SubagentStop", "Stop"}
MCP_NAME = "spillcheck_desktop_hooks_synthetic"
PROFILE = "owned-desktop-ordinary-hooks"
FINAL_COUNTS = ("valueCount", "occurrenceCount", "alertCount", "syntheticOccurrenceCount", "syntheticSessionCount")
CONTROLLED_ERRORS = (OSError, ValueError, KeyError, TypeError, RuntimeError,
                     selected.NativeEvidenceFailure, subprocess.SubprocessError)


def exclusive_json(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as file:
        json.dump(value, file, indent=2, sort_keys=True)
        file.write("\n")
        file.flush()
        os.fsync(file.fileno())


def private_root(directory):
    directory = Path(directory).absolute()
    fd = selected._directory(directory)
    try:
        info = os.fstat(fd)
        if info.st_mode & 0o077 or directory != directory.resolve():
            raise ValueError("privateOriginalRootRequired")
    finally:
        os.close(fd)
    return directory


def state_for(directory):
    directory = private_root(directory)
    state, _ = selected.private_json(directory / "preparation-private.json")
    if (state.get("schemaVersion") != 1 or state.get("directory") != str(directory)
            or state.get("profile") != PROFILE
            or str(uuid.UUID(state["registrationID"])) != state["registrationID"]):
        raise ValueError("ownedPreparationRequired")
    claude_desktop.require_owned_project_root(directory / "work")
    return state


def hook_command(directory, state, remove=False):
    command = [state["configurationExecutable"], "--claude-configure-hook",
        "--settings", str(directory / "work/.claude/settings.local.json"),
        "--helper", str(Path(state["app"]) / "Contents/Helpers/spillcheck-hook"),
        "--socket", str(directory / "store/capture.sock"), "--profile", PROFILE,
        "--version", state["producerVersion"], "--registration-id", state["registrationID"]]
    return command + (["--remove-hook"] if remove else [])


def owned_hooks_exact(settings, state, directory):
    if not isinstance(settings, dict) or not isinstance(settings.get("hooks", {}), dict):
        return False
    hooks = settings.get("hooks", {})
    marker = "Spillcheck hook " + state["registrationID"]
    expected_args = ["--socket", str(directory / "store/capture.sock"), "--agent", "claude-code",
                     "--interface", "standalone-cli", "--profile-id", PROFILE]
    found = set()
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            return False
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                return False
            for handler in group["hooks"]:
                if not isinstance(handler, dict):
                    return False
                if handler.get("statusMessage") != marker:
                    continue
                if (event in found or handler.get("type") != "command"
                        or handler.get("command") != str(Path(state["app"]) / "Contents/Helpers/spillcheck-hook")
                        or handler.get("args") != expected_args or handler.get("timeout") != 2):
                    return False
                found.add(event)
    return found == EVENTS


def prepare(args):
    directory = args.directory.absolute()
    if (directory.exists() or directory.is_symlink() or directory != directory.resolve()
            or len(str(directory / "store/capture.sock").encode()) >= 104):
        raise ValueError("freshShortDirectoryRequired")
    app = args.app.resolve()
    binding = live.candidate_snapshot(args.candidate_manifest, args.expected_bundle_sha256, app)
    if binding is None:
        raise ValueError("immutableCandidateRequired")
    claude_desktop.prepare(directory)
    work = directory / "work"
    (work / ".claude").mkdir(mode=0o700)
    state = {"schemaVersion": 1, "directory": str(directory), "app": str(app),
        "configurationExecutable": str(args.configuration_executable.resolve()),
        "candidateManifest": str(args.candidate_manifest.resolve()), "expectedBundleSHA256": args.expected_bundle_sha256,
        "candidateBinding": binding, "producerVersion": args.producer_version,
        "registrationID": str(uuid.uuid4()), "profile": PROFILE}
    # Preserve ownership before the first mutation so an interrupted preparation can remove its hook.
    exclusive_json(directory / "preparation-private.json", state)
    try:
        configured = subprocess.run(hook_command(directory, state), capture_output=True, timeout=15)
        if configured.returncode != 0:
            raise ValueError("ownedHookPreparationFailed")
        settings, _ = selected.private_json(work / ".claude/settings.local.json")
        if not owned_hooks_exact(settings, state, directory):
            raise ValueError("productionNineHookRegistrationRequired")
        exclusive_json(directory / "installed-settings-private.json", settings)
        mcp_fixture = work / "mcp_fixture.py"
        shutil.copyfile(ROOT / "Tests/ClaudeLive/mcp_fixture.py", mcp_fixture)
        mcp_fixture.chmod(0o600)
        mcp = {"mcpServers": {MCP_NAME: {"command": sys.executable, "args": [str(mcp_fixture)]}}}
        # Journal the exact planned bytes before installing the runtime registration.
        digest = hashlib.sha256((json.dumps(mcp, indent=2, sort_keys=True) + "\n").encode()).hexdigest()
        exclusive_json(directory / "owned-mcp-private.json", {"sha256": digest})
        exclusive_json(work / ".mcp.json", mcp)
        register = f"LEAKRET_M3_PROMPT {live.fixture.SECRET}. This is fake test data, never authentication.\n" \
            + (directory / "GUI_BOOTSTRAP.txt").read_text()
        (directory / "REGISTER_MAIN.txt").write_text(register)
        prompt = live.fixture.PROMPT.replace(f"User marker LEAKRET_M3_PROMPT {live.fixture.SECRET}.",
            "The user marker was already submitted in registration; do not repeat it.").replace("spillcheck_synthetic", MCP_NAME)
        prompt += "\nUse this conversation's native Agent tool, not a CLI or another main chat. " \
            "Do not repeat tool-only markers in assistant text. If a required tool is unavailable, stop and report it.\n"
        (directory / "MAIN.txt").write_text(prompt)
        for name in ("REGISTER_MAIN.txt", "MAIN.txt"):
            (directory / name).chmod(0o600)
    except CONTROLLED_ERRORS as error:
        result = {"prepared": False, "controlledFailureType": type(error).__name__,
            "configurationCleanup": cleanup_configuration(directory, state),
            "providerLaunched": False, "signedAppLaunched": False}
        try:
            exclusive_json(directory / "preparation-failure.json", result)
        except CONTROLLED_ERRORS:
            result["failureReportWritten"] = False
        return result
    return {"prepared": True, "ownedHookCount": len(EVENTS), "providerLaunched": False,
            "signedAppLaunched": False, "sourceHost": "desktop-code", "hookTransportInterface": "standalone-cli"}


def register(args):
    directory = private_root(args.directory)
    state = state_for(directory)
    work = directory / "work"
    runtime, identity_digest = selected.private_json(work / "selected-session-private.json")
    session = runtime["nativeSessionID"]
    if (str(uuid.UUID(session)) != session or runtime.get("workingDirectory") != str(work)
            or runtime.get("identitySource") != "own-runtime-CLAUDE_CODE_SESSION_ID"):
        raise ValueError("ownRuntimeIdentityRequired")
    # One observed standard path; never enumerate a personal project or search for fallback IDs.
    source = Path.home() / ".claude/projects" / re.sub(r"[^A-Za-z0-9]", "-", str(work)) / (session + ".jsonl")
    payload = selected._read(source, 2 * 1024 * 1024)
    manifest = {"schemaVersion": 2, "sourceInterface": "desktop-code", "nativeSessionId": session,
        "originalTranscriptPath": str(source), "workingDirectory": str(work),
        "producerVersion": state["producerVersion"], "hostVersion": args.host_version,
        "identitySource": runtime["identitySource"], "originalTranscriptPathDerivedThenVerified": True,
        "runtimeIdentityPath": str(work / "selected-session-private.json"), "runtimeIdentitySHA256": identity_digest,
        "sourceRegistrationByteCount": len(payload), "sourceRegistrationSHA256": hashlib.sha256(payload).hexdigest()}
    pending = directory / "registration-pending-private.json"
    exclusive_json(pending, manifest)
    try:
        _, binding = selected.registration_snapshot(pending, "desktop-code")
        _, native, _ = selected.native_checkpoint(source, session)
        if "PROMPT" not in native.get("typedMarkers", []) or "FINAL" in native.get("typedMarkers", []):
            raise ValueError("bootstrapOnlyNativeSourceRequired")
        exclusive_json(directory / "manifest.json", manifest)
    finally:
        pending.unlink()
    return {"registered": True, "runtimeIdentityBinding": binding, "providerLaunched": False,
            "hostOriginIndependentlyVerified": False}


def collector_command(directory, state, source_root):
    return [str(Path(state["app"]) / "Contents/MacOS/Spillcheck"), "--store-directory", str(directory / "store"),
        "--claude-profile", PROFILE, "--claude-version", state["producerVersion"],
        "--claude-interface", "desktop-code", "--claude-authorized-host", "standalone-cli",
        "--claude-authorized-host", "desktop-code", "--claude-source-root", str(source_root),
        "--acceptance-no-profile-catchup", "--acceptance-cleanup-new-vault", "--acceptance-claude-role-evidence",
        "--acceptance-hold", "--acceptance-report", str(directory / "app-report.json"),
        "--acceptance-finish-file", str(directory / "collector-finish"), "--acceptance-seconds", "120"]


def empty_baseline(report):
    return (report.get("storageReady") is True and report.get("collectionConfigured") is True
        and all(type(report.get(key)) is int and report[key] == 0
                for key in ("queueCount", "valueCount", "occurrenceCount", "alertCount",
                            "syntheticOccurrenceCount", "syntheticSessionCount"))
        and report.get("coverageReportTruncated") is False
        and report.get("gapReasons") == [] and report.get("transportRejectionCountsByStageAndReason") == {})


def new_marker_before_final(report, baseline_native, current_native, append_verified):
    return (append_verified and "FINAL" not in current_native.get("typedMarkers", [])
        and selected.new_committed_native_marker(report, baseline_native, current_native))


def ordinary_gate(report, native, version, *, baseline_empty, before_final, producer_finished):
    return (baseline_empty and before_final and producer_finished
        and selected.strict_selected_role_coverage(report, native, version)
        and type(report.get("queueCount")) is int and report["queueCount"] == 0
        and report.get("gapReasons") == [] and report.get("transportRejectionCountsByStageAndReason") == {}
        and report.get("coverageReportTruncated") is False)


def final_collection_checks(proof, result, version):
    before = proof.get("result", {})
    final_gate = proof.get("passed") is True and ordinary_gate(result, proof.get("nativeSourceEvidence", {}), version,
        baseline_empty=proof.get("emptyCollectorBaseline") is True,
        before_final=proof.get("newNativeMarkerCommittedBeforeFinal") is True,
        producer_finished=proof.get("producerOutcome") == "complete")
    stable = all(type(before.get(key)) is int and before[key] >= 0
        and type(result.get(key)) is int and result[key] == before[key] for key in FINAL_COUNTS)
    return {"finalOrdinaryHookGatePassed": final_gate, "postShutdownInventoryStable": stable}


def remove_hooks(directory, state):
    settings_path = directory / "work/.claude/settings.local.json"
    if not settings_path.exists() and not settings_path.is_symlink():
        return {"removed": True, "ownedRegistrationAbsent": True,
            "ownedRemovalPreservedCurrentUnownedSettings": True, "settingsAlreadyAbsent": True}
    before, _ = selected.private_json(settings_path)
    installed = directory / "installed-settings-private.json"
    original, snapshot_available = before, False
    try:
        original = selected.private_json(installed)[0]
        snapshot_available = True
    except CONTROLLED_ERRORS:
        # The setup UUID, not this diagnostic snapshot, owns the exact handler.
        # An interrupted snapshot write must not prevent safe owned removal.
        pass
    result = subprocess.run(hook_command(directory, state, remove=True), capture_output=True, timeout=15)
    after, _ = selected.private_json(settings_path)
    evidence = claude_desktop.settings_evidence({}, original, before, after, state["registrationID"])
    evidence["installedSnapshotAvailable"] = snapshot_available
    if not snapshot_available:
        evidence["ownedInstallPreservedUnownedSettings"] = None
    absent = claude_desktop.without_registration(after, state["registrationID"]) == after
    passed = result.returncode == 0 and absent and evidence["ownedRemovalPreservedCurrentUnownedSettings"]
    if passed and after == {}:
        settings_path.unlink()
    return dict(evidence, removed=passed, ownedRegistrationAbsent=absent)


def remove_mcp(directory):
    path = directory / "work/.mcp.json"
    if not path.exists() and not path.is_symlink():
        return True
    expected, _ = selected.private_json(directory / "owned-mcp-private.json")
    payload = selected._read(path, 64 * 1024)
    if hashlib.sha256(payload).hexdigest() != expected["sha256"]:
        return False
    path.unlink()
    return True


def cleanup_configuration(directory, state):
    """Independent attempts; no failure in one owned removal may skip the other."""
    result = {}
    try:
        result["hookCleanup"] = remove_hooks(directory, state)
    except CONTROLLED_ERRORS as error:
        result["hookCleanup"] = {"removed": False, "failureType": type(error).__name__}
    try:
        result["ownedMCPConfigurationRemoved"] = remove_mcp(directory)
    except CONTROLLED_ERRORS as error:
        result["ownedMCPConfigurationRemoved"] = False
        result["mcpCleanupFailureType"] = type(error).__name__
    result["cleaned"] = result["hookCleanup"].get("removed") is True and result["ownedMCPConfigurationRemoved"]
    return result


def ciphertext_clean(store):
    return store.is_dir() and all(live.fixture.SECRET.encode() not in path.read_bytes()
        for path in store.rglob("*") if path.is_file())


def observe(args):
    directory = private_root(args.directory)
    state = state_for(directory)
    output = args.output.absolute()
    if output.exists() or output.is_symlink() or (directory / "store").exists():
        raise ValueError("freshOutputAndVaultRequired")
    if not 30 <= args.duration <= 1800:
        raise ValueError("boundedObservationDurationRequired")
    manifest, binding = selected.registration_snapshot(directory / "manifest.json", "desktop-code")
    source, session = Path(manifest["originalTranscriptPath"]), manifest["nativeSessionId"]
    _, native_before, source_before = selected.native_checkpoint(source, session)
    if "FINAL" in native_before.get("typedMarkers", []):
        raise ValueError("uncompletedNativeFixtureRequired")
    settings, _ = selected.private_json(directory / "work/.claude/settings.local.json")
    if not owned_hooks_exact(settings, state, directory):
        raise ValueError("ownedHooksChangedBeforeObservation")
    app = Path(state["app"])
    candidate = live.candidate_snapshot(Path(state["candidateManifest"]), state["expectedBundleSHA256"], app)
    if candidate != state["candidateBinding"]:
        raise ValueError("preparedCandidateChanged")
    inventory = subprocess.run(["/usr/bin/pgrep", "-x", "Spillcheck"], capture_output=True)
    if inventory.returncode != 1:
        raise ValueError("signedAppAbsenceNotEstablished")
    exclusive_json(directory / "observation-started.json", {"started": True})
    report = {"schemaVersion": 1, "passed": False, "sourceHost": "desktop-code",
        "hookTransportInterface": "standalone-cli", "hostVersion": manifest["hostVersion"],
        "providerProducerVersion": state["producerVersion"], "hostOriginIndependentlyVerified": False,
        "candidateBinding": candidate, "sourceRegistrationBinding": binding,
        "activeSourcePrimed": False, "profileCatchupEnabled": False, "manualCaptureInjected": False,
        "replayPerformed": False, "providerLaunchedByRunner": False, "unrelatedHistoryEnumerated": False,
        "authenticationCopied": False, "sideQuestionCoverageEstablished": False,
        "settingsUIInstallationMeasured": False, "rememberedConnectionVerificationMeasured": False}
    process = None
    before_final = False
    baseline_empty = False
    native = {}
    cleanup = None
    termination = {"finishSignalWritten": False, "normalWaitCompleted": False,
                   "processGroupStopped": False, "readySignalRemoved": False}
    try:
        with (directory / "app-stdout-private.bin").open("xb") as stdout, \
                (directory / "app-stderr-private.bin").open("xb") as stderr:
            process = subprocess.Popen(collector_command(directory, state, source.parent),
                stdout=stdout, stderr=stderr, start_new_session=True)
            ready = live.wait_for_report(process, directory / "app-report.json", empty_baseline, 30)
            baseline_empty = empty_baseline(ready)
            if not baseline_empty:
                raise ValueError("emptyCollectorBaselineUnavailable")
            # Both source and app baselines are captured before the operator may submit MAIN.
            _, native_before, source_before = selected.native_checkpoint(source, session)
            if "FINAL" in native_before.get("typedMarkers", []):
                raise ValueError("fixtureCompletedBeforeReady")
            exclusive_json(directory / "ready.json", {"collectorReady": True, "emptyBaseline": True})
            deadline = time.monotonic() + args.duration
            while process.poll() is None and time.monotonic() < deadline and not (directory / "producer-finished.json").exists():
                current = live.read_report(directory / "app-report.json")
                if not before_final:
                    try:
                        paths, current_native, _ = selected.native_checkpoint(source, session)
                        before_final = new_marker_before_final(current, native_before, current_native,
                            selected.source_appended_since(source_before, paths))
                    except (OSError, ValueError, selected.NativeEvidenceFailure):
                        pass
                time.sleep(0.2)
            completion = selected.private_json(directory / "producer-finished.json")[0] \
                if (directory / "producer-finished.json").exists() else {}
            settled = live.settled_report(process, directory / "app-report.json")
            _, native, _ = selected.native_checkpoint(source, session)
            passed = ordinary_gate(settled, native, state["producerVersion"], baseline_empty=baseline_empty,
                before_final=before_final, producer_finished=completion.get("outcome") == "complete")
            # Immutable proof is recorded before shutdown and before any possible later replay.
            proof = {"passed": passed, "emptyCollectorBaseline": baseline_empty,
                "newNativeMarkerCommittedBeforeFinal": before_final, "producerOutcome": completion.get("outcome", "timeout"),
                "nativeSourceEvidence": native, "result": settled, "manualCaptureInjected": False,
                "replayPerformed": False}
            exclusive_json(directory / "ordinary-hook-proof.json", proof)
            report.update(ordinaryHookProof=proof)
    except CONTROLLED_ERRORS as error:
        report["controlledFailureType"] = type(error).__name__
    finally:
        if process is not None:
            try:
                exclusive_json(directory / "collector-finish", {"finished": True})
                termination["finishSignalWritten"] = True
            except CONTROLLED_ERRORS as error:
                termination["finishSignalFailureType"] = type(error).__name__
            try:
                process.wait(timeout=35)
                termination["normalWaitCompleted"] = True
            except CONTROLLED_ERRORS as error:
                termination["normalWaitFailureType"] = type(error).__name__
            try:
                cleanup = stop_group(process)
                termination["processGroupStopped"] = (not cleanup["term_permission_denied"]
                    and not cleanup["kill_permission_denied"])
            except CONTROLLED_ERRORS as error:
                termination["processGroupFailureType"] = type(error).__name__
        try:
            (directory / "ready.json").unlink(missing_ok=True)
            termination["readySignalRemoved"] = True
        except CONTROLLED_ERRORS as error:
            termination["readySignalFailureType"] = type(error).__name__
        report.update(cleanup_configuration(directory, state), termination=termination)
    result = live.read_report(directory / "app-report.json")
    store = directory / "store"
    try:
        clean = ciphertext_clean(store)
    except CONTROLLED_ERRORS as error:
        clean = False
        report["ciphertextInspectionFailureType"] = type(error).__name__
    try:
        unchanged = live.candidate_snapshot(Path(state["candidateManifest"]), state["expectedBundleSHA256"], app) == candidate
        _, final_binding = selected.registration_snapshot(directory / "manifest.json", "desktop-code")
        registration_unchanged = final_binding == binding
    except CONTROLLED_ERRORS:
        unchanged = registration_unchanged = False
    report.update(result=result, candidateUnchanged=unchanged, sourceRegistrationUnchanged=registration_unchanged,
        signedAppExitCode=process.returncode if process else None, processGroupCleanup=cleanup,
        ciphertextMarkerInspectionPassed=clean, originalSourceModified=False,
        newVaultCleanupConfirmed=result.get("newVaultCleanupPassed") is True)
    report.update(final_collection_checks(report.get("ordinaryHookProof", {}), result, state["producerVersion"]))
    report["passed"] = bool(report.get("ordinaryHookProof", {}).get("passed") and unchanged and registration_unchanged
        and report["finalOrdinaryHookGatePassed"] and report["postShutdownInventoryStable"]
        and process is not None and process.returncode == 0 and result.get("newVaultCleanupPassed") is True
        and all(termination[field] for field in ("finishSignalWritten", "normalWaitCompleted",
            "processGroupStopped", "readySignalRemoved"))
        and cleanup is not None and not cleanup["term_permission_denied"] and not cleanup["kill_permission_denied"]
        and report["hookCleanup"].get("removed") and report["ownedMCPConfigurationRemoved"] and clean)
    report["passScope"] = "Attended Desktop ordinary-hook discovery and collection of an exact native parent/own-child pair; twelve markers and five types per role. Active polling may collect later rows. No UI setup, remembered proof, side-question, history, restart or host attribution claim."
    exclusive_json(output, report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    preparation = sub.add_parser("prepare")
    preparation.add_argument("--directory", required=True, type=Path)
    preparation.add_argument("--app", required=True, type=Path)
    preparation.add_argument("--configuration-executable", required=True, type=Path)
    preparation.add_argument("--producer-version", required=True)
    preparation.add_argument("--candidate-manifest", required=True, type=Path)
    preparation.add_argument("--expected-bundle-sha256", required=True)
    registration = sub.add_parser("register")
    registration.add_argument("--directory", required=True, type=Path)
    registration.add_argument("--host-version", required=True)
    observer = sub.add_parser("observe")
    observer.add_argument("--directory", required=True, type=Path)
    observer.add_argument("--output", required=True, type=Path)
    observer.add_argument("--duration", type=int, default=600)
    finish = sub.add_parser("finish")
    finish.add_argument("--directory", required=True, type=Path)
    finish.add_argument("--outcome", choices=("complete", "limit", "error"), required=True)
    removal = sub.add_parser("remove-hooks")
    removal.add_argument("--directory", required=True, type=Path)
    cleanup = sub.add_parser("cleanup")
    cleanup.add_argument("--directory", required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.operation == "prepare":
            result = prepare(args)
        elif args.operation == "register":
            result = register(args)
        elif args.operation == "observe":
            result = observe(args)
        elif args.operation == "finish":
            directory = private_root(args.directory)
            state_for(directory)
            if not (directory / "ready.json").is_file():
                raise ValueError("activeObservationRequired")
            exclusive_json(directory / "producer-finished.json", {"outcome": args.outcome})
            result = {"signaled": True}
        else:
            directory = private_root(args.directory)
            state = state_for(directory)
            result = cleanup_configuration(directory, state) if args.operation == "cleanup" else remove_hooks(directory, state)
    except CONTROLLED_ERRORS as error:
        print(json.dumps({"passed": False, "controlledFailureType": type(error).__name__}))
        return 1
    # Public stdout never contains native paths, IDs, fixture bytes or settings.
    print(json.dumps({key: result[key] for key in ("prepared", "registered", "passed", "signaled", "removed", "cleaned",
        "controlledFailureType", "configurationCleanup", "ownedHookCount", "providerLaunched", "signedAppLaunched",
        "sourceHost", "hookTransportInterface") if key in result}, sort_keys=True))
    outcome = {"prepare": "prepared", "register": "registered", "observe": "passed", "finish": "signaled",
               "remove-hooks": "removed", "cleanup": "cleaned"}[args.operation]
    return 0 if result.get(outcome) is True else 1


if __name__ == "__main__":
    raise SystemExit(main())
