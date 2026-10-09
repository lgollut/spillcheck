#!/usr/bin/env python3
"""Actual Claude CLI -> production helper -> encrypted queue -> adapter/detector/store.

Only disposable configs and synthetic values are used. Authentication is reused
without configuration/history reuse; copied auth and provider transcripts are removed.
Printed reports contain counts/checks, never provider stdout, credentials or raw events.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
import uuid

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

EXPECTED_MARKERS = {"PROMPT": "userPrompt", "INTERMEDIATE": "intermediateResponse", "FINAL": "finalResponse",
                    "SHELL_OK": "toolOutput", "SHELL_ERROR": "toolError", "MCP_OK": "toolOutput",
                    "MCP_ERROR": "toolError", "CHILD_PROMPT": "userPrompt", "CHILD_FINAL": "finalResponse"}

# Fixed diagnostic labels only. Unknown field values are counted as "other", never exported.
DIAGNOSTIC_ENVELOPES = {"user", "assistant", "file-history-snapshot", "progress", "system", "queue-operation",
    "summary", "attachment", "last-prompt", "custom-title", "ai-title", "agent-name", "agent-color", "tag",
    "mode", "permission-mode", "atis-latch", "cost-state", "agent_metadata", "saved_hook_context"}
DIAGNOSTIC_BLOCKS = {"text", "tool_use", "tool_result", "thinking", "redacted_thinking", "image", "image_url",
    "audio", "tool_reference", "input_text", "output_text", "document"}
DIAGNOSTIC_SUBTYPES = {"init", "turn_duration", "compact_boundary", "api_error", "local_command", "stop_hook_summary",
    "hook_started", "hook_response", "hook_progress", "task_notification", "task_started", "task_progress"}
DIAGNOSTIC_ATTACHMENTS = {"agent_listing_delta", "mcp_instructions_delta", "environment", "model", "auto_mode",
    "total_tokens_reminder", "session_context", "date", "credential_org", "remote_session_change", "prompt_snapshot",
    "ultramemory_snapshot", "todo", "queued_command", "file", "selected_lines", "invoked_skills", "diagnostics",
    "hook_additional_context", "budget_usd", "output_style"}

def diagnostic_label(value, allowed):
    return value if isinstance(value, str) and value in allowed else ("missing" if value is None else "other")

def native_format_diagnostics(projects):
    """Count native shapes from this owned fixture without exporting content or native IDs."""
    envelopes, blocks, subtypes, unknown_shapes, attachments = {}, {}, {}, {}, {}
    malformed = 0
    ignored = {"file-history-snapshot", "progress", "system", "queue-operation", "summary"}
    def increment(counts, label):
        counts[label] = counts.get(label, 0) + 1
    for path in sorted(projects.rglob("*.jsonl")):
        for line in path.read_bytes().splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                malformed += 1
                continue
            if not isinstance(row, dict):
                malformed += 1
                continue
            kind = row.get("type")
            label = diagnostic_label(kind, DIAGNOSTIC_ENVELOPES)
            increment(envelopes, label)
            if row.get("subtype") is not None:
                increment(subtypes, label + "/" + diagnostic_label(row["subtype"], DIAGNOSTIC_SUBTYPES))
            if kind == "attachment":
                attachment = row.get("attachment")
                increment(attachments, diagnostic_label(attachment.get("type") if isinstance(attachment, dict) else attachment,
                    DIAGNOSTIC_ATTACHMENTS))
            if label not in {"user", "assistant"} | ignored:
                shape = label + ("/has-message" if "message" in row else "/no-message")
                shape += "/has-content" if "content" in row else "/no-content"
                increment(unknown_shapes, shape)
            message = row.get("message")
            if not isinstance(message, dict):
                continue
            content = message.get("content")
            if isinstance(content, str):
                increment(blocks, "text")
            elif isinstance(content, list):
                for block in content:
                    increment(blocks, diagnostic_label(block.get("type") if isinstance(block, dict) else None, DIAGNOSTIC_BLOCKS))
    return {"envelopeTypeCounts": dict(sorted(envelopes.items())), "contentBlockTypeCounts": dict(sorted(blocks.items())),
        "envelopeSubtypeCounts": dict(sorted(subtypes.items())), "additionalEnvelopeShapeCounts": dict(sorted(unknown_shapes.items())),
        "attachmentTypeCounts": dict(sorted(attachments.items())),
        "malformedRowCount": malformed, "labelsAreControlled": True,
        "scope": "Owned native fixture files before cleanup; shape counts alone do not establish required-content loss."}

def native_history_evidence(projects):
    """Inspect only this run's histories; retain native identities and hashes privately."""
    signatures = {}
    versions, kinds, markers = set(), {}, {}
    framing, fields_valid, rows = True, True, 0
    def strings(value):
        if isinstance(value, str):
            return [value]
        if isinstance(value, list):
            return [text for item in value for text in strings(item)]
        if isinstance(value, dict):
            if value.get("type") in {"image", "image_url", "audio", "tool_reference"}:
                return []
            return [text for key, item in value.items() if key != "type" for text in strings(item)]
        return []
    for path in sorted(projects.rglob("*.jsonl")):
        payload = path.read_bytes()
        framing = framing and (not payload or payload.endswith(b"\n"))
        native_ids = []
        for line in payload.splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                fields_valid = False
                continue
            if not isinstance(row, dict):
                fields_valid = False
                continue
            if row.get("type") not in {"user", "assistant"}:
                continue
            rows += 1
            message = row.get("message", {})
            fields_valid = fields_valid and isinstance(message, dict) and message.get("role") == row["type"]
            if not isinstance(message, dict):
                continue
            fields_valid = fields_valid and all(isinstance(row.get(key), str) and row[key]
                for key in ("uuid", "sessionId", "timestamp"))
            native_ids.append((row.get("sessionId"), row.get("uuid")))
            version = row.get("version") if isinstance(row.get("version"), str) and row["version"] else "unknown"
            versions.add(version)
            content = message.get("content", [])
            blocks = content if isinstance(content, list) else [{"type": "text", "text": content}]
            for block in blocks:
                if not isinstance(block, dict):
                    fields_valid = False
                    continue
                if block.get("type") == "text":
                    kind = "userPrompt" if row["type"] == "user" else (
                        "finalResponse" if message.get("stop_reason") == "end_turn" else "intermediateResponse")
                    text = block.get("text", "")
                elif block.get("type") == "tool_result":
                    kind = "toolError" if block.get("is_error") is True else "toolOutput"
                    text = "\n".join(strings(block.get("content")))
                    native_ids.append((row.get("sessionId"), block.get("tool_use_id")))
                else:
                    continue
                if not isinstance(text, str) or SECRET not in text:
                    continue
                kinds.setdefault(version, set()).add(kind)
                for marker, expected_kind in EXPECTED_MARKERS.items():
                    if kind != expected_kind or "LEAKRET_M3_" + marker not in text:
                        continue
                    if marker.startswith("CHILD_") and "/subagents/agent-" not in str(path):
                        continue
                    if marker == "CHILD_PROMPT" and not text.strip().startswith("LEAKRET_M3_CHILD_PROMPT"):
                        continue
                    markers.setdefault(version, set()).add(marker)
        signatures[str(path)] = (hashlib.sha256(payload).digest(), tuple(native_ids))
    return signatures, {"producerVersions": sorted(versions), "nativeTranscriptCount": len(signatures),
        "contentRowCount": rows, "completeJSONLFraming": framing, "requiredNativeFieldsValid": bool(fields_valid),
        "contentTypesByProducer": {version: sorted(values) for version, values in sorted(kinds.items())},
        "typedMarkersByProducer": {version: sorted(values) for version, values in sorted(markers.items())},
        "nativeFormatDiagnostics": native_format_diagnostics(projects)}

