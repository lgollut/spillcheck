#!/usr/bin/env python3
"""Coordinate fake-only, T3-owned Claude discovery through original ordinary hooks.

Only prepare/cleanup mutate the exact bound workspace's local hook registration.
Observe starts the fresh signed collector, never a provider or a T3 thread. The
producer helper records its own runtime identity; it never submits a capture.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests"))
from Support import claude_desktop


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


desktop = module("t3_hooks_desktop", Path(__file__).with_name("run-app-claude-desktop-hooks.py"))
gate = module("t3_hooks_gate", Path(__file__).with_name("claude_t3_hook_gate.py"))
selected, live = desktop.selected, desktop.live
PROFILE = "owned-t3-ordinary-hooks"
ERRORS = desktop.CONTROLLED_ERRORS + (UnicodeError,)
TASK_KEYS = ("taskId", "childThreadId", "childRunId", "providerInstanceId", "model")


def exclusive_bytes(path, raw, mode=0o600):
    """Publish fully synced bytes without replacing an existing control file."""
    parent = gate.directory_fd(path.parent)
    temporary = ".publish-" + str(uuid.uuid4())
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=parent)
        try:
            with os.fdopen(fd, "wb") as file:
                file.write(raw)
                file.flush()
                os.fsync(file.fileno())
            os.link(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
            os.fsync(parent)
        finally:
            os.unlink(temporary, dir_fd=parent)
    finally:
        os.close(parent)


def exclusive_json(path, value):
    exclusive_bytes(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode())


def state_for(directory):
    directory = desktop.private_root(directory)
    state = gate.read_json(directory / "preparation-private.json")[0]
    if (state.get("schemaVersion") != 1 or state.get("directory") != str(directory)
            or state.get("profile") != PROFILE or str(uuid.UUID(state["registrationID"])) != state["registrationID"]):
        raise ValueError("ownedPreparationRequired")
    workspace = Path(state["workspace"])
    if str(workspace) != state["workspace"] or not workspace.is_absolute():
        raise ValueError("exactWorkspaceRequired")
    claude_desktop.require_owned_project_root(workspace)
    return state


def hook_command(directory, state, remove=False):
    command = [state["configurationExecutable"], "--claude-configure-hook",
        "--settings", str(Path(state["workspace"]) / ".claude/settings.local.json"),
        "--helper", str(directory / "owned-hook"), "--socket", str(directory / "store/capture.sock"),
        "--profile", PROFILE, "--version", state["producerVersion"], "--registration-id", state["registrationID"]]
    return command + (["--remove-hook"] if remove else [])


def helper_args(directory):
    return ["--socket", str(directory / "store/capture.sock"), "--agent", "claude-code",
            "--interface", "standalone-cli", "--profile-id", PROFILE]


def owned_hooks_exact(settings, state, directory):
    if not isinstance(settings, dict) or not isinstance(settings.get("hooks", {}), dict):
        return False
    marker, found = "Spillcheck hook " + state["registrationID"], set()
    for event, groups in settings.get("hooks", {}).items():
        if not isinstance(groups, list):
            return False
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                return False
            for handler in group["hooks"]:
                if not isinstance(handler, dict):
                    return False
                if handler.get("statusMessage") == marker:
                    if (set(group) != {"hooks"} or len(group["hooks"]) != 1
                            or event in found or handler.get("type") != "command"
                            or handler.get("command") != str(directory / "owned-hook")
                            or handler.get("args") != helper_args(directory) or handler.get("timeout") != 2):
                        return False
                    found.add(event)
    return found == gate.EVENTS


def settings_snapshot(workspace):
    path = workspace / ".claude/settings.local.json"
    try:
        value, digest, mode = gate.read_json(path, private=False)
        if mode & 0o022:
            raise ValueError("settingsMustNotBeWritableByOtherUsers")
        return value, digest, mode
    except FileNotFoundError:
        # Do not mistake a replaced/symlink parent for an absent owned file.
        if (workspace / ".claude").is_symlink() or path.is_symlink():
            raise ValueError("unsafeSettingsPath")
        return None, None, None


def restore_mode(path, mode):
    parent = gate.directory_fd(path.parent)
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=parent)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
                raise ValueError("ownedSettingsRequired")
            os.fchmod(fd, mode)
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        os.close(parent)


def remove_owned_empty_settings_directory(directory, state):
    if not state["settingsDirectoryCreated"]:
        return
    identity = state.get("settingsDirectoryIdentity")
    if identity is None:
        try:
            identity = gate.read_json(directory / "settings-directory-private.json")[0]
        except FileNotFoundError:
            return  # No persisted creation identity grants removal authority.
    parent = gate.directory_fd(Path(state["workspace"]))
    try:
        try:
            info = os.stat(".claude", dir_fd=parent, follow_symlinks=False)
            if (stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
                    and identity == {"device": info.st_dev, "inode": info.st_ino}):
                os.rmdir(".claude", dir_fd=parent)
        except (FileNotFoundError, OSError):
            pass  # A replaced directory or new unowned content is preserved.
    finally:
        os.close(parent)


def remove_hooks(directory, state):
    workspace = Path(state["workspace"])
    path = workspace / ".claude/settings.local.json"
    before, _, mode = settings_snapshot(workspace)
    if before is None:
        remove_owned_empty_settings_directory(directory, state)
        return {"removed": True, "ownedRegistrationAbsent": True,
            "ownedRemovalPreservedCurrentUnownedSettings": True, "currentFileModePreserved": True}
    result = subprocess.run(hook_command(directory, state, True), capture_output=True, timeout=15)
    after, _, _ = settings_snapshot(workspace)
    if after is None:
        raise ValueError("settingsDisappearedDuringCleanup")
    evidence = claude_desktop.settings_evidence({}, before, before, after, state["registrationID"])
    absent = claude_desktop.without_registration(after, state["registrationID"]) == after
    restore_mode(path, mode)
    mode_preserved = stat.S_IMODE(path.lstat().st_mode) == mode
    passed = result.returncode == 0 and absent and evidence["ownedRemovalPreservedCurrentUnownedSettings"] and mode_preserved
    # Retain an empty settings file: a later user write must never be removed
    # using a stale after=={} snapshot as deletion authority.
    if passed:
        remove_owned_empty_settings_directory(directory, state)
    return {"removed": passed, "ownedRegistrationAbsent": absent, "currentFileModePreserved": mode_preserved,
        "ownedRemovalPreservedCurrentUnownedSettings": evidence["ownedRemovalPreservedCurrentUnownedSettings"]}


def close_admission(directory):
    # Hold the collector open while admitted original callbacks and inherited
    # helper lock descriptors drain. New callbacks cannot pass a closed gate.
    with gate.callback_lock(directory, exclusive=True, timeout=3):
        for name in ("ready.json", "gate-admission-private.json"):
            (directory / name).unlink(missing_ok=True)


def cleanup_configuration(directory, state):
    signals_removed = True
    drained = False
    try:
        close_admission(directory)
        drained = True
    except FileNotFoundError:
        drained = not any((directory / name).exists() for name in ("ready.json", "gate-admission-private.json"))
    except ERRORS:
        pass
    for name in ("ready.json", "gate-admission-private.json"):
        try:
            (directory / name).unlink(missing_ok=True)
        except ERRORS:
            signals_removed = False
    try:
        hooks = remove_hooks(directory, state)
    except ERRORS as error:
        hooks = {"removed": False, "failureType": type(error).__name__}
    return {"hookCleanup": hooks, "gateSignalsRemoved": signals_removed, "callbacksDrained": drained,
            "cleaned": hooks.get("removed") is True and signals_removed and drained}


def prompt(directory, workspace):
    command = shlex.join([sys.executable, str(Path(__file__).resolve()), "bind", "--directory", str(directory)])
    waiting = shlex.join([sys.executable, str(Path(__file__).resolve()), "wait-ready", "--directory", str(directory)])
    secret = live.fixture.SECRET
    return f"""This is an authorized fake-only Spillcheck test in a genuine T3-owned Claude child. Work in exactly {workspace}. Every credential below is synthetic and must never be used for authentication. No worktree, provider launch or separate CLI. Do not read histories, configuration, authentication, environment listings, unrelated files or existing browser tabs. User marker LEAKRET_M3_PROMPT {secret}.
