#!/usr/bin/env python3
"""Fresh signed CLI setup and exact-source omission recovery with normal hook review."""
import argparse
import errno
import fcntl
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import socket
import stat
import struct
import subprocess
import sys
import termios
import time

spec = importlib.util.spec_from_file_location("omission_shared", Path(__file__).with_name("run-app-codex-recovery.py"))
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
ROOT, require = shared.ROOT, shared.require
PROFILE = "owned-signed-codex-omission-recovery"
COUNTS = {"userPrompt": 3, "intermediateResponse": 1, "finalResponse": 1, "toolOutput": 1, "toolError": 1}
EVENTS = {"SessionStart", "UserPromptSubmit", "PostToolUse", "SubagentStart", "SubagentStop", "Stop", "Interrupt", "SessionEnd"}
TOKEN = shared.TOKEN.decode()
FIXTURE = Path(__file__).with_name("codex_omission_fixture.py")


def fixture_prompt(work):
    command = shlex.quote(sys.executable) + " " + shlex.quote(str(work / "fixture.py"))
    return (f"Run only this fake Spillcheck test. LEAKRET_M4_PROMPT {TOKEN}. "
        f"First run {command} identity exactly once. Stop if recorded is not true. "
        f"Send commentary exactly LEAKRET_M4_INTERMEDIATE {TOKEN}. "
        f"Run {command} output, then separately run {command} error. The latter intentionally exits 7. "
        "Do not read other files, browse, use MCP, create children, or retry commands. "
        f"Finish exactly LEAKRET_M4_FINAL {TOKEN}.")


def worker_command(binary, root, version):
    return shared.command(binary, root, "worker1")[:-1] + [
        "--acceptance-recovery-worker", "--acceptance-no-profile-catchup",
        "--acceptance-recovery-install-codex-profile", "--acceptance-recovery-home", str(root / "codex-home"),
        "--acceptance-recovery-executable", str(root / "reader"), "--acceptance-recovery-version", version]


def saved_setup(report, version):
    return (report.get("recoveryCodexSetupConnected") is True and report.get("recoveryCodexProfileInstalled") is True
        and report.get("recoveryCodexObservedExecutableVersion") == version
        and all(shared.digest_set({"one": [report.get(key)]}, "one") is not None for key in
            ("recoveryCodexRegistrationDigest", "recoveryCodexConnectionProofDigest")))


def same_saved_setup(before, after):
    return all(before.get(key) is not None and before.get(key) == after.get(key) for key in
        ("recoveryCodexRegistrationDigest", "recoveryCodexConnectionProofDigest"))


def owner_failure_summary(report):
    result = {}
    category = report.get("failureCategory")
    if category in ("protection", "owner-configuration-or-lifecycle"):
        result["failureCategory"] = category
    value = report.get("startupFailure")
    phases = {"preparingStorage", "probingStorage", "loadingDeviceKeys", "openingStore", "committingBootstrap"}
    reasons = {"bootstrapBusy", "bootstrapUnsafeJournal", "bootstrapJournalUnavailable",
        "bootstrapManifestMismatch", "bootstrapCommitUnconfirmed", "bootstrapRollbackIncomplete", "keyMissingManifest",
        "keyInvalidManifest", "keyMissing", "keyUnusable", "keyAccessGroupUnavailable", "keyUnsupportedInventoryAlgorithm",
        "storageUnsafeLocation", "storageDatabaseUnavailable", "storageManifestMissing", "storageManifestMismatch",
        "storageCorruptProtectedState", "storageProtectionUnavailable", "storageUnavailable", "unknown"}
    if isinstance(value, dict) and value.get("phase") in phases and value.get("reason") in reasons:
        details = {"phase": value["phase"], "reason": value["reason"]}
        if value["reason"] in ("keyMissing", "keyUnusable") and value.get("component") in ("queue", "identity", "inventory"):
            details["component"] = value["component"]
        if value["reason"] == "keyUnusable" and "component" in details and type(value.get("nativeStatusCode")) is int:
            details["nativeStatusCode"] = value["nativeStatusCode"]
        result["startupFailure"] = details
    return result


def provider_home_absent(home):
    return not home.exists() and not home.is_symlink()


