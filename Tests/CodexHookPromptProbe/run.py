#!/usr/bin/env python3
"""Normally reviewed one-shot Stop hook, then two exact native HookPrompt reads.

Import and boundary tests never launch a provider or access authentication.
"""
import argparse
import errno
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import struct
import subprocess
import sys
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[2]
VERSION = "0.162.1"
PARSER = "codex-content-contract-v16"
MAXIMUM = 2 * 1024 * 1024


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


common = load("hook_probe_common", ROOT / "Tests/CodexPlanProbe/run.py")
fixture = load("hook_probe_fixture", Path(__file__).with_name("fixture.py"))
require, ProbeFailure = common.require, common.ProbeFailure
SOURCE_INPUTS = [Path(__file__).resolve(), Path(__file__).with_name("fixture.py"),
    ROOT / "Tests/CodexPlanProbe/run.py", ROOT / "Tests/CodexLive/run.py",
    ROOT / "Tests/Support/processes.py", ROOT / "Tests/SpillcheckCoreTests/CodexHookPromptLiveTests.swift"]


def prompts(helper):
    identity = ("This is an isolated fake-only hook test. Run only this exact command:\n"
        + shlex.join([sys.executable, str(helper), "identity"])
        + "\nStop if recorded is not true. Do not read any other files or use other tools. "
        + "Then reply with only the following line, without punctuation or formatting:\n" + fixture.IDENTITY_FINAL)
    before = "Do not use tools. Reply with only the following line, without punctuation or formatting:\n" + fixture.BEFORE
    require(fixture.REASON_MARKER not in identity + before, "human-input-contains-reason")
    return identity, before


def identity_gate(value, root):
    return (isinstance(value, dict) and common.native_id(value.get("threadID"))
        and value.get("home") == str(root / "home") and value.get("cwd") == str(root / "work")
        and value.get("nativeIdentitySource") == "own-runtime-CODEX_THREAD_ID"
        and value.get("sourceEnumerationPerformed") is False)


def labels(data):
    text = data.decode("utf-8", "replace")
    text = re.sub(r"\x1b\][^\x07]*(?:\x07|\x1b\\)", "", text)
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
    compact = re.sub(r"\s+", "", text).casefold()
    return {"folder": "trustthisfolder?" in compact,
        "oneHook": "1hookisneworchanged" in compact,
        "reviewMenu": all(x in compact for x in ("1.reviewhooks", "2.trustallandcontinue", "3.continuewithouttrusting")),
        "trustFooter": all(x in compact for x in ("ttrustall", "enterreview", "escclose")),
        "detailsFooter": all(x in compact for x in ("enterdetails", "escclose"))}


def review_action(state, actions):
    if (not actions and state["folder"] and not any(state[k] for k in ("reviewMenu", "trustFooter", "detailsFooter"))):
        return "folder"
    if state["reviewMenu"] and state["oneHook"] and "review" not in actions and "trust" not in actions:
        return "review"
    if state["trustFooter"] and "review" in actions and "trust" not in actions:
        return "trust"
    if state["detailsFooter"] and actions and actions[-1] == "trust": return "escape"
    return None


class ReviewScheduler:
    """Wait past Codex's bounded post-draw input quarantine without retrying keys."""
    def __init__(self):
        self.candidate = None
        self.observed_at = None

    def ready(self, state, actions, now):
        action = review_action(state, actions)
        if action != self.candidate:
            self.candidate, self.observed_at = action, now if action else None
        if action is None or now - self.observed_at < 1.1: return None
        return action


def review_stage(actions):
    if "trust" in actions: return "hook-trust-acknowledgement", 20
    if "review" in actions: return "hook-browser-review", 20
    return "startup-hook-menu", 40


def progress(control, stage, terminal, started, sequence):
    # Only fixed stage/action names, allowlisted flags and byte counts survive.
    value = {"schemaVersion": 1, "stage": stage, "elapsedSeconds": round(time.monotonic() - started, 3),
             "actions": list(terminal.actions), "labels": labels(terminal.current),
             "terminalBytesObserved": terminal.total, "sinceActionBytesRetained": len(terminal.current)}
    common.write_json(control / ("progress-%02d.json" % sequence), value)
    return value


