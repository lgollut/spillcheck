#!/usr/bin/env python3
"""Prepare a manual GUI task; compile/run an exact-ID passive format probe only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TOKEN = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"


def prompt(work):
    helper = str(work / "fixture.py")
    command = lambda operation, role: "python3 " + json.dumps(helper) + " " + operation + " " + role + " --work " + json.dumps(str(work))
    bootstrap = f"""This is the identity-only bootstrap of one disposable native child of a manually created official Codex GUI local task. Work only in {work}. No files outside this owned folder, no network, auth, histories, config, trust, additional children or CLI sessions. Execute `{command('register', 'child')}`. This helper reads only your own CODEX_THREAD_ID, CODEX_HOME and HOME environment entries, writes bounded identity metadata in the owned folder, and waits for the passive collector. If identity is unavailable or it fails, stop and report that exact limitation. When it succeeds, finish with exactly SPILLCHECK_GUI_CHILD_BOOTSTRAP_READY. Perform no content fixture yet; the parent will send a separate native input to this same child."""
    child = f"""SPILLCHECK_GUI_CHILD_PROMPT {TOKEN}.
This is a new native user input to the already registered disposable GUI child. Keep the same original native thread and working directory {work}. Do not register again, create another child, inspect histories/config/auth/trust, access the network or create a CLI session. Send one short commentary containing SPILLCHECK_GUI_CHILD_INTERMEDIATE {TOKEN}; run `{command('ok', 'child')}`; run `{command('error', 'child')}` (expected exit7, preserve its tool error rather than fixing it); finish with exactly SPILLCHECK_GUI_CHILD_FINAL {TOKEN}. Do not repeat the tool markers in commentary or the final response."""
    return f"""SPILLCHECK_GUI_PARENT_PROMPT {TOKEN}.
Run only this fake-only Spillcheck fixture in this newly created official Codex GUI local task. Use the original local folder {work}; do not create a managed worktree or use a remote task. Do not read unrelated files, auth, histories, configuration or trust; do not access the network or create a CLI session. Do not modify project files except the fixture helper's own identity/handshake files. Keep every response short.

First execute `{command('register', 'parent')}`. The existing helper reads only your own CODEX_THREAD_ID, CODEX_HOME and HOME environment entries, writes native identity metadata in this owned folder, and waits up to ten minutes for the exact-source passive collector. Continue polling only this owned tool invocation if it returns a running session. If native identity is absent or this command fails, stop and report the exact missing capability; do not inspect or search provider histories.

When the command succeeds, send a commentary containing SPILLCHECK_GUI_PARENT_INTERMEDIATE {TOKEN}. Execute `{command('ok', 'parent')}`, then `{command('error', 'parent')}`. Exit7 is intentional; preserve the original failed tool output and do not fix it or repeat its marker in assistant responses.

Create exactly one native child with spawn_agent and fork_turns=none, keeping its original working directory in this same local project. Do not use an app delegate or a CLI substitute. Give that child this identity-only bootstrap message:
{json.dumps(bootstrap)}

Save the exact native child ID returned by spawn_agent. Wait for this child to finish with SPILLCHECK_GUI_CHILD_BOOTSTRAP_READY. If it reports a failed identity/collector capability, stop the fixture. This first completion is only the bootstrap, not the content fixture.

Then use the native send_input tool on that SAME child ID. Set its message to the entire literal string below, starting with the exact SPILLCHECK_GUI_CHILD_PROMPT marker. Do not paraphrase, omit or move that first marker into the parent's commentary or spawn arguments. A direct native input after bootstrap is required; a spawn-only instruction or another child does not satisfy the test.
{json.dumps(child)}

