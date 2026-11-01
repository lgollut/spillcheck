#!/usr/bin/env python3
"""Actual Claude CLI -> production helper -> encrypted queue -> adapter/detector/store.

Only disposable configs and synthetic values are used. Authentication is reused
without configuration/history reuse; copied auth is always removed. Successful
runs remove transcripts; failed runs retain their owned, private source artifacts.
Printed reports contain counts/checks, never provider stdout, credentials or raw events.
"""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests"))
from Support.processes import stop_group
from Support.claude_native_evidence import inspect_disposable_native_sources

SECRET = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
CHILD_PROMPT = f"""LEAKRET_M3_CHILD_PROMPT {SECRET}. Disposable synthetic test. Your first assistant text must contain LEAKRET_M3_CHILD_INTERMEDIATE {SECRET}. Use Bash to run printf 'LEAKRET_M3_CHILD_TOOL_OUTPUT {SECRET}\\n'. Then use Bash to run printf 'LEAKRET_M3_CHILD_TOOL_ERROR {SECRET}\\n' >&2; exit 7. This failure is intentional; do not repair it. End with LEAKRET_M3_CHILD_FINAL {SECRET}. Do not read files or browse."""
PROMPT = f"""Disposable local Spillcheck test. Every credential below is synthetic and must never be used for authentication. Do not read files or browse. User marker LEAKRET_M3_PROMPT {SECRET}.
1. Your first assistant text must contain LEAKRET_M3_INTERMEDIATE {SECRET}.
2. Run printf 'LEAKRET_M3_SHELL_OK {SECRET}\\n'; sleep 1 using Bash.
3. Run printf 'LEAKRET_M3_SHELL_ERROR {SECRET}\\n' >&2; exit 7 using Bash. This failure is intentional; do not repair it.
4. Call spillcheck_synthetic synthetic_output MCP with fail=false, then fail=true. The error is intentional; do not repair it.
5. Use your built-in Agent tool with the following exact prompt. Wait for its result:
{CHILD_PROMPT}
6. End with LEAKRET_M3_FINAL {SECRET}.
"""

def authentication(env, config):
    env["CLAUDE_CONFIG_DIR"] = str(config)
    auth = pathlib.Path.home() / ".claude/.credentials.json"
    if auth.is_file():
        shutil.copyfile(auth, config / ".credentials.json")
        os.chmod(config / ".credentials.json", 0o600)
    else:
        result = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
                                capture_output=True, timeout=10)
        if result.returncode == 0:
            try:
                token = json.loads(result.stdout).get("claudeAiOauth", {}).get("accessToken")
                if token:
                    env["CLAUDE_CODE_OAUTH_TOKEN"] = token
            except (ValueError, TypeError):
                pass


