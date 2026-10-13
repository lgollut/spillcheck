#!/usr/bin/env python3
"""Create one disposable standalone session, then read only its original public history.

Existing auth is copied with mode0600 and removed with the isolated CODEX_HOME. Existing
hooks, history and trust records are neither read nor modified. Model output stays in bounded
anonymous pipes; only controlled statuses/IDs/counts enter the report. Synthetic public fixture
material can be retained by the opt-in Swift probe for regression testing.
"""
import argparse
import contextlib
import json
import os
import pathlib
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOKEN = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
PARENT_MARKERS = {"PROMPT", "INTERMEDIATE", "FINAL", "SHELL_OK", "SHELL_ERROR", "MCP_OK", "MCP_ERROR"}
CHILD_MARKERS = {"CHILD_PROMPT", "CHILD_INTERMEDIATE", "CHILD_FINAL", "CHILD_TOOL_OUTPUT", "CHILD_TOOL_ERROR"}
REQUIRED_MARKERS = PARENT_MARKERS | CHILD_MARKERS


def fixture_prompt():
    child = (f"LEAKRET_M4_CHILD_PROMPT {TOKEN}. "
             f"Send commentary exactly LEAKRET_M4_CHILD_INTERMEDIATE {TOKEN}. "
             f"Run a shell command that prints LEAKRET_M4_CHILD_TOOL_OUTPUT {TOKEN} and exits 0. "
             f"Run a separate shell command that prints LEAKRET_M4_CHILD_TOOL_ERROR {TOKEN} and exits 7. "
             f"Do not read files, browse, or create children. Finish exactly LEAKRET_M4_CHILD_FINAL {TOKEN}.")
    return f"""Run only this synthetic Spillcheck acceptance task. Never authenticate with the fake token. LEAKRET_M4_PROMPT {TOKEN}.
Send a commentary response containing exactly LEAKRET_M4_INTERMEDIATE {TOKEN}.
Run a shell command that prints LEAKRET_M4_SHELL_OK {TOKEN} and exits 0.
Run a separate shell command that prints LEAKRET_M4_SHELL_ERROR {TOKEN} and exits 7.
Call spillcheck_synthetic.synthetic_output once with fail=false and once with fail=true.
Spawn exactly one native child with spawn_agent, fork_turns=none. Set message to this exact JSON string without shortening or rephrasing it: {json.dumps(child)}
Wait for that child's completed reply. Do not repeat the child markers yourself.
Do not read files or access the network. Finish with LEAKRET_M4_FINAL {TOKEN}.
Keep all commentary and final responses short."""


def typed_source_gate(final, *, before_catchup=False):
    """Require all five types in each exact role; aggregate parent text cannot fill child gaps."""
    if not isinstance(final, dict):
        return False
    suffix = "BeforeCatchUp" if before_catchup else ""
    typed = final.get("typedCommitted" + suffix)
    roles = final.get("typedCommittedByRole" + suffix)
    sources = final.get("nativeSourceRoles")

    def exactly_one(counts, expected):
        return (isinstance(counts, dict) and set(counts) == expected
                and all(type(value) is int and value == 1 for value in counts.values()))

    return (exactly_one(typed, REQUIRED_MARKERS) and isinstance(roles, dict)
            and set(roles) == {"parent", "child"}
            and exactly_one(roles["parent"], PARENT_MARKERS)
            and exactly_one(roles["child"], CHILD_MARKERS)
            and exactly_one(sources, {"primarySessionCount", "verifiedPrimarySessionCount",
                "nativeLinkedChildSessionCount", "verifiedNativeLinkedChildSessionCount"})
            and type(final.get("sessionCount")) is int and final["sessionCount"] == 2)