def refresh_provider_status(provider, worker, owner, path, version):
    """An atomically replaced report is unavailable until a full private read passes."""
    provider.connected = provider.fixture_collected = False
    deadline = time.monotonic() + 2
    while True:
        require(time.monotonic() < deadline, "private-report-snapshot-unavailable")
        worker.pump()
        require(worker.process.poll() is None and owner.process.poll() is None, "signed-worker-lost")
        try:
            current = shared.private_json(path)
        except shared.GateFailure as error:
            if error.gate not in ("private-file-boundary", "private-file-changed"):
                raise
        except (OSError, json.JSONDecodeError):
            pass
        else:
            provider.connected = saved_setup(current, version)
            provider.fixture_collected = provider.connected and shared.collected(current, COUNTS, version)
            return
        # Keep the controlled PTY responsive, but expose no stale setup/fixture proof.
        provider.pump()


class ReportProcess(shared.OwnedProcess):
    """Keep strict live-report reads, with a short retry budget for replacement."""
    def wait_report(self, path, predicate, gate, *, timeout=40):
        deadline = time.monotonic() + timeout
        unavailable_deadline = None
        report_observed = False
        while (now := time.monotonic()) < deadline:
            require(unavailable_deadline is None or now < unavailable_deadline, "private-report-snapshot-unavailable")
            self.pump()
            try:
                report = shared.private_json(path)
            except shared.GateFailure as error:
                if error.gate not in ("private-file-boundary", "private-file-changed"):
                    raise
                report_observed = True
            except FileNotFoundError:
                if not report_observed:
                    require(self.process.poll() is None, gate)
                    time.sleep(0.1)
                    continue
            except (OSError, json.JSONDecodeError):
                report_observed = True
            else:
                report_observed = True
                unavailable_deadline = None
                if predicate(report):
                    return report
                require(self.process.poll() is None, gate)
                time.sleep(0.1)
                continue
            now = time.monotonic()
            if unavailable_deadline is None:
                unavailable_deadline = now + 2
            require(now < unavailable_deadline, "private-report-snapshot-unavailable")
            require(self.process.poll() is None, gate)
            time.sleep(0.05)
        raise shared.GateFailure(gate)


def inventory(report, version):
    # A recovered target intentionally leaves the independent older omission visible.
    return shared.collected({**report, "gapReasons": []}, COUNTS, version)


def diagnostic_rows(report):
    require(report.get("recoveryWorkMeasurementAvailable") is True
        and report.get("recoveryOmissionMeasurementAvailable") is True
        and report.get("recoveryWorkTruncated") is False
        and report.get("recoveryOmissionTruncated") is False, "complete-recovery-measurement-required")
    works, omissions = report.get("recoveryWorkRecords"), report.get("recoveryOmissionRecords")
    require(isinstance(works, list) and len(works) <= 128 and isinstance(omissions, list) and len(omissions) <= 128,
        "recovery-row-budget")
    def index(rows, field):
        result = {}
        for row in rows:
            require(isinstance(row, dict) and shared.digest_set({"one": [row.get(field)]}, "one") is not None,
                "recovery-row-identity")
            require(row[field] not in result, "duplicate-recovery-row")
            result[row[field]] = row
        return result
    return index(works, "workDigest"), index(omissions, "omissionDigest")


def terminal_addition(before, after):
    old, _ = diagnostic_rows(before)
    new, omissions = diagnostic_rows(after)
    added = [row for key, row in new.items() if key not in old and row.get("state") == "terminal"]
    if len(added) != 1 or not shared.empty_unclaimed_queue(after):
        return None
    row = added[0]
    omission = omissions.get(row.get("omissionDigest"), {})
    start, end = row.get("contentIntervalStart"), row.get("contentIntervalEnd")
    if (row.get("operation") != "liveRead" or row.get("auditWindowPresent") is not True
        or not finite_number(start) or not finite_number(end) or not 0 < end - start <= 8 * 86400
        or shared.digest_set({"one": [row.get("retrySelectionDigest")]}, "one") is None
        or row.get("recoveryOfDigest") is not None or row.get("certificateTargetDigest") is not None
        or omission.get("state") not in ("retryable", "blocked") or omission.get("reason") != "sourceUnavailable"):
        return None
    return row


def distinct_failures(first, second):
    return (first["workDigest"] != second["workDigest"] and first["omissionDigest"] != second["omissionDigest"]
        and first["retrySelectionDigest"] == second["retrySelectionDigest"])


def both_unresolved(report, first, second):
    works, omissions = diagnostic_rows(report)
    return (distinct_failures(first, second) and all(works.get(row["workDigest"], {}).get("state") == "terminal"
        and omissions.get(row["omissionDigest"], {}).get("state") in ("retryable", "blocked") for row in (first, second)))


def finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def selected_recovery(report, older, selected):
    works, omissions = diagnostic_rows(report)
    if not (distinct_failures(older, selected) and report.get("recoveryCodexRetryControlConsumed") is True
        and report.get("recoveryCodexRetryActionAvailable") is True and report.get("recoveryCodexRetryInvoked") is True
        and report.get("recoveryCodexRetryTargetWorkDigest") == selected["workDigest"]
        and report.get("recoveryCodexRetryTargetOmissionDigest") == selected["omissionDigest"]
        and omissions.get(selected["omissionDigest"], {}).get("state") == "recovered"
        and omissions.get(older["omissionDigest"], {}).get("state") in ("retryable", "blocked")
        and works.get(older["workDigest"], {}).get("state") == "terminal"
        and works.get(selected["workDigest"], {}).get("state") == "recovered"
        and report.get("gapReasons") == ["sourceUnavailable"]
        and shared.empty_unclaimed_queue(report)):
        return False
    linked = [row for row in works.values() if row.get("recoveryOfDigest") == selected["workDigest"]]
    certified = [row for row in linked if row.get("certificateTargetDigest") is not None]
    if not 1 <= len(certified) <= 2 or any(row.get("recoveryOfDigest") == older["workDigest"] for row in works.values()):
        return False
    start, end = selected.get("contentIntervalStart"), selected.get("contentIntervalEnd")
    if not finite_number(start) or not finite_number(end) or not 0 < end - start <= 8 * 86400:
        return False
    intervals = []
    for row in linked:
        if (row.get("state") != "completed" or row.get("operation") != "historicalRead"
            or row.get("retrySelectionDigest") != selected["retrySelectionDigest"] or row.get("auditWindowPresent") is not True):
            return False
    for row in certified:
        left, right = row.get("certificateWindowStart"), row.get("certificateWindowEnd")
        completed = row.get("certificateCompletedAt")
        if (row.get("state") != "completed" or row.get("operation") != "historicalRead"
            or row.get("retrySelectionDigest") != selected["retrySelectionDigest"]
            or row.get("certificateTargetDigest") != selected["workDigest"] or row.get("auditWindowPresent") is not True
            or not all(finite_number(value) for value in (left, right, completed))
            or not 0 < right - left <= 7 * 86400 or completed < right):
            return False
        intervals.append((left, right))
    covered = start
    for left, right in sorted(intervals):
        if left > covered:
            return False
        covered = max(covered, right)
    return covered >= end


def hook_definition(home, helper, root):
    hooks = shared.private_json(home / "hooks.json")
    require(set(hooks) == {"hooks"} and set(hooks["hooks"]) == EVENTS, "exact-owned-hook-set-required")
    markers = set()
    for groups in hooks["hooks"].values():
        require(isinstance(groups, list) and len(groups) == 1 and set(groups[0]) == {"hooks"}
            and len(groups[0]["hooks"]) == 1, "exact-owned-hook-handler-required")
        handler = groups[0]["hooks"][0]
        require(set(handler) == {"type", "command", "timeout", "statusMessage"} and handler["type"] == "command"
            and shared.exact_int(handler["timeout"], 2)
            and shlex.split(handler["command"]) == [str(helper), "--socket", str(root / "protected-store/capture.sock"),
                "--agent", "codex", "--interface", "standalone-cli", "--profile-id", PROFILE], "owned-hook-command-mismatch")
        marker = handler["statusMessage"]
        require(isinstance(marker, str) and marker.startswith("Spillcheck hook ")
            and shared.canonical_id(marker[len("Spillcheck hook "):]), "owned-hook-marker-required")
        markers.add(marker)
    require(len(markers) == 1, "single-owned-registration-required")
    return hashlib.sha256(shared.private_bytes(home / "hooks.json")).hexdigest()


def terminal_labels(memory):
    clean = re.sub(rb"\x1b\][^\x07]*(?:\x07|\x1b\\)", b"", memory)
    clean = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", clean).decode(errors="replace")
    # Ratatui can position styled words with cursor commands instead of spaces.
    # Recognize only fixed 0.162.1 UI phrases, never return captured terminal text.
    compact = re.sub(r"\s+", "", clean).casefold()
    return {"folderTrustPrompt": "trustthisfolder?" in compact,
        "eightHooksNeedReview": "8hooksareneworchanged" in compact or "8hooksneedreview" in compact,
        "startupHooksReviewMenu": all(phrase in compact for phrase in
            ("1.reviewhooks", "2.trustallandcontinue", "3.continuewithouttrusting")),
        "hookEventsPage": "lifecyclehooksfromconfigandenabledplugins" in compact,
        "hookHandlerReviewPage": "ttrust" in compact and "escback" in compact,
        "hookHandlerTogglePage": "space/entertoggle" in compact and "escback" in compact,
        "trustAllControl": all(phrase in compact for phrase in ("ttrustall", "enterreview", "escclose")),
        "trustedDetailsControl": "enterdetails" in compact and "escclose" in compact}