Wait for the same child's SPILLCHECK_GUI_CHILD_FINAL completion after send_input. If native children or send_input are unavailable, report that exact limitation and do not substitute another route. Finish with exactly SPILLCHECK_GUI_PARENT_FINAL {TOKEN}.
"""


def core_fingerprints(root):
    paths = [root / "libSpillcheckCore.a"] + sorted((root / "SpillcheckCore.swiftmodule").glob("*"))
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in paths if path.is_file()}


def build(products, binary):
    module_map = ROOT / ".build/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap"
    before = core_fingerprints(products)
    with tempfile.TemporaryDirectory(prefix="spillcheck-gui-probe-build-") as temporary:
        snapshot = Path(temporary)
        shutil.copy2(products / "libSpillcheckCore.a", snapshot / "libSpillcheckCore.a")
        for module in ("SpillcheckCore.swiftmodule", "GRDB.swiftmodule"):
            shutil.copytree(products / module, snapshot / module)
        if core_fingerprints(snapshot) != before or core_fingerprints(products) != before:
            raise RuntimeError("Core build products changed during snapshot; wait for their build to finish")
        command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-target", "arm64-apple-macosx14.0",
            "-I", str(snapshot), "-Xcc", "-fmodule-map-file=" + str(module_map),
            str(Path(__file__).with_name("main.swift")), str(snapshot / "libSpillcheckCore.a"),
            "-lsqlite3", "-framework", "Security", "-framework", "LocalAuthentication", "-o", str(binary)]
        subprocess.run(command, cwd=ROOT, check=True)
        if core_fingerprints(products) != before:
            binary.unlink(missing_ok=True)
            raise RuntimeError("Core build products changed during compilation; retry after their build finishes")
    manifest = {"coreProducts": before, "probeSourceSHA256": hashlib.sha256(Path(__file__).with_name("main.swift").read_bytes()).hexdigest()}
    binary.with_suffix(".build.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def verify_reusable_build(products, binary):
    manifest = binary.with_suffix(".build.json")
    expected = {"coreProducts": core_fingerprints(products),
        "probeSourceSHA256": hashlib.sha256(Path(__file__).with_name("main.swift").read_bytes()).hexdigest()}
    if not manifest.is_file() or json.loads(manifest.read_text()) != expected:
        sys.exit("Prepared probe does not match current Core/source artifacts; rebuild before starting the manual fixture.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("prepare", "observe", "catchup"))
    parser.add_argument("--directory", type=Path, default=ROOT / ".build/harness-compatibility/manual-codex-gui-2026-10-09")
    parser.add_argument("--products-path", type=Path, default=ROOT / ".build/out/Products/Debug")
    parser.add_argument("--authorized-home", type=Path, help="Explicitly authorized GUI native store; never inferred from selected CLI.")
    parser.add_argument("--host-version", help="Actual official GUI About version, separately observed by the operator.")
    parser.add_argument("--host-version-evidence", choices=("officialBundleMetadata", "operatorAbout"), default="operatorAbout",
        help="How the official GUI host version was observed; defaults to an operator's About-window observation.")
    parser.add_argument("--executable", type=Path, default=Path.home() / ".local/bin/codex")
    parser.add_argument("--duration", type=int, default=600)
    parser.add_argument("--reuse-probe", action="store_true")
    parser.add_argument("--prepare-only", action="store_true", help="Write the fresh owned project/prompt without compiling while shared Core products are being built.")
    args = parser.parse_args()
    if args.prepare_only and args.mode != "prepare":
        parser.error("--prepare-only applies only to prepare")
    directory = args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    binary = directory / "codex-gui-format-probe"
    if args.mode == "prepare":
        work = directory / "work"
        work.mkdir(mode=0o700, exist_ok=True)
        if any(work.glob("*-identity.json")):
            sys.exit("Use a fresh directory for a new disposable GUI task; old native IDs are not reusable.")
        shutil.copyfile(Path(__file__).with_name("fixture.py"), work / "fixture.py")
        os.chmod(work / "fixture.py", 0o600)
        (work / "README.md").write_text("# Spillcheck disposable official Codex GUI fixture\n\nFake-only owned local project. No provider config, auth, history or hooks are copied here.\n")
        if not (work / ".git").exists():
            subprocess.run(["git", "init", "--quiet", str(work)], check=True, capture_output=True)
        (directory / "GUI_PROMPT.txt").write_text(prompt(work))
        os.chmod(directory / "GUI_PROMPT.txt", 0o600)
        if not args.prepare_only:
            build(args.products_path.resolve(), binary)
        print(json.dumps({"prepared": True, "project": str(work), "promptFile": str(directory / "GUI_PROMPT.txt"),
            "collectorExecutable": str(binary) if not args.prepare_only else None,
            "collectorCompiled": not args.prepare_only, "GUIAutomationUsed": False, "providerSessionCreated": False,
            "manualAction": "After the collector reports ready, create a new Local Codex chat in this exact project in the official GUI and paste GUI_PROMPT.txt."}, sort_keys=True))
        return
    if args.authorized_home is None or not args.host_version:
        parser.error("observe requires --authorized-home and --host-version from operator evidence")
    work = directory / "work"
    if args.mode == "observe" and any(work.glob("*-identity.json")):
        sys.exit("Observer must start before the new GUI task registers native identity. Prepare a fresh owned project.")
    if args.mode == "catchup" and not (work / "parent-identity.json").is_file():
        sys.exit("Catch-up requires this owned project's existing parent runtime identity; no source discovery is permitted.")
    if not args.reuse_probe:
        build(args.products_path.resolve(), binary)
    else:
        verify_reusable_build(args.products_path.resolve(), binary)
    report = {"schemaVersion": 1, "status": "unverified", "GUIAutomationUsed": False,
        "existingConfigurationModified": False, "hookTrustBypassed": False,
        "sourceHost": "official-codex-GUI", "productionGUICollectionEnabled": False,
        "exactNativeIdentitiesPublished": False, "hostVersionEvidence": args.host_version_evidence}
    child = None
    errors = ""
    try:
        with tempfile.TemporaryDirectory(prefix="spillcheck-codex-gui-format-probe-") as private:
            os.chmod(private, 0o700)
            command = [str(binary), "--project", str(work), "--authorized-home", str(args.authorized_home.resolve()),
                "--private-directory", private, "--host-version", args.host_version,
                "--host-version-evidence", args.host_version_evidence, "--executable", str(args.executable.absolute()),
                "--scanner", str(ROOT / ".build/scanner/betterleaks"), "--rules", str(ROOT / ".build/scanner/betterleaks.toml"),
                "--duration", str(args.duration)]
            if args.mode == "catchup":
                command.append("--catchup-only")
            child = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, start_new_session=True)
            first = child.stdout.readline(8192)
            ready = json.loads(first)
            print(json.dumps(ready, sort_keys=True), flush=True)
            if not ready.get("ready"):
                report["result"] = ready
            else:
                output, errors = child.communicate(timeout=min(900, max(10, args.duration)) + 90)
                if len(output.encode()) > 64 * 1024 or len(errors.encode()) > 64 * 1024:
                    raise ValueError("bounded-output-limit")
                if errors:
                    private_stderr = directory / ("catchup-stderr-private.log" if args.mode == "catchup" else "observer-stderr-private.log")
                    private_stderr.write_text(errors)
                    private_stderr.chmod(0o600)
                report["stderrBytesRetainedPrivately"] = len(errors.encode())
                rows = [json.loads(line) for line in output.splitlines()]
                report["result"] = next((row for row in reversed(rows) if row.get("finished")), {})
            report["exitCode"] = child.wait(timeout=5)
            report["status"] = "format-probe-passed" if report["exitCode"] == 0 and report.get("result", {}).get("passed") else "unmet-GUI-phase0-gate"
            if args.mode == "catchup" and report["exitCode"] == 0 and report.get("result", {}).get("selectedSourceCatchupPassed"):
                report["status"] = "selected-source-catchup-probe-passed-live-gate-unmet"
    except (subprocess.TimeoutExpired, ValueError) as error:
        report["status"] = "unmet-GUI-phase0-gate"
        report["reason"] = "collector-timeout" if isinstance(error, subprocess.TimeoutExpired) else "bounded-controlled-report-failure"
    finally:
        if child is not None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait(timeout=5)
            report["ownedObserverGroupStopped"] = True
        report["ephemeralEncryptedStoreRemoved"] = True
        if args.mode == "observe" and report["status"] != "format-probe-passed":
            (work / "collector-failed").touch()
        path = directory / ("codex-gui-selected-source-catchup.json" if args.mode == "catchup" else "codex-gui-format-probe.json")
        path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(json.dumps(report, sort_keys=True), flush=True)
    if report["status"] not in ("format-probe-passed", "selected-source-catchup-probe-passed-live-gate-unmet"):
        sys.exit(1)


if __name__ == "__main__":
    main()
