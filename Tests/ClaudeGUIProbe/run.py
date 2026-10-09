#!/usr/bin/env python3
"""Manual official local Code GUI probe. No GUI automation or provider launch."""
import argparse
import datetime
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests"))
from Support.processes import stop_group
spec = importlib.util.spec_from_file_location("claude_gui_fixture", ROOT / "Tests/ClaudeLive/run.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
REQUIRED = {"userPrompt", "intermediateResponse", "finalResponse", "toolOutput", "toolError"}
MAIN_MARKERS = {"PROMPT", "INTERMEDIATE", "FINAL", "SHELL_OK", "SHELL_ERROR", "CHILD_PROMPT", "CHILD_FINAL"}
SIDE_PROMPT = f"LEAKRET_PHASE0_SIDE_PROMPT {fixture.SECRET}. This credential is synthetic. Respond exactly LEAKRET_PHASE0_SIDE_FINAL {fixture.SECRET}. Do not use tools."
SIDE_ONLY_PROMPT = f"LEAKRET_PHASE0_SIDEPROBE_PROMPT {fixture.SECRET}. This credential is synthetic. Respond exactly LEAKRET_PHASE0_SIDEPROBE_FINAL {fixture.SECRET}. Do not use tools."
MAIN_PROMPT = f"""Disposable Spillcheck GUI collection test. The credential below is synthetic and must never be used for authentication. Do not read files or browse. LEAKRET_M3_PROMPT {fixture.SECRET}.
1. Your first assistant text must contain LEAKRET_M3_INTERMEDIATE {fixture.SECRET}.
2. Run printf 'LEAKRET_M3_SHELL_OK {fixture.SECRET}\\n'; sleep 3 using Bash.
3. Run printf 'LEAKRET_M3_SHELL_ERROR {fixture.SECRET}\\n' >&2; exit 7 using Bash. This failure is intentional; do not repair it.
4. Use your built-in Agent tool with prompt LEAKRET_M3_CHILD_PROMPT {fixture.SECRET}. Instruct the child to respond LEAKRET_M3_CHILD_FINAL {fixture.SECRET} only. Wait for its result.
5. End with LEAKRET_M3_FINAL {fixture.SECRET}. Do not repeat the shell result markers in assistant text.
"""

def write_private(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")
    os.chmod(path, 0o600)

def owned_file(path):
    info = path.lstat()
    if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode) or info.st_size > 2 * 1024 * 1024:
        raise ValueError("selectedSourceOwnershipTypeOrBudget")

def without_registration(settings, registration_id):
    # Reproduce only the ownership comparison, without exporting setting values.
    value = json.loads(json.dumps(settings)) if settings is not None else {}
    if not isinstance(value, dict) or not isinstance(value.get("hooks", {}), dict):
        raise ValueError("settingsOwnershipComparisonInvalid")
    markers = {"Spillcheck hook " + registration_id.lower(), "Leakret hook " + registration_id.lower()}
    hooks = value.get("hooks", {})
    for event in list(hooks):
        if not isinstance(hooks[event], list):
            raise ValueError("settingsOwnershipComparisonInvalid")
        groups = []
        for group in hooks[event]:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise ValueError("settingsOwnershipComparisonInvalid")
            retained = [handler for handler in group["hooks"]
                if isinstance(handler, dict) and handler.get("statusMessage") not in markers]
            if len(retained) != len(group["hooks"]) and not retained:
                continue
            group["hooks"] = retained
            groups.append(group)
        if groups:
            hooks[event] = groups
        else:
            hooks.pop(event)
    if not hooks:
        value.pop("hooks", None)
    return value

def permission_additions_only(before, after):
    if before == after or not isinstance(before, dict) or not isinstance(after, dict):
        return False
    if {key: value for key, value in before.items() if key != "permissions"} != {
            key: value for key, value in after.items() if key != "permissions"}:
        return False
    previous, current = before.get("permissions", {}), after.get("permissions", {})
    if not isinstance(previous, dict) or not isinstance(current, dict):
        return False
    for key, value in previous.items():
        if key not in current:
            return False
        if isinstance(value, list) and isinstance(current[key], list):
            if any(item not in current[key] for item in value):
                return False
        elif current[key] != value:
            return False
    # New non-list permission values can alter policy, so do not classify them as additions.
    return all(isinstance(value, list) for key, value in current.items() if key not in previous)

def settings_evidence(original, installed, before_removal, after_removal, registration_id):
    initial = without_registration(original, registration_id)
    post_install = without_registration(installed, registration_id)
    pre_remove = without_registration(before_removal, registration_id)
    post_remove = without_registration(after_removal, registration_id)
    install_preserved = initial == post_install
    removal_preserved = pre_remove == post_remove
    interval_changed = post_install != pre_remove
    only_permissions = permission_additions_only(post_install, pre_remove)
    empty_hook_normalized = (isinstance(original, dict) and original.get("hooks") == {}
        and isinstance(after_removal, dict) and "hooks" not in after_removal and initial == post_remove)
    return {"ownedInstallPreservedUnownedSettings": install_preserved,
        "ownedRemovalPreservedCurrentUnownedSettings": removal_preserved,
        "unownedSettingsChangedBeforeOwnedRemoval": interval_changed,
        "onlyPermissionAdditionsBeforeOwnedRemoval": only_permissions,
        "initialEmptyHookContainerNormalized": empty_hook_normalized,
        "settingsMismatchClassification": "ownedEditChangedUnownedSettings" if not (install_preserved and removal_preserved) else (
            "permissionAdditionsBeforeOwnedRemoval" if only_permissions else (
                "unownedChangesBeforeOwnedRemoval" if interval_changed else (
                    "emptyHookContainerNormalized" if empty_hook_normalized else "unchanged"))),
        "settingsChangeActorEstablished": False,
        "rawSettingsArchived": False}

def cold_gate(report):
    core = report.get("coldCatchUpCore", {})
    result = core.get("result", {})
    delivery = report.get("coldHistoryDelivery", {})
    def positive(value):
        return isinstance(value, int) and not isinstance(value, bool) and value > 0
    admitted = result.get("historicalQueueAdmissionCount")
    admission_measured = positive(admitted)
    audit_settled = (admission_measured and result.get("historicalAdmissionsSettled") is True
        and positive(result.get("historicalSettledAdmissionCount"))
        and result.get("historicalSettledAdmissionCount") == admitted
        and positive(result.get("historicalProgressCount")))
    required_observed = (all(positive(result.get("occurrencesByContentType", {}).get(kind)) for kind in REQUIRED)
        and all(positive(result.get("typedCommitted", {}).get(marker)) for marker in MAIN_MARKERS)
        and positive(result.get("sourceLatency", {}).get("historical", {}).get("committedSourceRevisionCount")))
    queued = result.get("queueCount")
    queue_settled = (isinstance(queued, int) and not isinstance(queued, bool) and queued == 0
        and "captureRejected" not in result.get("gapReasons", []))
    replay_encryption = (core.get("exitCode") == 0 and result.get("replayStable") is True
        and result.get("ciphertextMarkerInspectionPassed") is True)
    delivery_passed = delivery.get("exitCode") == 0 and positive(delivery.get("selectedSourceCount"))
    return {"coldHistoricalAuditAdmissionMeasured": admission_measured,
        "coldHistoricalAuditSettlementEstablished": audit_settled,
        "coldRequiredContentAndChildObserved": required_observed,
        "coldQueueSettledWithoutCaptureRejection": queue_settled,
        "coldEncryptedReplayPassed": replay_encryption,
        "coldRequiredContentAndChildCommitted": bool(required_observed and audit_settled and queue_settled
            and replay_encryption and delivery_passed)}

def selected_files(source):
    owned_file(source)
    children = source.parent / source.stem / "subagents"
    paths = [source]
    if children.exists():
        info = children.lstat()
        if info.st_uid != os.getuid() or not stat.S_ISDIR(info.st_mode):
            raise ValueError("selectedChildDirectoryOwnershipOrType")
        for child in sorted(children.glob("agent-*.jsonl"))[:32]:
            owned_file(child)
            paths.append(child)
    return paths

def native_summary(source, key, side_prompt_marker="LEAKRET_PHASE0_SIDE_PROMPT", side_final_marker="LEAKRET_PHASE0_SIDE_FINAL"):
    counts, versions, side_markers, ids = {}, set(), set(), set()
    framing, rows, bytes_read, malformed = True, 0, 0, 0
    for path in selected_files(source):
        data = path.read_bytes()
        bytes_read += len(data)
        framing = framing and data.endswith(b"\n")
        for marker in (side_prompt_marker, side_final_marker):
            if marker.encode() in data:
                side_markers.add(marker)
        for line in data.splitlines(keepends=True):
            if not line.endswith(b"\n"):
                continue
            try:
                row = json.loads(line)
            except ValueError:
                malformed += 1
                continue
            if not isinstance(row, dict):
                malformed += 1
                continue
            if row.get("type") not in {"user", "assistant"}:
                continue
            rows += 1
            versions.add(row.get("version") if isinstance(row.get("version"), str) and row["version"] else "unknown")
            message = row.get("message", {})
            if not isinstance(message, dict):
                malformed += 1
                continue
            for identity in (row.get("uuid"), row.get("turn_id"), message.get("id")):
                if isinstance(identity, str):
                    ids.add(hmac.new(key, identity.encode(), hashlib.sha256).hexdigest())
            blocks = message.get("content", [])
            if isinstance(blocks, str):
                blocks = [{"type": "text", "text": blocks}]
            for block in blocks:
                if not isinstance(block, dict):
                    malformed += 1
                    continue
                if block.get("type") == "text":
                    kind = "userPrompt" if row["type"] == "user" else (
                        "finalResponse" if message.get("stop_reason") == "end_turn" else "intermediateResponse")
                elif block.get("type") == "tool_result":
                    kind = "toolError" if block.get("is_error") is True else "toolOutput"
                else:
                    continue
                counts[kind] = counts.get(kind, 0) + 1
    return {"contentRowCount": rows, "contentCounts": counts, "producerVersions": sorted(versions),
        "completeJSONLFraming": framing, "selectedTranscriptCount": len(selected_files(source)), "bytesRead": bytes_read,
        "malformedControlledRecordCount": malformed,
        "sidePromptMarkerPresent": side_prompt_marker in side_markers,
        "sideFinalMarkerPresent": side_final_marker in side_markers}, ids

def hook_summary(journal, native_ids, native_path_comparisons=(), side_prompt_marker="LEAKRET_PHASE0_SIDE_PROMPT",
        side_final_marker="LEAKRET_PHASE0_SIDE_FINAL"):
    rows = [json.loads(line) for line in journal.read_text().splitlines()] if journal.exists() else []
    counts, delivered, groups = {}, {}, {}
    rejected = failures = 0
    for row in rows:
        event = row["event"]
        counts[event] = counts.get(event, 0) + 1
        if row.get("forwarded") and row.get("helperExitCode") == 0:
            delivered[event] = delivered.get(event, 0) + 1
        if not row.get("scopeMatches", False):
            rejected += 1
        if row.get("failure"):
            failures += 1
        if event == "MessageDisplay" and row.get("messageComparison"):
            groups.setdefault(row["messageComparison"], []).append(row)
    side_groups = [batch for batch in groups.values()
        if any(side_final_marker in row.get("controlledMarkers", []) for row in batch)]
    subagent_starts = [row for row in rows if row["event"] == "SubagentStart"]
    subagent_stops = [row for row in rows if row["event"] == "SubagentStop"]
    side_stops = [row for row in subagent_stops
        if side_final_marker in row.get("controlledMarkersByField", {}).get("last_assistant_message", [])]
    selected_side_stops = [row for row in side_stops if row.get("selectedCallbackMatches")]
    started_agents = {row["agentComparison"] for row in subagent_starts
        if row.get("selectedCallbackMatches") and row.get("agentComparison")}
    stop_signatures, final_groups = set(), {}
    for row in selected_side_stops:
        stop_signatures.add(tuple(row.get(field) for field in ("agentComparison", "agentTranscriptComparison",
            "lastAssistantMessageComparison", "sessionComparison")))
        if row.get("agentComparison"):
            final_groups.setdefault(row["agentComparison"], set()).add(row.get("lastAssistantMessageComparison"))
    def complete(batch):
        indexed = {}
        for row in batch:
            if row.get("index") is None or not row.get("identityFieldsValid"):
                return False
            signature = (row.get("deltaComparison"), row.get("final"), row.get("turnComparison"), row.get("sessionComparison"))
            indexed.setdefault(row["index"], set()).add(signature)
        indices = sorted(indexed)
        if not indices or indices != list(range(max(indices) + 1)) or any(len(values) != 1 for values in indexed.values()):
            return False
        signatures = [next(iter(indexed[index])) for index in indices]
        return (all(signature[1] is not None for signature in signatures)
            and [signature[1] for signature in signatures].count(True) == 1 and signatures[-1][1] is True
            and len({signature[2:] for signature in signatures}) == 1)
    return {"observedEvents": counts, "successfulProductionHelperDeliveries": delivered,
        "outsideSelectedSourceCount": rejected, "controlledHookFailureCount": failures,
        "displayMessageGroupCount": len(groups), "completeDisplayMessageGroupCount": sum(complete(batch) for batch in groups.values()),
        "sideFinalDisplayGroupCount": len(side_groups), "completeSideFinalDisplayGroupCount": sum(complete(batch) for batch in side_groups),
        "sideFinalDisplaySelectedSessionMatches": bool(side_groups) and all(row.get("selectedSessionMatches") for batch in side_groups for row in batch),
        "sideFinalDisplayIDExactNativeIdentityMatches": sum(identity in native_ids for identity in groups if groups[identity] in side_groups),
        "sidePromptHookObserved": any(row.get("scopeMatches") and side_prompt_marker in row.get("controlledMarkers", []) for row in rows),
        "sidePromptUserPromptSubmitObserved": any(row["event"] == "UserPromptSubmit" and row.get("selectedCallbackMatches")
            and side_prompt_marker in row.get("controlledMarkersByField", {}).get("prompt", []) for row in rows),
        "subagentStartCount": len(subagent_starts), "subagentStopCount": len(subagent_stops),
        "subagentStopSelectedCallbackCount": sum(bool(row.get("selectedCallbackMatches")) for row in subagent_stops),
        "sideFinalSubagentStopCount": len(side_stops),
        "sideFinalSubagentStopSelectedCallbackCount": len(selected_side_stops),
        "sideFinalSubagentStopSuccessfulDeliveryCount": sum(row.get("forwarded") and row.get("helperExitCode") == 0 for row in selected_side_stops),
        "sideFinalSubagentStopAgentTypeCategories": sorted({row.get("agentTypeCategory", "unmeasured") for row in selected_side_stops}),
        "sideFinalSubagentStopWithAgentIdentityCount": sum(bool(row.get("agentIdentityPresent")) for row in selected_side_stops),
        "sideFinalSubagentStopWithAgentTranscriptPathCount": sum(bool(row.get("agentTranscriptPathPresent")) for row in selected_side_stops),
        "sideFinalSubagentStopSelectedChildPathCount": sum(bool(row.get("agentTranscriptMatchesSelectedChild")) for row in selected_side_stops),
        "sideFinalSubagentStopExactExistingNativeTranscriptMatches": sum(bool(row.get("agentTranscriptComparison"))
            and row["agentTranscriptComparison"] in native_path_comparisons for row in selected_side_stops),
        "sideFinalSubagentStopAgentIDGroupCount": len(final_groups),
        "sideFinalSubagentStopAgentIDsMatchedStartCount": sum(identity in started_agents for identity in final_groups),
        "sideFinalSubagentStopDistinctEventCount": len(stop_signatures),
        "sideFinalSubagentStopDuplicateCount": len(selected_side_stops) - len(stop_signatures),
        "sideFinalSubagentStopConflictingFinalGroupCount": sum(len(values) > 1 for values in final_groups.values())}

def start_driver(args, directory, settings, helper):
    command = [str(args.acceptance_executable.resolve()), "--claude-live", "--directory", str(directory),
        "--settings", str(settings), "--helper", str(helper), "--source-root", str(args.source_root.resolve()),
        "--version", args.producer_version, "--scanner", str(ROOT / ".build/scanner/betterleaks"),
        "--rules", str(ROOT / ".build/scanner/betterleaks.toml"), "--duration", str(args.duration)]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    lines, diagnostics = [], bytearray()
    def consume(stream, target):
        for line in stream:
            target.append(line) if isinstance(target, list) else target.extend(line)
    threads = [threading.Thread(target=consume, args=(process.stdout, lines), daemon=True),
               threading.Thread(target=consume, args=(process.stderr, diagnostics), daemon=True)]
    for thread in threads:
        thread.start()
    end = time.monotonic() + 15
    while time.monotonic() < end and process.poll() is None:
        for line in lines:
            event = json.loads(line)
            if event.get("ready"):
                return process, lines, diagnostics, event
        time.sleep(0.1)
    stop_group(process)
    raise ValueError("coreReceiverNotReady")

def final_driver(process, lines, diagnostics, directory):
    (directory / "provider-finished").touch()
    try:
        process.wait(timeout=35)
    except subprocess.TimeoutExpired:
        stop_group(process)
    result = next((json.loads(line) for line in reversed(lines) if json.loads(line).get("finished")), {})
    cleanup = stop_group(process)
    return {"exitCode": process.returncode, "diagnosticBytes": len(diagnostics), "result": result,
            "processGroupCleanup": cleanup}

def registration(settings, helper):
    values = []
    for groups in json.loads(settings.read_text()).get("hooks", {}).values():
        for group in groups:
            for handler in group.get("hooks", []):
                if handler.get("command") == str(helper):
                    match = re.fullmatch(r"Spillcheck hook ([0-9a-f-]{36})", handler.get("statusMessage", ""))
                    if match:
                        values.append(match[1])
    if len(set(values)) != 1:
        raise ValueError("ownedRegistrationNotIdentified")
    return values[0]

def remove_registration(args, directory, settings, helper, registration_id):
    result = subprocess.run([str(args.acceptance_executable.resolve()), "--claude-configure-hook",
        "--settings", str(settings), "--helper", str(helper), "--socket", str(directory / "capture.sock"),
        "--profile", "claude-live", "--version", args.producer_version, "--registration-id", registration_id,
        "--remove-hook"], capture_output=True, timeout=10)
    return result.returncode == 0

def history_delivery(args, directory, paths):
    end = datetime.datetime.now(datetime.timezone.utc).timestamp() - 978307200
    import uuid
    body = {"kind": "LeakretClaudeHistory", "version": 1,
        "audit": {"id": str(uuid.uuid4()), "reason": "restart", "end": end, "start": end - 604800},
        "directories": [], "pending": [str(path) for path in paths], "deferred": [], "partial": False}
    result = subprocess.run([str(args.helper_executable.resolve()), "--socket", str(directory / "capture.sock"),
        "--agent", "claude-code", "--interface", "standalone-cli", "--profile-id", "claude-live"],
        input=json.dumps(body).encode(), capture_output=True, timeout=5)
    return {"exitCode": result.returncode, "diagnosticBytes": len(result.stderr), "selectedSourceCount": len(paths)}

def collect(args):
    os.umask(0o077)
    source = args.source.resolve()
    source.relative_to(args.source_root.resolve())
    selected_files(source)
    settings = args.settings.absolute()
    original = json.loads(settings.read_text()) if settings.exists() else None
    settings.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    report = {"schemaVersion": 1, "phase0Passed": False, "hostVersion": args.host_version,
        "expectedProducerVersion": args.producer_version, "officialGUICreatedSourceManuallySelected": True,
        "coreHarnessInterface": "standaloneCLI", "productionDesktopCollectorEnabled": False,
        "sourceAuthority": "nativeTranscript", "sideChatCanonicalCollectionEstablished": False,
        "probeMode": "sideOnly" if args.side_only else "mainAndSide"}
    side_prefix = "LEAKRET_PHASE0_SIDEPROBE" if args.side_only else "LEAKRET_PHASE0_SIDE"
    side_prompt_marker, side_final_marker = side_prefix + "_PROMPT", side_prefix + "_FINAL"
    directory = Path(tempfile.mkdtemp(prefix="spillcheck-claude-gui-probe-", dir="/tmp")).resolve()
    try:
        live, cold = directory / "live", directory / "cold"
        live.mkdir(); cold.mkdir()
        journal, config, control = directory / "hook-summary.jsonl", directory / "hook-config.json", directory / "manual-finished.json"
        key = os.urandom(32)
        write_private(config, {"comparisonKey": key.hex(), "source": str(source), "sessionID": args.session,
            "childDirectory": str(source.parent / source.stem / "subagents"), "journal": str(journal),
            "helper": str(args.helper_executable.resolve()),
            "events": ["SessionStart", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "PostToolBatch",
                "MessageDisplay", "SubagentStart", "SubagentStop", "Stop"],
            "markers": [side_prompt_marker, side_final_marker, "LEAKRET_M3_FINAL"]})
        wrapper = directory / "owned-hook"
        wrapper.write_text("#!/usr/bin/python3\nimport runpy, sys\nsys.argv = [" + repr(str(Path(__file__).with_name("hook.py")))
            + ", " + repr(str(config)) + "] + sys.argv[1:]\nrunpy.run_path(sys.argv[0], run_name='__main__')\n")
        wrapper.chmod(0o700)
        process, registration_id = None, None
        installed_settings, before_removal_settings = None, None
        try:
            process, lines, diagnostics, ready = start_driver(args, live, settings, wrapper)
            registration_id = registration(settings, wrapper)
            installed_settings = json.loads(settings.read_text())
            write_private(args.private_control, {"controlFile": str(control), "directory": str(directory), "settings": str(settings)})
            prompts = {"ready": True, "verificationPrompt": ready["verificationPrompt"],
                "probeMode": report["probeMode"], "sideChatPrompt": SIDE_ONLY_PROMPT if args.side_only else SIDE_PROMPT,
                "sideChatCommand": "/btw " + (SIDE_ONLY_PROMPT if args.side_only else SIDE_PROMPT),
                "finishCommand": "python3 Tests/ClaudeGUIProbe/run.py finish --control "
                    + str(args.private_control) + " --side-chat-submitted --side-response-visible",
                "maximumWaitSeconds": args.duration, "providerLaunches": 0}
            if not args.side_only:
                prompts["mainPrompt"] = MAIN_PROMPT
            print(json.dumps(prompts), flush=True)
            deadline = time.monotonic() + args.duration
            while time.monotonic() < deadline and process.poll() is None and not control.exists():
                time.sleep(0.2)
            report["manualCompletion"] = json.loads(control.read_text()) if control.exists() else {"finished": False}
            report["liveCore"] = final_driver(process, lines, diagnostics, live)
            process = None
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            report["controlledFailure"] = type(error).__name__
        finally:
            if process is not None:
                stop_group(process)
            if registration_id is None and settings.exists():
                try:
                    registration_id = registration(settings, wrapper)
                except ValueError:
                    pass
            before_removal_settings = json.loads(settings.read_text()) if settings.exists() else None
            report["ownedRegistrationRemoved"] = bool(registration_id) and remove_registration(args, live, settings, wrapper, registration_id)
        report["nativeSourceObservation"], native_ids = native_summary(source, key, side_prompt_marker, side_final_marker)
        native_paths = {hmac.new(key, str(path).encode(), hashlib.sha256).hexdigest() for path in selected_files(source)}
        report["hookObservation"] = hook_summary(journal, native_ids, native_paths, side_prompt_marker, side_final_marker)
        if report.get("ownedRegistrationRemoved"):
            cold_settings = cold / "settings.json"
            process = None
            try:
                process, lines, diagnostics, _ = start_driver(args, cold, cold_settings, args.helper_executable.resolve())
                report["coldHistoryDelivery"] = history_delivery(args, cold, selected_files(source))
                report["coldCatchUpCore"] = final_driver(process, lines, diagnostics, cold)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                report["coldControlledFailure"] = type(error).__name__
            finally:
                if process is not None:
                    stop_group(process)
        now = json.loads(settings.read_text()) if settings.exists() else None
        report["settingsSemanticallyPreserved"] = now == original or (original is None and now == {})
        if registration_id and installed_settings is not None:
            report["settingsPreservationEvidence"] = settings_evidence(original, installed_settings,
                before_removal_settings, now, registration_id)
        if original is None and now == {} and report.get("ownedRegistrationRemoved"):
            settings.unlink()
        report["sideChatHistoryUnavailableObserved"] = (report["manualCompletion"].get("sideResponseVisible", False)
            and (report["hookObservation"]["sideFinalDisplayGroupCount"] > 0
                or report["hookObservation"]["sideFinalSubagentStopSelectedCallbackCount"] > 0)
            and not report["nativeSourceObservation"]["sideFinalMarkerPresent"])
        report["sideChatFinalSubagentStopObserved"] = report["hookObservation"]["sideFinalSubagentStopSelectedCallbackCount"] > 0
        report["sideChatPromptLiveHookObserved"] = report["hookObservation"]["sidePromptUserPromptSubmitObserved"]
        live_result = report.get("liveCore", {}).get("result", {})
        report["mainFixtureRepeated"] = not args.side_only
        report["mainLiveRequiredContentCommitted"] = (not args.side_only and REQUIRED <= set(live_result.get("occurrencesByContentType", {}))
            and MAIN_MARKERS <= set(live_result.get("typedCommitted", {})))
        report["nativeChildLiveCommitted"] = not args.side_only and {"CHILD_PROMPT", "CHILD_FINAL"} <= set(live_result.get("typedCommitted", {}))
        report.update(cold_gate(report))
        report["remainingGates"] = ["Production GUI route and signed-app acceptance remain separate",
            "Side-chat prompt and response require an evidenced canonical live authority; display IDs cannot be merged with API message IDs",
            "All six local host/provider combinations, restart, upgrade, and scoped notification acceptance"]
    finally:
        if report.get("ownedRegistrationRemoved"):
            shutil.rmtree(directory)
        else:
            report["ownedRegistrationCleanupPending"] = True
    report["disposableProbeRootRemoved"] = not directory.exists()
    report["originalProviderHistoryRetained"] = source.is_file()
    if report.get("disposableProbeRootRemoved"):
        args.private_control.unlink(missing_ok=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)
    return 0 if report.get("ownedRegistrationRemoved") and report.get("disposableProbeRootRemoved") else 1

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("collect")
    for name in ("source", "source-root", "settings", "output", "private-control"):
        run.add_argument("--" + name, required=True, type=Path)
    for name in ("session", "producer-version", "host-version"):
        run.add_argument("--" + name, required=True)
    run.add_argument("--duration", type=int, default=600)
    run.add_argument("--side-only", action="store_true", help="Probe only a new side chat after the owned challenge; do not repeat the main fixture")
    run.add_argument("--acceptance-executable", type=Path, default=ROOT / ".build/out/Products/Debug/spillcheck-storage-acceptance")
    run.add_argument("--helper-executable", type=Path, default=ROOT / ".build/out/Products/Debug/spillcheck-hook")
    finish = commands.add_parser("finish")
    finish.add_argument("--control", type=Path, required=True)
    finish.add_argument("--side-chat-submitted", action="store_true")
    finish.add_argument("--side-response-visible", action="store_true")
    args = parser.parse_args()
    if args.command == "finish":
        owned_file(args.control)
        config = json.loads(args.control.read_text())
        write_private(Path(config["controlFile"]), {"finished": True, "sideChatSubmitted": args.side_chat_submitted,
            "sideResponseVisible": args.side_response_visible})
        return 0
    if not 30 <= args.duration <= 900:
        parser.error("duration must be between 30 and 900 seconds")
    args.private_control.parent.mkdir(parents=True, exist_ok=True)
    return collect(args)

if __name__ == "__main__":
    raise SystemExit(main())
