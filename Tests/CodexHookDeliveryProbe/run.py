#!/usr/bin/env python3
"""Real helper/socket/store/scanner checks using disposable fake-only processes."""
from __future__ import annotations

import argparse
import base64
from contextlib import suppress
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
# Public synthetic detector corpus value, never a usable credential.
VALUE = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
INPUT_ONLY = "ghp_Z9qR4vY2nL7sD8mF3xK6cP1aB5hJ0uE4wT9z"
MARKER = "SPILLCHECK_FAKE_HOOK_DELIVERY_CONTENT"


class CheckFailure(Exception):
    """Only closed test labels, never subprocess output or payloads."""


def require(condition, label):
    if not condition:
        raise CheckFailure(label)


class Receiver:
    def __init__(self, fixture, **overrides):
        self.fixture = fixture
        self.process = subprocess.Popen([str(fixture.probe)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        cwd=fixture.directory)
        fixture.receivers.append(self)
        self.buffer = b""
        self.send({**fixture.configuration, **overrides})
        require(self.read()["event"] == "ready", "receiver-start")

    def send(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b"\n")
        self.process.stdin.flush()

    def read(self, timeout=15):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            require(remaining > 0, "receiver-response-timeout")
            readable, _, _ = select.select([self.process.stdout], [], [], remaining)
            require(bool(readable), "receiver-response-timeout")
            data = os.read(self.process.stdout.fileno(), 65536)
            require(bool(data), "receiver-closed")
            self.buffer += data
            require(len(self.buffer) < 65536, "receiver-response-limit")
        line, self.buffer = self.buffer.split(b"\n", 1)
        response = json.loads(line)
        require(response.get("event") != "controlledFailure", "receiver-controlled-failure")
        return response

    def command(self, command):
        self.send({"command": command})
        return self.read()

    def kill(self):
        self.process.kill()  # SIGKILL: no close/checkpoint/finalizer can run.
        self.process.wait(timeout=5)
        require(self.process.returncode == -9, "abrupt-kill-not-measured")
        self.close_pipes()

    def stop(self):
        require(self.command("stop")["event"] == "stopped", "receiver-stop")
        self.process.wait(timeout=5)
        require(self.process.returncode == 0, "receiver-exit")
        require(self.process.stderr.read() == b"", "receiver-diagnostic-output")
        self.close_pipes()

    def close_pipes(self):
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream is not None:
                with suppress(OSError):
                    stream.close()


class Fixture:
    def __init__(self, probe, helper, scanner, rules):
        self.temporary = tempfile.TemporaryDirectory(prefix="spillcheck-hook-e2e-", dir="/tmp")
        self.directory = Path(self.temporary.name)
        self.probe, self.helper = probe, helper
        self.seed = os.urandom(32)
        vault = str(uuid.uuid4())
        self.configuration = {
            "directory": str(self.directory), "scanner": str(scanner), "rules": str(rules),
            "seed": base64.b64encode(self.seed).decode(),
            "manifest": {"schemaVersion": 1, "vaultID": vault,
                         "queueKeyID": str(uuid.uuid4()), "identityKeyID": str(uuid.uuid4()),
                         "inventoryRightID": "com.spillcheck.test.inventory.v1." + vault},
            "profile": "fake-profile-" + uuid.uuid4().hex,
            "session": "fake-session-" + uuid.uuid4().hex,
            "holdAfterCommit": False, "holdBeforeScan": False, "maximumHookBytes": 8192,
        }
        self.receivers = []
        self.helpers = []

    def receiver(self, **overrides):
        receiver = Receiver(self, **overrides)
        return receiver

    def packet(self, event="UserPromptSubmit", turn="fake-turn-1", call="fake-call-1", text=None):
        text = MARKER + " " + VALUE if text is None else text
        payload = {"hook_event_name": event, "session_id": self.configuration["session"],
                   "turn_id": turn, "cwd": "/synthetic/fake-only-project", "transcript_path": None}
        if event == "UserPromptSubmit":
            payload["prompt"] = text
        elif event == "Stop":
            payload.update(last_assistant_message=text, stop_hook_active=False)
        elif event == "PostToolUse":
            payload.update(tool_name="Bash", tool_use_id=call,
                           tool_input={"command": INPUT_ONLY},
                           tool_response={"stdout": text, "stderr": "", "exit_code": 0})
        return payload

    def start_delivery(self, payload):
        process = subprocess.Popen([str(self.helper), "--socket", str(self.directory / "capture.sock"),
                                    "--agent", "codex", "--interface", "desktop-code",
                                    "--profile-id", self.configuration["profile"]],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, cwd=self.directory)
        self.helpers.append(process)
        process.stdin.write(json.dumps(payload, separators=(",", ":")).encode())
        process.stdin.close()
        process.stdin = None
        return process

    @staticmethod
    def finish_delivery(process):
        stdout, stderr = process.communicate(timeout=3)
        require(process.returncode == 0 and stdout == b"{}\n" and stderr == b"", "helper-provider-transparent")

    def deliver(self, payload):
        self.finish_delivery(self.start_delivery(payload))

    def protected(self):
        forbidden = [VALUE.encode(), INPUT_ONLY.encode(), MARKER.encode(), self.seed,
                     self.configuration["profile"].encode(), self.configuration["session"].encode()]
        forbidden += [base64.b64encode(value) for value in forbidden]
        for path in self.directory.rglob("*"):
            if path.is_file():
                content = path.read_bytes()
                require(not any(value in content for value in forbidden), "plaintext-or-key-material-on-disk")
                require(path.stat().st_mode & 0o077 == 0, "private-file-permissions")

    def cleanup(self):
        for helper in self.helpers:
            if helper.poll() is None:
                with suppress(ProcessLookupError):
                    helper.kill()
                # stdin may have failed before start_delivery finished feeding it.
                if helper.stdin is not None:
                    with suppress(OSError):
                        helper.stdin.close()
                    helper.stdin = None
                helper.wait(timeout=5)
            for stream in (helper.stdin, helper.stdout, helper.stderr):
                if stream is not None:
                    with suppress(OSError):
                        stream.close()
        for receiver in self.receivers:
            if receiver.process.poll() is None:
                with suppress(ProcessLookupError):
                    receiver.process.kill()
                receiver.process.wait(timeout=5)
            receiver.close_pipes()
        self.temporary.cleanup()


def inventory(stats, occurrences, receipts=None):
    require(stats["event"] == "statistics" and stats["queueCount"] == 0, "queue-drained")
    require(stats["records"] == (1 if occurrences else 0), "value-deduplication")
    require(stats["occurrences"] == occurrences and stats["receipts"] == (occurrences if receipts is None else receipts),
            "appearance-and-receipt-counts")
    require(stats["scannerFailures"] == 0 and stats["nativeCalls"] == 0, "scanner-or-authority-failure")
    require(stats["allSourcesHookObserved"] and stats["nativeReadCount"] == 0, "hook-only-source-evidence")


def basic(f):
    receiver = f.receiver()
    prompt, final = f.packet(), f.packet("Stop")
    output = f.packet("PostToolUse", call="fake-output")
    error = f.packet("PostToolUse", call="fake-error")
    error["tool_response"] = {"stdout": "", "stderr": MARKER + " " + VALUE, "exit_code": 7}
    for packet in [final, output, prompt, error, output, error]:
        f.deliver(packet)
    require(receiver.command("statistics")["queueCount"] == 6, "initial-deliveries-admitted")
    stats = receiver.command("drain")
    inventory(stats, 4)
    require(stats["contentTypes"] == {kind: 1 for kind in ("userPrompt", "finalResponse", "toolOutput", "toolError")},
            "all-hook-content-types")
    require(stats["detectorCalls"] == 4 and stats["hookReadCount"] > 0 and not stats["diagnostics"], "successful-hook-scans")
    original = stats["inventoryDigest"]
    f.protected()
    receiver.stop()
    receiver = f.receiver()
    for packet in [error, final, prompt, output]:
        f.deliver(packet)
    require(receiver.command("statistics")["queueCount"] == 4, "restart-replays-admitted")
    replay = receiver.command("drain")
    inventory(replay, 4)
    require(replay["detectorCalls"] == 0 and replay["inventoryDigest"] == original, "restart-replay-stability")
    f.protected()
    receiver.stop()


def pause_resume(f):
    receiver = f.receiver()
    receiver.command("pause")
    f.deliver(f.packet(turn="fake-paused"))
    inventory(receiver.command("drain"), 0)
    receiver.command("resume")
    f.deliver(f.packet(turn="fake-admitted"))
    require(receiver.command("statistics")["queueCount"] == 1, "admitted-before-pause")
    receiver.command("pause")
    paused = receiver.command("drain")
    require(paused["queueCount"] == 1 and paused["occurrences"] == 0 and paused["detectorCalls"] == 0,
            "paused-worker-does-not-consume")
    receiver.command("resume")
    inventory(receiver.command("drain"), 1)
    f.protected()
    receiver.stop()


def lost_ack_and_crash(f):
    receiver = f.receiver(holdAfterCommit=True)
    packet = f.packet()
    helper = f.start_delivery(packet)
    try:
        barrier = receiver.read()
        require(barrier["event"] == "committedBeforeAck", "post-commit-pre-ack-boundary")
        f.protected()
        receiver.kill()
        f.finish_delivery(helper)
    finally:
        if helper.poll() is None:
            helper.kill(); helper.communicate(timeout=3)
    receiver = f.receiver()
    before = receiver.command("statistics")
    require(before["queueCount"] == 1 and before["occurrences"] == 0, "durable-queue-after-sigkill")
    f.deliver(packet)
    require(receiver.command("statistics")["queueCount"] == 2, "new-delivery-id-replay-admitted")
    stats = receiver.command("drain")
    inventory(stats, 1)
    require(stats["detectorCalls"] == 1 and abs(stats["firstObserved"] - barrier["capturedAt"]) < 0.001,
            "first-observation-survives-uncertain-delivery")
    f.protected()
    receiver.stop()


def binding_crash(f):
    receiver = f.receiver(holdBeforeScan=True)
    f.deliver(f.packet("Stop"))
    require(receiver.command("statistics")["queueCount"] == 1, "before-scan-capture-admitted")
    receiver.send({"command": "drain"})
    require(receiver.read()["event"] == "beforeScan", "post-binding-pre-scan-boundary")
    f.protected()
    receiver.kill()
    # This fixture uses a three-second claim lease, rather than altering wall-clock time.
    time.sleep(3.1)
    receiver = f.receiver()
    before = receiver.command("statistics")
    require(before["queueCount"] == 1 and before["occurrences"] == 0, "claimed-capture-survives-sigkill")
    stats = receiver.command("drain")
    inventory(stats, 1)
    require(stats["detectorCalls"] == 1 and stats["contentTypes"] == {"finalResponse": 1}, "reclaimed-work-scanned")
    f.deliver(f.packet("Stop"))
    require(receiver.command("statistics")["queueCount"] == 1, "reclaimed-replay-admitted")
    replay = receiver.command("drain")
    require(replay["detectorCalls"] == 1 and replay["inventoryDigest"] == stats["inventoryDigest"], "reclaimed-slot-replay")
    f.protected()
    receiver.stop()


def payload_bound(f):
    receiver = f.receiver()
    f.deliver(f.packet("PostToolUse", call="fake-oversize", text=MARKER + " " + VALUE + "x" * 9000))
    require(receiver.command("statistics")["queueCount"] == 1, "oversize-capture-admitted")
    stats = receiver.command("drain")
    inventory(stats, 0)
    require("oversizedRecord" in stats["diagnostics"] and stats["detectorCalls"] == 0, "bounded-payload-gap")
    f.deliver(f.packet("PostToolUse", call="fake-valid"))
    stats = receiver.command("drain")
    inventory(stats, 1)
    require(stats["contentTypes"] == {"toolOutput": 1}, "bounded-failure-does-not-block-next-tool")
    f.protected()
    receiver.stop()


def immutable_identity(f):
    receiver = f.receiver()
    original = f.packet("PostToolUse")
    f.deliver(original)
    require(receiver.command("statistics")["queueCount"] == 1, "original-tool-admitted")
    before = receiver.command("drain")
    inventory(before, 1)
    f.deliver(f.packet("PostToolUse", text="changed " + MARKER + " " + VALUE))
    require(receiver.command("statistics")["queueCount"] == 1, "changed-tool-admitted")
    after = receiver.command("drain")
    inventory(after, 1)
    require(after["detectorCalls"] == 1 and after["inventoryDigest"] == before["inventoryDigest"] and
            "hookIdentityConflict" in after["diagnostics"], "changed-slot-cannot-replace-evidence")
    f.deliver(original)
    require(receiver.command("statistics")["queueCount"] == 1, "conflicting-replay-admitted")
    replay = receiver.command("drain")
    require("hookIdentityConflict" in replay["diagnostics"] and replay["detectorCalls"] == 1,
            "replay-cannot-clear-conflict")
    f.protected()
    receiver.stop()


def unavailable(f):
    before = list(f.directory.iterdir())
    started = time.monotonic()
    f.deliver(f.packet())
    require(time.monotonic() - started < 1, "unavailable-helper-bounded")
    require(list(f.directory.iterdir()) == before, "unavailable-has-no-spool")
    receiver = f.receiver()
    inventory(receiver.command("drain"), 0)
    f.protected()
    receiver.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--products-path", type=Path, help="Reuse products without invoking SwiftPM; implies --skip-build.")
    parser.add_argument("--output-directory", type=Path, default=ROOT / ".build/implementation/codex-hook-delivery")
    args = parser.parse_args()
    output = args.output_directory.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if not args.skip_build and args.products_path is None:
        for product in ["spillcheck-hook", "spillcheck-codex-hook-delivery-probe"]:
            result = subprocess.run(["swift", "build", "--product", product], cwd=ROOT,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            (output / (product + "-build.log")).write_bytes(result.stdout)
            require(result.returncode == 0, "build-failed")
    if args.products_path is not None:
        products = args.products_path.resolve()
    else:
        result = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, capture_output=True, check=True, text=True)
        products = Path(result.stdout.strip())
    probe, helper = products / "spillcheck-codex-hook-delivery-probe", products / "spillcheck-hook"
    scanner, rules = ROOT / ".build/scanner/betterleaks", ROOT / ".build/scanner/betterleaks.toml"
    require(all(path.is_file() for path in [probe, helper, scanner, rules]), "required-artifact-missing")
    checks = []
    cases = [("typed-content-and-restart-replay", basic), ("pause-resume", pause_resume),
             ("lost-ack-sigkill-and-recovery", lost_ack_and_crash), ("binding-sigkill-and-recovery", binding_crash),
             ("bounded-tool-payload", payload_bound), ("immutable-tool-identity", immutable_identity),
             ("absent-endpoint-no-spool", unavailable)]
    for label, check in cases:
        fixture = Fixture(probe, helper, scanner, rules)
        try:
            check(fixture)
            fixture.protected()  # Include final SQLite close/checkpoint output.
            checks.append({"check": label, "passed": True})
        except Exception as error:
            # Exception details may include raw subprocess input; closed labels only.
            checks.append({"check": label, "passed": False,
                           "failure": str(error) if isinstance(error, CheckFailure) else "unexpected-test-error"})
        finally:
            fixture.cleanup()
    report = {"schemaVersion": 1, "passed": all(check["passed"] for check in checks), "checks": checks,
              "productionHelper": True, "productionCaptureServer": True, "productionEncryptedStore": True,
              "productionCodexEnrolledRouter": True, "productionPinnedScanner": True,
              "testOnlyAuthorityEnrollment": True, "ephemeralTestingKeys": True,
              "providerSessionsStarted": 0, "personalSettingsChanged": False, "keychainAccessed": False,
              "signedAppAcceptance": False, "genuineProviderHookDispatch": False,
              "automaticSideChatEnrollment": False,
              "artifactsSHA256": {label: hashlib.sha256(path.read_bytes()).hexdigest()
                                   for label, path in [("helper", helper), ("receiver", probe), ("scanner", scanner), ("rules", rules)]}}
    (output / "report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CheckFailure as error:
        print(json.dumps({"passed": False, "failure": str(error)}))
        raise SystemExit(1)
