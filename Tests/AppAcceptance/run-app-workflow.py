#!/usr/bin/env python3
"""Keep a signed, disposable synthetic inventory open for the native workflow checks.

The app uses its real production vault. Authenticate only in macOS. Quit normally to
verify worker teardown and scoped new-vault cleanup; failed runs preserve their manifest.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests"))
from Support.acceptance_artifacts import AcceptanceArtifacts

TOKEN = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
WORKFLOW_MARKERS = [TOKEN, "ghp_6tV2kQ9sR4nH7xB1wJ8mF3cL0yD5pA9eU2zG",
                    "ghp_3cN8vJ2qK6fB0tM9xE4sR1pH7wL5yD8aU2zG"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ready", required=True, type=Path)
    parser.add_argument("--app", type=Path, default=ROOT / ".build/app/Build/Products/Debug/Spillcheck.app",
                        help="Explicit signed app bundle; supports a disposable installation check.")
    parser.add_argument("--duration", type=int, default=3600)
    args = parser.parse_args()
    if not 30 <= args.duration <= 7200:
        parser.error("duration must be between 30 and 7200 seconds")
    os.umask(0o077)
    app = args.app.resolve()
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    with AcceptanceArtifacts("spillcheck-workflow-", args.output) as artifacts:
        root = artifacts.directory
        session = str(uuid.uuid4())
        source = root / (session + ".jsonl")
        store = root / "protected-store"
        report_path = root / "app-report.json"
        timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()

        def row(kind, content, reason=None):
            message = {"role": "assistant" if kind == "assistant" else "user", "content": content}
            if reason:
                message["stop_reason"] = reason
            return {"type": kind, "uuid": str(uuid.uuid4()), "sessionId": session,
                    "timestamp": timestamp, "isSidechain": False, "message": message}

        records = [row("user", "SPILLCHECK_WORKFLOW_PROMPT " + TOKEN),
                   row("assistant", [{"type": "text", "text": "SPILLCHECK_WORKFLOW_INTERMEDIATE " + TOKEN}], "tool_use"),
                   row("assistant", [{"type": "tool_use", "id": "workflow-ok", "name": "Bash", "input": {}},
                                     {"type": "tool_use", "id": "workflow-error", "name": "Bash", "input": {}}], "tool_use"),
                   row("user", [{"type": "tool_result", "tool_use_id": "workflow-ok", "content": "SPILLCHECK_WORKFLOW_OK " + TOKEN}]),
                   row("user", [{"type": "tool_result", "tool_use_id": "workflow-error", "is_error": True,
                                 "content": "SPILLCHECK_WORKFLOW_ERROR " + TOKEN}]),
                   row("assistant", [{"type": "text", "text": "SPILLCHECK_WORKFLOW_FINAL " + TOKEN}], "end_turn")]
        source.write_text("".join(json.dumps(x) + "\n" for x in records))
        command = [str(app / "Contents/MacOS/Spillcheck"), "--store-directory", str(store),
                   "--claude-profile", "workflow-synthetic", "--claude-version", "2.1.293",
                   "--claude-source-root", str(root), "--claude-active-source", str(source), "--claude-session", session,
                   "--acceptance-no-profile-catchup", "--acceptance-cleanup-new-vault", "--acceptance-hold",
                   "--acceptance-report", str(report_path), "--acceptance-seconds", "8"]
        stdout_file, stderr_file = root / "stdout.bin", root / "stderr.bin"
        with stdout_file.open("wb") as stdout, stderr_file.open("wb") as stderr:
            process = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
            args.ready.parent.mkdir(parents=True, exist_ok=True)
            ready = {"ready": True, "directory": str(root), "source": str(source), "appReport": str(report_path),
                     "processID": process.pid, "syntheticOnly": True, "leaseSeconds": args.duration}
            args.ready.write_text(json.dumps(ready, indent=2) + "\n")
            print(json.dumps({"ready": True, "readyReport": str(args.ready)}), flush=True)
            deadline = time.monotonic() + args.duration
            while process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.2)
            timed_out = process.poll() is None
            if timed_out:
                os.killpg(process.pid, 15)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, 9)
                    process.wait(timeout=5)
        result = json.loads(report_path.read_text()) if report_path.is_file() else {"reportMissing": True}
        clean = store.is_dir() and all(all(marker.encode() not in p.read_bytes() for marker in WORKFLOW_MARKERS)
                                      for p in store.rglob("*") if p.is_file())
        lifecycle_passed = (not timed_out and process.returncode == 0 and result.get("queueCount") == 0
                            and result.get("newVaultCleanupPassed") is True and clean)
        artifacts.report = {"schemaVersion": 1, "sourceIsSynthetic": True,
            "signedAppExitCode": process.returncode, "timedOut": timed_out,
            "stdoutBytes": stdout_file.stat().st_size, "diagnosticBytes": stderr_file.stat().st_size,
            "ciphertextMarkerInspectionPassed": clean, "result": result,
            "ciphertextSyntheticMarkersChecked": len(WORKFLOW_MARKERS),
            "passed": bool(lifecycle_passed),
            "passScope": "Normal native app termination, empty queue, ciphertext inspection and new-vault cleanup; manual workflow events require separate review."}
        args.ready.write_text(json.dumps({"ready": False, "finished": True}, indent=2) + "\n")
    return 0 if artifacts.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
