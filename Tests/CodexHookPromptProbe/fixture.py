#!/usr/bin/env python3
"""Owned identity helper and one-shot Stop callback; no general command execution."""
import json
import os
from pathlib import Path
import select
import stat
import subprocess
import sys
import time
import uuid

IDENTITY_FINAL = "SPILLCHECK_HOOK_IDENTITY_READY_42"
BEFORE = "SPILLCHECK_HOOK_BEFORE_42"
AFTER = "SPILLCHECK_HOOK_AFTER_42"
REASON_MARKER = "SPILLCHECK_INJECTED_HOOK_ONLY_97"
REASON = (REASON_MARKER + " é🙂\nThis is harmless hook-provided input. Do not use tools. "
          "Reply with only the following line, without punctuation or formatting:\n" + AFTER)


def native(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value and len(value) == 36
    except (ValueError, AttributeError):
        return False


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise ValueError("duplicate")
        result[key] = value
    return result


def turn_identifier(value):
    return isinstance(value, str) and 0 < len(value.encode()) <= 256 and not any(ord(c) < 32 for c in value)


def exclusive(path, value):
    data = json.dumps(value, sort_keys=True).encode() + b"\n"
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), "wb") as file:
        file.write(data); file.flush(); os.fsync(file.fileno())


def private(path):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as file:
        info = os.fstat(file.fileno())
        if not (stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
                and info.st_mode & 0o077 == 0 and info.st_size <= 65536): raise ValueError("boundary")
        return json.loads(file.read(65537), object_pairs_hook=unique)


def valid_callback(row, thread, work):
    return (isinstance(row, dict) and row.get("hook_event_name") == "Stop"
            and row.get("session_id") == thread and native(thread) and turn_identifier(row.get("turn_id"))
            and row.get("cwd") == str(work) and type(row.get("stop_hook_active")) is bool
            and isinstance(row.get("last_assistant_message"), str)
            and not any(row.get(key) is not None for key in ("agent_id", "parent_session_id")))


def callback_shape(row, thread, work):
    return {"object": isinstance(row, dict), "eventMatches": isinstance(row, dict) and row.get("hook_event_name") == "Stop",
        "sessionMatches": isinstance(row, dict) and row.get("session_id") == thread and native(thread),
        "cwdMatches": isinstance(row, dict) and row.get("cwd") == str(work),
        "turnBounded": isinstance(row, dict) and turn_identifier(row.get("turn_id")),
        "stopActiveBoolean": isinstance(row, dict) and type(row.get("stop_hook_active")) is bool,
        "assistantTextString": isinstance(row, dict) and isinstance(row.get("last_assistant_message"), str),
        "childFieldsAbsent": isinstance(row, dict) and not any(row.get(key) is not None for key in ("agent_id", "parent_session_id"))}


def decision(row, root, armed):
    if row["stop_hook_active"]:
        return ("continued" if row["last_assistant_message"] == AFTER else "unexpected-continuation"), {}
    if not armed:
        return ("identity-complete" if row["last_assistant_message"] == IDENTITY_FINAL else "unarmed"), {}
    if row["last_assistant_message"] != BEFORE: return "unexpected-final", {}
    try: exclusive(root / "blocked-once", {"schemaVersion": 1})
    except FileExistsError: return "already-blocked", {}
    return "blocked", {"decision": "block", "reason": REASON}


def read_stdin():
    data = b""; deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        readable, _, _ = select.select([sys.stdin.fileno()], [], [], max(0, deadline - time.monotonic()))
        if not readable: break
        part = os.read(sys.stdin.fileno(), 65537 - len(data))
        if not part: return json.loads(data, object_pairs_hook=unique)
        data += part
        if len(data) > 65536: raise ValueError("budget")
    raise ValueError("deadline")


def ancestors(parent, producer):
    result = []
    for _ in range(8):
        if type(parent) is not int or parent <= 1 or parent in result: raise ValueError("ancestry")
        result.append(parent)
        if parent == producer: return result
        # Only the next ancestor of this owned callback is queried; no process
        # enumeration or command lines. ps itself has no descendants.
        value = subprocess.run(["/bin/ps", "-p", str(parent), "-o", "ppid="],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=.2, check=True).stdout
        if len(value) > 32 or not value.strip().isdigit(): raise ValueError("ancestry")
        parent = int(value.strip())
    raise ValueError("ancestry")


def main():
    work = Path(__file__).resolve().parent
    root = work.parent
    if not root.name.startswith("spillcheck-native-hook-") or root != root.resolve(): return 2
    if len(sys.argv) != 2 or sys.argv[1] not in ("identity", "hook"): return 2
    if sys.argv[1] == "identity":
        thread = os.environ.get("CODEX_THREAD_ID")
        if (not native(thread) or Path.cwd().resolve() != work
                or os.environ.get("CODEX_HOME") != str(root / "home")): return 2
        exclusive(work / "identity.json", {"threadID": thread, "home": str(root / "home"),
            "cwd": str(work), "nativeIdentitySource": "own-runtime-CODEX_THREAD_ID",
            "sourceEnumerationPerformed": False})
        print('{"recorded":true}')
        return 0
    # Receipt exists before stdin is read; even malformed callbacks are represented
    # in cleanup. The runner never assumes the callback shares the CLI group.
    receipt = root / "callbacks" / (str(uuid.uuid4()) + ".json")
    process = {"pid": os.getpid(), "parentPID": os.getppid(), "pgid": os.getpgrp()}
    exclusive(receipt, {"schemaVersion": 1, **process})
    value = {"schemaVersion": 1, **process, "valid": False, "outcome": "unverified"}
    output = {}
    try:
        producer = private(root / "producer-process.json")["pid"]
        value.update(producerPID=producer, ancestorPIDs=ancestors(process["parentPID"], producer))
        row = read_stdin(); identity = private(work / "identity.json")
        value["shape"] = callback_shape(row, identity.get("threadID"), work)
        if not valid_callback(row, identity.get("threadID"), work): raise ValueError("callback")
        value.update(valid=True, sessionID=row["session_id"], turnID=row["turn_id"],
                     cwd=row["cwd"], stopHookActive=row["stop_hook_active"])
        armed = (root / "armed.json").exists() and private(root / "armed.json") == {"schemaVersion": 1}
        value["outcome"], output = decision(row, root, armed)
    except Exception:
        value["outcome"] = "invalid-callback"
    # A separate immutable completion joins the pre-read process receipt by name.
    exclusive(receipt.with_suffix(".done"), value)
    print(json.dumps(output, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
