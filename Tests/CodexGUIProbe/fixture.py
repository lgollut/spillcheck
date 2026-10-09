#!/usr/bin/env python3
"""Fake-only fixture helper, executed by a manually created official GUI task."""
import argparse
import json
import os
from pathlib import Path
import sys
import time

TOKEN = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"


def register(work, role):
    native = os.environ.get("CODEX_THREAD_ID")
    if not native or len(native.encode()) > 4096 or "\0" in native:
        (work / (role + "-unavailable.json")).write_text(json.dumps({
            "reason": "native-runtime-CODEX_THREAD_ID-unavailable", "role": role}) + "\n")
        return 64
    explicit = os.environ.get("CODEX_HOME")
    runtime_home = os.environ.get("HOME")
    candidate = explicit or (str(Path(runtime_home) / ".codex") if runtime_home else None)
    if not candidate or not Path(candidate).is_absolute():
        return 64
    evidence = {"schemaVersion": 1, "role": role, "nativeThreadID": native,
        "nativeIdentitySource": "own-runtime-CODEX_THREAD_ID",
        "storeCandidate": candidate,
        "storeCandidateSource": "own-runtime-CODEX_HOME" if explicit else "official-default-derived-from-own-runtime-HOME",
        "workingDirectory": str(Path.cwd().resolve()), "registeredAtUnix": time.time()}
    target = work / (role + "-identity.json")
    temporary = target.with_suffix(".tmp")
    temporary.write_text(json.dumps(evidence, sort_keys=True) + "\n")
    os.chmod(temporary, 0o600)
    temporary.replace(target)
    print("SPILLCHECK_GUI_" + role.upper() + "_IDENTITY_READY", flush=True)
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        if (work / (role + "-collector-ready")).is_file():
            print("SPILLCHECK_GUI_" + role.upper() + "_COLLECTOR_READY", flush=True)
            return 0
        if (work / "collector-failed").is_file():
            return 65
        time.sleep(0.25)
    return 66


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("register", "ok", "error"))
    parser.add_argument("role", choices=("parent", "child"))
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    work = args.work.resolve()
    if Path.cwd().resolve() != work:
        return 64
    if args.operation == "register":
        return register(work, args.role)
    print("SPILLCHECK_GUI_" + args.role.upper() + ("_TOOL_OUTPUT " if args.operation == "ok" else "_TOOL_ERROR ") + TOKEN)
    return 0 if args.operation == "ok" else 7


if __name__ == "__main__":
    sys.exit(main())
