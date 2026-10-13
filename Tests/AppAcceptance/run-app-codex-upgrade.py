#!/usr/bin/env python3
"""Genuine private Codex executable upgrade and orderly saved-profile restart."""
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
import subprocess
import struct
import sys
import termios
import time

spec = importlib.util.spec_from_file_location("upgrade_setup", Path(__file__).with_name("run-app-codex-omission-recovery.py"))
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)
shared, require, ROOT = setup.shared, setup.require, setup.ROOT
COUNTS, TOKEN = setup.COUNTS, setup.TOKEN
FIXTURE = Path(__file__).with_name("codex_upgrade_fixture.py")
state_spec = importlib.util.spec_from_file_location("upgrade_state_checks", Path(__file__).with_name("codex_upgrade_state.py"))
state_checks = importlib.util.module_from_spec(state_spec)
state_spec.loader.exec_module(state_checks)
RUNNER_INPUTS = ("Tests/AppAcceptance/run-app-codex-upgrade.py", "Tests/AppAcceptance/codex_upgrade_state.py",
    "Tests/AppAcceptance/codex_upgrade_fixture.py", "Tests/AppAcceptance/run-app-codex-omission-recovery.py",
    "Tests/AppAcceptance/run-app-codex-recovery.py", "Tests/CodexLive/run.py",
    "Tests/Support/acceptance_artifacts.py", "Tests/Support/processes.py",
    "Tests/BetaTrial/preflight.py", "Tests/BetaTrial/trial.py")


def runner_hashes():
    return {name: shared.preflight.hash_file(ROOT, name, [0]) for name in RUNNER_INPUTS}


def fixture_prompt(work, stage):
    require(stage in ("starting", "upgraded"), "fixture-stage-required")
    command = shlex.quote(sys.executable) + " " + shlex.quote(str(work / "fixture.py")) + " " + stage
    marker = "LEAKRET_UPGRADE_" + stage.upper()
    return (f"Run only this fake Spillcheck test. {marker}_PROMPT {TOKEN}. "
        f"First run {command} identity exactly once. Stop if recorded is not true. "
        f"Send commentary exactly {marker}_INTERMEDIATE {TOKEN}. "
        f"Run {command} output, then separately run {command} error. The latter intentionally exits 7. "
        "Do not read other files, browse, use MCP, create children, or retry commands. "
        f"Finish exactly {marker}_FINAL {TOKEN}.")


def worker_command(binary, root, name, *, install_version=None, preserve_user_state=False, remove_content=False):
    require(not remove_content or preserve_user_state, "removed-state-requires-user-state")
    if install_version is not None:
        require(name == "worker1", "only-first-worker-may-install")
        command = setup.worker_command(binary, root, install_version)
    else:
        command = shared.command(binary, root, name)[:-1] + ["--acceptance-recovery-worker", "--acceptance-no-profile-catchup"]
    return command + (["--acceptance-recovery-inventory-state", "--acceptance-recovery-upgrade-state"]
        if preserve_user_state else []) + (["--acceptance-recovery-upgrade-removed-state"] if remove_content else [])


def collected(report, versions):
    if not versions or len(set(versions)) != len(versions):
        return False
    count = len(versions)
    totals = {kind: value * count for kind, value in COUNTS.items()}
    grouped = report.get("syntheticOccurrencesByProducerVersionAndContentType")
    # Reuse the exact inventory/manifest/digest gate with only its single-source
    # cardinality generalized; producer grouping remains checked against real values.
    base = {**report, "syntheticSessionCount": 1, "observedAgentVersions": [versions[0]]}
    return (shared.collected(base, totals, versions[0])
        and shared.exact_int(report.get("syntheticSessionCount"), count)
        and report.get("observedAgentVersions") == sorted(versions)
        and isinstance(grouped, dict) and set(grouped) == set(versions)
        and all(grouped[version] == COUNTS and all(type(n) is int for n in grouped[version].values()) for version in versions))


def original_inventory_preserved(before, after):
    return (shared.manifest_digest(before) is not None and shared.manifest_digest(before) == shared.manifest_digest(after)
        and all(shared.digest_set(before, key, empty=key == "recoveryAlertDigests") is not None
            and shared.digest_set(after, key, empty=key == "recoveryAlertDigests") is not None
            and shared.digest_set(before, key, empty=key == "recoveryAlertDigests")
                <= shared.digest_set(after, key, empty=key == "recoveryAlertDigests") for key in shared.DIGEST_KEYS))


def pending_unchanged(before, after, baseline, *, remove_content=False):
    stable = state_checks.removed_unchanged if remove_content else shared.inventory_unchanged
    return (shared.singleton_pending(after, baseline) and stable(before, after)
        and shared.digest_set(before, "recoveryPendingCaptureDigests") == shared.digest_set(after, "recoveryPendingCaptureDigests"))


def removed_collected(report, versions, phase):
    """Deleted content uses metadata/receipt evidence, never fabricated occurrences."""
    return (report.get("storageReady") is True and report.get("collectionConfigured") is True
        and report.get("recoveryLoadedExistingManifest") is True
        and report.get("coverageReportTruncated") is False and report.get("gapReasons") == []
        and state_checks.validate_removed(report, versions, phase))


def pending_work(report, pending, version, state):
    identities = shared.digest_set(pending, "recoveryPendingCaptureDigests")
    if identities is None or len(identities) != 1:
        return None
    rows, _ = setup.diagnostic_rows(report)
    row = rows.get(next(iter(identities)))
    if (not isinstance(row, dict) or row.get("readerVersion") != version or row.get("state") != state
            or row.get("operation") != "liveRead" or row.get("omissionDigest") is not None
            or shared.digest_set({"one": [row.get("retrySelectionDigest")]}, "one") is None
            or type(row.get("admittedAt")) not in (int, float) or not math.isfinite(row["admittedAt"])):
        return None
    return row


