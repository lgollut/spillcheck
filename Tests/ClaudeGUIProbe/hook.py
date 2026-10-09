#!/usr/bin/python3
"""Controlled hook observations, followed by production encrypted delivery."""
import hashlib
import hmac
import json
import os
from pathlib import Path
import select
import stat
import subprocess
import sys
import time

MAX_EVENT = 8 * 1024 * 1024
MAX_JOURNAL = 8 * 1024 * 1024

def bounded_input():
    end = time.monotonic() + 0.18
    chunks, total = [], 0
    while time.monotonic() < end:
        readable, _, _ = select.select([0], [], [], max(0, end - time.monotonic()))
        if not readable:
            break
        chunk = os.read(0, min(65536, MAX_EVENT + 1 - total))
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)
        total += len(chunk)
        if total > MAX_EVENT:
            break
    raise ValueError("inputBudgetExceeded")

def append_summary(path, summary):
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode) or info.st_size >= MAX_JOURNAL:
            return
        encoded = (json.dumps(summary, sort_keys=True) + "\n").encode()
        if len(encoded) <= 8192 and info.st_size + len(encoded) <= MAX_JOURNAL:
            os.write(fd, encoded)
    finally:
        os.close(fd)

def controlled_summary(event, event_bytes, config, key):
    def digest(value):
        return hmac.new(key, value.encode(), hashlib.sha256).hexdigest() if isinstance(value, str) and value else None
    def path_value(value):
        return Path(value).expanduser().resolve() if isinstance(value, str) and value else None
    def selected_child(value):
        path = path_value(value)
        return bool(path and path.parent == Path(config["childDirectory"])
            and path.name.startswith("agent-") and path.suffix == ".jsonl")
    name = event.get("hook_event_name")
    transcript = path_value(event.get("transcript_path"))
    main_matches = transcript == Path(config["source"])
    session_matches = event.get("session_id") == config["sessionID"]
    path_matches = main_matches or selected_child(event.get("transcript_path"))
    scope_matches = (session_matches and (path_matches or event.get("transcript_path") is None)) or path_matches
    summary = {"receivedAt": time.time(), "event": name if name in config["events"] else "unrecognized",
        "forwarded": False, "selectedSessionMatches": session_matches, "selectedTranscriptMatches": path_matches,
        "selectedMainTranscriptMatches": main_matches, "selectedCallbackMatches": session_matches and main_matches,
        "scopeMatches": scope_matches, "eventBytes": event_bytes, "sessionComparison": digest(event.get("session_id"))}
    fields = ("delta",) if name == "MessageDisplay" else (
        ("last_assistant_message",) if name in {"SubagentStop", "Stop"} else ("prompt",))
    summary["controlledMarkersByField"] = {field: [marker for marker in config["markers"]
        if isinstance(event.get(field), str) and marker in event[field]] for field in fields}
    summary["controlledMarkers"] = sorted({marker for markers in summary["controlledMarkersByField"].values() for marker in markers})
    if name == "MessageDisplay":
        index, final, delta = event.get("index"), event.get("final"), event.get("delta")
        summary.update(turnComparison=digest(event.get("turn_id")), messageComparison=digest(event.get("message_id")),
            deltaComparison=digest(delta),
            index=index if isinstance(index, int) and not isinstance(index, bool) and index >= 0 else None,
            final=final if isinstance(final, bool) else None,
            deltaBytes=len(delta.encode()) if isinstance(delta, str) else None,
            identityFieldsValid=all(isinstance(event.get(field), str) and event[field] for field in ("turn_id", "message_id")))
    if name in {"SubagentStart", "SubagentStop"}:
        agent_type = event.get("agent_type")
        agent_path = path_value(event.get("agent_transcript_path"))
        summary.update(agentComparison=digest(event.get("agent_id")),
            agentTranscriptComparison=digest(str(agent_path)) if agent_path else None,
            agentTypeCategory="missing" if "agent_type" not in event else (
                "invalid" if not isinstance(agent_type, str) else ("empty" if not agent_type else "nonempty")),
            agentIdentityPresent=isinstance(event.get("agent_id"), str) and bool(event["agent_id"]),
            agentTranscriptPathPresent=agent_path is not None,
            agentTranscriptMatchesSelectedChild=selected_child(event.get("agent_transcript_path")))
        if name == "SubagentStop":
            last = event.get("last_assistant_message")
            summary.update(lastAssistantMessageComparison=digest(last),
                lastAssistantMessageBytes=len(last.encode()) if isinstance(last, str) else None,
                lastAssistantMessagePresent=isinstance(last, str))
    return summary

def main():
    config = json.loads(Path(sys.argv[1]).read_text())
    key = bytes.fromhex(config["comparisonKey"])
    summary = {"receivedAt": time.time(), "event": "unrecognized", "forwarded": False}
    try:
        raw = bounded_input()
        event = json.loads(raw)
        if not isinstance(event, dict):
            raise ValueError("objectRequired")
        summary = controlled_summary(event, len(raw), config, key)
        if not summary["scopeMatches"]:
            summary["failure"] = "outsideSelectedNativeSource"
            append_summary(config["journal"], summary)
            return 0
        result = subprocess.run([config["helper"], *sys.argv[2:]], input=raw, capture_output=True, timeout=0.8)
        summary.update(forwarded=True, helperExitCode=result.returncode, helperDiagnosticBytes=len(result.stderr))
        append_summary(config["journal"], summary)
        # The production helper emits no display replacement. Preserve its ordinary output.
        sys.stdout.buffer.write(result.stdout)
        return result.returncode
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        summary["failure"] = type(error).__name__
        try:
            append_summary(config["journal"], summary)
        except OSError:
            pass
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