def retain_failed_sources(home, destination, *, maximum_bytes=32 * 1024 * 1024, maximum_files=16):
    """Keep bounded original fake rollout bytes only; never copy credentials or arbitrary home files."""
    root = pathlib.Path(home) / "sessions"
    if not root.exists():
        return {"status": "no-native-rollouts", "fileCount": 0, "bytes": 0, "authenticationRetained": False}
    if root.is_symlink() or not root.is_dir():
        raise ValueError("invalid-owned-rollout-root")
    destination = pathlib.Path(destination)
    destination.mkdir(mode=0o700, parents=False, exist_ok=False)
    count, total, entries = 0, 0, 0
    # The runner owns this isolated provider home. It is never the user's original CODEX_HOME.
    def reject_unreadable_directory(_error):
        raise ValueError("owned-rollout-directory-unreadable")

    for directory, names, files in os.walk(root, followlinks=False, onerror=reject_unreadable_directory):
        entries += len(names) + len(files)
        if entries > 256:
            raise ValueError("owned-rollout-entry-budget-exhausted")
        names.sort()
        for name in names:
            if (pathlib.Path(directory) / name).is_symlink():
                raise ValueError("invalid-owned-rollout-directory")
        for name in sorted(files):
            source = pathlib.Path(directory) / name
            if source.suffix != ".jsonl":
                continue
            if count >= maximum_files:
                raise ValueError("owned-rollout-file-budget-exhausted")
            descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(descriptor, "rb") as handle:
                info = os.fstat(handle.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > maximum_bytes - total:
                    raise ValueError("invalid-owned-rollout-file")
                data = handle.read(maximum_bytes - total + 1)
                after = os.fstat(handle.fileno())
            if (len(data) > maximum_bytes - total or
                    (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns) !=
                    (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)):
                raise ValueError("owned-rollout-changed-or-over-budget")
            output = destination / f"source-{count + 1:02d}.jsonl"
            with os.fdopen(os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), "wb") as handle:
                handle.write(data)
            count += 1
            total += len(data)
    return {"status": "retained-original-fake-rollouts", "fileCount": count, "bytes": total,
            "authenticationRetained": False}


@contextlib.contextmanager
def disposable_source(report, report_path):
    with tempfile.TemporaryDirectory(prefix="spillcheck-m4-codex-cli-") as temporary:
        try:
            yield temporary
        finally:
            if report.get("passed") is not True:
                destination = pathlib.Path(report_path).resolve().with_suffix(".failed-native-sources")
                destination.parent.mkdir(parents=True, exist_ok=True)
                try:
                    report["failedSourceRetention"] = retain_failed_sources(pathlib.Path(temporary) / "home", destination)
                except (OSError, ValueError):
                    report["failedSourceRetention"] = {"status": "retention-incomplete", "authenticationRetained": False}