def observed_native_reader(report, version, *, after):
    rows = report.get("recoverySuccessfulReadRecords")
    if (report.get("recoverySuccessfulReadMeasurementAvailable") is not True
            or report.get("recoverySuccessfulReadTruncated") is not False
            or not isinstance(rows, list) or len(rows) > 128):
        return False
    matches = [row for row in rows if isinstance(row, dict) and row.get("provider") == "codex"
        and row.get("interface") == "standalone-cli" and row.get("path") == "publicHistory"
        and row.get("operation") == "liveRead"]
    return bool(matches) and all(row.get("readerVersion") == version
        and shared.digest_set({"one": [row.get("scopeDigest")]}, "one") is not None
        and type(row.get("succeededAt")) in (int, float) and math.isfinite(row["succeededAt"])
        and row["succeededAt"] >= after for row in matches)


def pending_work_preserved(before, after, pending, version, state):
    original = pending_work(before, pending, version, "queued")
    current = pending_work(after, pending, version, state)
    return original is not None and current is not None and all(original.get(key) == current.get(key)
        for key in ("workDigest", "readerVersion", "retrySelectionDigest", "admittedAt"))


def new_work_uses_upgraded_reader(before, after, version):
    prior, _ = setup.diagnostic_rows(before)
    current, _ = setup.diagnostic_rows(after)
    new = [row for identity, row in current.items() if identity not in prior and row.get("operation") == "liveRead"]
    return bool(new) and all(row.get("readerVersion") == version and row.get("state") == "completed" for row in new)


def selection(root, stage):
    value = shared.private_json(root / "work" / (stage + "-identity.json"))
    native = shared.canonical_id(value.get("threadID"))
    require(native != os.environ.get("CODEX_THREAD_ID") and value.get("stage") == stage
        and value.get("nativeIdentitySource") == "own-runtime-CODEX_THREAD_ID"
        and value.get("home") == str(root / "codex-home") and value.get("cwd") == str(root / "work")
        and value.get("sourceEnumerationPerformed") is False, "own-native-selection-required")
    return native


def resume_command(executable, root, native):
    require(shared.canonical_id(native) is not None, "exact-resume-identity-required")
    return [str(executable), "--no-daemon", "--no-alt-screen", "-a", "never", "-s", "workspace-write",
        "-C", str(root / "work"), "resume", native]


def resume_labels(memory, native):
    clean = re.sub(rb"\x1b\][^\x07]*(?:\x07|\x1b\\)", b"", memory)
    clean = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", clean).decode(errors="replace")
    compact = re.sub(r"\s+", "", clean)
    return {"startingHistoryRendered": all(marker in compact for marker in
        ("LEAKRET_UPGRADE_STARTING_FINAL", "LEAKRET_UPGRADE_STARTING_OUTPUT")),
        "exactResumeIdentityDisplayed": "codexresume" + native in compact}


def closed_failure(error):
    if isinstance(error, shared.GateFailure):
        known = {"resume-output-budget", "signed-worker-lost-during-resume", "exact-owned-cli-resume-unverified",
            "resume-process-cleanup-unconfirmed", "private-file-boundary", "private-file-changed", "duplicate-json-key"}
        return {"category": "gate", "gate": error.gate if error.gate in known else "other-gate"}
    if isinstance(error, (subprocess.TimeoutExpired, TimeoutError)):
        return {"category": "timeout"}
    if isinstance(error, OSError):
        return {"category": "os-error", **({"errno": error.errno} if type(error.errno) is int else {})}
    if isinstance(error, subprocess.SubprocessError):
        return {"category": "process-error"}
    return {"category": "controlled-error"}


def process_handoff(root, name, process, role):
    # Expected PGID follows the explicit setsid/start_new_session launch contract.
    # A recovery operator must recheck the exact command/root before signaling it.
    shared.write_json(root / name, {"schemaVersion": 1, "role": role, "pid": process.pid,
        "expectedProcessGroupID": process.pid, "ownedArtifactDirectory": str(root),
        "recordedAt": time.time(), "identityMustBeRevalidatedBeforeSignal": True})


def preserve_creator(owner, *, ready_observed, report):
    return (owner is not None and owner.process.poll() is None
        and (ready_observed or report.get("createdFreshVault") is True and report.get("ownerReady") is True)
        and report.get("cleanupPassed") is not True)


def stop_resume_before_close(process, master, groups, lifecycle, observation):
    failure = None
    try:
        if process is not None:
            try:
                cleanup = shared.stop_group(process)
                groups.append(cleanup)
                lifecycle["stopped"] = not cleanup["term_permission_denied"] and not cleanup["kill_permission_denied"]
                observation["processCleanup"] = cleanup
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                observation["processCleanupFailure"] = closed_failure(error)
                failure = error
    finally:
        # PTY closure can itself fail. It must never prevent stopping the process.
        try:
            os.close(master)
            observation["ptyClosed"] = True
        except OSError as error:
            observation["ptyClosed"] = False
            observation["ptyCloseFailure"] = closed_failure(error)
            if failure is None:
                failure = error
    observation["processStopped"] = lifecycle["stopped"]
    return failure


def quit_transition(*, history_seen, typed_at, echo_seen, submitted, now):
    if history_seen and typed_at is None:
        return "type"
    if typed_at is not None and not submitted and echo_seen and now - typed_at >= 0.25:
        return "submit"
    return None


