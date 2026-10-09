#!/usr/bin/env python3
"""Actual Claude CLI -> production helper -> encrypted queue -> adapter/detector/store.

Only disposable configs and synthetic values are used. Authentication is reused
without configuration/history reuse; copied auth and provider transcripts are removed.
Printed reports contain counts/checks, never provider stdout, credentials or raw events.
"""
import argparse
import datetime
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests"))
from Support.processes import stop_group

SECRET = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
PROMPT = f"""Disposable local Spillcheck test. Every credential below is synthetic and must never be used for authentication. Do not read files or browse. User marker LEAKRET_M3_PROMPT {SECRET}.
1. Your first assistant text must contain LEAKRET_M3_INTERMEDIATE {SECRET}.
2. Run printf 'LEAKRET_M3_SHELL_OK {SECRET}\\n'; sleep 1 using Bash.
3. Run printf 'LEAKRET_M3_SHELL_ERROR {SECRET}\\n' >&2; exit 7 using Bash. This failure is intentional; do not repair it.
4. Call spillcheck_synthetic synthetic_output MCP with fail=false, then fail=true. The error is intentional; do not repair it.
5. Use your built-in Agent tool with prompt LEAKRET_M3_CHILD_PROMPT {SECRET}. Instruct the child to respond LEAKRET_M3_CHILD_FINAL {SECRET} only. Wait for its result.
6. End with LEAKRET_M3_FINAL {SECRET}.
"""

def authentication(env, config):
    env["CLAUDE_CONFIG_DIR"] = str(config)
    auth = pathlib.Path.home() / ".claude/.credentials.json"
    if auth.is_file():
        shutil.copyfile(auth, config / ".credentials.json")
        os.chmod(config / ".credentials.json", 0o600)
    else:
        result = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w"], capture_output=True)
        if result.returncode == 0:
            try:
                token = json.loads(result.stdout).get("claudeAiOauth", {}).get("accessToken")
                if token:
                    env["CLAUDE_CODE_OAUTH_TOKEN"] = token
            except (ValueError, TypeError):
                pass

