#!/usr/bin/env python3
"""Measure a genuine disposable Codex producer through selected public-history polling.

Start the observer on exec's thread.started event. No hooks or trust records are
installed, copied, or bypassed. Only aggregate timings and controlled counts persist.
"""
import argparse
import datetime
import importlib.util
import json
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("codex_live_acceptance", pathlib.Path(__file__).with_name("run.py"))
FIXTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE)
TOKEN = FIXTURE.TOKEN
REQUIRED = {"PROMPT", "INTERMEDIATE", "FINAL", "SHELL_OK", "SHELL_ERROR", "MCP_OK", "MCP_ERROR", "CHILD_FINAL"}


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def evaluate_measurement(report):
    """Evaluate the established eight-marker Codex gate without changing measurements."""
    report["requiredTypedMarkers"] = sorted(REQUIRED)
    final = report.get("pipeline")
    report["passed"] = False
    report["latencyMeasurementPassed"] = False
    if not final:
        return
    latency = final["sourceLatency"]
    live = latency["live"]["canonicalReadStartToCommitObservation"]
    historical = latency["historical"]["canonicalReadStartToCommitObservation"]
    first_read = latency["firstCanonicalReadStartedAt"]
    overlap = bool(first_read and datetime.datetime.fromisoformat(first_read.replace("Z", "+00:00"))
                   < datetime.datetime.fromisoformat(report["producerFinishedAt"]))
    report["observerReadStartedWhileProducerRunning"] = overlap
    report["historicalLatencyMeasured"] = historical["count"] > 0
    report["liveLatencyMeasured"] = live["count"] > 0
    report["nativeChildPromptCoverage"] = {"validated": False,
        "optionalTypedObservedCount": final.get("typedObserved", {}).get("CHILD_PROMPT", 0),
        "limit": "The established Codex fixture requires the native child's own final. Its prompt remains unverified."}
    report["liveCanonicalReadStartP95WithinProposed120SecondTarget"] = bool(live["count"] > 0
        and live["p95"] < 120000)
    report["latencyMeasurementPassed"] = bool(overlap and live["count"] > 0
        and latency["unmeasuredSourceRevisionCount"] == 0
        and live["excludedNegativeOrNonfiniteCount"] == 0
        and REQUIRED <= set(final["typedCommittedBeforeCatchUp"]))
    cleanup = report.get("cleanup", {})
    report["passed"] = bool(report.get("actualProducerVersion") == "0.161.0"
        and report.get("actualReaderVersion") == "0.161.0" and report.get("producerExitCode") == 0
        and report.get("pipelineExitCode") == 0 and report.get("observerReady")
        and report["latencyMeasurementPassed"] and report["liveCanonicalReadStartP95WithinProposed120SecondTarget"]
        and REQUIRED <= set(final["typedCommitted"]) and final["syntheticValuePresent"]
        and final["queueCount"] == 0 and final["replayStable"] and final["finalCatchUpNewOccurrences"] == 0
        and final["ciphertextMarkerInspectionPassed"] and cleanup.get("disposableRootRemoved")
        and cleanup.get("temporaryAuthenticationRemoved") and cleanup.get("ownedProcessGroupsStopped"))