def deliver_history(helper, root, projects):
    # This is the existing production history request, delivered to the encrypted queue.
    # Swift Codable dates use seconds since 2001, independently of provider timestamps.
    end = datetime.datetime.now(datetime.timezone.utc).timestamp() - 978307200
    request = {"kind": "LeakretClaudeHistory", "version": 1,
               "audit": {"id": str(uuid.uuid4()), "reason": "firstLaunch", "start": end - 7 * 24 * 60 * 60, "end": end},
               "directories": [{"path": str(projects), "depth": 0, "cookie": 0}],
               "pending": [], "deferred": [], "partial": False}
    result = subprocess.run([str(helper), "--socket", str(root / "capture.sock"), "--agent", "claude-code",
        "--interface", "standalone-cli", "--profile-id", "claude-live"],
        input=json.dumps(request).encode(), capture_output=True, timeout=5)
    return {"exitCode": result.returncode, "stdoutBytes": len(result.stdout), "diagnosticBytes": len(result.stderr),
            "route": "productionSevenDayHistory", "producerWasRunBeforeDriver": True}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--timeout", type=int, default=360)
    parser.add_argument("--executable", default="claude", help="Selected Claude executable; no global install is changed.")
    parser.add_argument("--expected-version", help="Optional acceptance baseline; product collection is not restricted to this version.")
    parser.add_argument("--historical-producer-executable", help="Optional genuine producer used only before the driver starts, in the disposable home.")
    parser.add_argument("--expected-historical-version", help="Optional acceptance baseline for the separate historical producer.")
    parser.add_argument("--acceptance-executable", type=pathlib.Path,
                        default=ROOT / ".build/out/Products/Debug/spillcheck-storage-acceptance")
    parser.add_argument("--helper-executable", type=pathlib.Path,
                        default=ROOT / ".build/out/Products/Debug/spillcheck-hook")
    args = parser.parse_args()
    os.umask(0o077)
    binary = args.acceptance_executable.resolve()
    helper = args.helper_executable.resolve()
    executable = pathlib.Path(shutil.which(args.executable) or args.executable).resolve()
    version = subprocess.check_output([str(executable), "--version"], text=True).split()[0]
    if args.expected_version is not None and version != args.expected_version:
        raise SystemExit("Selected Claude executable does not match --expected-version")
    if not version or not binary.is_file() or not helper.is_file():
        raise SystemExit("A Claude executable and built acceptance/helper products are required")
    historical_executable, historical_version = None, None
    if args.historical_producer_executable:
        historical_executable = pathlib.Path(shutil.which(args.historical_producer_executable)
            or args.historical_producer_executable).resolve()
        historical_version = subprocess.check_output([str(historical_executable), "--version"], text=True).split()[0]
        if args.expected_historical_version is not None and historical_version != args.expected_historical_version:
            raise SystemExit("Historical producer does not match --expected-historical-version")
    elif args.expected_historical_version is not None:
        parser.error("--expected-historical-version requires --historical-producer-executable")
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
        historical_provider_runs, historical_signatures, historical_evidence = [], {}, {}
        historical_failure = None
        if historical_executable is not None:
            try:
                historical_provider_runs.append(run_provider(historical_executable, PROMPT, env, project, mcp))
                historical_signatures, historical_evidence = native_history_evidence(config / "projects")
                if historical_provider_runs[0]["exitCode"] != 0:
                    historical_failure = "historicalProviderRunFailed"
                elif not (historical_evidence["completeJSONLFraming"] and historical_evidence["requiredNativeFieldsValid"]
                    and set(EXPECTED_MARKERS) <= set(historical_evidence["typedMarkersByProducer"].get(historical_version, []))):
                    historical_failure = "historicalProviderRequiredNativeContentMissing"
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                historical_failure = "historicalProviderUnavailable-" + type(error).__name__
        providers, driver_cleanup = [], None
        report = {"schemaVersion": 4 if historical_executable else 3, "agentVersion": version,
                  "executablePath": str(executable), "expectedVersion": args.expected_version,
                  "interface": "standaloneCLI", "startedAt": started_at, "passed": False}
        if historical_executable is not None:
            report.update(historicalProducerVersion=historical_version,
                historicalExecutablePath=str(historical_executable), expectedHistoricalVersion=args.expected_historical_version,
                historicalProducerRuns=historical_provider_runs, historicalNativeSourceEvidence=historical_evidence,
                historicalProducerWasInvokedAsCLI=True, guiHostCollectionEstablished=False)
        if historical_failure:
            report.update(unmetGate=historical_failure, providerRuns=[], driverLaunched=False)
        else:
            report, providers, driver_cleanup = drive_collection(args, root, config, project, mcp, env,
                binary, quoted_helper, executable, version, report, historical_version, historical_signatures)
        if historical_executable is not None:
            historical_version_after = subprocess.check_output([str(historical_executable), "--version"], text=True).split()[0]
            report.update(historicalProducerVersionAfterRun=historical_version_after,
                historicalExecutableVersionStable=historical_version_after == historical_version)
            report["passed"] = report["passed"] and report["historicalExecutableVersionStable"]
    report["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    cleanup_checks = [p["processGroupCleanup"] for p in providers + historical_provider_runs]
    if driver_cleanup is not None:
        cleanup_checks.append(driver_cleanup)
    processes_stopped = all(not check["term_permission_denied"] and not check["kill_permission_denied"] for check in cleanup_checks)
    report["cleanup"] = {"disposableRootRemoved":not root.exists(),"temporaryAuthenticationRemoved":not root.exists(),
                         "ownedProcessGroupsStopped":processes_stopped,"driverProcessGroupCleanup":driver_cleanup,
                         "existingHookSettingsModified":False,"existingHistoriesModified":False}
    report["passed"] = report["passed"] and report["cleanup"]["disposableRootRemoved"] and processes_stopped
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report,sort_keys=True))
    return 0 if report["passed"] else 1