def terminal_session():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


class Provider:
    """Bounded owned PTY; root drives fixed normal UI actions, never arbitrary commands."""
    def __init__(self, executable, root, challenge):
        self.root, self.challenge = root, challenge
        self.memory, self.total, self.actions, self.labels = b"", 0, [], {}
        self.action_memory, self.action_labels, self.post_trust_details = b"", {}, False
        self.connected = self.fixture_collected = False
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 130, 0, 0))
        environment = {key: value for key, value in os.environ.items()
            if key != "CODEX_THREAD_ID" and not key.startswith("SPILLCHECK_")}
        environment.update(CODEX_HOME=str(root / "codex-home"), TERM="xterm-256color")
        self.server = socket.socket(socket.AF_UNIX)
        try:
            self.server.bind(str(root / "provider-control.sock"))
            os.chmod(root / "provider-control.sock", 0o600)
            self.server.listen(1)
            self.process = subprocess.Popen([str(executable), "--no-daemon", "--no-alt-screen", "-a", "never",
                "-s", "workspace-write", "-C", str(root / "work")], cwd=root / "work", env=environment,
                stdin=slave, stdout=slave, stderr=slave, preexec_fn=terminal_session)
        except (OSError, subprocess.SubprocessError):
            self.server.close()
            os.close(self.master)
            raise
        finally:
            os.close(slave)

    def state(self):
        return {"running": self.process.poll() is None, "observedUIStates": self.labels,
            "sinceLastActionUIStates": self.action_labels, "postTrustDetailsObserved": self.post_trust_details,
            "actions": self.actions, "setupConnected": self.connected, "fixtureCollected": self.fixture_collected,
            "terminalBytesDiscarded": self.total, "rawTerminalRetained": False}

    def action(self, action):
        allowed = {"enter": b"\r", "escape": b"\x1b", "hooks": b"/hooks", "quit": b"/quit"}
        if action == "review":
            require(self.action_labels.get("startupHooksReviewMenu"), "startup-hook-review-menu-not-observed")
            payload = b"1"
        elif action == "trust":
            require(self.labels.get("eightHooksNeedReview") and self.action_labels.get("trustAllControl") and "trust" not in self.actions,
                "normal-hook-review-not-observed")
            payload = b"t"
        elif action in ("verify", "fixture"):
            require("trust" in self.actions and self.post_trust_details and action not in self.actions,
                "hook-trust-review-incomplete")
            require(action == "verify" or self.connected, "genuine-setup-verification-required")
            prompt = self.challenge if action == "verify" else fixture_prompt(self.root / "work")
            payload = b"\x1b[200~" + prompt.encode() + b"\x1b[201~"
        else:
            require(action in allowed, "unknown-provider-control")
            require(action != "quit" or self.fixture_collected, "fixture-not-collected")
            payload = allowed[action]
        require(self.process.poll() is None and len(self.actions) < 40, "provider-control-budget")
        os.write(self.master, payload)
        self.actions.append(action)
        self.action_memory, self.action_labels = b"", {}

    def observe(self, data):
        self.total += len(data)
        require(self.total <= 2 * 1024 * 1024, "provider-output-budget")
        self.memory = (self.memory + data)[-65536:]
        self.action_memory = (self.action_memory + data)[-65536:]
        self.labels.update({key: self.labels.get(key, False) or value for key, value in terminal_labels(self.memory).items()})
        self.action_labels = terminal_labels(self.action_memory)
        if self.actions and self.actions[-1] == "trust" and self.action_labels.get("trustedDetailsControl"):
            self.post_trust_details = True

    def pump(self):
        ready, _, _ = select.select([self.master, self.server], [], [], 0.05)
        if self.master in ready:
            try:
                data = os.read(self.master, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                data = b""
            self.observe(data)
            if b"\x1b[6n" in data:
                os.write(self.master, b"\x1b[1;1R")
        if self.server in ready:
            connection, _ = self.server.accept()
            with connection:
                connection.settimeout(1)
                action = connection.recv(128).decode().strip()
                try:
                    if action != "state":
                        self.action(action)
                    response = self.state()
                except (ValueError, RuntimeError):
                    response = {"sent": False, "controlledFailure": "provider-action-rejected"}
                connection.sendall(json.dumps(response).encode())

    def stop(self):
        result = shared.stop_group(self.process)
        self.server.close()
        os.close(self.master)
        self.memory = self.action_memory = b""
        path = self.root / "provider-control.sock"
        if path.exists():
            path.unlink()
        return result


def selection(root):
    value = shared.private_json(root / "work/native-identity.json")
    native = shared.canonical_id(value.get("threadID"))
    require(native != os.environ.get("CODEX_THREAD_ID") and value.get("nativeIdentitySource") == "own-runtime-CODEX_THREAD_ID"
        and value.get("home") == str(root / "codex-home") and value.get("cwd") == str(root / "work")
        and value.get("sourceEnumerationPerformed") is False, "own-native-selection-required")
    return native


def deliver(helper, root, native, lifecycle):
    cleanup = {}
    lifecycle["stopped"] = False
    try:
        code, output, _ = shared.live.bounded([str(helper), "--socket", str(root / "protected-store/capture.sock"),
            "--agent", "codex", "--interface", "standalone-cli", "--profile-id", PROFILE],
            environment=dict(os.environ), directory=root / "work", timeout=5, maximum_bytes=1024,
            input_bytes=json.dumps({"hook_event_name": "SpillcheckHistoryPoll", "session_id": native}).encode(), cleanup_report=cleanup)
    finally:
        lifecycle["stopped"] = cleanup.get("leaderExited") is True and cleanup.get("groupKillPermissionDenied") is False
    require(code == 0 and output.strip() == b"{}" and lifecycle["stopped"], "helper-lifetime-unconfirmed")


def control(args):
    private = shared.private_json(args.private_control)
    root = Path(private["ownedArtifactDirectory"])
    require(root == root.resolve(strict=True) and root.name.startswith("spillcheck-cx-omit-"), "owned-control-required")
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(2)
        client.connect(str(root / "provider-control.sock"))
        client.sendall(args.action.encode())
        value = json.loads(client.recv(16384))
    print(json.dumps(value, sort_keys=True))
    return 0


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="mode", required=True)
    run = commands.add_parser("run")
    for name in ("app", "candidate-manifest", "executable", "auth-file", "output", "private-control"):
        run.add_argument("--" + name, required=True, type=Path)
    run.add_argument("--expected-bundle-sha256", required=True)
    run.add_argument("--expected-version", required=True)
    run.add_argument("--model", required=True)
    inspect = commands.add_parser("control")
    inspect.add_argument("--private-control", required=True, type=Path)
    inspect.add_argument("--action", choices=("state", "enter", "escape", "hooks", "review", "trust", "verify", "fixture", "quit"), required=True)
    return parser.parse_args(argv)