def callback_rows(root, completed=True):
    starts = sorted((root / "callbacks").glob("*.json"))
    require(len(starts) <= 8, "callback-budget")
    rows = []
    for path in starts:
        start = common.decode(common.private_bytes(path, 4096))
        require(all(type(start.get(k)) is int and 1 < start[k] < 2 ** 31
                    for k in ("pid", "pgid", "parentPID")), "callback-process-identity")
        done = path.with_suffix(".done")
        if done.exists():
            row = common.decode(common.private_bytes(done, 4096))
            require(all(row.get(k) == start[k] for k in ("pid", "pgid", "parentPID")), "callback-process-changed")
            rows.append(row)
        elif completed:
            raise ProbeFailure("callback-incomplete")
        else: rows.append(start)
    return rows


def callback_gate(rows, thread, work, producer_pid=None):
    if not 3 <= len(rows) <= 8: return False
    if not all(row.get("valid") is True and row.get("sessionID") == thread
        and fixture.turn_identifier(row.get("turnID")) and row.get("cwd") == str(work) for row in rows): return False
    if producer_pid is not None and not all(isinstance(row.get("ancestorPIDs"), list)
        and 1 <= len(row["ancestorPIDs"]) <= 8 and row["ancestorPIDs"][0] == row.get("parentPID")
        and row["ancestorPIDs"][-1] == producer_pid and row.get("producerPID") == producer_pid
        for row in rows): return False
    outcomes = [row.get("outcome") for row in rows]
    return (outcomes.count("identity-complete") == 1 and outcomes.count("blocked") == 1
        and outcomes.count("continued") == 1 and len(outcomes) == 3
        and all(row.get("stopHookActive") is (row["outcome"] == "continued") for row in rows))


def absent(pid, group=False):
    try:
        (os.killpg if group else os.kill)(pid, 0)
        return False
    except ProcessLookupError: return True
    except (PermissionError, OSError): return False


def callbacks_stopped(rows, timeout=2):
    deadline = time.monotonic() + timeout
    while True:
        if all(absent(row["pid"]) and absent(row["pgid"], True) for row in rows): return True
        if time.monotonic() >= deadline: return False
        time.sleep(.02)


def callback_summary(rows):
    outcomes = {key: 0 for key in ("identity-complete", "blocked", "continued", "unarmed", "already-blocked",
        "unexpected-final", "unexpected-continuation", "invalid-callback", "incomplete")}
    shape_keys = ("object", "eventMatches", "sessionMatches", "cwdMatches", "turnBounded", "stopActiveBoolean",
                  "assistantTextString", "childFieldsAbsent")
    for row in rows: outcomes[row.get("outcome") if row.get("outcome") in outcomes else "incomplete"] += 1
    return {"schemaVersion": 1, "callbackCount": len(rows), "validCount": sum(row.get("valid") is True for row in rows),
        "outcomeCounts": outcomes,
        "shapeTrueCounts": {key: sum(row.get("shape", {}).get(key) is True for row in rows) for key in shape_keys}}


def terminal_session():
    os.setsid(); fcntl.ioctl(0, termios.TIOCSCTTY, 0)