def run_resume(executable, root, native, worker, owner, groups, lifecycle, observation):
    master, slave = pty.openpty()
    environment = {key: value for key, value in os.environ.items()
        if key != "CODEX_THREAD_ID" and not key.startswith("SPILLCHECK_")}
    environment.update(CODEX_HOME=str(root / "codex-home"), TERM="xterm-256color")
    process, memory, typed_at, echo_memory = None, b"", None, b""
    seen = {"startingHistoryRendered": False, "exactResumeIdentityDisplayed": False}
    observation.update(**seen, rawTerminalRetained=False, terminalBytesDiscarded=0,
        promptArgumentSupplied=False, modelTurnRequested=False, normalQuitTyped=False,
        normalQuitComposerObserved=False, normalQuitSent=False, processStopped=True, ptyClosed=False)
    failure, phase = None, "launch"
    try:
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 130, 0, 0))
            process = subprocess.Popen(resume_command(executable, root, native), cwd=root / "work", env=environment,
                stdin=slave, stdout=slave, stderr=slave, preexec_fn=setup.terminal_session)
            lifecycle["stopped"] = False
            process_handoff(root, "resume-process-private.json", process, "exact-owned-CLI-resume")
        finally:
            os.close(slave)
        phase = "observe-history"
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            worker.pump()
            require(worker.process.poll() is None and owner.process.poll() is None, "signed-worker-lost-during-resume")
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                try:
                    data = os.read(master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    data = b""
                if not data:
                    break
                observation["terminalBytesDiscarded"] += len(data)
                require(observation["terminalBytesDiscarded"] <= 2 * 1024 * 1024, "resume-output-budget")
                memory = (memory + data)[-65536:]
                seen = {key: seen[key] or value for key, value in resume_labels(memory, native).items()}
                observation.update(seen)
                if typed_at is not None:
                    echo_memory = (echo_memory + data)[-8192:]
                    clean = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", echo_memory)
                    observation["normalQuitComposerObserved"] = b"/quit" in clean
                if b"\x1b[6n" in data:
                    os.write(master, b"\x1b[1;1R")
            elif process.poll() is not None:
                break
            transition = quit_transition(history_seen=seen["startingHistoryRendered"], typed_at=typed_at,
                echo_seen=observation["normalQuitComposerObserved"], submitted=observation["normalQuitSent"], now=time.monotonic())
            if transition == "type":
                # Match the working controlled CLI flow: text, a redraw, then Enter.
                os.write(master, b"\x1b[200~/quit\x1b[201~")
                typed_at = time.monotonic()
                observation["normalQuitTyped"] = True
                phase = "observe-quit-composer"
            elif transition == "submit":
                os.write(master, b"\r")
                observation["normalQuitSent"] = True
                phase = "wait-normal-exit"
        process.wait(timeout=5)
        observation["exitCode"] = process.returncode
        require(process.returncode == 0 and observation["normalQuitSent"] and all(seen.values()), "exact-owned-cli-resume-unverified")
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
        failure = error
        observation["failurePhase"] = phase
        observation["failure"] = closed_failure(error)
    finally:
        cleanup_failure = stop_resume_before_close(process, master, groups, lifecycle, observation)
        memory = echo_memory = b""
        if failure is None and cleanup_failure is not None:
            failure = cleanup_failure
            observation["failurePhase"] = "teardown"
            observation["failure"] = closed_failure(cleanup_failure)
    if failure is not None:
        raise shared.GateFailure("owned-cli-resume-failed") from None
    require(lifecycle["stopped"] and observation["ptyClosed"], "resume-process-cleanup-unconfirmed")
    return observation


class Provider(setup.Provider):
    def __init__(self, executable, root, challenge, stage):
        self.stage, self.trusted_menu_observed = stage, False
        super().__init__(executable, root, challenge)

    def observe(self, data):
        super().observe(data)
        if self.stage == "upgraded" and self.actions and self.actions[-1] in ("enter", "review", "trust") \
                and self.action_labels.get("trustedDetailsControl"):
            self.trusted_menu_observed = True

    def state(self):
        return {**super().state(), "producerStage": self.stage,
            "upgradedTrustedHookMenuObserved": self.trusted_menu_observed}

    def action(self, action):
        require(not (self.stage == "upgraded" and action == "verify"), "saved-proof-must-not-be-reverified")
        if action != "fixture":
            return super().action(action)
        require(self.connected and "fixture" not in self.actions and (self.post_trust_details
            if self.stage == "starting" else self.trusted_menu_observed), "normal-trust-and-saved-proof-required")
        require(self.process.poll() is None and len(self.actions) < 40, "provider-control-budget")
        prompt = fixture_prompt(self.root / "work", self.stage)
        os.write(self.master, b"\x1b[200~" + prompt.encode() + b"\x1b[201~")
        self.actions.append(action)
        self.action_memory, self.action_labels = b"", {}


def refresh_provider(provider, worker, owner, path, versions, expected_reader, *, preserve_user_state=False, remove_content=False):
    provider.connected = provider.fixture_collected = False
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        worker.pump()
        require(worker.process.poll() is None and owner.process.poll() is None, "signed-worker-lost")
        try:
            row = shared.private_json(path)
        except shared.GateFailure as error:
            if error.gate not in ("private-file-boundary", "private-file-changed"):
                raise
        except (OSError, json.JSONDecodeError):
            pass
        else:
            provider.connected = setup.saved_setup(row, expected_reader)
            if remove_content:
                observed = removed_collected(row, versions, "baseline" if len(versions) == 1 else "removed-upgrade14")
            else:
                observed = collected(row, versions) and (not preserve_user_state
                    or state_checks.validate(row, versions, "baseline" if len(versions) == 1 else "reviewed-revoked14"))
            provider.fixture_collected = provider.connected and observed
            return
        provider.pump()
    raise shared.GateFailure("private-report-snapshot-unavailable")


def control(args):
    private = shared.private_json(args.private_control)
    root = Path(private["ownedArtifactDirectory"])
    require(root == root.resolve(strict=True) and root.name.startswith("spillcheck-cx-upgrade-"), "owned-control-required")
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(2)
        client.connect(str(root / "provider-control.sock"))
        client.sendall(args.action.encode())
        value = json.loads(client.recv(16384))
    print(json.dumps(value, sort_keys=True))
    return 0


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    run = modes.add_parser("run")
    for name in ("app", "candidate-manifest", "starting-executable", "upgraded-executable", "auth-file", "output", "private-control"):
        run.add_argument("--" + name, type=Path, required=True)
    for name in ("expected-bundle-sha256", "expected-starting-version", "expected-upgraded-version", "model"):
        run.add_argument("--" + name, required=True)
    run.add_argument("--preserve-user-state", action="store_true",
        help="Keep two reviews, a seeded stored delivery receipt and retained revoked-value state through the genuine upgrade.")
    run.add_argument("--remove-content-before-upgrade", action="store_true",
        help="With --preserve-user-state, revoke and delete the reviewed fixture before upgrade; require new appearances to stay metadata-only.")
    inspect = modes.add_parser("control")
    inspect.add_argument("--private-control", type=Path, required=True)
    inspect.add_argument("--action", choices=("state", "enter", "escape", "hooks", "review", "trust", "verify", "fixture", "quit"), required=True)
    return parser.parse_args(argv)


def run(args):
    os.umask(0o077)
    preserve_state = getattr(args, "preserve_user_state", False)
    remove_content = getattr(args, "remove_content_before_upgrade", False)
    require(not remove_content or preserve_state, "removed-state-requires-user-state")
    def same(before, after):
        if remove_content:
            return state_checks.removed_unchanged(before, after)
        return shared.inventory_unchanged(before, after) and (not preserve_state or state_checks.unchanged(before, after))
    def after_deletion_collected(row, versions):
        if remove_content:
            return removed_collected(row, versions, "removed-upgrade7" if len(versions) == 1 else "removed-upgrade14")
        return collected(row, versions)
    require(not args.output.exists() and not args.output.is_symlink() and not args.private_control.exists()
        and not args.private_control.is_symlink() and args.output.absolute() != args.private_control.absolute(), "fresh-report-paths-required")
    require(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}", args.model) is not None, "explicit-model-required")
    old, new = args.expected_starting_version, args.expected_upgraded_version
    require(old != new, "distinct-genuine-versions-required")
    app = args.app.resolve(strict=True)
    executables = [args.starting_executable.resolve(strict=True), args.upgraded_executable.resolve(strict=True)]
    require(executables[0] != executables[1], "distinct-executables-required")
    manifest = shared.preflight.read_manifest(args.candidate_manifest)
    manifest_hash = shared.preflight.hash_file(args.candidate_manifest.parent, args.candidate_manifest.name, [0])
    input_hashes = runner_hashes()
    require(manifest["bundleSHA256"] == shared.preflight.digest_value(args.expected_bundle_sha256)
        and shared.preflight.check(manifest, app, ROOT)["consistent"], "frozen-candidate-required")
    binary, helper = app / "Contents/MacOS/Spillcheck", app / "Contents/Helpers/spillcheck-hook"
    executable_hashes = [shared.preflight.hash_file(path.parent, path.name, [0]) for path in executables]
    require(executable_hashes[0] != executable_hashes[1], "distinct-executable-bytes-required")
    fixture_bytes = FIXTURE.read_bytes()
    with shared.AcceptanceArtifacts("spillcheck-cx-upgrade-", args.output) as artifacts:
        root, token = artifacts.directory, os.urandom(32)
        shared.write_new(root / "run-token", token)
        shared.write_json(root / "candidate-build.json", manifest)
        args.private_control.parent.mkdir(parents=True, exist_ok=True)
        shared.write_json(args.private_control, {"schemaVersion": 1, "ownedArtifactDirectory": str(root),
            "reportPath": str(args.output.absolute()), "runTokenPath": str(root / "run-token"),
            "cleanupOwnerReport": str(root / "owner-report.json"), "loadedWorkersMayDeleteKeys": False,
            "ownerProcessHandoff": str(root / "owner-process-private.json"),
            "resumeProcessHandoff": str(root / "resume-process-private.json"),
            "cleanupAuthority": "original-fresh-vault-owner-only", "protectionCleanupReportField": "ownedProtectionCleanupPending"})
        report = {"schemaVersion": 1, "scope": "signed-genuine-CLI-executable-upgrade-removed-user-content" if remove_content
            else "signed-genuine-CLI-executable-upgrade-retained-user-state" if preserve_state
            else "signed-genuine-CLI-executable-upgrade-orderly-restart", "passed": False,
            "candidateBundleSHA256": args.expected_bundle_sha256, "startingProducerVersion": old,
            "candidateManifestSHA256": manifest_hash,
            "upgradedProducerVersion": new, "model": args.model, "providerLaunchCount": 0,
            "providerObservations": [], "personalConfigurationChanged": False, "personalSourceEnumerationPerformed": False,
            "sourceDiscoveryUsedForSelection": False,
            "hookTrustBypassed": False, "rawTerminalRetained": False, "syntheticPendingPollAdmission": True,
            "providerPendingHookDispatchEstablished": False, "fullCodexAcceptance": False,
            "T3Acceptance": False, "desktopAcceptance": False, "nativeChildCoverageEstablished": False,
            "sourceOpeningEstablished": False, "checkpointMigrationEstablished": False,
            "schemaMigrationEstablished": False, "crashRecoveryEstablished": False,
            "retainedUserStateRequested": preserve_state and not remove_content,
            "removedUserContentRequested": remove_content, "storedDeliveryReceiptSeeded": False,
            "systemNotificationDeliveryEstablished": False, "removedContentAcrossUpgradeEstablished": False,
            "wholeSourceRereadEstablished": False, "secondDetectorScanEstablished": False,
            "checks": {}}
        artifacts.report = report
        checks, workers, groups, shutdowns = report["checks"], [], [], []
        owner = provider = None
        owner_ready_observed = False
        auth_hash = None
        helper_lifetime, resume_lifetime, final = {"stopped": True}, {"stopped": True}, {}
        home, work, reader = root / "codex-home", root / "work", root / "reader"
        phase = "private-fixture"
        try:
            home.mkdir(mode=0o700)
            work.mkdir(mode=0o700)
            home_identity = (home.stat().st_dev, home.stat().st_ino)
            shared.write_new(work / "fixture.py", fixture_bytes)
            os.symlink(str(executables[0]), reader)
            versions = [shared.live.observe_version(path, environment=dict(os.environ, CODEX_HOME=str(home)),
                directory=work, expected=expected) for path, expected in zip(executables, (old, new))]
            checks["twoGenuineExecutableVersionsObserved"] = versions == [old, new]
            phase = "fresh-owner-and-profile"
            owner = setup.ReportProcess(shared.command(binary, root, "owner"))
            process_handoff(root, "owner-process-private.json", owner.process, "fresh-vault-cleanup-owner")
            owner.wait_report(root / "owner-report.json", lambda r: r.get("ownerReady") is True
                and r.get("createdFreshVault") is True, "fresh-owner-unavailable")
            owner_ready_observed = True
            authentication = shared.private_bytes(args.auth_file)
            auth_hash = hashlib.sha256(authentication).hexdigest()
            shared.write_new(home / "auth.json", authentication)
            del authentication
            shared.write_new(home / "config.toml", ("model = " + json.dumps(args.model) + "\n[analytics]\nenabled = false\n").encode())
            worker = setup.ReportProcess(worker_command(binary, root, "worker1", install_version=old,
                preserve_user_state=preserve_state, remove_content=remove_content))
            workers.append(worker)
            ready = worker.wait_report(root / "worker1-report.json", lambda r: r.get("storageReady") is True
                and r.get("collectionConfigured") is True and r.get("recoveryCodexProfileInstalled") is True
                and isinstance(r.get("recoveryCodexVerificationPrompt"), str), "saved-profile-challenge-unavailable")
            challenge = ready["recoveryCodexVerificationPrompt"]
            require(challenge.startswith("Spillcheck connection test SPILLCHECK_SETUP_SYNTHETIC_") and len(challenge) < 512,
                "controlled-verification-prompt-required")
            hook_hash = setup.hook_definition(home, helper, root)
            phase = "starting-genuine-provider"
            provider = Provider(executables[0], root, challenge, "starting")
            report["providerLaunchCount"] += 1
            deadline = time.monotonic() + 360
            while provider.process.poll() is None and time.monotonic() < deadline:
                refresh_provider(provider, worker, owner, root / "worker1-report.json", [old], old,
                    preserve_user_state=preserve_state, remove_content=remove_content)
                provider.pump()
            require(provider.process.poll() == 0 and provider.fixture_collected, "starting-fixture-incomplete")
            report["providerObservations"].append(provider.state())
            stopped = provider.stop()
            groups.append(stopped)
            require(not stopped["term_permission_denied"] and not stopped["kill_permission_denied"], "provider-stop-unconfirmed")
            provider = None
            native = selection(root, "starting")
            starting_binding = shared.private_bytes(work / "starting-identity.json")
            baseline = worker.wait_report(root / "worker1-report.json", lambda r: setup.saved_setup(r, old)
                and collected(r, [old]) and shared.empty_unclaimed_queue(r), "starting-inventory-unsettled")
            checks["genuineStartingProfileAndFiveTypesVerified"] = True
            phase = "pause-and-admit-owned-pending-poll"
            shared.write_new(root / "stop-codex-polling", token)
            worker.wait_report(root / "worker1-report.json", lambda r: r.get("recoveryCodexPollingStopped") is True
                and shared.empty_unclaimed_queue(r) and shared.inventory_unchanged(baseline, r), "polling-not-stopped")
            shared.write_new(root / "stop-processing", token)
            paused = worker.wait_report(root / "worker1-report.json", lambda r: r.get("recoveryProcessingStopped") is True
                and shared.empty_unclaimed_queue(r) and shared.inventory_unchanged(baseline, r), "processing-not-stopped")
            if preserve_state:
                phase = "save-reviews-delivery-and-revocation"
                validate = state_checks.validate_removed if remove_content else state_checks.validate
                review_transition = state_checks.removed_reviewed_transition if remove_content else state_checks.reviewed_transition
                require(validate(paused, [old], "baseline"), "exact-user-state-baseline-required")
                shared.write_new(root / "inventory-review-and-receipt", token)
                reviewed = worker.wait_report(root / "worker1-report.json", lambda r:
                    review_transition(paused, r, old), "review-and-store-receipt-not-saved")
                (root / "inventory-review-and-receipt").unlink()
                checks["twoDistinctReviewsAndStoredDeliverySavedBeforeUpgrade"] = True
                report["storedDeliveryReceiptSeeded"] = True
                report["storedDeliveryReceiptKind"] = reviewed.get("recoveryInventorySeededReceiptKind")
                if remove_content:
                    phase = "revoke-and-remove-reviewed-content"
                    shared.write_new(root / "inventory-obsolete-and-remove", token)
                    changed = worker.wait_report(root / "worker1-report.json", lambda r:
                        state_checks.removed_transition(reviewed, r, old), "revoked-content-not-removed")
                    (root / "inventory-obsolete-and-remove").unlink()
                    checks["revokedContentAndProtectedPayloadsRemovedBeforeUpgrade"] = True
                else:
                    shared.write_new(root / "inventory-acknowledge-revoked", token)
                    changed = worker.wait_report(root / "worker1-report.json", lambda r:
                        state_checks.acknowledged_transition(reviewed, r, old), "retained-revoked-state-not-saved")
                    (root / "inventory-acknowledge-revoked").unlink()
                    checks["retainedValueAcknowledgedRevokedBeforeUpgrade"] = True
                baseline = paused = changed
                phase = "admit-owned-pending-poll-after-review"
            setup.deliver(helper, root, native, helper_lifetime)
            pending = worker.wait_report(root / "worker1-report.json", lambda r: shared.singleton_pending(r, paused)
                and same(baseline, r) and pending_work(r, r, old, "queued") is not None,
                "exact-pending-poll-unavailable")
            checks["singleEncryptedUnclaimedPollAdmitted"] = True
            phase = "genuine-executable-upgrade"
            require(reader.is_symlink() and os.readlink(reader) == str(executables[0]), "owned-reader-changed")
            replacement = root / "reader-replacement"
            os.symlink(str(executables[1]), replacement)
            os.replace(replacement, reader)
            upgraded = worker.wait_report(root / "worker1-report.json", lambda r: setup.saved_setup(r, new)
                and setup.same_saved_setup(baseline, r) and pending_unchanged(pending, r, paused, remove_content=remove_content) and same(paused, r)
                and pending_work_preserved(pending, r, pending, old, "queued"), "production-upgrade-not-observed")
            require(setup.hook_definition(home, helper, root) == hook_hash, "owned-registration-changed")
            shared.write_json(root / "upgrade-with-pending-private.json", upgraded)
            checks["productionSetupDetectedGenuineUpgradeWithSameProof"] = True
            checks["upgradePreservesExactPendingInventoryReceiptsAlerts"] = True
            shared.write_new(root / "exit-with-pending", token)
            worker.wait_exit()
            stopped = shared.private_json(root / "worker1-report.json")
            require(stopped.get("acceptancePhase") == "shutdown-complete"
                and pending_unchanged(pending, stopped, paused, remove_content=remove_content) and same(paused, stopped)
                and pending_work_preserved(pending, stopped, pending, old, "queued")
                and setup.saved_setup(stopped, new) and not (root / "protected-store/capture.sock").exists(), "pending-exit-unconfirmed")
            checks["oldWorkerExitedNormallyWithExactPendingPoll"] = True
            (root / "stop-processing").unlink()
            (root / "exit-with-pending").unlink()
            phase = "saved-profile-cold-restart"
            worker = setup.ReportProcess(worker_command(binary, root, "worker2",
                preserve_user_state=preserve_state, remove_content=remove_content))
            workers.append(worker)
            recovered = worker.wait_report(root / "worker2-report.json", lambda r: setup.saved_setup(r, new)
                and setup.same_saved_setup(baseline, r) and after_deletion_collected(r, [old])
                and shared.pending_recovered(stopped, r) and same(baseline, r)
                and pending_work_preserved(pending, r, pending, old, "completed")
                and observed_native_reader(r, new, after=pending_work(pending, pending, old, "queued")["admittedAt"]),
                "saved-profile-pending-recovery-unavailable", timeout=60)
            checks["sameSavedProfileAndVaultRestoredWithoutReinstall"] = True
            checks["exactPendingPollConsumedAndSuccessfullyProcessed"] = True
            checks["restartAddsNoOccurrencesReceiptsOrAlerts"] = True
            checks["oldAdmissionPreservedAndActualUpgradedReaderObserved"] = True
            checks["actualSignedWorkerRestart"] = workers[0].process.pid != worker.process.pid and workers[0].process.poll() == 0
            shared.write_new(root / "worker2-finish", b"finished\n")
            worker.wait_exit()
            drained = shared.private_json(root / "worker2-report.json")
            require(drained.get("acceptancePhase") == "shutdown-complete" and shared.empty_unclaimed_queue(drained)
                and same(recovered, drained) and not (root / "protected-store/capture.sock").exists(),
                "recovery-worker-shutdown-unconfirmed")
            (root / "stop-codex-polling").unlink()
            worker = setup.ReportProcess(worker_command(binary, root, "worker3",
                preserve_user_state=preserve_state, remove_content=remove_content))
            workers.append(worker)
            worker.wait_report(root / "worker3-report.json", lambda r: setup.saved_setup(r, new)
                and setup.same_saved_setup(baseline, r) and same(drained, r)
                and after_deletion_collected(r, [old]) and shared.empty_unclaimed_queue(r), "new-producer-worker-unavailable")
            checks["actualSignedWorkerRestart"] = len({p.process.pid for p in workers}) == 3 and all(
                p.process.poll() == 0 for p in workers[:-1])
            phase = "upgraded-genuine-provider"
            require(setup.hook_definition(home, helper, root) == hook_hash, "owned-registration-changed")
            provider = Provider(executables[1], root, "", "upgraded")
            report["providerLaunchCount"] += 1
            deadline = time.monotonic() + 360
            while provider.process.poll() is None and time.monotonic() < deadline:
                refresh_provider(provider, worker, owner, root / "worker3-report.json", [old, new], new,
                    preserve_user_state=preserve_state, remove_content=remove_content)
                provider.pump()
            require(provider.process.poll() == 0 and provider.fixture_collected, "upgraded-fixture-incomplete")
            report["providerObservations"].append(provider.state())
            groups.append(provider.stop())
            require(not groups[-1]["term_permission_denied"] and not groups[-1]["kill_permission_denied"], "provider-stop-unconfirmed")
            provider = None
            require(selection(root, "upgraded") != native and shared.private_bytes(work / "starting-identity.json") == starting_binding,
                "distinct-owned-runtime-sources-required")
            before_replay = worker.wait_report(root / "worker3-report.json", lambda r: after_deletion_collected(r, [old, new])
                and setup.saved_setup(r, new) and setup.same_saved_setup(baseline, r)
                and shared.empty_unclaimed_queue(r)
                and (state_checks.new_metadata_preserves_removal(baseline, r, old, new) if remove_content
                    else original_inventory_preserved(baseline, r)
                        and (not preserve_state or state_checks.new_content_preserves_original(baseline, r, old, new)))
                and new_work_uses_upgraded_reader(stopped, r, new)
                and observed_native_reader(r, new, after=pending_work(pending, pending, old, "queued")["admittedAt"]),
                "both-producers-not-collected")
            checks["bothGenuineProducersCommittedExactFiveTypes"] = True
            checks["originalInventoryReceiptsAlertsSurviveNewContent"] = True
            if remove_content:
                checks["fullRemovedStateSurvivesUpgradeAndColdRestart"] = True
                checks["newProducerAddsOnlyMetadataWithNoPayloadsOrAlerts"] = True
                checks["originalRemovedLocationsAndRevocationSurviveNewContent"] = True
            elif preserve_state:
                checks["fullReviewedRevokedStateSurvivesUpgradeAndColdRestart"] = True
                checks["newProducerAddsOnlyObsoleteAppearancesWithNoAlert"] = True
                checks["originalReviewsRevocationAndStoredDeliverySurviveNewContent"] = True
            checks["newAdmissionsUseUpgradedReaderVersion"] = True
            phase = "owned-cli-resume-without-turn"
            report["resumeLaunchCount"] = 1
            report["resumeObservation"] = {}
            run_resume(executables[1], root, native, worker, owner, groups, resume_lifetime, report["resumeObservation"])
            before_replay = worker.wait_report(root / "worker3-report.json", lambda r: after_deletion_collected(r, [old, new])
                and same(before_replay, r) and shared.empty_unclaimed_queue(r), "resume-changed-inventory")
            checks["exactOwnedCLIResumeWithoutNewTurn"] = True
            shared.write_new(root / "stop-codex-polling", token)
            before_replay = worker.wait_report(root / "worker3-report.json", lambda r: r.get("recoveryCodexPollingStopped") is True
                and same(before_replay, r) and shared.empty_unclaimed_queue(r), "replay-polling-not-stopped")
            phase = "post-upgrade-exact-source-replay"
            for selected in (native, selection(root, "upgraded")):
                prior = shared.digest_set(before_replay, "recoverySuccessfullyProcessedCaptureDigests", empty=True)
                setup.deliver(helper, root, selected, helper_lifetime)
                before_replay = worker.wait_report(root / "worker3-report.json", lambda r: after_deletion_collected(r, [old, new])
                    and same(before_replay, r) and shared.empty_unclaimed_queue(r)
                    and prior is not None and prior < (shared.digest_set(r, "recoverySuccessfullyProcessedCaptureDigests", empty=True) or set()),
                    "exact-source-replay-not-stable")
            checks["bothSourceReplaysAddNoOccurrencesReceiptsAlerts"] = True
            if remove_content:
                checks["fullRemovedStateSurvivesResumeAndBothReplays"] = True
            elif preserve_state:
                checks["fullReviewedRevokedStateSurvivesResumeAndBothReplays"] = True
            require(setup.hook_definition(home, helper, root) == hook_hash
                and reader.is_symlink() and os.readlink(reader) == str(executables[1]), "owned-registration-or-reader-changed")
            checks["ownedRegistrationPreservedAcrossBothProducersAndResume"] = True
            shared.write_new(root / "worker3-finish", b"finished\n")
            worker.wait_exit()
            final = shared.private_json(root / "worker3-report.json")
            require(final.get("acceptancePhase") == "shutdown-complete" and after_deletion_collected(final, [old, new])
                and shared.empty_unclaimed_queue(final) and same(before_replay, final)
                and setup.saved_setup(final, new) and setup.same_saved_setup(baseline, final), "final-upgrade-state-changed")
            checks["finalQueueEmptyWithoutGaps"] = True
        except (OSError, ValueError, KeyError, TypeError, RuntimeError, TimeoutError, BufferError, subprocess.SubprocessError) as error:
            report.update(unmetGate=error.gate if isinstance(error, shared.GateFailure) else phase, failureCategory="controlled-run-failure")
        finally:
            provider_stopped = provider is None
            if provider is not None:
                report["providerObservations"].append(provider.state())
                try:
                    result = provider.stop()
                    groups.append(result)
                    provider_stopped = not result["term_permission_denied"] and not result["kill_permission_denied"]
                except (OSError, RuntimeError):
                    pass
            for index, worker in enumerate(workers, 1):
                if worker.process.poll() is None:
                    try:
                        if not (root / f"worker{index}-finish").exists():
                            shared.write_new(root / f"worker{index}-finish", b"finished\n")
                        worker.wait_exit()
                    except (OSError, RuntimeError):
                        pass
                group_stopped = False
                try:
                    result = worker.stop()
                    groups.append(result)
                    group_stopped = not result["term_permission_denied"] and not result["kill_permission_denied"]
                except (OSError, RuntimeError):
                    pass
                shutdown = {}
                try:
                    shutdown = shared.private_json(root / f"worker{index}-report.json")
                except (OSError, ValueError, RuntimeError):
                    pass
                shutdowns.append({"exitCode": worker.process.poll(), "shutdownPhase": shutdown.get("acceptancePhase"),
                    "groupStopped": group_stopped})
            auth_removed = setup.provider_home_absent(home)
            if home.exists() and provider_stopped and resume_lifetime["stopped"] and all(row["groupStopped"] for row in shutdowns):
                try:
                    require(not home.is_symlink() and (home.stat().st_dev, home.stat().st_ino) == home_identity, "owned-home-replaced")
                    if "unmetGate" in report:
                        try:
                            report["failedOwnedSourceRetention"] = shared.live.retain_failed_sources(home, root / "failed-native-sources")
                        except (OSError, ValueError):
                            report["failedOwnedSourceRetention"] = {"status": "retention-incomplete", "authenticationRetained": False}
                    shutil.rmtree(home)
                    auth_removed = setup.provider_home_absent(home)
                except (OSError, RuntimeError, UnboundLocalError):
                    pass
            checks["temporaryAuthenticationAndOwnedRegistrationRemoved"] = auth_removed
            authorized = shared.safe_creator_cleanup(shutdowns, helper_stopped=helper_lifetime["stopped"] and resume_lifetime["stopped"] and provider_stopped,
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
            if setup.owner_failure_summary(owner_report):
                report["ownerFailureDiagnostic"] = setup.owner_failure_summary(owner_report)
            retained_creator = preserve_creator(owner, ready_observed=owner_ready_observed, report=owner_report)
            report["originalCreatorRetainedForCleanup"] = retained_creator
            if retained_creator:
                # The creator has a bounded 900-second lifetime. Retain its original
                # authority for the operator's exact cleanup handoff instead of killing it.
                try:
                    shared.write_json(root / "owner-retained-private.json", {"schemaVersion": 1,
                        "pid": owner.process.pid, "expectedProcessGroupID": owner.process.pid,
                        "ownerProcessHandoff": str(root / "owner-process-private.json"),
                        "ownerFinishControl": str(root / "owner-finish"), "runTokenPath": str(root / "run-token"),
                        "creatorLifetimeLimitSeconds": 900, "cleanupStillRequiresAllOwnedSourcesStoppedAndAuthenticationRemoved": True,
                        "loadedWorkerCleanupAuthorized": False})
                except (OSError, RuntimeError):
                    report["creatorRetentionHandoffWriteFailed"] = True
            elif owner is not None:
                try:
                    groups.append(owner.stop())
                except (OSError, RuntimeError):
                    checks["ownerGroupStopFailed"] = False
            checks["creatorCleanupAuthorizedAfterNormalShutdown"] = authorized
            checks["originalFreshCreatorCleanupPassed"] = owner_report.get("createdFreshVault") is True and owner_report.get("cleanupPassed") is True
            report["ownedProtectionCleanupPending"] = owner is not None and owner_report.get("cleanupPassed") is not True
            checks["ownedProcessGroupsStopped"] = not retained_creator and provider_stopped and helper_lifetime["stopped"] and resume_lifetime["stopped"] and bool(groups) and all(
                not row["term_permission_denied"] and not row["kill_permission_denied"] for row in groups)
            checks["noAppDiagnosticsOrOutput"] = all(not any(p.counts.values()) for p in workers + ([owner] if owner else []))
            try:
                checks["encryptedMarkerInspectionPassed"] = shared.marker_free(root / "protected-store")
                checks["fixtureHelperUnchanged"] = shared.private_bytes(work / "fixture.py") == fixture_bytes
                checks["bothInstalledExecutablesUnchanged"] = [shared.preflight.hash_file(p.parent, p.name, [0]) for p in executables] == executable_hashes
                checks["candidateAndProductionInputsUnchanged"] = shared.preflight.check(manifest, app, ROOT)["consistent"]
                checks["candidateManifestBytesUnchanged"] = shared.preflight.hash_file(
                    args.candidate_manifest.parent, args.candidate_manifest.name, [0]) == manifest_hash
                checks["runnerAndLibraryBytesUnchanged"] = runner_hashes() == input_hashes
                checks["originalAuthenticationFileUnchanged"] = auth_hash is not None and hashlib.sha256(
                    shared.private_bytes(args.auth_file)).hexdigest() == auth_hash
            except (OSError, ValueError, RuntimeError):
                checks["finalBoundaryChecksPassed"] = False
            report["result"] = {"newVaultCleanupPassed": checks["originalFreshCreatorCleanupPassed"],
                "syntheticOccurrenceCount": final.get("syntheticOccurrenceCount"), "syntheticSessionCount": final.get("syntheticSessionCount"),
                "syntheticOccurrencesByProducerVersionAndContentType": final.get("syntheticOccurrencesByProducerVersionAndContentType", {}),
                "queueCount": final.get("queueCount"), "gapReasons": final.get("gapReasons")}
            if remove_content:
                measured_state = final.get("recoveryInventoryState", {})
                removed_state = measured_state.get("removedUpgrade", {})
                report["result"].update(removedStatePhase=measured_state.get("phase"),
                    inventoryCounts=measured_state.get("counts"),
                    protectedPayloadRowCount=measured_state.get("payloadRowCount"),
                    removedLocationReceiptCount=measured_state.get("removedLocationReceiptCount"),
                    metadataOnlyRecordCount=removed_state.get("metadataOnlyRecordCount"),
                    deliveryCounts=measured_state.get("deliveryCounts"),
                    nativeSourceWitness=final.get("recoveryInventoryRemovedUpgradeWitness"))
            elif preserve_state:
                measured_state = final.get("recoveryInventoryState", {})
                upgrade_state = measured_state.get("upgrade", {})
                report["result"].update(retainedStatePhase=measured_state.get("phase"),
                    reviewCounts=measured_state.get("reviewCounts"), deliveryCounts=measured_state.get("deliveryCounts"),
                    classificationCounts=upgrade_state.get("classificationCounts"), revokedMarkerCount=measured_state.get("revokedMarkerCount"))
            required = {"twoGenuineExecutableVersionsObserved", "genuineStartingProfileAndFiveTypesVerified",
                "singleEncryptedUnclaimedPollAdmitted", "productionSetupDetectedGenuineUpgradeWithSameProof",
                "upgradePreservesExactPendingInventoryReceiptsAlerts", "oldWorkerExitedNormallyWithExactPendingPoll",
                "sameSavedProfileAndVaultRestoredWithoutReinstall", "exactPendingPollConsumedAndSuccessfullyProcessed",
                "restartAddsNoOccurrencesReceiptsOrAlerts", "oldAdmissionPreservedAndActualUpgradedReaderObserved",
                "newAdmissionsUseUpgradedReaderVersion", "actualSignedWorkerRestart", "bothGenuineProducersCommittedExactFiveTypes",
                "originalInventoryReceiptsAlertsSurviveNewContent", "exactOwnedCLIResumeWithoutNewTurn", "bothSourceReplaysAddNoOccurrencesReceiptsAlerts",
                "ownedRegistrationPreservedAcrossBothProducersAndResume",
                "finalQueueEmptyWithoutGaps", "temporaryAuthenticationAndOwnedRegistrationRemoved",
                "creatorCleanupAuthorizedAfterNormalShutdown", "originalFreshCreatorCleanupPassed", "ownedProcessGroupsStopped",
                "noAppDiagnosticsOrOutput", "encryptedMarkerInspectionPassed", "fixtureHelperUnchanged", "bothInstalledExecutablesUnchanged",
                "candidateAndProductionInputsUnchanged", "candidateManifestBytesUnchanged",
                "runnerAndLibraryBytesUnchanged", "originalAuthenticationFileUnchanged"}
            if remove_content:
                required |= {"twoDistinctReviewsAndStoredDeliverySavedBeforeUpgrade", "revokedContentAndProtectedPayloadsRemovedBeforeUpgrade",
                    "fullRemovedStateSurvivesUpgradeAndColdRestart", "newProducerAddsOnlyMetadataWithNoPayloadsOrAlerts",
                    "originalRemovedLocationsAndRevocationSurviveNewContent", "fullRemovedStateSurvivesResumeAndBothReplays"}
            elif preserve_state:
                required |= {"twoDistinctReviewsAndStoredDeliverySavedBeforeUpgrade", "retainedValueAcknowledgedRevokedBeforeUpgrade",
                    "fullReviewedRevokedStateSurvivesUpgradeAndColdRestart", "newProducerAddsOnlyObsoleteAppearancesWithNoAlert",
                    "originalReviewsRevocationAndStoredDeliverySurviveNewContent", "fullReviewedRevokedStateSurvivesResumeAndBothReplays"}
            report["passed"] = "unmetGate" not in report and required <= checks.keys() and all(value is True for value in checks.values())
            report["signedCLIExecutableUpgradeAndOrderlyRestartEstablished"] = report["passed"]
            report["signedRetainedUserStateAcrossCLIUpgradeEstablished"] = report["passed"] and preserve_state and not remove_content
            report["removedContentAcrossUpgradeEstablished"] = report["passed"] and remove_content
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