def drive_collection(args, root, config, project, mcp, env, binary, quoted_helper, executable, version,
                     report, historical_version, historical_signatures):
    driver = subprocess.Popen([str(binary),"--claude-live","--directory",str(root),"--settings",str(config/"settings.json"),
        "--helper",str(quoted_helper),"--version",version,"--scanner",str(ROOT/".build/scanner/betterleaks"),
        "--rules",str(ROOT/".build/scanner/betterleaks.toml"),"--source-root",str(config/"projects"),"--duration",str(args.timeout)],
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
        if historical_version is not None:
            report["historicalCaptureDelivery"] = deliver_history(quoted_helper, root, config / "projects")
        providers = [run_provider(executable,ready["verificationPrompt"],env,project,mcp),
                     run_provider(executable,PROMPT,env,project,mcp),
                     run_provider(executable,f"Respond exactly LEAKRET_M3_FINAL {SECRET}. This is synthetic test data.",env,project,mcp)]
        (root/"provider-finished").touch()
        driver.wait(timeout=args.timeout)
        thread.join(timeout=2); error_thread.join(timeout=2)
        final = next((json.loads(line) for line in reversed(lines) if json.loads(line).get("finished")),None)
        assert final is not None
        version_after = subprocess.check_output([str(executable), "--version"], text=True).split()[0]
        report.update({"versionAfterRun":version_after,"executableVersionStable":version_after == version,
                  "providerRuns":providers,"driverExitCode":driver.returncode,
                  "driverDiagnosticBytes":len(diagnostics),"result":final,
                  "driverLaunched":True,"t3LatencyMeasured":False,
                  "historicalLatencyMeasured":final["sourceLatency"]["historical"]["committedSourceRevisionCount"] > 0})
        expected = {"PROMPT","INTERMEDIATE","FINAL","SHELL_OK","SHELL_ERROR","MCP_OK","MCP_ERROR","CHILD_PROMPT","CHILD_FINAL"}
        report["passed"] = (report["executableVersionStable"] and version in final["producerVersions"]
            and final["observedExecutableVersion"] == version
            and all(p["exitCode"]==0 for p in providers) and driver.returncode==0 and final["setupState"]=="connected"
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
        report["nativeFormatDiagnostics"] = native_format_diagnostics(config / "projects")
        if historical_version is not None:
            after_signatures, after_evidence = native_history_evidence(config / "projects")
            identities_stable = bool(historical_signatures) and all(after_signatures.get(path) == signature
                for path, signature in historical_signatures.items())
            typed_counts_cover_both = all(final["typedCommitted"].get(marker, 0) >= 2 for marker in EXPECTED_MARKERS)
            mixed_versions = {historical_version, version} <= set(final["producerVersions"]) and historical_version != version
            report.update(nativeHistoryIdentityAndContentStable=identities_stable,
                combinedNativeSourceEvidence=after_evidence, mixedProducerVersionsEstablished=mixed_versions,
                typedCommittedCountsCoverBothProducerCorpora=typed_counts_cover_both,
                historicalCaptureWasSyntheticDelivery=True)
            report["passed"] = (report["passed"] and identities_stable and typed_counts_cover_both and mixed_versions
                and report["historicalLatencyMeasured"] and report["historicalCaptureDelivery"]["exitCode"] == 0
                and final.get("historicalQueueAdmissionCount", 0) > 0 and final.get("historicalAdmissionsSettled") is True)
    finally:
        driver_cleanup = stop_group(driver)
    return report, providers, driver_cleanup

if __name__ == "__main__":
    raise SystemExit(main())