def run(args):
    os.umask(0o077)
    require(not args.output.exists() and not args.output.is_symlink() and not args.private_control.exists()
        and not args.private_control.is_symlink() and args.output.absolute() != args.private_control.absolute(), "fresh-report-paths-required")
    require(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}", args.model) is not None, "explicit-model-required")
    app, executable = args.app.resolve(strict=True), args.executable.resolve(strict=True)
    manifest = shared.preflight.read_manifest(args.candidate_manifest)
    require(manifest["bundleSHA256"] == shared.preflight.digest_value(args.expected_bundle_sha256)
        and shared.preflight.check(manifest, app, ROOT)["consistent"], "frozen-candidate-required")
    binary, helper = app / "Contents/MacOS/Spillcheck", app / "Contents/Helpers/spillcheck-hook"
    executable_hash = shared.preflight.hash_file(executable.parent, executable.name, [0])
    fixture_bytes = FIXTURE.read_bytes()
    with shared.AcceptanceArtifacts("spillcheck-cx-omit-", args.output) as artifacts:
        root = artifacts.directory
        token = os.urandom(32)
        shared.write_new(root / "run-token", token)
        shared.write_json(root / "candidate-build.json", manifest)
        args.private_control.parent.mkdir(parents=True, exist_ok=True)
        shared.write_json(args.private_control, {"schemaVersion": 1, "ownedArtifactDirectory": str(root),
            "reportPath": str(args.output.absolute()), "runTokenPath": str(root / "run-token"),
            "cleanupOwnerReport": str(root / "owner-report.json"), "loadedWorkersMayDeleteKeys": False,
            "cleanupAuthority": "original-fresh-vault-owner-only", "protectionCleanupReportField": "ownedProtectionCleanupPending"})
        report = {"schemaVersion": 1, "scope": "signed-fresh-CLI-selected-omission-recovery", "passed": False,
            "candidateBundleSHA256": args.expected_bundle_sha256, "readerVersion": args.expected_version,
            "producerVersion": args.expected_version, "model": args.model, "providerLaunchCount": 0,
            "personalConfigurationChanged": False, "personalSourceEnumerationPerformed": False,
            "sourceDiscoveryUsedForSelection": False, "hookTrustBypassed": False,
            "rawTerminalRetained": False, "syntheticFailurePollAdmission": True, "providerFailureHookDispatchEstablished": False,
            "fullCodexAcceptance": False, "T3Acceptance": False, "desktopAcceptance": False,
            "nativeChildCoverageEstablished": False, "sourceOpeningEstablished": False, "checks": {}}
        artifacts.report = report
        checks = report["checks"]
        owner = worker = provider = None
        groups, shutdowns = [], []
        helper_lifetime = {"stopped": True}
        home, work, reader = root / "codex-home", root / "work", root / "reader"
        final = {}
        phase = "private-fixture"
        try:
            home.mkdir(mode=0o700)
            work.mkdir(mode=0o700)
            home_identity = (home.stat().st_dev, home.stat().st_ino)
            shared.write_new(home / "auth.json", shared.private_bytes(args.auth_file))
            shared.write_new(home / "config.toml", ("model = " + json.dumps(args.model) + "\n[analytics]\nenabled = false\n").encode())
            shared.write_new(work / "fixture.py", fixture_bytes)
            os.symlink(str(executable), reader)
            version = shared.live.observe_version(executable, environment=dict(os.environ, CODEX_HOME=str(home)), directory=work,
                expected=args.expected_version)
            checks["actualVersionObserved"] = version == args.expected_version
            phase = "fresh-vault-owner"
            owner = ReportProcess(shared.command(binary, root, "owner"))
            owner.wait_report(root / "owner-report.json", lambda row: row.get("ownerReady") is True
                and row.get("createdFreshVault") is True, "fresh-owner-unavailable")
            phase = "saved-profile-install"
            worker = ReportProcess(worker_command(binary, root, version))
            ready = worker.wait_report(root / "worker1-report.json", lambda row: row.get("storageReady") is True
                and row.get("collectionConfigured") is True and row.get("recoveryCodexProfileInstalled") is True
                and isinstance(row.get("recoveryCodexVerificationPrompt"), str), "saved-codex-challenge-unavailable")
            challenge = ready["recoveryCodexVerificationPrompt"]
            require(challenge.startswith("Spillcheck connection test SPILLCHECK_SETUP_SYNTHETIC_")
                and len(challenge) < 512, "controlled-verification-prompt-required")
            hook_hash = hook_definition(home, helper, root)
            checks["exactProductionOwnedHooksInstalled"] = True
            phase = "genuine-cli-provider"
            provider = Provider(executable, root, challenge)
            report["providerLaunchCount"] = 1
            deadline = time.monotonic() + 360
            while provider.process.poll() is None and time.monotonic() < deadline:
                refresh_provider_status(provider, worker, owner, root / "worker1-report.json", version)
                provider.pump()
            require(provider.process.poll() == 0 and provider.fixture_collected, "genuine-cli-fixture-incomplete")
            provider_result = provider.state()
            report["providerObservation"] = provider_result
            stopped = provider.stop()
            groups.append(stopped)
            require(stopped["term_permission_denied"] is False and stopped["kill_permission_denied"] is False,
                "provider-groups-not-stopped")
            provider = None
            require(hook_definition(home, helper, root) == hook_hash, "owned-hook-definition-changed")
            native = selection(root)
            baseline = worker.wait_report(root / "worker1-report.json", lambda row: saved_setup(row, version)
                and shared.collected(row, COUNTS, version) and shared.empty_unclaimed_queue(row), "fixture-baseline-not-settled")
            checks["genuineSavedProfileVerifiedThroughEncryptedDelivery"] = True
            checks["ownRuntimeIdentityAndSevenAppearancesFiveTypes"] = True
            phase = "stop-native-polling"
            shared.write_new(root / "stop-codex-polling", token)
            baseline = worker.wait_report(root / "worker1-report.json", lambda row: row.get("recoveryCodexPollingStopped") is True
                and saved_setup(row, version) and shared.collected(row, COUNTS, version) and shared.empty_unclaimed_queue(row),
                "normal-native-polling-not-stopped")
            _, baseline_omissions = diagnostic_rows(baseline)
            require(not baseline_omissions, "fixture-baseline-has-omissions")
            require(os.readlink(reader) == str(executable), "owned-reader-link-changed")
            reader.unlink()
            worker.wait_report(root / "worker1-report.json", lambda row: row.get("recoveryCodexSetupConnected") is False
                and row.get("recoveryCodexProfileInstalled") is True and same_saved_setup(baseline, row)
                and shared.empty_unclaimed_queue(row), "missing-reader-not-observed-by-setup")
            phase = "first-terminal-poll"
            deliver(helper, root, native, helper_lifetime)
            first_report = worker.wait_report(root / "worker1-report.json", lambda row: terminal_addition(baseline, row) is not None,
                "first-poll-not-terminal", timeout=35)
            first = terminal_addition(baseline, first_report)
            phase = "second-terminal-poll"
            deliver(helper, root, native, helper_lifetime)
            second_report = worker.wait_report(root / "worker1-report.json", lambda row: terminal_addition(first_report, row) is not None,
                "second-poll-not-terminal", timeout=35)
            second = terminal_addition(first_report, second_report)
            require(distinct_failures(first, second) and both_unresolved(second_report, first, second), "independent-omissions-required")
            shared.write_json(root / "two-omissions-private.json", second_report)
            checks["twoDistinctTerminalPollsRetainSeparateOmissions"] = True
            phase = "restore-owned-reader"
            require(not reader.exists() and not reader.is_symlink(), "owned-reader-path-substituted")
            os.symlink(str(executable), reader)
            worker.wait_report(root / "worker1-report.json", lambda row: saved_setup(row, version)
                and same_saved_setup(baseline, row), "normal-saved-profile-reconnection-failed")
            deliver(helper, root, native, helper_lifetime)
            ordinary = worker.wait_report(root / "worker1-report.json", lambda row: inventory(row, version)
                and both_unresolved(row, first, second) and shared.empty_unclaimed_queue(row)
                and shared.inventory_unchanged(baseline, row)
                and (shared.digest_set(second_report, "recoverySuccessfullyProcessedCaptureDigests", empty=True) or set())
                    < (shared.digest_set(row, "recoverySuccessfullyProcessedCaptureDigests", empty=True) or set()),
                "ordinary-read-did-not-preserve-omissions", timeout=35)
            checks["ordinarySuccessfulReadPreservesBothOmissions"] = True
            phase = "production-source-retry"
            shared.write_new(root / "retry-terminal-codex-source", token)
            recovered = worker.wait_report(root / "worker1-report.json", lambda row: selected_recovery(row, first, second)
                and inventory(row, version) and shared.inventory_unchanged(ordinary, row)
                and same_saved_setup(baseline, row), "selected-omission-not-recovered", timeout=105)
            shared.write_json(root / "selected-recovery-private.json", recovered)
            checks["productionRetrySelectedLatestExactSource"] = True
            checks["certifiedLinkedAuditsRecoverOnlySelectedOmission"] = True
            checks["inventoryReceiptsAlertsAndSavedProofUnchanged"] = True
            shared.write_new(root / "worker1-finish", b"finished\n")
            worker.wait_exit()
            final = shared.private_json(root / "worker1-report.json")
            require(final.get("acceptancePhase") == "shutdown-complete" and selected_recovery(final, first, second)
                and inventory(final, version) and shared.inventory_unchanged(recovered, final), "final-recovery-state-changed")
            checks["normalShutdownPreservesSelectedRecoveryAndOlderOmission"] = True
        except (OSError, ValueError, KeyError, TypeError, RuntimeError, TimeoutError, BufferError, subprocess.SubprocessError) as error:
            report.update(unmetGate=error.gate if isinstance(error, shared.GateFailure) else phase, failureCategory="controlled-run-failure")
        finally:
            provider_stopped = provider is None
            if provider is not None:
                report["providerObservation"] = provider.state()
                try:
                    result = provider.stop()
                    groups.append(result)
                    provider_stopped = result["term_permission_denied"] is False and result["kill_permission_denied"] is False
                except (OSError, RuntimeError):
                    pass
            if worker is not None:
                if worker.process.poll() is None:
                    try:
                        if not (root / "worker1-finish").exists():
                            shared.write_new(root / "worker1-finish", b"finished\n")
                        worker.wait_exit()
                    except (OSError, RuntimeError):
                        pass
                stopped = False
                try:
                    result = worker.stop()
                    groups.append(result)
                    stopped = result["term_permission_denied"] is False and result["kill_permission_denied"] is False
                except (OSError, RuntimeError):
                    pass
                shutdown = {}
                try:
                    shutdown = shared.private_json(root / "worker1-report.json")
                except (OSError, ValueError, RuntimeError):
                    pass
                shutdowns.append({"exitCode": worker.process.poll(), "shutdownPhase": shutdown.get("acceptancePhase"), "groupStopped": stopped})
            auth_removed = provider_home_absent(home)
            if home.exists() and provider_stopped and all(row["groupStopped"] for row in shutdowns):
                try:
                    require(not home.is_symlink() and (home.stat().st_dev, home.stat().st_ino) == home_identity,
                        "owned-provider-home-replaced")
                    if "unmetGate" in report:
                        try:
                            report["failedOwnedSourceRetention"] = shared.live.retain_failed_sources(home, root / "failed-native-sources")
                        except (OSError, ValueError):
                            report["failedOwnedSourceRetention"] = {"status": "retention-incomplete", "authenticationRetained": False}
                    shutil.rmtree(home)
                    auth_removed = provider_home_absent(home)
                except (OSError, RuntimeError, UnboundLocalError):
                    pass
            checks["temporaryAuthenticationAndOwnedRegistrationRemoved"] = auth_removed
            authorized = shared.safe_creator_cleanup(shutdowns, helper_stopped=helper_lifetime["stopped"] and provider_stopped,
                socket_absent=not (root / "protected-store/capture.sock").exists()) and auth_removed
            if owner is not None and authorized and owner.process.poll() is None:
                try:
                    shared.write_new(root / "owner-finish", token)
                    owner.wait_exit()
                except (OSError, RuntimeError):
                    pass
            owner_report = {}
            try:
                owner_report = shared.private_json(root / "owner-report.json")
            except (OSError, ValueError, RuntimeError):
                pass
            if owner_failure_summary(owner_report):
                report["ownerFailureDiagnostic"] = owner_failure_summary(owner_report)
            if owner is not None:
                try:
                    groups.append(owner.stop())
                except (OSError, RuntimeError):
                    checks["ownerGroupStopFailed"] = False
            checks["creatorCleanupAuthorizedAfterShutdownAndProviderRemoval"] = authorized
            checks["originalFreshCreatorCleanupPassed"] = owner_report.get("createdFreshVault") is True and owner_report.get("cleanupPassed") is True
            report["ownedProtectionCleanupPending"] = owner is not None and owner_report.get("cleanupPassed") is not True
            checks["ownedProcessGroupsStopped"] = provider_stopped and helper_lifetime["stopped"] and bool(groups) and all(
                row["term_permission_denied"] is False and row["kill_permission_denied"] is False for row in groups)
            checks["noAppDiagnosticsOrOutput"] = all(not any(process.counts.values()) for process in (owner, worker) if process is not None)
            try:
                checks["encryptedMarkerInspectionPassed"] = shared.marker_free(root / "protected-store")
                checks["fixtureHelperUnchanged"] = shared.private_bytes(work / "fixture.py") == fixture_bytes
                checks["readerExecutableUnchanged"] = shared.preflight.hash_file(executable.parent, executable.name, [0]) == executable_hash
                checks["candidateAndProductionInputsUnchanged"] = shared.preflight.check(manifest, app, ROOT)["consistent"]
            except (OSError, ValueError, RuntimeError):
                checks["finalBoundaryChecksPassed"] = False
            report["result"] = {"newVaultCleanupPassed": checks["originalFreshCreatorCleanupPassed"],
                "syntheticOccurrenceCount": final.get("syntheticOccurrenceCount"),
                "syntheticOccurrencesByContentType": final.get("syntheticOccurrencesByContentType", {}),
                "queueCount": final.get("queueCount"), "olderIndependentOmissionIntentionallyRetained": True}
            required = {"actualVersionObserved", "exactProductionOwnedHooksInstalled", "genuineSavedProfileVerifiedThroughEncryptedDelivery",
                "ownRuntimeIdentityAndSevenAppearancesFiveTypes", "twoDistinctTerminalPollsRetainSeparateOmissions",
                "ordinarySuccessfulReadPreservesBothOmissions", "productionRetrySelectedLatestExactSource",
                "certifiedLinkedAuditsRecoverOnlySelectedOmission", "inventoryReceiptsAlertsAndSavedProofUnchanged",
                "normalShutdownPreservesSelectedRecoveryAndOlderOmission", "temporaryAuthenticationAndOwnedRegistrationRemoved",
                "creatorCleanupAuthorizedAfterShutdownAndProviderRemoval", "originalFreshCreatorCleanupPassed", "ownedProcessGroupsStopped",
                "noAppDiagnosticsOrOutput", "encryptedMarkerInspectionPassed", "fixtureHelperUnchanged", "readerExecutableUnchanged",
                "candidateAndProductionInputsUnchanged"}
            report["passed"] = "unmetGate" not in report and required <= checks.keys() and all(checks.values())
            report["signedCLISelectedOmissionRecoveryEstablished"] = report["passed"]
    return 0 if artifacts.passed else 1


def main(argv=None):
    try:
        args = arguments(argv)
        return control(args) if args.mode == "control" else run(args)
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError):
        print(json.dumps({"passed": False, "status": "preflight-or-control-rejected"}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
