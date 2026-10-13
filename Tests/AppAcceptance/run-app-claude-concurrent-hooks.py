#!/usr/bin/env python3
"""One unprimed signed collector, three runtime-bound genuine Claude hosts.

Preparation does not launch apps/providers. Explicit produce-cli and observe
commands own their respective processes. Desktop and T3 remain externally driven.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import shlex
import shutil
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


t3 = module("concurrent_t3", Path(__file__).with_name("run-app-claude-t3-hooks.py"))
desktop, gate, selected, live = t3.desktop, t3.gate, t3.selected, t3.live
sys.path.insert(0, str(ROOT / "Tests"))
from Support.claude_concurrent_evidence import inspect_concurrent_sources, LANE_FIELDS

PROFILE = "owned-concurrent-claude-hooks"
HOSTS = ("cli", "desktop", "t3")
FINAL_ORDER = ("desktop", "cli", "t3")
ERRORS = t3.ERRORS
MCP_NAME = "spillcheck_concurrent_synthetic"
HERE = Path(__file__).resolve()
MAX_EXECUTABLE_BYTES = 512 * 1024 * 1024


def shared_clock():
    """An explicit system clock for stamps compared by independent Python processes."""
    read = getattr(time, "clock_gettime", None)
    clock_id = getattr(time, "CLOCK_MONOTONIC", None)
    if not callable(read) or clock_id is None:
        raise ValueError("sharedMonotonicClockUnavailable")
    try:
        value = read(clock_id)
    except (OSError, ValueError):
        raise ValueError("sharedMonotonicClockUnavailable") from None
    if type(value) not in (float, int) or not math.isfinite(value) or value < 0:
        raise ValueError("sharedMonotonicClockUnavailable")
    return value


class ProducerFailure(ValueError):
    def __init__(self, code, host=None):
        super().__init__(code)
        self.code, self.host = code, host


def require_producers_active(directory, released=()):
    for name, code in (("observer-aborted.json", "observer-aborted"), ("collection-closed.json", "collection-closed")):
        path = directory / name
        if path.exists() or path.is_symlink():
            raise ProducerFailure(code)
    for host in HOSTS:
        path = lane_directory(directory, host) / "producer-finished.json"
        if not path.exists() and not path.is_symlink():
            continue
        result = gate.read_json(path)[0]
        if host not in released:
            raise ProducerFailure("producer-finished-before-release", host)
        if result.get("completed") is not True:
            raise ProducerFailure("producer-failed", host)


def executable_sha256(path):
    """Hash one canonical owned executable without using transcript byte limits."""
    path = Path(path)
    if not path.is_absolute() or path != path.resolve():
        raise ValueError("canonicalExecutableRequired")
    directory = gate.directory_fd(path.parent)
    descriptor = None
    try:
        parent_before = os.fstat(directory)
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1
                or not before.st_mode & stat.S_IXUSR or not 0 < before.st_size <= MAX_EXECUTABLE_BYTES):
            raise ValueError("ownedBoundedRegularExecutableRequired")
        def identity(value):
            return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns,
                value.st_uid, value.st_mode, value.st_nlink)
        digest, count = hashlib.sha256(), 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, MAX_EXECUTABLE_BYTES + 1 - count))
            if not chunk:
                break
            count += len(chunk)
            if count > MAX_EXECUTABLE_BYTES:
                raise ValueError("executableByteBudgetExceeded")
            digest.update(chunk)
        if (count != before.st_size or identity(before) != identity(os.fstat(descriptor))
                or identity(before) != identity(os.stat(path.name, dir_fd=directory, follow_symlinks=False))):
            raise ValueError("executableChangedDuringHash")
        current_parent = gate.directory_fd(path.parent)
        try:
            after = os.fstat(current_parent)
            if (parent_before.st_dev, parent_before.st_ino) != (after.st_dev, after.st_ino):
                raise ValueError("executableDirectoryChangedDuringHash")
        finally:
            os.close(current_parent)
        return digest.hexdigest()
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(directory)


def state_for(directory):
    directory = desktop.private_root(directory)
    state = gate.read_json(directory / "preparation-private.json")[0]
    if (state.get("schemaVersion") != 1 or state.get("directory") != str(directory)
            or state.get("profile") != PROFILE or set(state.get("lanes", {})) != set(HOSTS)):
        raise ValueError("ownedConcurrentPreparationRequired")
    for host in HOSTS:
        lane = state["lanes"][host]
        workspace = Path(lane["workspace"])
        if lane.get("host") != host or workspace != workspace.resolve() or not workspace.is_absolute():
            raise ValueError("originalBoundWorkspaceRequired")
        claude_desktop.require_owned_project_root(workspace)
    return state


def lane_directory(directory, host):
    if host not in HOSTS:
        raise ValueError("knownHostRequired")
    return directory / host


def helper_args(directory):
    return ["--socket", str(directory / "store/capture.sock"), "--agent", "claude-code",
            "--interface", "standalone-cli", "--profile-id", PROFILE]


def hook_command(directory, state, host, remove=False):
    lane = state["lanes"][host]
    command = [state["configurationExecutable"], "--claude-configure-hook", "--settings",
        str(Path(lane["workspace"]) / ".claude/settings.local.json"), "--helper",
        str(lane_directory(directory, host) / "owned-hook"), "--socket", str(directory / "store/capture.sock"),
        "--profile", PROFILE, "--version", lane["producerVersion"], "--registration-id", lane["registrationID"]]
    return command + (["--remove-hook"] if remove else [])


def owned_hooks_exact(settings, directory, state, host):
    if not isinstance(settings, dict) or not isinstance(settings.get("hooks", {}), dict):
        return False
    marker, found = "Spillcheck hook " + state["lanes"][host]["registrationID"], set()
    for event, groups in settings.get("hooks", {}).items():
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
                if (set(group) != {"hooks"} or len(group["hooks"]) != 1 or event in found
                        or handler.get("type") != "command" or handler.get("timeout") != 2
                        or handler.get("command") != str(lane_directory(directory, host) / "owned-hook")
                        or handler.get("args") != helper_args(directory)):
                    return False
                found.add(event)
    return found == gate.EVENTS


def signal(directory, name, value):
    t3.exclusive_json(directory / name, value)


def pulse(place, value):
    temporary = ".heartbeat-" + str(uuid.uuid4())
    signal(place, temporary, value)
    fd = gate.directory_fd(place)
    try:
        os.replace(temporary, "final-heartbeat-private.json", src_dir_fd=fd, dst_dir_fd=fd)
    finally:
        os.close(fd)


def all_producers_waiting(directory, lanes, now=None):
    now = shared_clock() if now is None else now
    for lane in lanes:
        place = lane_directory(directory, lane["host"])
        expected = {"runtimeIdentitySHA256": lane["runtimeIdentitySHA256"]}
        if gate.read_json(place / "at-final-barrier.json")[0] != expected:
            return False
        value = gate.read_json(place / "final-heartbeat-private.json")[0]
        at = value.get("monotonic")
        if (value.get("runtimeIdentitySHA256") != lane["runtimeIdentitySHA256"]
                or value.get("clock") != "CLOCK_MONOTONIC"
                or type(at) not in (int, float) or not math.isfinite(at) or not 0 <= now - at < 3
                or type(value.get("pid")) is not int or value["pid"] <= 0):
            return False
        os.kill(value["pid"], 0)
    return True


def helper_command(directory, host, operation):
    return shlex.join([sys.executable, str(HERE), operation, "--directory", str(directory), "--host", host])


def producer_prompt(directory, state, host):
    lane = state["lanes"][host]
    secret = live.fixture.SECRET
    if host == "t3":
        content = t3.prompt(lane_directory(directory, host), Path(lane["workspace"]))
        start = content.index("3. After collectorReady")
        end = content.index("10. After the native child")
        body = content[start:end].replace("collectorReady is exactly true", "released is exactly true")
    else:
        content = live.fixture.PROMPT
        start = content.index("1. Your first assistant")
        end = content.index("6. End with")
        body = content[start:end].replace("spillcheck_synthetic", MCP_NAME)
    return f"""Authorized fake-only Spillcheck concurrency test. Work in exactly {lane['workspace']}, using this genuine {host} session. Every value below is synthetic and must never be used for authentication. Do not read repository files, histories, settings, credentials, environment listings, or unrelated tabs. Do not create a worktree or launch another provider. User marker LEAKRET_M3_PROMPT {secret}.
