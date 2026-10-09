#!/usr/bin/env python3
"""Create one disposable standalone session, then read only its original public history.

Existing auth is copied with mode0600 and removed with the isolated CODEX_HOME. Existing
hooks, history and trust records are neither read nor modified. Model output stays in bounded
anonymous pipes; only controlled statuses/IDs/counts enter the report. Synthetic public fixture
material can be retained by the opt-in Swift probe for regression testing.
"""
import argparse
import json
import os
import pathlib
import selectors
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOKEN = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"

def bounded(command, *, environment, directory, input_bytes=b"", timeout=120, maximum_bytes=4*1024*1024,
            on_output_line=None, cleanup_report=None):
    child = subprocess.Popen(command, cwd=directory, env=environment, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    started = time.monotonic()
    output = bytearray()
    pending_line = bytearray()
    errors = 0
    try:
        child.stdin.write(input_bytes)
        child.stdin.close()
        selector = selectors.DefaultSelector()
        for handle in (child.stdout, child.stderr):
            os.set_blocking(handle.fileno(), False)
            selector.register(handle, selectors.EVENT_READ)
        while selector.get_map():
            if time.monotonic() - started > timeout:
                raise TimeoutError()
            for key, _ in selector.select(0.05):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                elif key.fileobj is child.stdout:
                    if len(output) + len(chunk) > maximum_bytes:
                        raise BufferError()
                    output.extend(chunk)
                    if on_output_line is not None:
                        pending_line.extend(chunk)
                        while b"\n" in pending_line:
                            line, _, remaining = pending_line.partition(b"\n")
                            pending_line = bytearray(remaining)
                            on_output_line(bytes(line))
                else:
                    errors += len(chunk)
                    if errors > 64*1024:
                        raise BufferError()
        return child.wait(timeout=2), bytes(output), round((time.monotonic()-started)*1000, 1)
    finally:
        # Kill the owned process group even when its leader exited but a descendant survived.
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            if cleanup_report is not None:
                cleanup_report["groupKillPermissionDenied"] = True
        child.wait(timeout=5)
        if cleanup_report is not None:
            cleanup_report.setdefault("groupKillPermissionDenied", False)
            cleanup_report["ownedGroupTerminationRequested"] = True
            cleanup_report["leaderExited"] = child.returncode is not None
        child.stdout.close()
        child.stderr.close()

def observe_version(executable, *, environment, directory, expected=None, cleanup_report=None):
    code, output, _ = bounded([str(executable), "--version"], environment=environment,
        directory=directory, timeout=10, maximum_bytes=1024, cleanup_report=cleanup_report)
    text = output.decode("utf-8", errors="strict").strip()
    if code != 0 or not text.startswith("codex-cli "):
        raise ValueError("unrecognized-codex-executable")
    version = text[len("codex-cli "):]
    if not version or len(version.encode()) > 256 or any(c.isspace() for c in version) or "\0" in version:
        raise ValueError("malformed-codex-version")
    if expected is not None and version != expected:
        raise ValueError("acceptance-baseline-version-mismatch")
    return version

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", default=str(pathlib.Path.home()/".local/bin/codex"))
    parser.add_argument("--reader-executable", help="Passive reader; defaults to the producer executable")
    parser.add_argument("--expect-producer-version", help="Optional strict baseline for this acceptance run")
    parser.add_argument("--expect-reader-version", help="Optional strict reader baseline for this run")
    parser.add_argument("--report", default=str(ROOT/".build/implementation/codex-cli-live.json"))
    parser.add_argument("--fixtures", default=str(ROOT/"Tests/Fixtures/Codex"))
    args = parser.parse_args()
    report = {"schemaVersion": 1, "interface": "standalone-cli", "expectedProducerVersion": args.expect_producer_version,
        "expectedReaderVersion": args.expect_reader_version,
        "existingConfigurationModified": False, "hookTrustBypassed": False, "status": "unverified"}
    private = None
    producer_cleanup, probe_cleanup, driver_cleanup = {}, {}, {}
    producer_version_cleanup, reader_version_cleanup = {}, {}
    try:
        with tempfile.TemporaryDirectory(prefix="spillcheck-m4-codex-cli-") as temporary:
            private = pathlib.Path(temporary).resolve()
            os.chmod(private, 0o700)
            home, work = private/"home", private/"work"
            home.mkdir(mode=0o700); work.mkdir(mode=0o700)
            auth = pathlib.Path.home()/".codex/auth.json"
            if not auth.is_file():
                report["status"] = "authentication-unavailable"
                return
            shutil.copyfile(auth, home/"auth.json")
            os.chmod(home/"auth.json", 0o600)
            config = 'model = "gpt-6.1-sol"\nmodel_reasoning_effort = "low"\n[features]\nmulti_agent = true\n[analytics]\nenabled = false\n[mcp_servers.spillcheck_synthetic]\ndefault_tools_approval_mode = "approve"\ncommand = "/usr/bin/python3"\nargs = [' + json.dumps(str(ROOT/"Tests/Fixtures/Codex/mcp_fixture.py")) + ']\n'
            (home/"config.toml").write_text(config)
            os.chmod(home/"config.toml", 0o600)
            env = dict(os.environ)
            env["CODEX_HOME"] = str(home)
            reader = args.reader_executable or args.executable
            report["actualProducerVersion"] = observe_version(args.executable, environment=env, directory=work, expected=args.expect_producer_version, cleanup_report=producer_version_cleanup)
            report["actualReaderVersion"] = observe_version(reader, environment=env, directory=work, expected=args.expect_reader_version, cleanup_report=reader_version_cleanup)
            prompt = f"""Run only this synthetic Spillcheck acceptance task. LEAKRET_M4_PROMPT {TOKEN}.
Send a commentary response containing exactly LEAKRET_M4_INTERMEDIATE {TOKEN}.
Run a shell command that prints LEAKRET_M4_SHELL_OK {TOKEN} and exits0.
Run a shell command that prints LEAKRET_M4_SHELL_ERROR {TOKEN} and exits7.
Call spillcheck_synthetic.synthetic_output once with fail=false and once with fail=true.
Spawn exactly one native child with spawn_agent, fork_turns=none, and this entire literal message including both marker/token occurrences: "LEAKRET_M4_CHILD_PROMPT {TOKEN}. Reply only: LEAKRET_M4_CHILD_FINAL {TOKEN}." Wait for that child's completed reply.
Do not read files or access the network. Finish with LEAKRET_M4_FINAL {TOKEN}.
Keep all commentary and final responses short."""
            code, output, elapsed = bounded([args.executable, "--no-daemon", "-a", "never", "exec",
                "--skip-git-repo-check", "--json", "-s", "read-only", "-C", str(work), "-"],
                environment=env, directory=work, input_bytes=prompt.encode(), timeout=180, cleanup_report=producer_cleanup)
            report["producerExitCode"] = code; report["producerMilliseconds"] = elapsed
            events = []
            for row in output.splitlines():
                try:
                    events.append(json.loads(row))
                except ValueError:
                    pass
            ids = [x.get("thread_id") for x in events if x.get("type") == "thread.started"]
            ids = [x for x in ids if isinstance(x, str)]
            report["createdThreadCount"] = len(ids)
            if code != 0 or len(ids) != 1:
                report["status"] = "producer-unavailable"
                return
            report["threadID"] = ids[0]
            pathlib.Path(args.fixtures).mkdir(parents=True, exist_ok=True)
            probe_report = private/"public-read.json"
            env.update(SPILLCHECK_CODEX_PROBE_HOME=str(home), SPILLCHECK_CODEX_PROBE_THREAD_IDS=ids[0],
                SPILLCHECK_CODEX_PROBE_EXECUTABLE=reader, SPILLCHECK_CODEX_PROBE_INTERFACE="standalone-cli", SPILLCHECK_CODEX_PROBE_REPORT=str(probe_report),
                SPILLCHECK_CODEX_PROBE_FIXTURE_DIRECTORY=args.fixtures)
            probe_code, _, _ = bounded(["/usr/bin/swift", "test", "--filter", "CodexPublicLiveTests"],
                environment=env, directory=ROOT, timeout=180, maximum_bytes=4*1024*1024, cleanup_report=probe_cleanup)
            report["publicReadExitCode"] = probe_code
            if probe_report.exists():
                report["publicRead"] = json.loads(probe_report.read_bytes())
            report["status"] = "public-read-complete" if probe_code == 0 else "public-read-unavailable"
            binary = ROOT/".build/out/Products/Debug/spillcheck-storage-acceptance"
            driver = subprocess.Popen([str(binary), "--codex-observe", "--interface", "standalone-cli",
                "--directory", str(private), "--codex-home", str(home), "--executable", reader,
                "--reader-version", report["actualReaderVersion"],
                "--threads", ids[0], "--scanner", str(ROOT/".build/scanner/betterleaks"),
                "--rules", str(ROOT/".build/scanner/betterleaks.toml"), "--duration", "60"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                ready = json.loads(driver.stdout.readline())
                if not ready.get("ready"):
                    raise ValueError("driver-not-ready")
                time.sleep(5)
                (private/"provider-finished").touch()
                rest, errors = driver.communicate(timeout=70)
                finals = [json.loads(line) for line in rest.splitlines()]
                final = next((x for x in reversed(finals) if x.get("finished")), None)
                report["pipeline"] = final
                report["pipelineExitCode"] = driver.returncode
                report["pipelineDiagnosticBytes"] = len(errors)
                required = {"PROMPT", "INTERMEDIATE", "FINAL", "SHELL_OK", "SHELL_ERROR", "MCP_OK", "MCP_ERROR", "CHILD_FINAL"}
                report["passed"] = bool(final and driver.returncode == 0
                    and final.get("actualReaderVersion") == report["actualReaderVersion"]
                    and final.get("observedProducerVersions") == [report["actualProducerVersion"]] and required <= set(final["typedCommitted"]) and final["syntheticValuePresent"]
                    and all(final["typedCommitted"].get(marker) == 1 for marker in required)
                    and final.get("nativeLocationsUnique") and not final.get("gapReasons")
                    and final["queueCount"] == 0 and final["replayStable"] and final["ciphertextMarkerInspectionPassed"])
            finally:
                try:
                    os.killpg(driver.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    driver_cleanup["groupKillPermissionDenied"] = True
                driver.wait(timeout=5)
                driver_cleanup.update(leaderExited=driver.returncode is not None, ownedGroupTerminationRequested=True)
                driver_cleanup.setdefault("groupKillPermissionDenied", False)
                driver.stdout.close(); driver.stderr.close()
    except (OSError, ValueError, TimeoutError, BufferError, subprocess.TimeoutExpired):
        report["status"] = "bounded-attempt-failed"
    finally:
        removed = private is None or not private.exists()
        process_cleanup = [producer_version_cleanup, reader_version_cleanup, producer_cleanup, probe_cleanup, driver_cleanup]
        groups_stopped = all(item.get("leaderExited") and not item.get("groupKillPermissionDenied") for item in process_cleanup)
        report["cleanup"] = {"disposableRootRemoved": removed, "temporaryAuthenticationRemoved": removed,
            "ownedProcessGroupsStopped": groups_stopped}
        report["passed"] = bool(report.get("passed") and removed and groups_stopped)
        path = pathlib.Path(args.report)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2, sort_keys=True)+"\n")
        print(json.dumps({"status": report["status"], "report": str(path)}))

if __name__ == "__main__":
    main()