def provider_failure_details(output, errors, *, exit_code, timed_out=False):
    """Classify bounded, explicitly flagged provider errors without exporting their text.

    Ordinary model text, prompts, tool results and malformed output are not evidence
    for an account diagnosis. Unknown or conflicting error formats stay generic.
    """
    if timed_out:
        return {"failureCategory": "providerTimedOut", "failureClassificationTruncated": False}
    if exit_code == 0:
        return {}
    categories, truncated = set(), False
    codes = {"rate_limit": "rateLimit", "rate_limit_error": "rateLimit",
        "authentication_error": "authenticationUnavailable", "authentication_failed": "authenticationUnavailable",
        "invalid_api_key": "authenticationUnavailable", "error_max_budget_usd": "fixtureBudgetLimit"}

    def text_category(value):
        nonlocal truncated
        if not isinstance(value, str):
            return
        truncated = truncated or len(value) > 4096
        selected = value[:4096].strip().lower()
        for pattern, category in (
            (r"^(?:you['’]ve|you have) hit your session limit\b", "sessionLimit"),
            (r"^(?:not logged in\b|invalid api key\b|authentication failed\b)", "authenticationUnavailable"),
            (r"^(?:rate limit exceeded\b|too many requests\b)", "rateLimit")):
            if re.search(pattern, selected):
                categories.add(category)

    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("duplicate provider field")
            value[key] = item
        return value

    for data, limit in ((output, 256 * 1024), (errors, 16 * 1024)):
        if not isinstance(data, bytes):
            continue
        if len(data) > limit:
            truncated = True
            data = data[-limit:]
            _, separator, data = data.partition(b"\n")
            if not separator:
                continue
        lines = data.splitlines()
        truncated = truncated or len(lines) > 128
        for line in lines[-128:]:
            if len(line) > 32768:
                truncated = True
                continue
            try:
                row = json.loads(line, object_pairs_hook=unique)
            except (ValueError, RecursionError):
                continue
            if not isinstance(row, dict):
                continue
            kind, error = row.get("type"), row.get("error")
            subtype = row.get("subtype")
            flagged = (kind == "error" or kind == "result" and
                (row.get("is_error") is True or isinstance(subtype, str) and subtype.startswith("error_"))
                or kind == "assistant" and (row.get("isApiErrorMessage") is True
                    or isinstance(error, str) and error in codes or isinstance(error, dict)))
            if not flagged:
                continue
            for code in (subtype, error if isinstance(error, str) else None,
                         error.get("type") if isinstance(error, dict) else None,
                         error.get("code") if isinstance(error, dict) else None):
                if isinstance(code, str) and code in codes:
                    categories.add(codes[code])
            if isinstance(error, dict):
                text_category(error.get("message"))
            elif isinstance(error, str):
                text_category(error)
            if kind == "result":
                text_category(row.get("result"))
                messages = row.get("errors", [])
                if isinstance(messages, list):
                    truncated = truncated or len(messages) > 32
                    for message in messages[:32]:
                        text_category(message)
            elif kind == "error":
                text_category(row.get("message"))
            elif kind == "assistant":
                message = row.get("message")
                content = message.get("content") if isinstance(message, dict) else None
                if isinstance(content, list):
                    truncated = truncated or len(content) > 32
                    for block in content[:32]:
                        if isinstance(block, dict) and block.get("type") == "text":
                            text_category(block.get("text"))
    # A session quota is a more specific rate limit. Other conflicts remain unknown.
    if "sessionLimit" in categories:
        categories.discard("rateLimit")
    return {"failureCategory": next(iter(categories)) if len(categories) == 1 else "providerFailed",
            "failureClassificationTruncated": truncated}


def run_provider(executable, prompt, env, project, mcp, timeout=150):
    command = [str(executable), "--print", "--verbose", "--output-format", "stream-json", "--include-partial-messages",
               "--include-hook-events", "--forward-subagent-text", "--dangerously-skip-permissions",
               "--setting-sources", "user", "--strict-mcp-config", "--mcp-config", str(mcp), "--max-budget-usd", "3"]
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             cwd=project, env=env, start_new_session=True)
    try:
        output, errors = child.communicate(prompt.encode(), timeout=timeout)
        result = {"exitCode":child.returncode,"outputBytes":len(output),"diagnosticBytes":len(errors)}
        result.update(provider_failure_details(output, errors, exit_code=child.returncode))
    except subprocess.TimeoutExpired as error:
        result = {"exitCode":None,"timedOut":True,"outputBytes":len(error.output or b""),
                  "diagnosticBytes":len(error.stderr or b"")}
        result.update(provider_failure_details(b"", b"", exit_code=None, timed_out=True))
    finally:
        cleanup = stop_group(child)
    result["processGroupCleanup"] = cleanup
    return result

def required_coverage_complete(result):
    # Absence of evidence must not pass when used with an older driver.
    return result.get("gapReasons") == [] and result.get("coverageReportTruncated") is False

def remove_temporary_authentication(config):
    """Retain only owned provider sources, never config/authentication material.

    Claude may refresh credentials or create other configuration files, so deleting
    just the original credentials filename is insufficient. Do not follow links.
    """
    try:
        config.lstat()
    except FileNotFoundError:
        return True
    except OSError:
        return False
    removed = True
    try:
        if config.is_symlink():
            config.unlink()
            return True
        for path in config.iterdir():
            try:
                if path.name == "projects" and path.is_dir() and not path.is_symlink():
                    continue
                if path.is_dir() and not path.is_symlink():
                    shutil.rmtree(path)
                else:
                    path.unlink()
            except OSError:
                removed = False
    except OSError:
        removed = False
    return removed