def run_provider(executable, prompt, env, project, mcp, timeout=150):
    command = [str(executable), "--print", "--verbose", "--output-format", "stream-json", "--include-partial-messages",
               "--include-hook-events", "--forward-subagent-text", "--dangerously-skip-permissions",
               "--setting-sources", "user", "--strict-mcp-config", "--mcp-config", str(mcp), "--max-budget-usd", "3"]
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             cwd=project, env=env, start_new_session=True)
    try:
        output, errors = child.communicate(prompt.encode(), timeout=timeout)
        result = {"exitCode":child.returncode,"outputBytes":len(output),"diagnosticBytes":len(errors)}
    finally:
        cleanup = stop_group(child)
    result["processGroupCleanup"] = cleanup
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--timeout", type=int, default=360)
    parser.add_argument("--executable", default="claude", help="Exact validated Claude executable; no global install is changed.")
    parser.add_argument("--acceptance-executable", type=pathlib.Path,
                        default=ROOT / ".build/out/Products/Debug/spillcheck-storage-acceptance")
    args = parser.parse_args()
    os.umask(0o077)
    binary = args.acceptance_executable.resolve()
    helper = ROOT / ".build/out/Products/Debug/spillcheck-hook"
    executable = pathlib.Path(shutil.which(args.executable) or args.executable).resolve()
    version = subprocess.check_output([str(executable), "--version"], text=True).split()[0]
    if version != "2.1.293" or not binary.is_file() or not helper.is_file():
        raise SystemExit("Validated Claude 2.1.293 and built acceptance/helper products are required")
    started_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    with tempfile.TemporaryDirectory(prefix="lr-m6-claude-quoted ' $ `-",dir="/tmp") as name:
        root = pathlib.Path(name).resolve()
        quoted_helper = root / "helper quoted ' $ `"
        shutil.copyfile(helper, quoted_helper); os.chmod(quoted_helper, 0o700)
        config = root / "claude"; config.mkdir()
        (config / "projects").mkdir()
        project = root / "project"; project.mkdir()
        mcp = root / "mcp.json"
        mcp.write_text(json.dumps({"mcpServers":{"spillcheck_synthetic":{"command":"/usr/bin/python3","args":[str(pathlib.Path(__file__).with_name("mcp_fixture.py"))]}}}))
        env = dict(os.environ)
        env["DISABLE_AUTOUPDATER"] = "1"
        authentication(env,config)
        driver = subprocess.Popen([str(binary),"--claude-live","--directory",str(root),"--settings",str(config/"settings.json"),
            "--helper",str(quoted_helper),"--version",version,"--scanner",str(ROOT/".build/scanner/betterleaks"),
            "--rules",str(ROOT/".build/scanner/betterleaks.toml"),"--duration",str(args.timeout)],
            stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        lines = []
        diagnostics = bytearray()
        def consume(stream,destination):
            for line in stream:
                destination.append(line) if isinstance(destination,list) else destination.extend(line)
        try:
            ready_bytes = driver.stdout.readline()
            ready = json.loads(ready_bytes)
            assert ready.get("ready") is True
            thread = threading.Thread(target=consume,args=(driver.stdout,lines),daemon=True); thread.start()
            error_thread = threading.Thread(target=consume,args=(driver.stderr,diagnostics),daemon=True); error_thread.start()
            providers = [run_provider(executable,ready["verificationPrompt"],env,project,mcp),
                         run_provider(executable,PROMPT,env,project,mcp),
                         run_provider(executable,f"Respond exactly LEAKRET_M3_FINAL {SECRET}. This is synthetic test data.",env,project,mcp)]
            (root/"provider-finished").touch()
            driver.wait(timeout=args.timeout)
            thread.join(timeout=2); error_thread.join(timeout=2)
            final = next((json.loads(line) for line in reversed(lines) if json.loads(line).get("finished")),None)
            assert final is not None
            report = {"schemaVersion":2,"agentVersion":version,"interface":"standaloneCLI", "startedAt":started_at,
                      "providerRuns":providers,"driverExitCode":driver.returncode,
                      "driverDiagnosticBytes":len(diagnostics),"result":final,
                      "t3LatencyMeasured":False,"historicalLatencyMeasured":final["sourceLatency"]["historical"]["committedSourceRevisionCount"] > 0}
            expected = {"PROMPT","INTERMEDIATE","FINAL","SHELL_OK","SHELL_ERROR","MCP_OK","MCP_ERROR","CHILD_PROMPT","CHILD_FINAL"}
            report["passed"] = (all(p["exitCode"]==0 for p in providers) and driver.returncode==0 and final["setupState"]=="connected"
                and expected <= set(final["typedCommitted"]) and final["syntheticValuePresent"] and final["sessionCount"]>=2
                and {"userPrompt","intermediateResponse","finalResponse","toolOutput","toolError"} <= set(final["occurrencesByContentType"])
                and final["syntheticAlertCount"]>=2 and final["queueCount"]==0 and final["replayStable"] and final["ciphertextMarkerInspectionPassed"])
            latency = final["sourceLatency"]
            live = latency["live"]
            report["latencyMeasurementPassed"] = (live["committedSourceRevisionCount"] > 0
                and latency["unmeasuredSourceRevisionCount"] == 0
                and live["canonicalObservationToCommitObservation"]["count"] == live["committedSourceRevisionCount"]
                and live["queueCaptureToCommitObservation"]["count"] == live["committedSourceRevisionCount"])
            report["liveCanonicalObservationP95WithinProposed120SecondTarget"] = (
                live["canonicalObservationToCommitObservation"]["count"] > 0
                and live["canonicalObservationToCommitObservation"]["p95"] < 120000)
            report["passed"] = report["passed"] and report["latencyMeasurementPassed"]
        finally:
            driver_cleanup = stop_group(driver)
    report["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    cleanup_checks = [p["processGroupCleanup"] for p in providers] + [driver_cleanup]
    processes_stopped = all(not check["term_permission_denied"] and not check["kill_permission_denied"] for check in cleanup_checks)
    report["cleanup"] = {"disposableRootRemoved":not root.exists(),"temporaryAuthenticationRemoved":not root.exists(),
                         "ownedProcessGroupsStopped":processes_stopped,"driverProcessGroupCleanup":driver_cleanup,
                         "existingHookSettingsModified":False,
                         "existingHistoriesModified":False}
    report["passed"] = report["passed"] and report["cleanup"]["disposableRootRemoved"] and processes_stopped
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report,sort_keys=True))
    return 0 if report["passed"] else 1

if __name__ == "__main__":
    raise SystemExit(main())