class Terminal:
    def __init__(self, executable, root, lifetime, control):
        self.process = None; self.master = None; self.current = b""; self.total = 0
        self.actions = []; self.lifetime = lifetime
        self.deadline = time.monotonic() + 300
        master, slave = pty.openpty(); self.master = master
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 160, 0, 0))
            env = common.environment(root, root / "home"); env["TERM"] = "xterm-256color"
            self.process = subprocess.Popen([str(executable), "--no-daemon", "--no-alt-screen", "-a", "never",
                "-s", "workspace-write", "-C", str(root / "work")], cwd=root / "work", env=env,
                stdin=slave, stdout=slave, stderr=slave, preexec_fn=terminal_session)
            lifetime["producerStopped"] = False; lifetime["providerLaunchCount"] += 1
            common.write_json(control / "producer-process.json", {"pid": self.process.pid,
                "pgid": self.process.pid, "ownedRoot": str(root)})
            common.write_json(root / "producer-process.json", {"pid": self.process.pid})
        except BaseException:
            self.stop()
            raise
        finally: os.close(slave)

    def pump(self):
        require(time.monotonic() < self.deadline, "producer-timeout")
        require(self.process.poll() is None, "producer-exited-before-completion")
        ready, _, _ = select.select([self.master], [], [], .05)
        if not ready: return
        try: data = os.read(self.master, 65536)
        except OSError as error:
            if error.errno == errno.EIO: data = b""
            else: raise
        self.total += len(data); require(self.total <= MAXIMUM, "terminal-output-budget")
        if b"\x1b[6n" in data: os.write(self.master, b"\x1b[1;1R")
        self.current = (self.current + data)[-65536:]

    def send(self, action, data):
        os.write(self.master, data); self.actions.append(action); self.current = b""

    def submit(self, action, text):
        self.send(action + "-paste", b"\x1b[200~" + text.encode() + b"\x1b[201~")
        end = time.monotonic() + .25
        while time.monotonic() < end: self.pump()
        self.send(action + "-enter", b"\r")

    def stop(self):
        try:
            if self.process is not None:
                result = common.processes.stop_group(self.process)
                self.lifetime["producerStopped"] = (self.process.poll() is not None
                    and not result["term_permission_denied"] and not result["kill_permission_denied"])
        finally:
            if self.master is not None:
                try: os.close(self.master)
                finally: self.master = None