def write_artifact_pointer(pointer, root, auth_removed):
    """Never replace an earlier run's handoff, even after a partial write."""
    try:
        pointer.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(pointer, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump({"schemaVersion":1,"ownedArtifactRoot":str(root),
                       "temporaryAuthenticationRemoved":auth_removed}, stream, indent=2)
            stream.write("\n")
        return True
    except OSError:
        return False

def finalize_artifacts(root, passed, pointer):
    """Delete successful fixtures; keep failed fake sources after stripping auth."""
    auth_removed = remove_temporary_authentication(root / "claude")
    root_deletion_failed = False
    if passed and auth_removed:
        try:
            shutil.rmtree(root)
        except OSError:
            root_deletion_failed = True
    retained, root_state_confirmed = True, True
    try:
        root.lstat()
    except FileNotFoundError:
        retained = False
    except OSError:
        root_state_confirmed = False
    pointer_written, fallback_used, stderr_handoff = False, False, False
    if retained:
        pointer_written = write_artifact_pointer(pointer, root, auth_removed)
        if not pointer_written:
            recovery_pointer = pointer.with_name(pointer.stem + ".recovery.json")
            pointer_written = write_artifact_pointer(recovery_pointer, root, auth_removed)
            fallback_used = pointer_written
        if not pointer_written:
            try:
                print("Private acceptance artifacts retained: " + str(root), file=sys.stderr, flush=True)
                stderr_handoff = True
            except (OSError, ValueError):
                pass
    return {"disposableRootRemoved":not retained,"failedArtifactsRetained":retained,
            "temporaryAuthenticationRemoved":auth_removed,"rootDeletionFailed":root_deletion_failed,
            "artifactRootStateConfirmed":root_state_confirmed,"artifactPointerWritten":pointer_written,
            "artifactPointerUsedFallback":fallback_used,"artifactPointerWriteFailed":retained and not pointer_written,
            "privateStderrHandoffWritten":stderr_handoff,
            "cleanupComplete":auth_removed and not root_deletion_failed and root_state_confirmed
                and (not retained or pointer_written)}

EXPECTED_MARKERS = {"PROMPT": "userPrompt", "INTERMEDIATE": "intermediateResponse", "FINAL": "finalResponse",
                    "SHELL_OK": "toolOutput", "SHELL_ERROR": "toolError", "MCP_OK": "toolOutput",
                    "MCP_ERROR": "toolError", "CHILD_PROMPT": "userPrompt", "CHILD_INTERMEDIATE": "intermediateResponse",
                    "CHILD_FINAL": "finalResponse", "CHILD_TOOL_OUTPUT": "toolOutput", "CHILD_TOOL_ERROR": "toolError"}

def typed_role_coverage_complete(result):
    """All twelve original source markers need exact committed role/revision evidence."""
    roles = result.get("typedCommittedByRole", {})
    native = result.get("nativeSourceRoles", {})
    if (result.get("roleEvidenceWithinBudget") is not True
        or type(native.get("conflictingSourceIdentityCount")) is not int or native["conflictingSourceIdentityCount"] != 0
        or any(type(native.get(key)) is not int or native[key] < 1
               for key in ("verifiedParentSourceCount", "verifiedOwnChildSourceCount"))):
        return False
    return all(type(roles.get("child" if marker.startswith("CHILD_") else "parent", {}).get(marker)) is int
        and roles["child" if marker.startswith("CHILD_") else "parent"][marker] > 0 for marker in EXPECTED_MARKERS)


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
    "hook_additional_context", "budget_usd", "output_style", "edited_text_file", "hook_non_blocking_error",
    "hook_cancelled", "hook_success", "structured_output"}

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
    """Inspect exact owned source files; retain only native signatures privately."""
    paths, evidence = inspect_disposable_native_sources(projects, SECRET)
    signatures = {}
    if evidence["requiredNativeFieldsValid"] and evidence["completeJSONLFraming"]:
        # The bounded inspector selects the only paths eligible for this fixture.
        # Re-read using its same ownership, no-follow, stability and byte limits.
        from Support.claude_native_evidence import _read, MAXIMUM_TOTAL_BYTES
        total = 0
        for path, _ in paths:
            payload = _read(path, MAXIMUM_TOTAL_BYTES - total)
            total += len(payload)
            native_ids = []
            for line in payload.splitlines():
                row = json.loads(line)
                if row.get("type") not in {"user", "assistant"}:
                    continue
                native_ids.append((row.get("sessionId"), row.get("uuid")))
                content = row.get("message", {}).get("content", [])
                if isinstance(content, list):
                    native_ids.extend((row.get("sessionId"), block.get("tool_use_id")) for block in content
                        if isinstance(block, dict) and block.get("type") == "tool_result")
            signatures[str(path)] = (hashlib.sha256(payload).digest(), tuple(native_ids))
    return signatures, {**evidence, "nativeFormatDiagnostics": native_format_diagnostics(projects)}

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
    artifact_pointer = args.output.with_suffix(".private-artifacts.json")
    if artifact_pointer.exists() or artifact_pointer.is_symlink():
        raise SystemExit("Existing failed-artifact pointer must be preserved; choose a new --output path")
    started_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    report = {"schemaVersion": 4 if historical_executable else 3, "agentVersion": version,
              "executablePath": str(executable), "expectedVersion": args.expected_version,
              "interface": "standaloneCLI", "startedAt": started_at, "passed": False,
              "providerRuns":[], "historicalProducerRuns":[], "driverLaunched":False}
    root = pathlib.Path(tempfile.mkdtemp(prefix="lr-m6-claude-quoted ' $ `-",dir="/tmp")).resolve()
    execution_completed = False
    try:
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
        historical_provider_runs = report["historicalProducerRuns"]
        historical_signatures, historical_evidence = {}, {}
        historical_failure = None
        if historical_executable is not None:
            try:
                historical_provider_runs.append(run_provider(historical_executable, PROMPT, env, project, mcp))
                historical_signatures, historical_evidence = native_history_evidence(config / "projects")
                if historical_provider_runs[0]["exitCode"] != 0:
                    historical_failure = "historicalProviderRunFailed"
                    report["providerFailureCategory"] = historical_provider_runs[0].get("failureCategory", "providerFailed")
                elif not (historical_evidence["completeJSONLFraming"] and historical_evidence["requiredNativeFieldsValid"]
                    and historical_evidence.get("completeNativeParentChildPairCountByProducer", {}).get(historical_version, 0) > 0
                    and set(EXPECTED_MARKERS) <= set(historical_evidence["typedMarkersByProducer"].get(historical_version, []))):
                    historical_failure = "historicalProviderRequiredNativeContentMissing"
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                historical_failure = "historicalProviderUnavailable-" + type(error).__name__
        if historical_executable is not None:
            report.update(historicalProducerVersion=historical_version,
                historicalExecutablePath=str(historical_executable), expectedHistoricalVersion=args.expected_historical_version,
                historicalProducerRuns=historical_provider_runs, historicalNativeSourceEvidence=historical_evidence,
                historicalProducerWasInvokedAsCLI=True, guiHostCollectionEstablished=False)
        if historical_failure:
            report.update(unmetGate=historical_failure, providerRuns=[], driverLaunched=False)
        else:
            report, _, _ = drive_collection(args, root, config, project, mcp, env,
                binary, quoted_helper, executable, version, report, historical_version, historical_signatures)
        if historical_executable is not None:
            historical_version_after = subprocess.check_output([str(historical_executable), "--version"], text=True).split()[0]
            report.update(historicalProducerVersionAfterRun=historical_version_after,
                historicalExecutableVersionStable=historical_version_after == historical_version)
            report["passed"] = report["passed"] and report["historicalExecutableVersionStable"]
        execution_completed = True
    except Exception as error:
        report["passed"] = False
        # Never export exception text: subprocess errors can include prompt/auth data.
        report.setdefault("unmetGate", "fixtureExecutionFailed" if report["driverLaunched"] else "fixtureSetupFailed")
        report["failureKind"] = (type(error).__name__ if isinstance(error,
            (OSError, ValueError, subprocess.SubprocessError, AssertionError)) else "other")
    finally:
        cleanup_checks = [p["processGroupCleanup"] for p in report["providerRuns"] + report["historicalProducerRuns"]]
        driver_cleanup = report.pop("driverProcessGroupCleanup", None)
        if driver_cleanup is not None:
            cleanup_checks.append(driver_cleanup)
        processes_stopped = (not report["driverLaunched"] or driver_cleanup is not None) and all(
            not check["term_permission_denied"] and not check["kill_permission_denied"] for check in cleanup_checks)
        report["passed"] = report["passed"] and execution_completed and processes_stopped
        report["cleanup"] = finalize_artifacts(root, report["passed"], artifact_pointer)
        report["cleanup"].update(ownedProcessGroupsStopped=processes_stopped,
            driverProcessGroupCleanup=driver_cleanup, existingHookSettingsModified=False, existingHistoriesModified=False)
    report["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    report["passed"] = report["passed"] and report["cleanup"]["disposableRootRemoved"] and report["cleanup"]["cleanupComplete"]
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
    report["driverLaunched"] = True
    providers = report["providerRuns"]
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
        for prompt in (ready["verificationPrompt"], PROMPT,
                       f"Respond exactly LEAKRET_M3_FINAL {SECRET}. This is synthetic test data."):
            providers.append(run_provider(executable,prompt,env,project,mcp))
            if providers[-1]["exitCode"] != 0:
                report.update(unmetGate="providerRunFailed",
                    providerFailureCategory=providers[-1].get("failureCategory", "providerFailed"))
                break
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
        expected = set(EXPECTED_MARKERS)
        report["passed"] = (report["executableVersionStable"] and version in final["producerVersions"]
            and final["observedExecutableVersion"] == version
            and all(p["exitCode"]==0 for p in providers) and driver.returncode==0 and final["setupState"]=="connected"
            and typed_role_coverage_complete(final)
            and final.get("committedNativeParentChildPairCountByProducer", {}).get(version, 0) > 0 and expected <= set(final["typedCommitted"]) and final["syntheticValuePresent"] and final["sessionCount"]>=2
            and {"userPrompt","intermediateResponse","finalResponse","toolOutput","toolError"} <= set(final["occurrencesByContentType"])
            and final["syntheticAlertCount"]>=2 and final["queueCount"]==0 and final["replayStable"] and final["ciphertextMarkerInspectionPassed"])
        report["individualRoleCoveragePassed"] = typed_role_coverage_complete(final)
        report["requiredCoverageComplete"] = required_coverage_complete(final)
        report["passed"] = report["passed"] and report["requiredCoverageComplete"]
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
        _, native_evidence = inspect_disposable_native_sources(config / "projects", SECRET)
        report["nativeSourceEvidence"] = native_evidence
        report["passed"] = (report["passed"] and native_evidence["requiredNativeFieldsValid"]
            and native_evidence["completeJSONLFraming"] and native_evidence["individualNativeRoleCoverageComplete"]
            and native_evidence["completeNativeParentChildPairCountByProducer"].get(version, 0) > 0 and set(EXPECTED_MARKERS) <= set(native_evidence["typedMarkers"]))
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
                and all(after_evidence["completeNativeParentChildPairCountByProducer"].get(producer, 0) > 0
                    and final.get("committedNativeParentChildPairCountByProducer", {}).get(producer, 0) > 0
                    for producer in (historical_version, version))
                and report["historicalLatencyMeasured"] and report["historicalCaptureDelivery"]["exitCode"] == 0
                and final.get("historicalQueueAdmissionCount", 0) > 0 and final.get("historicalAdmissionsSettled") is True)
    finally:
        driver_cleanup = stop_group(driver)
        report["driverProcessGroupCleanup"] = driver_cleanup
    return report, providers, driver_cleanup

if __name__ == "__main__":
    raise SystemExit(main())