def bounded_json(path, *, maximum_bytes):
    """Read one owned regular fixture without following a link or exporting its contents."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > maximum_bytes:
            raise ValueError("invalid-owned-probe-file")
        data = handle.read(maximum_bytes + 1)
    if len(data) > maximum_bytes:
        raise ValueError("owned-probe-file-budget-exhausted")
    value = json.loads(data)
    if not isinstance(value, dict):
        raise ValueError("invalid-owned-probe-object")
    return value


def canonical_native_id(value):
    if not isinstance(value, str) or len(value) != 36:
        raise ValueError("invalid-owned-native-identity")
    try:
        valid = str(uuid.UUID(value)) == value
    except ValueError:
        valid = False
    if not valid:
        raise ValueError("invalid-owned-native-identity")
    return value


def signed_source_threads(public_report, fixture, *, parent, producer_version, reader_version):
    """Derive exactly one child from the complete, original owned parent's native links.

    The signed app follows these links itself. Explicitly selecting the same child keeps
    its exact session-count assertion valid without accepting an arbitrary extra session.
    This selection does not establish the signed child's individual content types.
    """
    parent = canonical_native_id(parent)
    if (not isinstance(public_report, dict) or public_report.get("schemaVersion") != 2
            or public_report.get("interface") != "standalone-cli"
            or public_report.get("readerVersion") != reader_version
            or any(public_report.get(key) is not True for key in ("passive", "networkDenied", "forkDenied"))
            or any(type(public_report.get(key)) is not int or public_report[key] != 0
                   for key in ("startCalls", "resumeCalls"))):
        raise ValueError("unverified-owned-public-read")
    threads = public_report.get("threads")
    if not isinstance(threads, list) or len(threads) != 1 or not isinstance(threads[0], dict):
        raise ValueError("unexpected-owned-public-thread-count")
    thread = threads[0]
    if (thread.get("threadID") != parent or thread.get("metadataMatches") is not True
            or thread.get("cliVersion") != producer_version or thread.get("status") != "read-complete"
            or thread.get("mappedGapReasons") != []):
        raise ValueError("incomplete-owned-parent-read")
    if not isinstance(fixture, dict) or fixture.get("thread") != {"id": parent, "cliVersion": producer_version}:
        raise ValueError("owned-parent-fixture-mismatch")
    entries = fixture.get("items")
    if not isinstance(entries, list) or not 1 <= len(entries) <= 1024:
        raise ValueError("owned-parent-item-budget-invalid")
    item_ids, children = [], set()
    for entry in entries:
        item = entry.get("item") if isinstance(entry, dict) else None
        if not isinstance(item, dict):
            raise ValueError("invalid-owned-native-item")
        item_id = item.get("id")
        if not isinstance(item_id, str) or not item_id or len(item_id.encode()) > 4096 or "\0" in item_id:
            raise ValueError("invalid-owned-native-item")
        item_ids.append(item_id)
        references = []
        if item.get("agentThreadId") is not None:
            references.append(canonical_native_id(item["agentThreadId"]))
        if item.get("receiverThreadIds") is not None:
            receivers = item["receiverThreadIds"]
            if not isinstance(receivers, list) or len(receivers) > 4:
                raise ValueError("invalid-owned-child-references")
            references.extend(canonical_native_id(value) for value in receivers)
        if references and item.get("type") not in ("subAgentActivity", "collabAgentToolCall"):
            raise ValueError("unrecognized-owned-child-reference")
        if parent in references:
            raise ValueError("owned-child-references-parent")
        children.update(references)
    if item_ids != thread.get("nativeItemIDs") or len(set(item_ids)) != len(item_ids):
        raise ValueError("owned-parent-item-mismatch")
    if len(children) != 1:
        raise ValueError("unexpected-owned-native-child-count")
    return [parent, next(iter(children))]


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
    parser.add_argument("--signed-app", type=pathlib.Path,
                        help="Also read the exact fresh standalone source with this signed app before cleanup.")
    parser.add_argument("--expect-producer-version", help="Optional strict baseline for this acceptance run")
    parser.add_argument("--expect-reader-version", help="Optional strict reader baseline for this run")
    parser.add_argument("--report", default=str(ROOT/".build/implementation/codex-cli-live.json"))
    parser.add_argument("--fixtures", default=str(ROOT/"Tests/Fixtures/Codex"))
    args = parser.parse_args()
    report = {"schemaVersion": 1, "interface": "standalone-cli", "expectedProducerVersion": args.expect_producer_version,
        "expectedReaderVersion": args.expect_reader_version,
        "existingConfigurationModified": False, "hookTrustBypassed": False, "status": "unverified"}
    private = None
    producer_cleanup, probe_cleanup, driver_cleanup, signed_cleanup = {}, {}, {}, {}
    producer_version_cleanup, reader_version_cleanup = {}, {}
    try:
        with disposable_source(report, args.report) as temporary:
            private = pathlib.Path(temporary).resolve()
            os.chmod(private, 0o700)
            home, work = private/"home", private/"work"
            home.mkdir(mode=0o700); work.mkdir(mode=0o700)
            auth = pathlib.Path.home()/".codex/auth.json"
            if not auth.is_file():
                report["status"] = "authentication-unavailable"
                return 1
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
            prompt = fixture_prompt()
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
                return 1
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
                report["publicRead"] = bounded_json(probe_report, maximum_bytes=1024*1024)
            report["status"] = "public-read-complete" if probe_code == 0 else "public-read-unavailable"
            if args.signed_app is not None:
                if probe_code != 0:
                    raise ValueError("owned-public-probe-failed")
                canonical_native_id(ids[0])
                selected_threads = signed_source_threads(report.get("publicRead"),
                    bounded_json(pathlib.Path(args.fixtures)/(ids[0] + ".json"), maximum_bytes=8*1024*1024),
                    parent=ids[0], producer_version=report["actualProducerVersion"],
                    reader_version=report["actualReaderVersion"])
                report["signedSourceSelection"] = {"parentCount": 1, "nativeLinkedChildCount": 1,
                    "completeParentPublicRead": True, "originalNativeChildLinkVerified": True}
                signed_report = private / "signed-app-report.json"
                signed_code, _, _ = bounded([sys.executable,
                    str(ROOT / "Tests/AppAcceptance/run-app-codex-pipeline.py"),
                    "--app", str(args.signed_app.resolve()),
                    *[argument for thread in selected_threads for argument in ("--thread", thread)], "--home", str(home),
                    "--expected-parent", selected_threads[0], "--expected-child", selected_threads[1],
                    "--executable", reader, "--interface", "standalone-cli",
                    "--expect-reader-version", report["actualReaderVersion"],
                    "--expect-producer-version", report["actualProducerVersion"],
                    "--output", str(signed_report), "--private-control",
                    str(pathlib.Path(args.report).resolve().with_suffix(".signed-private.json"))], environment=env, directory=ROOT, timeout=90,
                    cleanup_report=signed_cleanup)
                report["signedAppScope"] = "Passive read of the exact fresh CLI parent and its one original native-linked child; require all five content types in each role, exact native links, encrypted storage, queue drain and vault cleanup."
                report["signedAppExitCode"] = signed_code
                report["signedApp"] = json.loads(signed_report.read_text()) if signed_report.is_file() else {"passed": False}
                report["signedNativeChildCoverageEstablished"] = bool(signed_code == 0
                    and report["signedApp"].get("passed") is True
                    and report["signedApp"].get("nativeChildAllFiveTypesEstablished") is True)
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
                report["requiredTypedMarkers"] = sorted(REQUIRED_MARKERS)
                report["nativeChildAllFiveTypesEstablished"] = typed_source_gate(final)
                report["passed"] = bool(final and driver.returncode == 0
                    and final.get("actualReaderVersion") == report["actualReaderVersion"]
                    and final.get("observedProducerVersions") == [report["actualProducerVersion"]]
                    and report["nativeChildAllFiveTypesEstablished"] and final["syntheticValuePresent"]
                    and final.get("nativeLocationsUnique") and not final.get("gapReasons")
                    and final["queueCount"] == 0 and final["replayStable"] and final["ciphertextMarkerInspectionPassed"])
                if args.signed_app is not None:
                    report["passed"] = bool(report["passed"] and report.get("signedAppExitCode") == 0
                        and report.get("signedApp", {}).get("passed") and report["signedNativeChildCoverageEstablished"])
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
        if args.signed_app is not None:
            process_cleanup.append(signed_cleanup)
        groups_stopped = all(item.get("leaderExited") and not item.get("groupKillPermissionDenied") for item in process_cleanup)
        if args.signed_app is not None:
            signed = report.get("signedApp", {})
            groups_stopped = bool(groups_stopped and signed.get("signedAppExitCode") == 0
                and not signed.get("timedOut", True) and signed.get("result", {}).get("newVaultCleanupPassed") is True)
        report["cleanup"] = {"disposableRootRemoved": removed, "temporaryAuthenticationRemoved": removed,
            "ownedProcessGroupsStopped": groups_stopped}
        report["passed"] = bool(report.get("passed") and removed and groups_stopped)
        if args.signed_app is not None:
            report["passed"] = bool(report.get("passed") and report.get("signedAppExitCode") == 0
                                    and report.get("signedApp", {}).get("passed")
                                    and report.get("signedNativeChildCoverageEstablished"))
        path = pathlib.Path(args.report)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2, sort_keys=True)+"\n")
        print(json.dumps({"status": report["status"], "passed": report["passed"], "report": str(path)}))
    return 0 if report.get("passed") is True else 1

if __name__ == "__main__":
    raise SystemExit(main())