def stop_owned_group(child):
    if child is None:
        return {"launched": False, "groupKillPermissionDenied": False, "leaderExited": True}
    result = {"launched": True, "groupKillPermissionDenied": False, "ownedGroupTerminationRequested": True}
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except PermissionError:
        result["groupKillPermissionDenied"] = True
    time.sleep(0.2)
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        result["groupKillPermissionDenied"] = True
    child.wait(timeout=5)
    result["leaderExited"] = child.returncode is not None
    child.stdout.close()
    child.stderr.close()
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", default=str(pathlib.Path.home() / ".local/bin/codex"))
    parser.add_argument("--acceptance-executable", default=str(ROOT / ".build/out/Products/Debug/spillcheck-storage-acceptance"))
    parser.add_argument("--report", default=str(ROOT / ".build/implementation/codex-observation-latency.json"))
    args = parser.parse_args()
    report = {"schemaVersion": 1, "startedAt": now(), "interface": "standalone-cli",
              "collectionPath": "exact-selected-public-native-items", "configuredProducerVersion": "0.161.0",
              "configuredReaderVersion": "0.161.0", "passed": False, "latencyMeasurementPassed": False,
              "t3LatencyMeasured": False, "hookDeliveryLatencyMeasured": False,
              "existingConfigurationModified": False, "existingHistoriesModified": False,
              "existingHookSettingsModified": False, "hookTrustBypassed": False,
              "status": "unverified"}
    private = None
    temporary_directory = None
    version_cleanup = {}
    driver = None
    producer_cleanup = {}
    driver_cleanup = None
    try:
        temporary_directory = tempfile.TemporaryDirectory(prefix="spillcheck-m6-codex-latency-")
        temporary = temporary_directory.name
        private = pathlib.Path(temporary).resolve()
        os.chmod(private, 0o700)
        home, work = private / "home", private / "work"
        home.mkdir(mode=0o700)
        work.mkdir(mode=0o700)
        auth = pathlib.Path.home() / ".codex/auth.json"
        if not auth.is_file():
            report["status"] = "authentication-unavailable"
            return
        shutil.copyfile(auth, home / "auth.json")
        os.chmod(home / "auth.json", 0o600)
        config = ('model = "gpt-6.1-sol"\nmodel_reasoning_effort = "low"\n'
                  '[features]\nmulti_agent = true\n[analytics]\nenabled = false\n'
                  '[mcp_servers.spillcheck_synthetic]\ndefault_tools_approval_mode = "approve"\n'
                  'command = "/usr/bin/python3"\nargs = ['
                  + json.dumps(str(ROOT / "Tests/Fixtures/Codex/mcp_fixture.py")) + ']\n')
        (home / "config.toml").write_text(config)
        os.chmod(home / "config.toml", 0o600)
        env = dict(os.environ)
        env["CODEX_HOME"] = str(home)
        version_code, version_bytes, _ = FIXTURE.bounded([args.executable, "--version"], environment=env,
            directory=work, timeout=10, maximum_bytes=65536, cleanup_report=version_cleanup)
        version = version_bytes.decode("utf-8", errors="replace").strip()
        if version_code != 0 or version != "codex-cli 0.161.0":
            report["status"] = "unsupported-producer-version"
            return
        report["actualProducerVersion"] = "0.161.0"
        report["actualReaderVersion"] = "0.161.0"

        def output_line(line):
            nonlocal driver
            try:
                event = json.loads(line)
            except ValueError:
                return
            if event.get("type") != "thread.started":
                return
            if driver is not None or not isinstance(event.get("thread_id"), str):
                raise ValueError("unexpected-thread-start-count")
            report["threadID"] = event["thread_id"]
            report["observerLaunchRequestedAt"] = now()
            driver = subprocess.Popen([args.acceptance_executable, "--codex-observe",
                "--interface", "standalone-cli", "--directory", str(private), "--codex-home", str(home),
                "--executable", args.executable, "--threads", event["thread_id"], "--scanner",
                str(ROOT / ".build/scanner/betterleaks"), "--rules",
                str(ROOT / ".build/scanner/betterleaks.toml"), "--duration", "240"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)

        prompt = f"""Run only this synthetic Spillcheck acceptance task. LEAKRET_M4_PROMPT {TOKEN}.
Send a commentary response containing exactly LEAKRET_M4_INTERMEDIATE {TOKEN}.
Run a shell command that prints LEAKRET_M4_SHELL_OK {TOKEN} and exits 0.
Run a shell command that prints LEAKRET_M4_SHELL_ERROR {TOKEN} and exits 7.
Call spillcheck_synthetic.synthetic_output once with fail=false and once with fail=true.
Spawn exactly one native child with spawn_agent, fork_turns=none, and this entire literal message including both marker/token occurrences: "LEAKRET_M4_CHILD_PROMPT {TOKEN}. Reply only: LEAKRET_M4_CHILD_FINAL {TOKEN}." Wait for that child's completed reply.
Do not read files or access the network. Finish with LEAKRET_M4_FINAL {TOKEN}.
Keep all commentary and final responses short."""
        report["producerStartedAt"] = now()
        code, output, elapsed = FIXTURE.bounded([args.executable, "--no-daemon", "-a", "never", "exec",
            "--skip-git-repo-check", "--json", "-s", "read-only", "-C", str(work), "-"],
            environment=env, directory=work, input_bytes=prompt.encode(), timeout=180,
            on_output_line=output_line, cleanup_report=producer_cleanup)
        report.update(producerExitCode=code, producerMilliseconds=elapsed, producerOutputBytes=len(output),
                      producerFinishedAt=now())
        if code != 0 or driver is None:
            report["status"] = "producer-unavailable"
            return
        # Allow the production poll to see the last durable rows before stopping admission.
        time.sleep(2)
        (private / "provider-finished").touch()
        driver_output, errors = driver.communicate(timeout=70)
        if len(driver_output) > 1024 * 1024 or len(errors) > 64 * 1024:
            raise BufferError("driver-output-limit")
        events = [json.loads(line) for line in driver_output.splitlines()]
        final = next((event for event in reversed(events) if event.get("finished")), None)
        ready = next((event for event in events if event.get("ready")), None)
        report.update(pipeline=final, pipelineExitCode=driver.returncode, pipelineDiagnosticBytes=len(errors),
                      observerReady=bool(ready), status="public-observation-complete")
        driver_cleanup = stop_owned_group(driver)
        driver = None
    except (OSError, ValueError, TimeoutError, BufferError, subprocess.TimeoutExpired):
        report["status"] = "bounded-attempt-failed"
    finally:
        if driver is not None:
            driver_cleanup = stop_owned_group(driver)
        if temporary_directory is not None:
            temporary_directory.cleanup()
        root_removed = private is None or not private.exists()
        groups_stopped = (version_cleanup.get("leaderExited", False)
            and not version_cleanup.get("groupKillPermissionDenied", False)
            and producer_cleanup.get("leaderExited", False)
            and not producer_cleanup.get("groupKillPermissionDenied", False)
            and driver_cleanup is not None and driver_cleanup.get("leaderExited", False)
            and not driver_cleanup.get("groupKillPermissionDenied", False))
        report["finishedAt"] = now()
        report["cleanup"] = {"disposableRootRemoved": root_removed,
            "temporaryAuthenticationRemoved": root_removed, "ownedProcessGroupsStopped": groups_stopped,
            "versionProbeProcessGroup": version_cleanup, "producerProcessGroup": producer_cleanup,
            "observerProcessGroup": driver_cleanup}
        evaluate_measurement(report)
        path = pathlib.Path(args.report)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(json.dumps({"status": report["status"], "passed": report["passed"], "report": str(path)}))


if __name__ == "__main__":
    main()
