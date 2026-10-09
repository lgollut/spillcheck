#!/usr/bin/env python3
"""Exercise the signed app and bundled scanner on a disposable synthetic transcript."""
import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests"))
from Support.acceptance_artifacts import AcceptanceArtifacts

SECRET = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--app", type=Path, default=ROOT / ".build/app/Build/Products/Debug/Spillcheck.app")
args = parser.parse_args()
app = args.app.resolve()
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
os.umask(0o077)
with AcceptanceArtifacts("spillcheck-app-pipeline-", args.output) as artifacts:
    root = artifacts.directory
    session = str(uuid.uuid4())
    source = root / (session + ".jsonl")
    store = root / "protected-store"
    report_path = root / "app-report.json"
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    def row(kind, content, stop_reason=None):
        message = {"role": "assistant" if kind == "assistant" else "user", "content": content}
        if stop_reason:
            message["stop_reason"] = stop_reason
        return {"type": kind, "uuid": str(uuid.uuid4()), "sessionId": session,
                "timestamp": timestamp, "isSidechain": False, "message": message}
    rows = [row("user", "SPILLCHECK_APP_PROMPT " + SECRET),
            row("assistant", [{"type": "text", "text": "SPILLCHECK_APP_INTERMEDIATE " + SECRET}], "tool_use"),
            row("assistant", [{"type": "tool_use", "id": "app-shell-ok", "name": "Bash", "input": {}},
                              {"type": "tool_use", "id": "app-shell-error", "name": "Bash", "input": {}}], "tool_use"),
            row("user", [{"type": "tool_result", "tool_use_id": "app-shell-ok", "content": "SPILLCHECK_APP_OK " + SECRET}]),
            row("user", [{"type": "tool_result", "tool_use_id": "app-shell-error", "is_error": True, "content": "SPILLCHECK_APP_ERROR " + SECRET}]),
            row("assistant", [{"type": "text", "text": "SPILLCHECK_APP_FINAL " + SECRET}], "end_turn")]
    source.write_text("".join(json.dumps(record) + "\n" for record in rows))
    command = [str(app / "Contents/MacOS/Spillcheck"), "--store-directory", str(store),
               "--claude-profile", "app-synthetic", "--claude-version", "2.1.293",
               "--claude-source-root", str(root), "--claude-active-source", str(source), "--claude-session", session,
               "--acceptance-cleanup-new-vault", "--acceptance-report", str(report_path), "--acceptance-seconds", "8"]
    started = time.monotonic()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    samples = []
    sampling_done = threading.Event()

    def sample_app_rss():
        while not sampling_done.is_set():
            try:
                observed = subprocess.run(["/bin/ps", "-o", "rss=", "-p", str(process.pid)],
                                          capture_output=True, text=True, timeout=1)
                if observed.returncode == 0 and observed.stdout.strip():
                    samples.append(int(observed.stdout.strip()) * 1024)
            except (ValueError, subprocess.TimeoutExpired, OSError):
                pass
            sampling_done.wait(0.1)

    sampler = threading.Thread(target=sample_app_rss, daemon=True)
    sampler.start()
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=35)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(process.pid, 15)
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, 9)
            stdout, stderr = process.communicate()
    finally:
        sampling_done.set()
        sampler.join(timeout=2)
    artifacts.report.update(signedAppExitCode=process.returncode, timedOut=timed_out,
                            stdoutBytes=len(stdout), diagnosticBytes=len(stderr))
    result = json.loads(report_path.read_text()) if report_path.is_file() else {"reportMissing": True}
    clean = store.is_dir() and all(SECRET.encode() not in path.read_bytes() for path in store.rglob("*") if path.is_file())
    expected = {"userPrompt", "intermediateResponse", "finalResponse", "toolOutput", "toolError"}
    passed = not timed_out and process.returncode == 0 and result.get("storageReady") and result.get("collectionConfigured") \
        and result.get("queueCount") == 0 and result.get("valueCount") == 1 and result.get("occurrenceCount") == 5 \
        and set(result.get("occurrencesByContentType", {})) == expected and not result.get("gapReasons") \
        and result.get("newVaultCleanupPassed") is True and clean
    output = {"schemaVersion": 1, "signedAppExitCode": process.returncode,
              "timedOut": timed_out,
              "stdoutBytes": len(stdout), "diagnosticBytes": len(stderr),
              "ciphertextMarkerInspectionPassed": clean, "sourceIsSynthetic": True,
              "scannerIsSignedBundleChild": True,
              "processElapsedSeconds": round(time.monotonic() - started, 3),
              "appMemory": {"sampleCount": len(samples), "nominalSamplingDelaySeconds": 0.1,
                            "sampledPeakRSSBytes": max(samples) if samples else None,
                            "lastSampleRSSBytes": samples[-1] if samples else None,
                            "scope": "Signed GUI process startup, five-content synthetic ingestion and idle; excludes scanner/helper children, large inventory and authenticated rendering. Actual sample spacing includes ps execution overhead; sampling is not an exact high-water mark."},
              "protectedStoreBytesAfterQuit": sum(path.stat().st_size for path in store.rglob("*") if path.is_file()),
              "result": result, "passed": bool(passed and samples)}
    artifacts.report = output
raise SystemExit(0 if artifacts.passed else 1)
