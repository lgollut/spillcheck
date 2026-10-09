#!/usr/bin/env python3
"""Append a validated controlled Mod summary. Never accepts provider text or native IDs."""
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import sys

EVENTS = {"session.start", "prompt.submit", "command.run", "turn.start", "turn.step", "turn.complete", "ui.render"}
FIELDS = {"turnId", "agentId", "requestId", "messageId", "parentTurnId", "parentAgentId", "sessionId"}
MARKERS = {"LEAKRET_PHASE0_MODSIDE_PROMPT", "LEAKRET_PHASE0_MODSIDE_FINAL", "LEAKRET_PHASE0_MODMAIN_PROMPT", "LEAKRET_PHASE0_MODMAIN_FINAL"}
HEX = re.compile(r"[0-9a-f]{64}")
MAX_INPUT, MAX_JOURNAL, MAX_ROWS = 16384, 1024 * 1024, 256

def identity(value):
    if not isinstance(value, dict) or set(value) != FIELDS:
        return False
    for field in value.values():
        if not isinstance(field, dict) or not set(field) <= {"present", "kind", "comparison"}:
            return False
        if type(field.get("present")) is not bool or field.get("kind") not in {"absent", "string", "other"}:
            return False
        if "comparison" in field and not isinstance(field["comparison"], str):
            return False
        if "comparison" in field and not HEX.fullmatch(field["comparison"]):
            return False
    return True

def valid(value):
    allowed = {"schemaVersion", "sequence", "event", "phase", "selectedSessionMatches", "nativeIdentity",
        "textField", "text", "index", "component", "surface", "reason", "isAborted", "propsIdentity"}
    if not isinstance(value, dict) or not set(value) <= allowed or value.get("schemaVersion") != 1:
        return False
    if value.get("event") not in EVENTS or value.get("phase") not in {"input", "result"} or value.get("selectedSessionMatches") is not True:
        return False
    if type(value.get("sequence")) is not int or not 1 <= value["sequence"] <= MAX_ROWS:
        return False
    if not identity(value.get("nativeIdentity")) or ("propsIdentity" in value and not identity(value["propsIdentity"])):
        return False
    if value.get("textField") not in {None, "text", "args", "answer", "props.text"}:
        return False
    text = value.get("text")
    if not isinstance(text, dict) or not set(text) <= {"present", "kind", "length", "truncated", "markers", "comparison"}:
        return False
    if type(text.get("present")) is not bool or text.get("kind") not in {"absent", "string", "other"}:
        return False
    if text["kind"] == "string":
        if type(text.get("length")) is not int or text["length"] < 0 or type(text.get("truncated")) is not bool:
            return False
        if not isinstance(text.get("markers"), list) or any(marker not in MARKERS for marker in text["markers"]):
            return False
        if not isinstance(text.get("comparison"), str) or not HEX.fullmatch(text["comparison"]):
            return False
    elif set(text) != {"present", "kind"}:
        return False
    return ((value.get("index") is None or type(value["index"]) is int and value["index"] >= 0)
        and value.get("component") in {None, "UserMessage", "AssistantMessage", "CommandOutput"}
        and value.get("surface") in {None, "desktop", "terminal", "vscode", "mobile"}
        and value.get("reason") in {None, "answer", "aborted", "refusal", "error"}
        and (value.get("isAborted") is None or type(value["isAborted"]) is bool))

def append(path, value):
    if not valid(value):
        raise ValueError("controlledSchemaRejected")
    path = Path(path)
    if not path.is_absolute() or path.name != "mod-summary.jsonl":
        raise ValueError("ownedJournalPathRejected")
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(directory)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError("ownedJournalDirectoryRejected")
        file = os.open(path.name, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=directory)
        try:
            fcntl.flock(file, fcntl.LOCK_EX)
            info = os.fstat(file)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > MAX_JOURNAL:
                raise ValueError("ownedJournalFileRejected")
            old = os.read(file, MAX_JOURNAL + 1)
            encoded = (json.dumps(value, separators=(",", ":")) + "\n").encode()
            if old.count(b"\n") >= MAX_ROWS or len(old) + len(encoded) > MAX_JOURNAL:
                raise ValueError("ownedJournalBudgetExceeded")
            os.lseek(file, 0, os.SEEK_END)
            os.write(file, encoded)
        finally:
            os.close(file)
    finally:
        os.close(directory)

def main():
    try:
        if len(sys.argv) != 2:
            return 1
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        if len(raw) > MAX_INPUT:
            return 1
        append(sys.argv[1], json.loads(raw))
        return 0
    except (ValueError, OSError, TypeError):
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