def produce(executable, root, lifetime, control):
    terminal = None; stage = "startup-hook-menu"; started = time.monotonic(); sequence = 0
    try:
        terminal = Terminal(executable, root, lifetime, control)
        scheduler = ReviewScheduler(); stage_started = time.monotonic()
        progress(control, stage, terminal, started, sequence); sequence += 1
        while "escape" not in terminal.actions:
            terminal.pump()
            current_stage, budget = review_stage(terminal.actions)
            if current_stage != stage:
                stage, stage_started = current_stage, time.monotonic()
                progress(control, stage, terminal, started, sequence); sequence += 1
            require(time.monotonic() - stage_started < budget, "hook-review-stage-timeout")
            action = scheduler.ready(labels(terminal.current), terminal.actions, time.monotonic())
            if action:
                progress(control, stage, terminal, started, sequence); sequence += 1
                terminal.send(action, {"folder": b"\r", "review": b"1", "trust": b"t", "escape": b"\x1b"}[action])
        review_hashes = {"hookDefinitionSHA256": common.digest((root / "home/hooks.json").read_bytes()),
                         "handlerSHA256": common.digest((root / "work/fixture.py").read_bytes())}
        stage = "binding-owned-session"
        progress(control, stage, terminal, started, sequence); sequence += 1
        identity_prompt, before_prompt = prompts(root / "work/fixture.py")
        terminal.submit("identity", identity_prompt)
        identity = None
        while True:
            terminal.pump()
            if (root / "work/identity.json").exists():
                identity = common.decode(common.private_bytes(root / "work/identity.json", 4096))
                require(identity_gate(identity, root), "owned-identity-unverified")
                rows = callback_rows(root, completed=False)
                if any(row.get("outcome") == "identity-complete" for row in rows): break
        common.write_json(root / "armed.json", {"schemaVersion": 1})
        stage = "awaiting-native-continuation"
        progress(control, stage, terminal, started, sequence); sequence += 1
        terminal.submit("fixture", before_prompt)
        while True:
            terminal.pump(); rows = callback_rows(root, completed=False)
            if any(row.get("outcome") == "continued" for row in rows): break
            require(not any(row.get("outcome") in ("invalid-callback", "unexpected-final", "unexpected-continuation")
                            for row in rows), "callback-contract-mismatch")
        require(callback_gate(rows, identity["threadID"], root / "work", terminal.process.pid), "callback-sequence-unverified")
        stage = "normal-provider-quit"
        progress(control, stage, terminal, started, sequence); sequence += 1
        terminal.submit("quit", "/quit")
        end = time.monotonic() + 10
        while terminal.process.poll() is None and time.monotonic() < end:
            try: terminal.pump()
            except ProbeFailure:
                if terminal.process.poll() is None: raise
        require(terminal.process.poll() == 0, "producer-normal-shutdown-unverified")
        require(review_hashes == {"hookDefinitionSHA256": common.digest((root / "home/hooks.json").read_bytes()),
                                 "handlerSHA256": common.digest((root / "work/fixture.py").read_bytes())}, "trusted-definition-changed")
        common.write_json(control / "owned-native-selection.json", {**identity,
            "callbackTurnID": next(row["turnID"] for row in rows if row["outcome"] == "blocked"),
            "identityPrompt": identity_prompt, "fixturePrompt": before_prompt, "reason": fixture.REASON,
            "identityCommand": shlex.join([sys.executable, str(root / "work/fixture.py"), "identity"]),
            "allowedIdentityCommands": allowed_commands(root / "work/fixture.py")})
        return identity, {"normalOneHookReviewObserved": True, "normalTrustObserved": True,
            "postTrustDetailsObserved": True, "normalProducerShutdown": True, "callbackCount": len(rows),
            "oneShotBlockCount": 1, "activeContinuationCount": 1, "ownRuntimeIdentityRecorded": True,
            "hookDefinitionUnchangedAfterTrust": True, "reasonAbsentHumanPrompts": True, **review_hashes}
    except BaseException:
        common.write_json(control / "producer-failure.json", {"stage": stage,
            "labels": labels(terminal.current) if terminal else {}, "actions": terminal.actions if terminal else [],
            "elapsedSeconds": round(time.monotonic() - started, 3),
            "terminalBytesObserved": terminal.total if terminal else 0,
            "sinceActionBytesRetained": len(terminal.current) if terminal else 0})
        raise
    finally:
        try:
            if terminal is not None: terminal.stop()
        finally:
            try:
                rows = callback_rows(root, completed=False)
                lifetime["callbacksStopped"] = callbacks_stopped(rows)
            except Exception: lifetime["callbacksStopped"] = False


PASSIVE_CHECKS = {"nativeHookPromptVerified", "nativeTurnMeasured", "metadataMatches", "sourceIdentityMatches",
    "sourceBytesAndPointersPreserved", "sourceOriginVerified", "userPromptMapping", "reasonAbsentHumanInput",
    "hookRunIDMetadataOnly", "gapFree", "actualSecondRead", "replayStable", "readerShutdownCompletedWithinDeadline",
    "passive", "networkDenied", "forkDenied"}
PASSIVE_FIELDS = PASSIVE_CHECKS | {"status", "parserContract", "readerVersion", "producerVersion",
    "threadReadCalls", "itemReadCalls", "turnReadCalls", "threadListCalls", "resumeCalls",
    "hookPromptItemCount", "hookPromptSourceCount", "segmentCount", "segmentPointers", "textBytes", "textSHA256",
    "nativeTurnEqualsStopCallbackTurn", "gapReasons", "gapDiagnostics"}


def public_passive(value):
    return {key: value[key] for key in sorted(PASSIVE_FIELDS) if key in value}


def allowed_commands(helper):
    command = shlex.join([sys.executable, str(helper), "identity"])
    return [command, *[shlex.join([shell, "-lc", command]) for shell in ("/bin/zsh", "/bin/bash", "/bin/sh")]]