1. Use Bash once to run: {command}
The helper reads only your own CLAUDE_CODE_SESSION_ID. Stop without searching if runtimeIdentityRecorded is not true. Never print the UUID.
2. Use Bash to run: {waiting}
Each call waits at most 45 seconds. Repeat only while collectorReady is false and waitBudgetExhausted is false, at most eight calls; the helper enforces a six-minute total budget. Stop on any error. Never create or alter readiness, hook, source, settings or producer-completion files. Do not emit fixture markers before readiness.
3. After collectorReady is exactly true, emit LEAKRET_M3_INTERMEDIATE {secret} in assistant text.
4. With Bash run: printf 'LEAKRET_M3_SHELL_OK {secret}\\n'; sleep 1
5. With Bash run: printf 'LEAKRET_M3_SHELL_ERROR {secret}\\n' >&2; exit 7
This failure is intentional; do not repair it.
6. Use the actual T3 MCP preview_status tool to initialize its browser context, then preview_open with open=false and reuseExistingTab=false, omitting url. Use only the returned exact tabId. Do not select an existing tab or navigate away from the new blank document.
7. On that exact tab, call preview_evaluate with expression: "LEAKRET_M3_MCP_OK {secret}"
8. On the same tab, call preview_evaluate with expression: (() => {{ throw new Error("LEAKRET_M3_MCP_ERROR {secret}"); }})()
Keep the intentional MCP error. Close only your created tab with t3_preview_close, even after an error. Do not substitute Bash or assistant text for the MCP results.
9. Use the native built-in Agent tool with this exact child prompt and wait for its result:
{live.fixture.CHILD_PROMPT}
10. After the native child finishes and your tab is closed, run only sleep 30 using Bash. This lets the separate collector verify live commitments before your final reply.
11. End with LEAKRET_M3_FINAL {secret}.
Never repeat tool-only markers in assistant text. If required native Agent or MCP tools are unavailable, stop and report that fact. Do not modify repository files or settings. Only the helper may write the two owned runtime/wait control files. The root orchestrator records terminal completion after task_status; never write it yourself.
"""


def prepare(args):
    directory, workspace = args.directory.absolute(), args.workspace.absolute()
    if (directory.exists() or directory.is_symlink() or directory != directory.resolve()
            or len(str(directory / "store/capture.sock").encode()) >= 104):
        raise ValueError("freshShortCanonicalDirectoryRequired")
    claude_desktop.require_owned_project_root(workspace)
    if workspace != workspace.resolve():
        raise ValueError("boundOriginalWorkspaceRequired")
    parent = gate.directory_fd(directory.parent)
    os.close(parent)
    app = args.app.resolve()
    binding = live.candidate_snapshot(args.candidate_manifest, args.expected_bundle_sha256, app)
    if binding is None:
        raise ValueError("immutableCandidateRequired")
    before, initial_digest, mode = settings_snapshot(workspace)
    directory.mkdir(mode=0o700)
    state = {"schemaVersion": 1, "directory": str(directory), "workspace": str(workspace), "app": str(app),
        "configurationExecutable": str(args.configuration_executable.resolve()),
        "candidateManifest": str(args.candidate_manifest.resolve()), "expectedBundleSHA256": args.expected_bundle_sha256,
        "candidateBinding": binding, "producerVersion": args.producer_version, "hostVersion": args.host_version,
        "registrationID": str(uuid.uuid4()), "profile": PROFILE,
        "settingsInitiallyPresent": before is not None, "initialSettingsMode": mode,
        "initialSettingsSHA256": initial_digest,
        "settingsDirectoryCreated": not (workspace / ".claude").exists()}
    exclusive_json(directory / "preparation-private.json", state)
    try:
        if state["settingsDirectoryCreated"]:
            (workspace / ".claude").mkdir(mode=0o700)
            info = (workspace / ".claude").lstat()
            state["settingsDirectoryIdentity"] = {"device": info.st_dev, "inode": info.st_ino}
            exclusive_json(directory / "settings-directory-private.json", state["settingsDirectoryIdentity"])
        gate_path = Path(__file__).with_name("claude_t3_hook_gate.py").resolve()
        wrapper = (f"#!{sys.executable}\nimport runpy, sys\nsys.argv = [{str(gate_path)!r}, {str(directory)!r}, *sys.argv[1:]]\n"
            f"runpy.run_path({str(gate_path)!r}, run_name='__main__')\n").encode()
        exclusive_bytes(directory / "owned-hook", wrapper, 0o700)
        exclusive_bytes(directory / "callback.lock", b"")
        lock = (directory / "callback.lock").lstat()
        config = {"directory": str(directory), "workspace": str(workspace), "registrationID": state["registrationID"],
            "helper": str(app / "Contents/Helpers/spillcheck-hook"), "helperArgs": helper_args(directory),
            "lockIdentity": {"device": lock.st_dev, "inode": lock.st_ino}}
        exclusive_json(directory / "gate-config-private.json", config)
        exclusive_json(directory / "gate-integrity-private.json", {
            "gateSHA256": hashlib.sha256(gate_path.read_bytes()).hexdigest(),
            "wrapperSHA256": hashlib.sha256(wrapper).hexdigest(),
            "configSHA256": gate.read_json(directory / "gate-config-private.json")[1]})
        exclusive_bytes(directory / "TASK_PROMPT.txt", prompt(directory, workspace).encode())
        installed = subprocess.run(hook_command(directory, state), capture_output=True, timeout=15)
        after, installed_digest, _ = settings_snapshot(workspace)
        if after is not None and mode is not None:
            restore_mode(workspace / ".claude/settings.local.json", mode)
        if installed.returncode != 0 or not owned_hooks_exact(after, state, directory):
            raise ValueError("productionNineHooksRequired")
        if claude_desktop.without_registration(after, state["registrationID"]) != (before or {}):
            raise ValueError("unownedSettingsChangedAtInstall")
        exclusive_json(directory / "settings-install-evidence.json", {
            "ownedInstallPreservedUnownedSettings": True, "installedSettingsSHA256": installed_digest,
            "initialSettingsModePreserved": mode is None or stat.S_IMODE((workspace / ".claude/settings.local.json").lstat().st_mode) == mode})
    except ERRORS as error:
        report = {"prepared": False, "failureType": type(error).__name__,
            "configurationCleanup": cleanup_configuration(directory, state), "providerLaunched": False}
        exclusive_json(directory / "preparation-failure.json", report)
        return report
    return {"prepared": True, "ownedHookCount": len(gate.EVENTS), "providerLaunched": False,
            "sourceHost": "t3", "hookTransportInterface": "standalone-cli"}


def bind(directory):
    state = state_for(directory)
    if Path.cwd().resolve() != Path(state["workspace"]):
        raise ValueError("boundWorkspaceMismatch")
    session = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if str(uuid.UUID(session)) != session:
        raise ValueError("ownRuntimeSessionIdentityUnavailable")
    exclusive_json(directory / "runtime-identity-private.json", {"schemaVersion": 1, "nativeSessionID": session,
        "identitySource": "own-runtime-CLAUDE_CODE_SESSION_ID", "workingDirectory": state["workspace"]})
    return {"runtimeIdentityRecorded": True, "nativeIdentityPublished": False, "historyRead": False}


def wait_ready(directory, *, clock=time.monotonic, sleep=time.sleep):
    state = state_for(directory)
    runtime = gate.read_json(directory / "runtime-identity-private.json")[0]
    if (Path.cwd().resolve() != Path(state["workspace"])
            or os.environ.get("CLAUDE_CODE_SESSION_ID") != runtime.get("nativeSessionID")):
        raise ValueError("sameBoundRuntimeRequired")
    started = clock()
    try:
        budget = gate.read_json(directory / "wait-budget-private.json")[0]
    except FileNotFoundError:
        exclusive_json(directory / "wait-budget-private.json", {"startedMonotonic": started})
        budget = {"startedMonotonic": started}
    initial = budget.get("startedMonotonic")
    if type(initial) not in (int, float) or not math.isfinite(initial) or not 0 <= initial <= started:
        raise ValueError("invalidWaitBudget")
    end = min(started + 45, initial + 360)
    while clock() < end:
        try:
            gate.admission(directory)
            return {"collectorReady": True, "waitBudgetExhausted": False}
        except FileNotFoundError:
            pass
        sleep(min(0.2, max(0, end - clock())))
    return {"collectorReady": False, "waitBudgetExhausted": clock() >= initial + 360}


def register_source(directory, state):
    runtime, digest, _ = gate.read_json(directory / "runtime-identity-private.json")
    session = runtime.get("nativeSessionID")
    if (not isinstance(session, str) or str(uuid.UUID(session)) != session
            or runtime.get("workingDirectory") != state["workspace"]
            or runtime.get("identitySource") != "own-runtime-CLAUDE_CODE_SESSION_ID"):
        raise ValueError("ownRuntimeIdentityRequired")
    source = gate.native_source(state["workspace"], session)
    payload = selected._read(source, 2 * 1024 * 1024)
    manifest = {"schemaVersion": 2, "sourceInterface": "t3", "nativeSessionId": session,
        "originalTranscriptPath": str(source), "workingDirectory": state["workspace"],
        "producerVersion": state["producerVersion"], "hostVersion": state["hostVersion"],
        "identitySource": runtime["identitySource"], "originalTranscriptPathDerivedThenVerified": True,
        "runtimeIdentityPath": str(directory / "runtime-identity-private.json"), "runtimeIdentitySHA256": digest,
        "sourceRegistrationByteCount": len(payload), "sourceRegistrationSHA256": hashlib.sha256(payload).hexdigest()}
    exclusive_json(directory / "manifest.json", manifest)
    _, binding = selected.registration_snapshot(directory / "manifest.json", "t3")
    _, native, _ = selected.native_checkpoint(source, session)
    if "PROMPT" not in native.get("typedMarkers", []) or "FINAL" in native.get("typedMarkers", []):
        raise ValueError("onlyIncompleteOwnedFixtureRequired")
    return manifest, binding


def task_receipt(path, *, completed=False, initial=None):
    value, digest, _ = gate.read_json(path)
    if any(not isinstance(value.get(key), str) or not value[key] or len(value[key]) > 2048 for key in TASK_KEYS):
        raise ValueError("externalT3TaskReceiptRequired")
    if initial is not None and any(value[key] != initial[key] for key in TASK_KEYS):
        raise ValueError("sameDelegatedTaskRequired")
    if completed and (value.get("status") != "completed" or value.get("workState") != "result_available"
            or value.get("hasPendingChildRuns") is not False):
        raise ValueError("terminalT3TaskRequired")
    return {key: value[key] for key in TASK_KEYS}, digest


def collector_command(directory, state, source_root):
    command = desktop.collector_command(directory, state, source_root)
    return [PROFILE if item == desktop.PROFILE else "t3" if item == "desktop-code" else item for item in command]


def hook_evidence(directory):
    path = directory / "hook-counts-private.jsonl"
    raw = selected._read(path, gate.MAX_JOURNAL)
    if not raw.endswith(b"\n"):
        raise ValueError("completeHookJournalRequired")
    counts, failures = {}, 0
    for line in raw.splitlines():
        row = json.loads(line, object_pairs_hook=gate.unique)
        if (not isinstance(row, dict) or set(row) != {"event", "helperExitCode"}
                or row["event"] not in gate.EVENTS or type(row["helperExitCode"]) is not int):
            raise ValueError("controlledHookJournalRequired")
        counts[row["event"]] = counts.get(row["event"], 0) + 1
        failures += row["helperExitCode"] != 0
    return {"originalHookCallbacksForwarded": sum(counts.values()), "forwardedCountsByEvent": counts,
            "helperFailures": failures, "passed": sum(counts.values()) > 0 and failures == 0}


def gate_integrity(directory):
    expected = gate.read_json(directory / "gate-integrity-private.json")[0]
    actual = {"gateSHA256": hashlib.sha256(Path(gate.__file__).read_bytes()).hexdigest(),
        "wrapperSHA256": hashlib.sha256(selected._read(directory / "owned-hook", 65536)).hexdigest(),
        "configSHA256": gate.read_json(directory / "gate-config-private.json")[1]}
    return expected == actual


def completion_evidence(directory, initial):
    if gate.read_json(directory / "task-start-private.json")[0] != initial:
        raise ValueError("initialTaskReceiptChanged")
    receipt = directory / "task-finish-private.json"
    task_receipt(receipt, completed=True, initial=initial)
    digest = gate.read_json(receipt)[1]
    completion = gate.read_json(directory / "producer-finished.json")[0]
    if completion != {"outcome": "complete", "taskReceiptSHA256": digest}:
        raise ValueError("terminalTaskReceiptChanged")
    return completion


def observe(args):
    directory = desktop.private_root(args.directory)
    state = state_for(directory)
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("freshOutputRequired")
    report = {"schemaVersion": 1, "passed": False, "sourceHost": "t3", "hookTransportInterface": "standalone-cli",
        "hostVersion": state["hostVersion"], "providerProducerVersion": state["producerVersion"],
        "hostOriginIndependentlyVerified": False, "hostEvidenceSource": "externalT3DelegatedTaskReceipts",
        "activeSourcePrimed": False, "profileCatchupEnabled": False, "manualCaptureInjected": False,
        "replayPerformed": False, "providerLaunchedByRunner": False, "unrelatedHistoryEnumerated": False,
        "authenticationCopied": False, "settingsUIInstallationMeasured": False,
        "rememberedConnectionVerificationMeasured": False}
    process, cleanup, candidate, binding, task = None, None, None, None, None
    native, before_final, baseline_empty = {}, False, False
    termination = {"finishSignalWritten": False, "normalWaitCompleted": False,
                   "processGroupStopped": False, "readySignalRemoved": False, "callbacksDrainedBeforeShutdown": False}
    try:
        if (directory / "store").exists() or (directory / "store").is_symlink() or not 30 <= args.duration <= 1800:
            raise ValueError("freshVaultAndBoundedDurationRequired")
        task, task_digest = task_receipt(args.task_record)
        exclusive_json(directory / "task-start-private.json", task)
        report["initialTaskReceiptSHA256"] = task_digest
        manifest, binding = register_source(directory, state)
        source, session = Path(manifest["originalTranscriptPath"]), manifest["nativeSessionId"]
        settings = settings_snapshot(Path(state["workspace"]))[0]
        if not owned_hooks_exact(settings, state, directory) or not gate_integrity(directory):
            raise ValueError("ownedRegistrationOrGateChanged")
        app = Path(state["app"])
        candidate = live.candidate_snapshot(Path(state["candidateManifest"]), state["expectedBundleSHA256"], app)
        if candidate != state["candidateBinding"]:
            raise ValueError("preparedCandidateChanged")
        report.update(candidateBinding=candidate, sourceRegistrationBinding=binding)
        if subprocess.run(["/usr/bin/pgrep", "-x", "Spillcheck"], capture_output=True).returncode != 1:
            raise ValueError("signedAppAbsenceNotEstablished")
        exclusive_json(directory / "observation-started.json", {"started": True})
        with (directory / "app-stdout-private.bin").open("xb") as stdout, \
                (directory / "app-stderr-private.bin").open("xb") as stderr:
            process = subprocess.Popen(collector_command(directory, state, source.parent),
                stdout=stdout, stderr=stderr, start_new_session=True)
            ready = live.wait_for_report(process, directory / "app-report.json", desktop.empty_baseline, 30)
            baseline_empty = desktop.empty_baseline(ready)
            if not baseline_empty:
                raise ValueError("emptyCollectorBaselineUnavailable")
            _, native_before, source_before = selected.native_checkpoint(source, session)
            if "FINAL" in native_before.get("typedMarkers", []):
                raise ValueError("producerCompletedBeforeReadiness")
            # Identity admission scopes only the pass-through gate. Neither record supplies
            # a source, native session or synthetic capture to the empty signed collector.
            exclusive_json(directory / "gate-admission-private.json", {
                "session": session, "source": str(source), "workspace": state["workspace"],
                "registrationID": state["registrationID"], "runtimeIdentitySHA256": manifest["runtimeIdentitySHA256"]})
            exclusive_json(directory / "ready.json", {"collectorReady": True, "emptyBaseline": True,
                "registrationID": state["registrationID"]})
            deadline = time.monotonic() + args.duration
            while process.poll() is None and time.monotonic() < deadline and not (directory / "producer-finished.json").exists():
                current = live.read_report(directory / "app-report.json")
                if not before_final:
                    try:
                        paths, current_native, _ = selected.native_checkpoint(source, session)
                        before_final = desktop.new_marker_before_final(current, native_before, current_native,
                            selected.source_appended_since(source_before, paths))
                    except (OSError, ValueError, selected.NativeEvidenceFailure):
                        pass
                time.sleep(0.2)
            completion = completion_evidence(directory, task) if (directory / "producer-finished.json").exists() else {}
            gate.admission(directory)
            report["admissionUnchangedBeforeShutdown"] = (
                gate.read_json(directory / "gate-admission-private.json")[0] == {
                    "session": session, "source": str(source), "workspace": state["workspace"],
                    "registrationID": state["registrationID"], "runtimeIdentitySHA256": manifest["runtimeIdentitySHA256"]})
            close_admission(directory)
            termination["callbacksDrainedBeforeShutdown"] = True
            settled = live.settled_report(process, directory / "app-report.json")
            _, native, _ = selected.native_checkpoint(source, session)
            forwarded = hook_evidence(directory)
            passed = desktop.ordinary_gate(settled, native, state["producerVersion"], baseline_empty=baseline_empty,
                before_final=before_final, producer_finished=completion.get("outcome") == "complete") and forwarded["passed"]
            proof = {"passed": passed, "emptyCollectorBaseline": baseline_empty,
                "newNativeMarkerCommittedBeforeFinal": before_final, "producerOutcome": completion.get("outcome", "timeout"),
                "nativeSourceEvidence": native, "result": settled, "ordinaryHookForwarding": forwarded,
                "manualCaptureInjected": False, "replayPerformed": False}
            exclusive_json(directory / "ordinary-hook-proof.json", proof)
            report.update(ordinaryHookProof=proof, terminalTaskReceiptSHA256=completion.get("taskReceiptSHA256"),
                externalT3TaskCompletionRecorded=completion.get("outcome") == "complete")
    except ERRORS as error:
        report["controlledFailureType"] = type(error).__name__
    finally:
        # Drain admitted callbacks before the collector shuts down, including a
        # helper whose launching Python callback was cancelled by the host.
        try:
            report["ownedHooksUnchangedBeforeCleanup"] = owned_hooks_exact(
                settings_snapshot(Path(state["workspace"]))[0], state, directory)
        except ERRORS:
            report["ownedHooksUnchangedBeforeCleanup"] = False
        if not termination["callbacksDrainedBeforeShutdown"]:
            try:
                close_admission(directory)
                termination["callbacksDrainedBeforeShutdown"] = True
            except ERRORS as error:
                termination["callbackDrainFailureType"] = type(error).__name__
        try:
            for name in ("ready.json", "gate-admission-private.json"):
                (directory / name).unlink(missing_ok=True)
            termination["readySignalRemoved"] = True
        except ERRORS as error:
            termination["readySignalFailureType"] = type(error).__name__
        if process is not None:
            try:
                exclusive_json(directory / "collector-finish", {"finished": True})
                termination["finishSignalWritten"] = True
            except ERRORS as error:
                termination["finishSignalFailureType"] = type(error).__name__
            try:
                process.wait(timeout=35)
                termination["normalWaitCompleted"] = True
            except ERRORS as error:
                termination["normalWaitFailureType"] = type(error).__name__
            try:
                cleanup = desktop.stop_group(process)
                termination["processGroupStopped"] = not cleanup["term_permission_denied"] and not cleanup["kill_permission_denied"]
            except ERRORS as error:
                termination["processGroupFailureType"] = type(error).__name__
        report.update(cleanup_configuration(directory, state), termination=termination)
    result = live.read_report(directory / "app-report.json")
    try:
        clean = desktop.ciphertext_clean(directory / "store")
        unchanged = candidate is not None and live.candidate_snapshot(Path(state["candidateManifest"]),
            state["expectedBundleSHA256"], Path(state["app"])) == candidate
        _, final_binding = selected.registration_snapshot(directory / "manifest.json", "t3")
        registration_unchanged = final_binding == binding
        integrity = gate_integrity(directory)
        forwarding = hook_evidence(directory)
        completion_evidence(directory, task)
        task_unchanged = task_receipt(args.task_record)[1] == report["initialTaskReceiptSHA256"]
    except ERRORS as error:
        clean = unchanged = registration_unchanged = integrity = task_unchanged = False
        forwarding = {"passed": False}
        report["finalEvidenceFailureType"] = type(error).__name__
    report.update(result=result, candidateUnchanged=unchanged, sourceRegistrationUnchanged=registration_unchanged,
        gateIntegrityUnchanged=integrity, finalHookForwarding=forwarding,
        externalTaskReceiptsUnchanged=task_unchanged,
        signedAppExitCode=process.returncode if process else None, processGroupCleanup=cleanup,
        ciphertextMarkerInspectionPassed=clean, originalSourceModified=False,
        newVaultCleanupConfirmed=result.get("newVaultCleanupPassed") is True)
    report.update(desktop.final_collection_checks(report.get("ordinaryHookProof", {}), result, state["producerVersion"]))
    report["passed"] = bool(report.get("ordinaryHookProof", {}).get("passed") and unchanged and registration_unchanged
        and integrity and forwarding.get("passed") and report.get("externalT3TaskCompletionRecorded")
        and task_unchanged and report.get("admissionUnchangedBeforeShutdown")
        and report.get("ownedHooksUnchangedBeforeCleanup")
        and report["finalOrdinaryHookGatePassed"] and report["postShutdownInventoryStable"]
        and process is not None and process.returncode == 0 and result.get("newVaultCleanupPassed") is True
        and all(termination[field] for field in ("finishSignalWritten", "normalWaitCompleted", "processGroupStopped", "readySignalRemoved", "callbacksDrainedBeforeShutdown"))
        and report["cleaned"] and clean)
    report["passScope"] = "Ordinary-hook discovery of an externally attested T3-owned fake Claude task and its native child; twelve markers, all five types per role, live-before-final commits. Configured standalone-cli transport is shared-profile evidence, not host attribution. No source priming, history, replay, UI setup or remembered-connection claim."
    exclusive_json(output, report)
    return report


def finish(directory, task_result):
    state_for(directory)
    gate.admission(directory)
    initial = gate.read_json(directory / "task-start-private.json")[0]
    value, digest, _ = gate.read_json(task_result)
    task_receipt(task_result, initial=initial)
    if value.get("status") not in {"completed", "failed", "cancelled", "interrupted"} or value.get("hasPendingChildRuns") is not False:
        raise ValueError("terminalTaskWithoutPendingRunsRequired")
    outcome = "error"
    if value["status"] == "completed":
        task_receipt(task_result, completed=True, initial=initial)
        outcome = "complete"
    exclusive_json(directory / "task-finish-private.json", value)
    digest = gate.read_json(directory / "task-finish-private.json")[1]
    exclusive_json(directory / "producer-finished.json", {"outcome": outcome, "taskReceiptSHA256": digest})
    return {"signaled": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    preparation = sub.add_parser("prepare")
    preparation.add_argument("--directory", required=True, type=Path)
    preparation.add_argument("--workspace", required=True, type=Path)
    preparation.add_argument("--app", required=True, type=Path)
    preparation.add_argument("--configuration-executable", required=True, type=Path)
    preparation.add_argument("--producer-version", required=True)
    preparation.add_argument("--host-version", required=True)
    preparation.add_argument("--candidate-manifest", required=True, type=Path)
    preparation.add_argument("--expected-bundle-sha256", required=True)
    for operation in ("bind", "wait-ready", "cleanup"):
        sub.add_parser(operation).add_argument("--directory", required=True, type=Path)
    observer = sub.add_parser("observe")
    observer.add_argument("--directory", required=True, type=Path)
    observer.add_argument("--task-record", required=True, type=Path)
    observer.add_argument("--output", required=True, type=Path)
    observer.add_argument("--duration", type=int, default=600)
    completion = sub.add_parser("finish")
    completion.add_argument("--directory", required=True, type=Path)
    completion.add_argument("--task-result", required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.operation == "prepare":
            result = prepare(args)
        elif args.operation == "observe":
            result = observe(args)
        else:
            directory = desktop.private_root(args.directory)
            if args.operation == "bind":
                result = bind(directory)
            elif args.operation == "wait-ready":
                result = wait_ready(directory)
            elif args.operation == "finish":
                result = finish(directory, args.task_result)
            else:
                result = cleanup_configuration(directory, state_for(directory))
    except ERRORS as error:
        print(json.dumps({"passed": False, "controlledFailureType": type(error).__name__}))
        return 1
    fields = ("prepared", "passed", "signaled", "cleaned", "runtimeIdentityRecorded", "collectorReady", "waitBudgetExhausted",
        "failureType", "controlledFailureType", "configurationCleanup", "providerLaunched", "ownedHookCount")
    print(json.dumps({key: result[key] for key in fields if key in result}, sort_keys=True))
    if args.operation == "wait-ready":
        return 1 if result.get("waitBudgetExhausted") else 0
    outcome = {"prepare": "prepared", "observe": "passed", "finish": "signaled", "cleanup": "cleaned", "bind": "runtimeIdentityRecorded"}[args.operation]
    return 0 if result.get(outcome) is True else 1


if __name__ == "__main__":
    raise SystemExit(main())
