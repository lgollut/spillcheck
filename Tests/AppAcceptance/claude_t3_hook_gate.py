#!/usr/bin/env python3
"""Fake-session admission for original Claude hooks; never constructs a capture."""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import stat
import subprocess
import sys
import time
import uuid

EVENTS = {"SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "PostToolBatch",
          "MessageDisplay", "SubagentStart", "SubagentStop", "Stop"}
MAX_EVENT = 8 * 1024 * 1024
MAX_JOURNAL = 1024 * 1024


def unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicateField")
        value[key] = item
    return value


def directory_fd(path):
    path = Path(path).absolute()
    if path != path.resolve():
        raise ValueError("canonicalDirectoryRequired")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        if os.fstat(fd).st_uid != os.getuid():
            raise ValueError("ownedDirectoryRequired")
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_json(path, *, private=True, limit=65536):
    path = Path(path)
    parent = directory_fd(path.parent)
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    finally:
        os.close(parent)
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1
                or private and before.st_mode & 0o077 or before.st_size > limit):
            raise ValueError("ownedBoundedFileRequired")
        raw = os.read(fd, limit + 1)
        after = os.fstat(fd)
        if (len(raw) != before.st_size or (before.st_ino, before.st_size, before.st_mtime_ns)
                != (after.st_ino, after.st_size, after.st_mtime_ns)):
            raise ValueError("fileChanged")
        value = json.loads(raw, object_pairs_hook=unique)
        if not isinstance(value, dict):
            raise ValueError("objectRequired")
        return value, hashlib.sha256(raw).hexdigest(), stat.S_IMODE(before.st_mode)
    finally:
        os.close(fd)


def bounded_input():
    deadline = time.monotonic() + 0.18
    chunks, total = [], 0
    while time.monotonic() < deadline:
        readable, _, _ = select.select([0], [], [], max(0, deadline - time.monotonic()))
        if not readable:
            break
        chunk = os.read(0, min(65536, MAX_EVENT + 1 - total))
        if not chunk:
            return b"".join(chunks)
        total += len(chunk)
        chunks.append(chunk)
        if total > MAX_EVENT:
            break
    raise ValueError("hookInputBudgetExceeded")


def append_event(directory, event, exit_code):
    parent = directory_fd(directory)
    try:
        fd = os.open("hook-counts-private.jsonl", os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                     0o600, dir_fd=parent)
    finally:
        os.close(parent)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        info = os.fstat(fd)
        raw = (json.dumps({"event": event, "helperExitCode": exit_code}, sort_keys=True) + "\n").encode()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077
                or info.st_nlink != 1 or info.st_size + len(raw) > MAX_JOURNAL):
            raise ValueError("hookJournalBudgetExceeded")
        if os.write(fd, raw) != len(raw):
            raise OSError("shortJournalWrite")
    finally:
        os.close(fd)


def admission(directory):
    config = read_json(directory / "gate-config-private.json")[0]
    ready = read_json(directory / "ready.json")[0]
    accepted = read_json(directory / "gate-admission-private.json")[0]
    runtime, digest, _ = read_json(directory / "runtime-identity-private.json")
    session = runtime.get("nativeSessionID")
    if (not isinstance(session, str) or str(uuid.UUID(session)) != session
            or runtime.get("identitySource") != "own-runtime-CLAUDE_CODE_SESSION_ID"
            or runtime.get("workingDirectory") != config.get("workspace")
            or accepted.get("runtimeIdentitySHA256") != digest
            or accepted.get("session") != session or accepted.get("workspace") != config.get("workspace")
            or accepted.get("source") != str(native_source(config.get("workspace"), session))
            or accepted.get("registrationID") != config.get("registrationID")
            or ready != {"collectorReady": True, "emptyBaseline": True, "registrationID": config.get("registrationID")}
            or config.get("directory") != str(directory)):
        raise ValueError("exactAdmissionRequired")
    return config, accepted


def native_source(workspace, session):
    if not isinstance(workspace, str) or not Path(workspace).is_absolute():
        raise ValueError("boundWorkspaceRequired")
    return Path.home() / ".claude/projects" / re.sub(r"[^A-Za-z0-9]", "-", workspace) / (session + ".jsonl")


@contextlib.contextmanager
def callback_lock(directory, *, exclusive=False, timeout=0.25):
    config = read_json(directory / "gate-config-private.json")[0]
    parent = directory_fd(directory)
    try:
        fd = os.open("callback.lock", os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    finally:
        os.close(parent)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077
                or info.st_nlink != 1 or info.st_size != 0
                or config.get("lockIdentity") != {"device": info.st_dev, "inode": info.st_ino}):
            raise ValueError("ownedCallbackLockRequired")
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("callbackDrainUnavailable")
                time.sleep(0.01)
        yield fd
    finally:
        os.close(fd)


def selected_event(event, accepted):
    if not isinstance(event, dict) or event.get("session_id") != accepted["session"]:
        return False
    if (event.get("hook_event_name") not in EVENTS or event.get("cwd") != accepted["workspace"]
            or event.get("transcript_path") != accepted["source"]):
        return False
    child = event.get("agent_transcript_path")
    if child is not None:
        if not isinstance(child, str):
            return False
        path = Path(child)
        source = Path(accepted["source"])
        if (str(path) != child or not path.is_absolute() or ".." in path.parts
                or path.parent != source.parent / source.stem / "subagents"
                or not path.name.startswith("agent-") or path.suffix != ".jsonl"):
            return False
    return True


def forward_locked(directory, raw, supplied_args, lock_fd, run):
    # Before runtime admission/readiness, discard without a journal or source read.
    try:
        config, accepted = admission(directory)
    except (OSError, ValueError, KeyError, TypeError):
        return 0, b""
    try:
        event = json.loads(raw, object_pairs_hook=unique)
    except (ValueError, UnicodeError):
        return 0, b""
    if not selected_event(event, accepted):
        return 0, b""
    if supplied_args != config.get("helperArgs"):
        raise ValueError("originalProductionArgumentsRequired")
    name = event["hook_event_name"]
    try:
        # Keep admission's shared lock in a surviving helper if the host cancels
        # this Python callback before the helper exits.
        result = run([config["helper"], *supplied_args], input=raw, capture_output=True, timeout=0.8,
                     pass_fds=(lock_fd,))
        append_event(directory, name, result.returncode)
        return result.returncode, result.stdout
    except (OSError, subprocess.SubprocessError):
        append_event(directory, name, -1)
        raise


def forward(directory, raw, supplied_args, run=subprocess.run):
    stack = contextlib.ExitStack()
    try:
        fd = stack.enter_context(callback_lock(directory))
    except (OSError, ValueError, KeyError, TypeError):
        # An unavailable lock/config before selection must not disturb other
        # sessions. Selected helper/argument failures remain visible.
        stack.close()
        return 0, b""
    with stack:
        return forward_locked(directory, raw, supplied_args, fd, run)


def main():
    try:
        directory = Path(sys.argv[1]).absolute()
        status, output = forward(directory, bounded_input(), sys.argv[2:])
        sys.stdout.buffer.write(output)
        return status
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