def passive_gate(value):
    return (all(value.get(key) is True for key in PASSIVE_CHECKS)
        and value.get("status") == "native-hook-prompt-read-and-replayed" and value.get("parserContract") == PARSER
        and value.get("readerVersion") == VERSION and value.get("producerVersion") == VERSION
        and value.get("gapReasons") == [] and value.get("gapDiagnostics") == []
        and type(value.get("nativeTurnEqualsStopCallbackTurn")) is bool
        and all(value.get(key) == expected for key, expected in {"threadReadCalls": 2, "itemReadCalls": 2,
            "turnReadCalls": 2, "threadListCalls": 0, "resumeCalls": 0, "hookPromptItemCount": 1, "hookPromptSourceCount": 1,
            "segmentCount": 1, "segmentPointers": ["/fragments/0/text"],
            "textBytes": len(fixture.REASON.encode()), "textSHA256": common.digest(fixture.REASON.encode())}.items()))


def cleanup(report, lifetime, original, original_hash, root, home, root_identity, home_identity):
    checked = dict(lifetime)
    checked["producerStopped"] = lifetime["producerStopped"] and lifetime["callbacksStopped"]
    common.finish_cleanup(report, checked, original_path=original, original_hash=original_hash,
        root=root, home=home, root_identity=root_identity, home_identity=home_identity)