First use Bash to run: {helper_command(directory, host, 'bind')}
Stop if runtimeIdentityRecorded is not true. Never print the session UUID.
Next use Bash to run: {helper_command(directory, host, 'wait-ready')}
Repeat while released is false and waitBudgetExhausted is false, at most twenty calls. Each waits at most 40 seconds. Stop on any error. Do not emit any fixture response/tool markers before released is true.
Then perform these fixture steps once. Native Agent and MCP tools are required; stop if unavailable. Preserve the two intentional errors. Never repeat tool-only markers in assistant text.
{body}
After the child has finished and any owned blank tab is closed, use Bash to run: {helper_command(directory, host, 'wait-final')}
Repeat while released is false and waitBudgetExhausted is false, at most twenty calls. Do not end the conversation or emit the final marker until released is true. Never write control, settings, source, readiness, or completion files yourself. The helper writes only owned control files.
Once released is true, reply exactly LEAKRET_M3_FINAL {secret}.
"""


def prepare(args):
    progress = {"stage": "preparation-path"}
    try:
        return _prepare(args, progress)
    except ERRORS as error:
        return {"prepared": False, "failureType": type(error).__name__, "failureStage": progress["stage"],
            "providerLaunched": False, "signedAppLaunched": False}


def _prepare(args, progress):
    directory = args.directory.absolute()
    if (directory.exists() or directory.is_symlink() or directory != directory.resolve()
            or len(str(directory / "store/capture.sock").encode()) >= 104):
        raise ValueError("freshShortCanonicalDirectoryRequired")
    os.close(gate.directory_fd(directory.parent))
    progress["stage"] = "preparation-clock"
    shared_clock()
    progress["stage"] = "preparation-workspace"
    workspace = args.workspace.resolve()
    claude_desktop.require_owned_project_root(workspace)
    app = args.app.resolve()
    progress["stage"] = "preparation-candidate"
    candidate = live.candidate_snapshot(args.candidate_manifest, args.expected_bundle_sha256, app)
    if candidate is None:
        raise ValueError("immutableCandidateRequired")
    executable = args.cli_executable.resolve()
    progress["stage"] = "preparation-executable"
    executable_digest = executable_sha256(executable)
    progress["stage"] = "preparation-files"
    directory.mkdir(mode=0o700)
    lanes = {}
    for host in HOSTS:
        place = lane_directory(directory, host)
        if host == "t3":
            place.mkdir(mode=0o700)
        else:
            claude_desktop.prepare(place)
        work = workspace if host == "t3" else place / "work"
        before, digest, mode = t3.settings_snapshot(work)
        lanes[host] = {"host": host, "workspace": str(work), "registrationID": str(uuid.uuid4()),
            "producerVersion": args.desktop_version if host == "desktop" else args.cli_version,
            "hostVersion": args.desktop_host_version if host == "desktop" else args.t3_host_version if host == "t3" else args.cli_version,
            "initialSettingsSHA256": digest, "initialSettingsMode": mode,
            "settingsDirectoryCreated": not (work / ".claude").exists()}
    state = {"schemaVersion": 1, "directory": str(directory), "profile": PROFILE, "lanes": lanes,
        "app": str(app), "candidateManifest": str(args.candidate_manifest.resolve()),
        "expectedBundleSHA256": args.expected_bundle_sha256, "candidateBinding": candidate,
        "configurationExecutable": str(args.configuration_executable.resolve()),
        "cliExecutable": str(executable), "cliExecutableSHA256": executable_digest,
        "cliSessionID": str(uuid.uuid4())}
    signal(directory, "preparation-private.json", state)
    try:
        for host in HOSTS:
            progress["stage"] = {"cli": "preparation-cli-hooks", "desktop": "preparation-desktop-hooks",
                "t3": "preparation-t3-hooks"}[host]
            lane, place = lanes[host], lane_directory(directory, host)
            work = Path(lane["workspace"])
            before, _, mode = t3.settings_snapshot(work)
            if lane["settingsDirectoryCreated"]:
                (work / ".claude").mkdir(mode=0o700)
                info = (work / ".claude").lstat()
                signal(place, "settings-directory-private.json", {"device": info.st_dev, "inode": info.st_ino})
            gate_path = Path(gate.__file__).resolve()
            wrapper = (f"#!{sys.executable}\nimport runpy, sys\nsys.argv = [{str(gate_path)!r}, {str(place)!r}, *sys.argv[1:]]\n"
                f"runpy.run_path({str(gate_path)!r}, run_name='__main__')\n").encode()
            t3.exclusive_bytes(place / "owned-hook", wrapper, 0o700)
            t3.exclusive_bytes(place / "callback.lock", b"")
            info = (place / "callback.lock").lstat()
            signal(place, "gate-config-private.json", {"directory": str(place), "workspace": str(work),
                "registrationID": lane["registrationID"], "helper": str(app / "Contents/Helpers/spillcheck-hook"),
                "helperArgs": helper_args(directory), "lockIdentity": {"device": info.st_dev, "inode": info.st_ino}})
            signal(place, "gate-integrity-private.json", {"gateSHA256": hashlib.sha256(gate_path.read_bytes()).hexdigest(),
                "wrapperSHA256": hashlib.sha256(wrapper).hexdigest(),
                "configSHA256": gate.read_json(place / "gate-config-private.json")[1]})
            installed = subprocess.run(hook_command(directory, state, host), capture_output=True, timeout=15)
            after, _, _ = t3.settings_snapshot(work)
            if mode is not None and after is not None:
                t3.restore_mode(work / ".claude/settings.local.json", mode)
            if (installed.returncode != 0 or not owned_hooks_exact(after, directory, state, host)
                    or claude_desktop.without_registration(after, lane["registrationID"]) != (before or {})):
                raise ValueError("ownedNineHookInstallRequired")
            if host != "t3":
                fixture = work / "mcp_fixture.py"
                t3.exclusive_bytes(fixture, (ROOT / "Tests/ClaudeLive/mcp_fixture.py").read_bytes())
                mcp = {"mcpServers": {MCP_NAME: {"command": sys.executable, "args": [str(fixture)]}}}
                raw = (json.dumps(mcp, indent=2, sort_keys=True) + "\n").encode()
                signal(place, "owned-mcp-private.json", {"sha256": hashlib.sha256(raw).hexdigest()})
                t3.exclusive_bytes(work / ".mcp.json", raw)
            t3.exclusive_bytes(place / "PROMPT.txt", producer_prompt(directory, state, host).encode())
    except ERRORS as error:
        result = {"prepared": False, "failureType": type(error).__name__, "failureStage": progress["stage"],
            "configurationCleanup": cleanup(directory, state), "providerLaunched": False, "signedAppLaunched": False}
        signal(directory, "preparation-failure.json", result)
        return result
    return {"prepared": True, "ownedHookCount": 27, "providerLaunched": False, "signedAppLaunched": False}


def bound_runtime(directory, state, host):
    place, lane = lane_directory(directory, host), state["lanes"][host]
    runtime, digest, _ = gate.read_json(place / "runtime-identity-private.json")
    session = runtime.get("nativeSessionID")
    if (not isinstance(session, str) or str(uuid.UUID(session)) != session
            or runtime.get("schemaVersion") != 1 or runtime.get("workingDirectory") != lane["workspace"]
            or runtime.get("identitySource") != "own-runtime-CLAUDE_CODE_SESSION_ID"
            or host == "cli" and session != state["cliSessionID"]):
        raise ValueError("ownRuntimeBindingRequired")
    return runtime, digest


def bind(directory, host):
    state = state_for(directory)
    lane, place = state["lanes"][host], lane_directory(directory, host)
    session = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if (Path.cwd().resolve() != Path(lane["workspace"]) or str(uuid.UUID(session)) != session
            or host == "cli" and session != state["cliSessionID"]):
        raise ValueError("ownRuntimeIdentityUnavailable")
    signal(place, "runtime-identity-private.json", {"schemaVersion": 1, "nativeSessionID": session,
        "workingDirectory": lane["workspace"], "identitySource": "own-runtime-CLAUDE_CODE_SESSION_ID"})
    return {"runtimeIdentityRecorded": True, "nativeIdentityPublished": False}


def wait_release(directory, host, final=False, *, clock=time.monotonic, sleep=time.sleep, shared=shared_clock):
    state = state_for(directory)
    runtime, _ = bound_runtime(directory, state, host)
    if (os.environ.get("CLAUDE_CODE_SESSION_ID") != runtime["nativeSessionID"]
            or str(Path.cwd().resolve()) != runtime["workingDirectory"]):
        raise ValueError("sameBoundRuntimeRequired")
    place = lane_directory(directory, host)
    name = "final" if final else "ready"
    try:
        budget = gate.read_json(place / (name + "-wait-budget-private.json"))[0]
    except FileNotFoundError:
        budget = {"clock": "CLOCK_MONOTONIC", "startedMonotonic": shared()}
        signal(place, name + "-wait-budget-private.json", budget)
    started = budget.get("startedMonotonic")
    if (budget.get("clock") != "CLOCK_MONOTONIC" or type(started) not in (float, int)
            or not math.isfinite(started) or not 0 <= started <= shared()):
        raise ValueError("boundedWaitRequired")
    if final:
        gate.admission(place)
        try:
            signal(place, "at-final-barrier.json", {"runtimeIdentitySHA256": bound_runtime(directory, state, host)[1]})
        except FileExistsError:
            pass
    deadline = clock() + min(40, max(0, 800 - (shared() - started)))
    while clock() < deadline:
        if (directory / "observer-aborted.json").exists() or (directory / "collection-closed.json").exists():
            raise ValueError("collectorClosed")
        if final:
            pulse(place, {"runtimeIdentitySHA256": bound_runtime(directory, state, host)[1],
                "clock": "CLOCK_MONOTONIC", "monotonic": shared(), "pid": os.getpid()})
        try:
            gate.admission(place)
            if not final or gate.read_json(place / "final-release.json")[0] == {"released": True}:
                return {"released": True, "waitBudgetExhausted": False}
        except FileNotFoundError:
            pass
        sleep(min(1, max(0, deadline - clock())))
    return {"released": False, "waitBudgetExhausted": shared() >= started + 800}


def register_sources(directory, state):
    lanes = []
    for host in HOSTS:
        runtime, digest = bound_runtime(directory, state, host)
        lane, place = state["lanes"][host], lane_directory(directory, host)
        source = gate.native_source(lane["workspace"], runtime["nativeSessionID"])
        raw = selected._read(source, 2 * 1024 * 1024)
        item = dict(lane, nativeSessionID=runtime["nativeSessionID"], originalTranscriptPath=str(source),
            runtimeIdentityPath=str(place / "runtime-identity-private.json"), runtimeIdentitySHA256=digest,
            sourceRegistrationByteCount=len(raw), sourceRegistrationSHA256=hashlib.sha256(raw).hexdigest())
        lanes.append({key: item[key] for key in LANE_FIELDS})
    _, evidence, _ = inspect_concurrent_sources(lanes, live.fixture.SECRET, require_complete=False)
    if (evidence.get("admittedUniverseValid") is not True
            or any("PROMPT" not in value.get("typedMarkers", []) or "FINAL" in value.get("typedMarkers", [])
                for value in evidence["hosts"].values())):
        raise ValueError("incompleteProducersRequired")
    signal(directory, "source-bindings-private.json", {"lanes": lanes})
    return lanes


def collector_command(directory, state):
    return [str(Path(state["app"]) / "Contents/MacOS/Spillcheck"), "--store-directory", str(directory / "store"),
        "--claude-profile", PROFILE, "--claude-version", state["lanes"]["cli"]["producerVersion"],
        "--claude-interface", "standalone-cli", "--claude-authorized-host", "standalone-cli",
        "--claude-authorized-host", "desktop-code", "--claude-authorized-host", "t3",
        "--claude-source-root", str(Path.home() / ".claude/projects"), "--acceptance-no-profile-catchup",
        "--acceptance-cleanup-new-vault", "--acceptance-claude-role-evidence", "--acceptance-hold",
        "--acceptance-report", str(directory / "app-report.json"), "--acceptance-finish-file",
        str(directory / "collector-finish"), "--acceptance-seconds", "120"]


def counts_for(state, completed):
    result = {}
    for host in completed:
        version = state["lanes"][host]["producerVersion"]
        result[version] = result.get(version, 0) + 1
    return result


def healthy(report):
    return (report.get("storageReady") is True and report.get("collectionConfigured") is True
        and report.get("coverageReportTruncated") is False and report.get("gapReasons") == []
        and report.get("transportRejectionCountsByStageAndReason") == {}
        and type(report.get("queueCount")) is int and report["queueCount"] == 0)


def exact_pairs(report, state, completed):
    actual = report.get("claudeCommittedNativeParentChildPairCountByProducer")
    return (isinstance(actual, dict) and all(type(n) is int and n > 0 for n in actual.values())
        and actual == counts_for(state, completed))


def before_final_native(evidence):
    expected = set(live.fixture.EXPECTED_MARKERS) - {"FINAL"}
    return all(expected <= set(evidence["hosts"][host].get("typedMarkers", []))
        and "FINAL" not in evidence["hosts"][host].get("typedMarkers", []) for host in HOSTS)


def close_all(directory):
    result = {}
    for host in HOSTS:
        place = lane_directory(directory, host)
        drained, signals_removed = False, True
        try:
            t3.close_admission(place)
            drained = True
        except FileNotFoundError:
            drained = not any((place / name).exists() for name in ("ready.json", "gate-admission-private.json"))
        except ERRORS:
            pass
        for name in ("ready.json", "gate-admission-private.json", "final-release.json"):
            try:
                (place / name).unlink(missing_ok=True)
            except ERRORS:
                signals_removed = False
        result[host] = {"callbacksDrained": drained, "signalsRemoved": signals_removed}
    return result


def cleanup(directory, state=None):
    state = state or state_for(directory)
    closed = True
    try:
        signal(directory, "collection-closed.json", {"closed": True})
    except FileExistsError:
        pass
    except ERRORS:
        closed = False
    closures, lanes = close_all(directory), {}
    for host in HOSTS:
        lane, place = state["lanes"][host], lane_directory(directory, host)
        work = Path(lane["workspace"])
        item = dict(closures[host], hooksRemoved=False, unownedSettingsPreserved=False, ownedMCPRemoved=host == "t3")
        try:
            before, _, mode = t3.settings_snapshot(work)
            if before is None:
                item.update(hooksRemoved=True, unownedSettingsPreserved=True)
            else:
                result = subprocess.run(hook_command(directory, state, host, True), capture_output=True, timeout=15)
                after, _, _ = t3.settings_snapshot(work)
                if after is None:
                    raise ValueError("settingsDisappearedDuringCleanup")
                t3.restore_mode(work / ".claude/settings.local.json", mode)
                item["hooksRemoved"] = result.returncode == 0 and claude_desktop.without_registration(after, lane["registrationID"]) == after
                item["unownedSettingsPreserved"] = (claude_desktop.without_registration(before, lane["registrationID"])
                    == claude_desktop.without_registration(after, lane["registrationID"]) and stat.S_IMODE((work / ".claude/settings.local.json").lstat().st_mode) == mode)
            if lane["settingsDirectoryCreated"]:
                t3.remove_owned_empty_settings_directory(place, lane)
        except ERRORS as error:
            item["hookCleanupFailureType"] = type(error).__name__
        if host != "t3":
            try:
                item["ownedMCPRemoved"] = desktop.remove_mcp(place)
            except ERRORS as error:
                item["mcpCleanupFailureType"] = type(error).__name__
        item["cleaned"] = all(item.get(key) is True for key in
            ("callbacksDrained", "signalsRemoved", "hooksRemoved", "unownedSettingsPreserved", "ownedMCPRemoved"))
        lanes[host] = item
    return {"lanes": lanes, "collectionClosedSignalWritten": closed,
        "cleaned": closed and all(item["cleaned"] for item in lanes.values())}


def produce_cli(directory, duration):
    state = state_for(directory)
    place, lane = lane_directory(directory, "cli"), state["lanes"]["cli"]
    executable = Path(state["cliExecutable"])
    if not 60 <= duration <= 1800 or executable_sha256(executable) != state["cliExecutableSHA256"]:
        raise ValueError("boundCLIExecutableRequired")
    version = subprocess.check_output([str(executable), "--version"], timeout=15).decode().split()[0]
    if version != lane["producerVersion"]:
        raise ValueError("exactCLIProducerVersionRequired")
    command = [str(executable), "--print", "--verbose", "--output-format", "stream-json",
        "--include-partial-messages", "--include-hook-events", "--forward-subagent-text", "--dangerously-skip-permissions",
        "--setting-sources", "project,local", "--strict-mcp-config", "--mcp-config", str(Path(lane["workspace"]) / ".mcp.json"),
        "--session-id", state["cliSessionID"], "--max-budget-usd", "5"]
    process, cleanup_result = None, None
    result = {"completed": False, "host": "cli", "executableSHA256": state["cliExecutableSHA256"],
        "producerVersion": version, "sharedProfileAuthenticationCopied": False}
    try:
        with (place / "provider-stdout-private.bin").open("xb") as out, (place / "provider-stderr-private.bin").open("xb") as err:
            environment = os.environ.copy()
            environment.pop("CLAUDE_CONFIG_DIR", None)
            process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=out, stderr=err,
                cwd=lane["workspace"], env=environment, start_new_session=True)
            signal(place, "process-start-private.json", {"pid": process.pid, "sessionID": state["cliSessionID"],
                "executableSHA256": state["cliExecutableSHA256"], "producerVersion": version})
            process.stdin.write((place / "PROMPT.txt").read_bytes())
            process.stdin.close()
            deadline = time.monotonic() + duration
            while process.poll() is None and time.monotonic() < deadline:
                if (directory / "observer-aborted.json").exists() or (directory / "collection-closed.json").exists():
                    raise ValueError("collectorAborted")
                if out.tell() + err.tell() > 16 * 1024 * 1024:
                    raise ValueError("providerOutputBudgetExceeded")
                time.sleep(0.2)
            if process.poll() is None:
                raise TimeoutError("boundedCLIProducerTimeout")
            result["completed"] = process.returncode == 0
    except ERRORS as error:
        result["failureType"] = type(error).__name__
    finally:
        if process is not None:
            try:
                cleanup_result = desktop.stop_group(process)
            except ERRORS as error:
                result["cleanupFailureType"] = type(error).__name__
        result.update(exitCode=process.returncode if process else None, processGroupCleanup=cleanup_result)
        result["completed"] = bool(result["completed"] and cleanup_result and not cleanup_result["term_permission_denied"] and not cleanup_result["kill_permission_denied"])
        signal(place, "producer-finished.json", result)
    return result


def record_external(directory, host, receipt):
    state = state_for(directory)
    place = lane_directory(directory, host)
    bound_runtime(directory, state, host)
    value, digest, _ = gate.read_json(receipt)
    if host == "t3":
        initial = gate.read_json(place / "task-start-private.json")[0]
        t3.task_receipt(receipt, completed=True, initial=initial)
    elif host == "desktop":
        expected = {"sourceHost": "official-claude-desktop", "originalLocalWorkspace": True,
            "normalHookReviewCompleted": True, "finalResponseObserved": True,
            "producerVersion": state["lanes"][host]["producerVersion"], "hostVersion": state["lanes"][host]["hostVersion"]}
        if value != expected:
            raise ValueError("exactDesktopAttestationRequired")
    else:
        raise ValueError("CLICompletionMustComeFromOwnedProcess")
    signal(place, "external-finish-private.json", value)
    committed_digest = gate.read_json(place / "external-finish-private.json")[1]
    signal(place, "producer-finished.json", {"completed": True, "externalReceiptSHA256": committed_digest,
        "originalExternalReceiptSHA256": digest})
    return {"recorded": True, "host": host}


def completion_evidence(directory, state):
    for host in HOSTS:
        place = lane_directory(directory, host)
        result = gate.read_json(place / "producer-finished.json")[0]
        if result.get("completed") is not True:
            return False
        if host == "cli":
            started = gate.read_json(place / "process-start-private.json")[0]
            if (started.get("sessionID") != state["cliSessionID"] or started.get("executableSHA256") != state["cliExecutableSHA256"]
                    or result.get("exitCode") != 0 or result.get("executableSHA256") != state["cliExecutableSHA256"]):
                return False
        else:
            value, digest, _ = gate.read_json(place / "external-finish-private.json")
            if digest != result.get("externalReceiptSHA256"):
                return False
            if host == "t3":
                t3.task_receipt(place / "external-finish-private.json", completed=True,
                    initial=gate.read_json(place / "task-start-private.json")[0])
            elif value.get("finalResponseObserved") is not True:
                return False
    return True


def completion_snapshot(directory, initial_task):
    if gate.read_json(directory / "t3/task-start-private.json")[0] != initial_task:
        raise ValueError("originalT3TaskIdentityChanged")
    names = [f"{host}/producer-finished.json" for host in HOSTS] + ["cli/process-start-private.json",
        "t3/task-start-private.json", "t3/external-finish-private.json", "desktop/external-finish-private.json"]
    return {name: gate.read_json(directory / name)[1] for name in names}


def completion_unchanged(directory, state, initial_task, frozen):
    return bool(frozen) and completion_evidence(directory, state) and completion_snapshot(directory, initial_task) == frozen


def native_sources_unchanged(directory, lanes, native, frozen, initial_state_digest):
    _, final_native, final_sources = inspect_concurrent_sources(lanes, live.fixture.SECRET)
    return (bool(frozen) and final_sources == frozen and final_native == native
        and gate.read_json(directory / "source-bindings-private.json")[0] == {"lanes": lanes}
        and gate.read_json(directory / "preparation-private.json")[1] == initial_state_digest)


def final_gate(report, state, native, overlap, stages, completed):
    return (healthy(report) and overlap and completed and len(stages) == 3
        and all(item == {"host": host, "passed": True,
            "expectedCommittedPairsByProducer": counts_for(state, FINAL_ORDER[:index + 1])}
            for index, (host, item) in enumerate(zip(FINAL_ORDER, stages)))
        and live.strict_role_coverage_complete(report) and exact_pairs(report, state, HOSTS)
        and native.get("passed") is True and native.get("allThreePairsComplete") is True
        and native.get("admittedUniverseValid") is True
        and type(native.get("nativeCanonicalSessionCount")) is int and 3 <= native["nativeCanonicalSessionCount"] <= 6
        and type(report.get("syntheticSessionCount")) is int and report["syntheticSessionCount"] == native["nativeCanonicalSessionCount"]
        and set(report.get("observedAgentVersions", [])) == set(counts_for(state, HOSTS)))


def observe(args):
    directory, output = desktop.private_root(args.directory), args.output.absolute()
    state = state_for(directory)
    if output.exists() or output.is_symlink():
        raise ValueError("freshOutputRequired")
    report = {"schemaVersion": 1, "passed": False, "activeSourcePrimed": False, "profileCatchupEnabled": False,
        "manualCaptureInjected": False, "replayPerformed": False, "unrelatedHistoryEnumerated": False,
        "sharedHookTransport": "standalone-cli", "hostOriginInferredFromTransport": False}
    process, cleanup_result, candidate = None, None, None
    lanes, native, stages, proof, proof_sources, proof_completion, task = [], {}, [], {}, {}, {}, None
    initial_state_digest = gate.read_json(directory / "preparation-private.json")[1]
    termination = {name: False for name in ("callbacksDrained", "finishSignalWritten", "normalWaitCompleted", "processGroupStopped")}
    overlap = False
    phase = "binding"
    try:
        shared_clock()
        require_producers_active(directory)
        if (directory / "store").exists() or (directory / "store").is_symlink() or not 60 <= args.duration <= 1800:
            raise ValueError("freshVaultAndBoundedDurationRequired")
        task, _ = t3.task_receipt(args.task_record)
        signal(directory / "t3", "task-start-private.json", task)
        lanes = register_sources(directory, state)
        for host in HOSTS:
            if (not owned_hooks_exact(t3.settings_snapshot(Path(state["lanes"][host]["workspace"]))[0], directory, state, host)
                    or not t3.gate_integrity(lane_directory(directory, host))):
                raise ValueError("ownedHooksOrGateChanged")
        candidate = live.candidate_snapshot(Path(state["candidateManifest"]), state["expectedBundleSHA256"], Path(state["app"]))
        if candidate != state["candidateBinding"]:
            raise ValueError("preparedCandidateChanged")
        report["candidateBinding"] = candidate
        if subprocess.run(["/usr/bin/pgrep", "-x", "Spillcheck"], capture_output=True).returncode != 1:
            raise ValueError("signedAppAbsenceNotEstablished")
        with (directory / "app-stdout-private.bin").open("xb") as out, (directory / "app-stderr-private.bin").open("xb") as err:
            phase = "empty-readiness"
            process = subprocess.Popen(collector_command(directory, state), stdout=out, stderr=err, start_new_session=True)
            baseline = live.wait_for_report(process, directory / "app-report.json", desktop.empty_baseline, 30)
            if not desktop.empty_baseline(baseline):
                raise ValueError("emptyCollectorBaselineUnavailable")
            _, before_native, before_sources = inspect_concurrent_sources(lanes, live.fixture.SECRET, require_complete=False)
            if (before_native.get("admittedUniverseValid") is not True
                    or any("FINAL" in item.get("typedMarkers", []) for item in before_native["hosts"].values())):
                raise ValueError("incompleteProducersAtCollectorReadinessRequired")
            for lane in lanes:
                place = lane_directory(directory, lane["host"])
                registration = state["lanes"][lane["host"]]["registrationID"]
                signal(place, "gate-admission-private.json", {"session": lane["nativeSessionID"], "source": lane["originalTranscriptPath"],
                    "workspace": lane["workspace"], "registrationID": registration, "runtimeIdentitySHA256": lane["runtimeIdentitySHA256"]})
                signal(place, "ready.json", {"collectorReady": True, "emptyBaseline": True, "registrationID": registration})
            deadline = time.monotonic() + args.duration
            phase = "concurrent-barrier"
            while process.poll() is None and time.monotonic() < deadline:
                require_producers_active(directory)
                try:
                    if all((lane_directory(directory, host) / "at-final-barrier.json").exists() for host in HOSTS):
                        paths, native, _ = inspect_concurrent_sources(lanes, live.fixture.SECRET, require_complete=False)
                        all_growth = all(selected.source_appended_since(
                            {key: value for key, value in before_sources.items() if key[0] == lane["originalTranscriptPath"]},
                            [path for path in paths if str(path[0]) == lane["originalTranscriptPath"]]) for lane in lanes)
                        current = live.read_report(directory / "app-report.json")
                        overlap = (native.get("admittedUniverseValid") is True and before_final_native(native)
                            and all_growth and all_producers_waiting(directory, lanes) and healthy(current)
                            and exact_pairs(current, state, ())
                            and current.get("syntheticSessionCount") == native.get("nativeCanonicalSessionCount")
                            and type(current.get("syntheticOccurrenceCount")) is int and current["syntheticOccurrenceCount"] > 0
                            and not any((lane_directory(directory, host) / "producer-finished.json").exists() for host in HOSTS))
                        if overlap:
                            signal(directory, "concurrent-before-final-proof.json", {"passed": True,
                                "allThreeRuntimeBoundAtFinalBarrier": True, "allThreeNativeParentsGrewAfterReadiness": True,
                                "collectionGrowthWhileAllFinalsAbsent": True, "perHostCommittedBeforeFinalMeasured": False,
                                "nativeSourceEvidence": native, "result": current})
                            break
                except ERRORS:
                    pass
                time.sleep(0.2)
            if not overlap:
                raise ValueError("concurrentPublicationBarrierUnavailable")
            for index, host in enumerate(FINAL_ORDER):
                phase = {"desktop": "staged-final-desktop", "cli": "staged-final-cli", "t3": "staged-final-t3"}[host]
                signal(lane_directory(directory, host), "final-release.json", {"released": True})
                completed = FINAL_ORDER[:index + 1]
                passed = False
                while process.poll() is None and time.monotonic() < deadline:
                    require_producers_active(directory, completed)
                    try:
                        _, native, _ = inspect_concurrent_sources(lanes, live.fixture.SECRET, require_complete=False)
                        native_finished = {name for name in HOSTS if "FINAL" in native["hosts"][name].get("typedMarkers", [])}
                        current = live.read_report(directory / "app-report.json")
                        passed = (native.get("admittedUniverseValid") is True and native_finished == set(completed)
                            and healthy(current) and exact_pairs(current, state, completed))
                        if passed:
                            break
                    except ERRORS:
                        pass
                    time.sleep(0.2)
                stages.append({"host": host, "passed": passed, "expectedCommittedPairsByProducer": counts_for(state, completed)})
                if not passed:
                    raise ValueError("stagedExactPairCoverageUnavailable")
            phase = "external-completion"
            while process.poll() is None and time.monotonic() < deadline:
                require_producers_active(directory, HOSTS)
                try:
                    if completion_evidence(directory, state):
                        break
                except FileNotFoundError:
                    pass
                time.sleep(0.2)
            completed = completion_evidence(directory, state)
            phase = "callback-drain"
            closure = close_all(directory)
            termination["callbacksDrained"] = all(item["callbacksDrained"] and item["signalsRemoved"] for item in closure.values())
            if not termination["callbacksDrained"]:
                raise ValueError("allCallbacksMustDrainBeforeProof")
            current = live.settled_report(process, directory / "app-report.json")
            phase = "final-proof"
            _, native, proof_sources = inspect_concurrent_sources(lanes, live.fixture.SECRET)
            proof_completion = completion_snapshot(directory, task)
            forwarding = {host: t3.hook_evidence(lane_directory(directory, host)) for host in HOSTS}
            passed = final_gate(current, state, native, overlap, stages, completed) and all(item["passed"] for item in forwarding.values())
            proof = {"passed": passed, "emptyCollectorBaseline": True, "concurrentProductionMeasured": overlap,
                "stageProofs": stages, "nativeSourceEvidence": native, "result": current,
                "originalHookForwardingByHost": forwarding, "externalAndOwnedProducerCompletionVerified": completed}
            signal(directory, "ordinary-hook-proof.json", proof)
    except ERRORS as error:
        report["controlledFailureType"] = type(error).__name__
        report["failureStage"] = phase
        if isinstance(error, ProducerFailure):
            report["producerFailureCode"] = error.code
            if error.host is not None:
                report["producerFailureHost"] = error.host
        try:
            signal(directory, "observer-aborted.json", {"aborted": True})
        except ERRORS:
            pass
    finally:
        try:
            report["ownedHooksUnchangedBeforeCleanup"] = all(owned_hooks_exact(
                t3.settings_snapshot(Path(state["lanes"][host]["workspace"]))[0], directory, state, host) for host in HOSTS)
        except ERRORS:
            report["ownedHooksUnchangedBeforeCleanup"] = False
        closure = close_all(directory)
        termination["callbacksDrained"] = termination["callbacksDrained"] or all(item["callbacksDrained"] and item["signalsRemoved"] for item in closure.values())
        if process is not None:
            for name, action in (
                ("finishSignalWritten", lambda: signal(directory, "collector-finish", {"finished": True})),
                ("normalWaitCompleted", lambda: process.wait(timeout=35))):
                try:
                    action()
                    termination[name] = True
                except ERRORS as error:
                    report[name + "FailureType"] = type(error).__name__
            try:
                cleanup_result = desktop.stop_group(process)
                termination["processGroupStopped"] = not cleanup_result["term_permission_denied"] and not cleanup_result["kill_permission_denied"]
            except ERRORS as error:
                report["processCleanupFailureType"] = type(error).__name__
        report["configurationCleanup"] = cleanup(directory, state)
    result = live.read_report(directory / "app-report.json")
    checks = {"candidateUnchanged": False, "nativeBindingsUnchanged": False, "gatesUnchanged": False,
        "ciphertextMarkerInspectionPassed": False, "producerCompletionUnchanged": False}
    try:
        checks["candidateUnchanged"] = candidate is not None and live.candidate_snapshot(Path(state["candidateManifest"]), state["expectedBundleSHA256"], Path(state["app"])) == candidate
        checks["nativeBindingsUnchanged"] = native_sources_unchanged(directory, lanes, native, proof_sources, initial_state_digest)
        checks["gatesUnchanged"] = all(t3.gate_integrity(lane_directory(directory, host)) for host in HOSTS)
        checks["ciphertextMarkerInspectionPassed"] = desktop.ciphertext_clean(directory / "store")
        checks["producerCompletionUnchanged"] = completion_unchanged(directory, state, task, proof_completion)
    except ERRORS as error:
        report["finalEvidenceFailureType"] = type(error).__name__
    stable = all(type(proof.get("result", {}).get(key)) is int and type(result.get(key)) is int
        and result[key] == proof["result"][key] for key in desktop.FINAL_COUNTS)
    final_ok = final_gate(result, state, native, overlap, stages, checks["producerCompletionUnchanged"])
    report.update(checks, ordinaryHookProof=proof, result=result, termination=termination,
        signedAppExitCode=process.returncode if process else None, processGroupCleanup=cleanup_result,
        postShutdownInventoryStable=stable, finalCollectionGatePassed=final_ok)
    report["passed"] = bool(proof.get("passed") and all(checks.values()) and stable and final_ok
        and report["ownedHooksUnchangedBeforeCleanup"] and all(termination.values())
        and report["configurationCleanup"]["cleaned"] and process is not None and process.returncode == 0
        and result.get("newVaultCleanupPassed") is True)
    report["unmetGates"] = [name for name, passed in (
        ("frozen-proof", proof.get("passed") is True), ("unchanged-evidence", all(checks.values())),
        ("post-shutdown-inventory", stable), ("final-collection", final_ok),
        ("owned-configuration", report["ownedHooksUnchangedBeforeCleanup"] and report["configurationCleanup"]["cleaned"]),
        ("normal-shutdown", all(termination.values()) and process is not None and process.returncode == 0),
        ("creator-vault-cleanup", result.get("newVaultCleanupPassed") is True)) if not passed]
    report["passScope"] = "Concurrent genuine CLI/Desktop/T3 native publication to one unprimed shared-profile collector; staged receipt-backed twelve-marker/five-type completion for each bound parent and its sole child. Host origin uses owned CLI process plus external Desktop/T3 receipts. No claim of per-host committed-before-final timing, side questions, history, UI setup, or remembered connection verification."
    signal(output.parent, output.name, report)
    return report


def operation_exit_code(operation, result):
    if operation in ("wait-ready", "wait-final"):
        # A bounded wait that has not released yet is normal producer progress.
        return 0 if result.get("released") is True or result.get("waitBudgetExhausted") is False else 1
    key = {"prepare": "prepared", "observe": "passed", "produce-cli": "completed", "cleanup": "cleaned",
        "bind": "runtimeIdentityRecorded", "finish": "recorded"}[operation]
    return 0 if result.get(key) is True else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    p = sub.add_parser("prepare")
    for name in ("directory", "workspace", "app", "configuration-executable", "candidate-manifest", "cli-executable"):
        p.add_argument("--" + name, required=True, type=Path)
    for name in ("expected-bundle-sha256", "cli-version", "desktop-version", "desktop-host-version", "t3-host-version"):
        p.add_argument("--" + name, required=True)
    for operation in ("bind", "wait-ready", "wait-final", "finish"):
        p = sub.add_parser(operation)
        p.add_argument("--directory", required=True, type=Path)
        p.add_argument("--host", required=True, choices=HOSTS)
        if operation == "finish":
            p.add_argument("--receipt", required=True, type=Path)
    for operation in ("observe", "produce-cli", "cleanup"):
        p = sub.add_parser(operation)
        p.add_argument("--directory", required=True, type=Path)
        if operation != "cleanup":
            p.add_argument("--duration", type=int, default=1200)
        if operation == "observe":
            p.add_argument("--task-record", required=True, type=Path)
            p.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        directory = args.directory.absolute()
        if args.operation == "prepare":
            result = prepare(args)
        elif args.operation == "bind":
            result = bind(directory, args.host)
        elif args.operation in ("wait-ready", "wait-final"):
            result = wait_release(directory, args.host, args.operation == "wait-final")
        elif args.operation == "finish":
            result = record_external(directory, args.host, args.receipt)
        elif args.operation == "produce-cli":
            result = produce_cli(directory, args.duration)
        elif args.operation == "cleanup":
            result = cleanup(directory)
        else:
            result = observe(args)
        print(json.dumps(result, sort_keys=True))
        return operation_exit_code(args.operation, result)
    except ERRORS as error:
        print(json.dumps({"passed": False, "controlledFailureType": type(error).__name__, "operation": args.operation}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
