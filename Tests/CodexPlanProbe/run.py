#!/usr/bin/env python3
"""Produce one fake Plan turn for shared signed native-content acceptance.

The callers own acceptance, passive reads and cleanup. Other content producers
also import these bounded RPC and owned-file helpers. Importing launches nothing.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import selectors
import shutil
import stat
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
VERSION = "0.162.1"
PARSER = "codex-content-contract-v16"
MARKER = "SPILLCHECK_FAKE_NATIVE_PLAN_42"
PROMPT = ("This is an isolated fake-only plan-format test. No investigation or questions are needed. "
          "Do not use any tools, commands, agents, web search, files, or external services. "
          "Return exactly one proposed_plan block containing this harmless plan:\n"
          "<proposed_plan>\n# Fake plan\n1. Note " + MARKER + ".\n"
          "2. End this formatting test without taking any action.\n</proposed_plan>\n"
          "Keep all plan text inside the block. Do not implement the plan.")
MAXIMUM = 2 * 1024 * 1024
SAFE_ITEMS = {"userMessage", "agentMessage", "reasoning", "plan"}


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


live = load("plan_codex_live", ROOT / "Tests/CodexLive/run.py")
processes = load("plan_processes", ROOT / "Tests/Support/processes.py")


class ProbeFailure(Exception):
    """Only fixed internal categories may cross into the public report."""


def require(condition, category):
    if not condition:
        raise ProbeFailure(category)


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProbeFailure("duplicate-json-key")
        result[key] = value
    return result


def decode(data):
    require(len(data) <= MAXIMUM, "response-budget")
    try:
        result = json.loads(data, object_pairs_hook=unique,
                            parse_constant=lambda _: (_ for _ in ()).throw(ProbeFailure("invalid-json-number")))
    except (ValueError, UnicodeError, RecursionError):
        raise ProbeFailure("invalid-json") from None
    require(isinstance(result, dict), "invalid-json-object")
    return result


def native_id(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value and len(value) == 36
    except (ValueError, AttributeError):
        return False


def opaque_id(value):
    return isinstance(value, str) and 0 < len(value.encode()) <= 256 and not any(ord(c) < 32 for c in value)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def private_bytes(path, maximum=MAXIMUM):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as handle:
        before = os.fstat(handle.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                and before.st_nlink == 1 and before.st_mode & 0o077 == 0
                and before.st_size <= maximum, "private-file-boundary")
        value = handle.read(maximum + 1)
        after = os.fstat(handle.fileno())
    fields = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_nlink)
    require(fields(before) == fields(after) and len(value) <= maximum, "private-file-changed")
    return value


def exclusive(path, data):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), "wb") as handle:
        handle.write(data)


def write_json(path, data):
    exclusive(path, json.dumps(data, sort_keys=True, indent=2).encode() + b"\n")


def environment(root, home):
    return {"PATH": "/usr/bin:/bin", "HOME": str(root), "CODEX_HOME": str(home),
            "TMPDIR": str(root), "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}


def turn_parameters(thread, model):
    require(native_id(thread), "invalid-owned-thread")
    return {"threadId": thread, "input": [{"type": "text", "text": PROMPT, "text_elements": []}],
            "collaborationMode": {"mode": "plan", "settings": {"model": model,
                "reasoning_effort": None, "developer_instructions": None}}}


class Observation:
    def __init__(self):
        self.thread = None
        self.turn = None
        self.pending = []
        self.plan = None
        self.done = False
        self.item_counts = {}

    def bind_thread(self, result, model, work):
        thread = result.get("thread", {})
        require(isinstance(thread, dict) and native_id(thread.get("id")), "invalid-owned-thread")
        require(result.get("model") == model and thread.get("cliVersion") == VERSION,
                "producer-version-or-model-mismatch")
        require(result.get("cwd") == str(work) and thread.get("cwd") == str(work)
                and thread.get("parentThreadId") is None and thread.get("forkedFromId") is None
                and thread.get("ephemeral") is False, "fresh-thread-contract")
        require(self.thread is None, "duplicate-owned-thread")
        self.thread = thread["id"]
        self._flush()

    def bind_turn(self, result):
        turn = result.get("turn", {})
        require(isinstance(turn, dict) and native_id(turn.get("id")), "invalid-owned-turn")
        require(self.turn is None, "duplicate-owned-turn")
        self.turn = turn["id"]
        self._flush()

    def _flush(self):
        pending, self.pending = self.pending, []
        for row in pending:
            self.event(row)

    def event(self, row):
        require(not ("method" in row and "id" in row), "unexpected-server-request")
        method = row.get("method")
        params = row.get("params", {})
        require(isinstance(params, dict), "invalid-notification")
        if method not in {"thread/started", "item/started", "item/completed", "turn/started", "turn/completed"}:
            return
        if self.thread is None or (method != "thread/started" and self.turn is None):
            require(len(self.pending) < 128, "early-event-budget")
            self.pending.append(row)
            return
        if method == "thread/started":
            require(params.get("thread", {}).get("id") == self.thread, "unowned-thread-event")
            return
        require(params.get("threadId") == self.thread, "unowned-thread-event")
        if method.startswith("turn/"):
            turn = params.get("turn", {})
            require(isinstance(turn, dict) and turn.get("id") == self.turn, "unowned-turn-event")
            if method == "turn/completed":
                require(not self.done and turn.get("status") == "completed" and turn.get("error") is None,
                        "turn-not-completed")
                self.done = True
            return
        require(params.get("turnId") == self.turn, "unowned-turn-event")
        item = params.get("item", {})
        require(isinstance(item, dict) and item.get("type") in SAFE_ITEMS, "unexpected-native-item")
        require(opaque_id(item.get("id")), "invalid-native-item-id")
        if method == "item/completed":
            kind = item["type"]
            self.item_counts[kind] = self.item_counts.get(kind, 0) + 1
            if kind == "plan":
                text = item.get("text")
                require(self.plan is None and isinstance(text, str) and 0 < len(text.encode()) <= 16384
                        and text.count(MARKER) == 1, "native-plan-missing-or-ambiguous")
                self.plan = {"itemID": item["id"], "textSHA256": digest(text.encode()),
                             "textBytes": len(text.encode())}

    def complete(self):
        require(self.thread is not None and self.turn is not None and self.done
                and self.plan is not None and not self.pending, "native-plan-incomplete")
        return {"nativePlanCompleted": True, "completedPlanCount": 1,
                "planTextBytes": self.plan["textBytes"], "planTextSHA256": self.plan["textSHA256"],
                "completedItemCounts": self.item_counts, "unexpectedToolRequests": 0}


class RPC:
    def __init__(self, process, selector, observation):
        self.process, self.selector, self.observation = process, selector, observation
        self.buffer = b""
        self.total = 0
        self.stderr = 0
        self.serial = 0
        self.responses = {}
        self.deadline = time.monotonic() + 150
        for stream in (process.stdout, process.stderr):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ)

    def write(self, row):
        self.process.stdin.write(json.dumps(row, separators=(",", ":")).encode() + b"\n")
        self.process.stdin.flush()

    def pump(self, deadline):
        require(time.monotonic() < min(deadline, self.deadline), "producer-timeout")
        for key, _ in self.selector.select(min(.1, max(0, deadline - time.monotonic()))):
            data = os.read(key.fileobj.fileno(), 65536)
            if not data:
                self.selector.unregister(key.fileobj)
                continue
            if key.fileobj is self.process.stderr:
                self.stderr += len(data)
                require(self.stderr <= 65536, "diagnostic-budget")
                continue
            self.total += len(data)
            require(self.total <= MAXIMUM, "response-budget")
            self.buffer += data
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                if not line.strip():
                    continue
                row = decode(line)
                if "method" in row:
                    self.observation.event(row)
                else:
                    require(type(row.get("id")) is int and row["id"] == self.serial
                            and row["id"] not in self.responses, "unexpected-rpc-response")
                    self.responses[row["id"]] = row
        require(self.process.poll() is None or self.responses or self.observation.done, "producer-exited-early")

    def request(self, method, params):
        self.serial += 1
        self.write({"id": self.serial, "method": method, "params": params})
        deadline = min(self.deadline, time.monotonic() + 30)
        while self.serial not in self.responses:
            self.pump(deadline)
        row = self.responses.pop(self.serial)
        require("error" not in row and isinstance(row.get("result"), dict), "rpc-request-failed")
        return row["result"]


def produce(executable, model, root, home, work, lifetime, private_control):
    observation = Observation()
    selector = selectors.DefaultSelector()
    process = None
    normal = False
    try:
        process = subprocess.Popen([str(executable), "--no-daemon", "app-server", "--stdio"],
            cwd=work, env=environment(root, home), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, start_new_session=True)
        lifetime["producerStopped"] = False
        lifetime["providerLaunchCount"] = 1
        write_json(private_control / "producer-process.json", {"pid": process.pid, "root": str(root)})
        rpc = RPC(process, selector, observation)
        rpc.request("initialize", {"clientInfo": {"name": "spillcheck-fake-plan-probe", "version": "1"},
            "capabilities": {"experimentalApi": True}})
        rpc.write({"method": "initialized", "params": {}})
        modes = rpc.request("collaborationMode/list", {})
        require(isinstance(modes.get("data"), list) and len(modes["data"]) <= 32
                and any(isinstance(item, dict) and item.get("mode") == "plan" for item in modes["data"]),
                "plan-mode-unavailable")
        models = rpc.request("model/list", {"limit": 100, "includeHidden": True})
        require(isinstance(models.get("data"), list) and len(models["data"]) <= 100
                and any(isinstance(item, dict) and item.get("model") == model for item in models["data"]),
                "requested-model-unavailable")
        result = rpc.request("thread/start", {"model": model, "allowProviderModelFallback": False,
            "cwd": str(work), "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": False,
            "developerInstructions": "Perform only the supplied fake plan-format task. Do not call tools or read files."})
        observation.bind_thread(result, model, work)
        result = rpc.request("turn/start", turn_parameters(observation.thread, model))
        observation.bind_turn(result)
        while not observation.done:
            rpc.pump(rpc.deadline)
        report = observation.complete()
        write_json(private_control / "owned-native-identity.json", {"threadID": observation.thread,
            "turnID": observation.turn, **observation.plan})
        process.stdin.close()
        end = time.monotonic() + 8
        while process.poll() is None and time.monotonic() < end:
            rpc.pump(end)
        normal = process.poll() == 0
        require(normal, "producer-normal-shutdown-unverified")
        report["normalProducerShutdown"] = normal
        return observation, report
    finally:
        try:
            if process is not None:
                stopped = processes.stop_group(process)
                lifetime["producerStopped"] = (process.poll() is not None and not stopped["term_permission_denied"]
                                                and not stopped["kill_permission_denied"])
        finally:
            selector.close()
            if process is not None:
                for stream in (process.stdin, process.stdout, process.stderr):
                    try:
                        stream.close()
                    except OSError:
                        pass


def cleanup_auth(home, root_identity):
    info = home.lstat()
    require(not stat.S_ISLNK(info.st_mode) and stat.S_ISDIR(info.st_mode)
            and (info.st_dev, info.st_ino) == root_identity, "owned-home-replaced")
    auth = home / "auth.json"
    if auth.exists() or auth.is_symlink():
        require(not auth.is_symlink(), "owned-auth-replaced")
        auth.unlink()
    return not auth.exists() and not auth.is_symlink()


def finish_cleanup(report, lifetime, *, original_path, original_hash, root, home, root_identity, home_identity):
    # A rotating/unreadable source credential fails acceptance but must not keep
    # the exact owned copy alive after all readers and the producer have stopped.
    try:
        report["originalAuthUnchanged"] = (original_hash is not None
            and digest(private_bytes(original_path, 1024 * 1024)) == original_hash)
    except Exception:
        report["originalAuthUnchanged"] = False
    try:
        if all(lifetime[key] for key in ("producerStopped", "readerStopped", "versionProcessStopped")):
            report["authRemoved"] = cleanup_auth(home, home_identity)
            info = root.lstat()
            require(not stat.S_ISLNK(info.st_mode) and (info.st_dev, info.st_ino) == root_identity,
                    "owned-root-replaced")
            shutil.rmtree(root)
            report["ownedRootRemoved"] = not root.exists() and not root.is_symlink()
    except Exception:
        report["cleanupFailure"] = "owned-cleanup-unconfirmed"


if __name__ == "__main__":
    raise SystemExit("Standalone source probe retired; use "
        "Tests/AppAcceptance/run-app-codex-native-content.py with --fixture plan. "
        "See Tests/AppAcceptance/README.md for signed acceptance setup.")