def refresh_callback_cleanup(root, lifetime, report, control):
    if lifetime["producerStopped"] and lifetime["readerStopped"]:
        try:
            final_rows = callback_rows(root, completed=False)
            lifetime["callbacksStopped"] = callbacks_stopped(final_rows)
            report["callbacks"] = callback_summary(final_rows)
            common.write_json(control / "callback-summary.json", report["callbacks"])
        except Exception: lifetime["callbacksStopped"] = False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, default=Path.home() / ".local/bin/codex")
    parser.add_argument("--auth-file", type=Path, default=Path.home() / ".codex/auth.json")
    parser.add_argument("--model", default="gpt-6-astra")
    parser.add_argument("--scratch-path", type=Path, default=ROOT / ".build")
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--private-control", type=Path, required=True)
    args = parser.parse_args()
    require(re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", args.model) is not None, "invalid-model")
    require(not args.report.exists() and not args.report.is_symlink(), "report-already-exists")
    args.private_control.mkdir(mode=0o700, parents=False, exist_ok=False)
    executable = args.executable.expanduser().resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix="spillcheck-native-hook-")).resolve()
    home, work = root / "home", root / "work"
    for path in (home, work, root / "callbacks"): path.mkdir(mode=0o700)
    ri, hi = root.stat(), home.stat()
    lifetime = {"producerStopped": True, "readerStopped": True, "versionProcessStopped": True,
                "callbacksStopped": True, "providerLaunchCount": 0}
    report = {"schemaVersion": 1, "passed": False, "fixture": "one-genuine-native-hook-prompt", "model": args.model,
        "signedAppAcceptance": False, "desktopAcceptance": False, "t3Acceptance": False,
        "fullHostAcceptance": False, "detectorReceiptAcceptance": False, "generalAdditionalContextAcceptance": False,
        "authRemoved": False, "originalAuthUnchanged": False, "ownedRootRemoved": False}
    original = None
    try:
        source_hashes = {str(path.relative_to(ROOT)): common.digest(path.read_bytes()) for path in SOURCE_INPUTS}
        executable_hash = common.digest(executable.read_bytes())
        report.update(executableSHA256=executable_hash, sourceSHA256=source_hashes)
        common.write_json(args.private_control / "input-bindings.json", {
            "schemaVersion": 1, "expectedVersion": VERSION, "expectedParserContract": PARSER,
            "executableSHA256": executable_hash, "sourceSHA256": source_hashes})
        version_cleanup = {}; lifetime["versionProcessStopped"] = False
        try:
            version = common.live.observe_version(str(executable), environment=common.environment(root, home),
                directory=work, expected=VERSION, cleanup_report=version_cleanup)
        finally:
            lifetime["versionProcessStopped"] = (version_cleanup.get("leaderExited") is True
                and version_cleanup.get("groupKillPermissionDenied") is False)
        require(version == VERSION and lifetime["versionProcessStopped"], "reader-version-mismatch")
        common.exclusive(work / "fixture.py", Path(__file__).with_name("fixture.py").read_bytes())
        command = "exec " + shlex.join([sys.executable, str(work / "fixture.py"), "hook"])
        common.write_json(home / "hooks.json", {"hooks": {"Stop": [{"hooks": [{"type": "command",
            "command": command, "timeout": 3, "statusMessage": "Spillcheck fake native input probe"}]}]}})
        common.exclusive(home / "config.toml", (f'model = "{args.model}"\nweb_search = "disabled"\n'
            '[analytics]\nenabled = false\n[otel]\nexporter = "none"\n').encode())
        authentication = common.private_bytes(args.auth_file, 1024 * 1024); original = common.digest(authentication)
        common.exclusive(home / "auth.json", authentication); del authentication
        identity, producer = produce(executable, root, lifetime, args.private_control)
        report["producer"] = producer
        require(lifetime["producerStopped"] and lifetime["callbacksStopped"], "owned-process-cleanup-unconfirmed")
        report["authRemoved"] = common.cleanup_auth(home, (hi.st_dev, hi.st_ino))
        passive_path = args.private_control / "passive-report.json"
        env = dict(os.environ); env.update(common.environment(root, home))
        env.update({"SPILLCHECK_HOOK_PROBE_HOME": str(home), "SPILLCHECK_HOOK_PROBE_THREAD": identity["threadID"],
            "SPILLCHECK_HOOK_PROBE_SELECTION": str(args.private_control / "owned-native-selection.json"),
            "SPILLCHECK_HOOK_PROBE_EXECUTABLE": str(executable), "SPILLCHECK_HOOK_PROBE_REPORT": str(passive_path)})
        reader_cleanup = {}; lifetime["readerStopped"] = False
        try:
            completed, _, _ = common.live.bounded(["/usr/bin/swift", "test", "--scratch-path", str(args.scratch_path),
                "--skip-build", "--no-parallel", "--filter", "CodexHookPromptLiveTests"],
                environment=env, directory=ROOT, timeout=90, maximum_bytes=MAXIMUM, cleanup_report=reader_cleanup)
        finally:
            lifetime["readerStopped"] = (reader_cleanup.get("leaderExited") is True
                and reader_cleanup.get("groupKillPermissionDenied") is False)
        require(completed == 0, "passive-witness-process-failed")
        passive = common.decode(common.private_bytes(passive_path))
        require(passive_gate(passive), "passive-witness-unverified")
        report["passive"] = public_passive(passive)
        require(common.digest(executable.read_bytes()) == executable_hash and source_hashes == {
            str(path.relative_to(ROOT)): common.digest(path.read_bytes()) for path in SOURCE_INPUTS}, "probe-inputs-changed")
        lifetime["callbacksStopped"] = callbacks_stopped(callback_rows(root))
        report.update(probeInputsUnchanged=True, executableSHA256=executable_hash, sourceSHA256=source_hashes, passed=True)
    except ProbeFailure as error: report["failureCategory"] = str(error)
    except Exception: report["failureCategory"] = "probe-unavailable"
    finally:
        # Recheck after every passive-read outcome; never reuse a stale
        # producer-only observation to authorize credential/root removal.
        refresh_callback_cleanup(root, lifetime, report, args.private_control)
        cleanup(report, lifetime, args.auth_file, original, root, home, (ri.st_dev, ri.st_ino), (hi.st_dev, hi.st_ino))
        report.update(lifetime)
        report["passed"] = report["passed"] and all(report[k] is True for k in (
            "producerStopped", "readerStopped", "versionProcessStopped", "callbacksStopped",
            "authRemoved", "originalAuthUnchanged", "ownedRootRemoved"))
        report["privateCleanupPending"] = not report["ownedRootRemoved"]
        if not report["ownedRootRemoved"]:
            common.write_json(args.private_control / "cleanup-handoff.json", {"ownedRoot": str(root), **lifetime,
                "authenticationMayRemain": not report["authRemoved"]})
        common.write_json(args.report, report)
    print(json.dumps(report, sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
