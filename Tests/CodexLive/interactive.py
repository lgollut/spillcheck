#!/usr/bin/env python3
"""Owned disposable /hooks trust and encrypted production-pipeline acceptance.

Keep this driver alive while the user runs the printed interactive command. Touch the printed
finishFile only after the synthetic task and Codex quit. No hook-trust bypass is accepted.
"""
import argparse
import json
import os
import pathlib
import shlex
import shutil
import signal
import subprocess
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOKEN = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", default=str(ROOT/".build/implementation/codex-interactive-live.json"))
    parser.add_argument("--ready", default=str(ROOT/".build/implementation/codex-interactive-ready.json"))
    parser.add_argument("--duration", type=int, default=900)
    args = parser.parse_args()
    os.umask(0o077)
    helper = ROOT/".build/app/Build/Products/Debug/Spillcheck.app/Contents/Helpers/spillcheck-hook"
    binary = ROOT/".build/out/Products/Debug/spillcheck-storage-acceptance"
    codex = pathlib.Path.home()/".local/bin/codex"
    if not all(p.is_file() for p in [helper, binary, codex, ROOT/".build/scanner/betterleaks"]):
        raise SystemExit("Build the signed app, acceptance product and pinned scanner first.")
    with tempfile.TemporaryDirectory(prefix="spillcheck-codex-live-", dir="/tmp") as temporary:
        root = pathlib.Path(temporary).resolve()
        home, work = root/"codex", root/"work"
        home.mkdir(mode=0o700); work.mkdir(mode=0o700)
        auth = pathlib.Path.home()/".codex/auth.json"
        if not auth.is_file():
            raise SystemExit("Existing Codex authentication is unavailable.")
        shutil.copyfile(auth, home/"auth.json"); os.chmod(home/"auth.json", 0o600)
        (home/"config.toml").write_text('model = "gpt-6.1-sol"\nmodel_reasoning_effort = "low"\n[features]\nmulti_agent = true\n[analytics]\nenabled = false\n[mcp_servers.spillcheck_synthetic]\ndefault_tools_approval_mode = "approve"\ncommand = "/usr/bin/python3"\nargs = [' +
            json.dumps(str(ROOT/"Tests/Fixtures/Codex/mcp_fixture.py")) + ']\n')
        driver = subprocess.Popen([str(binary), "--codex-live", "--directory", str(root), "--codex-home", str(home),
            "--executable", str(codex), "--helper", str(helper), "--scanner", str(ROOT/".build/scanner/betterleaks"),
            "--rules", str(ROOT/".build/scanner/betterleaks.toml"), "--duration", str(args.duration)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        reports = []
        errors = bytearray()
        def consume(stream, destination):
            for line in stream:
                if isinstance(destination, list):
                    try:
                        destination.append(json.loads(line))
                    except ValueError:
                        continue
                elif len(destination) < 65536:
                    destination.extend(line[:65536-len(destination)])
        try:
            first = driver.stdout.readline()
            ready = json.loads(first)
            if not ready.get("ready"):
                raise RuntimeError("Acceptance driver did not become ready.")
            command = " ".join([f"CODEX_HOME={shlex.quote(str(home))}", shlex.quote(str(codex)), "--no-daemon",
                "-a", "never", "-s", "read-only", "-C", shlex.quote(str(work))])
            prompt = f"""Synthetic Spillcheck acceptance. Never authenticate with the test token. LEAKRET_M4_PROMPT {TOKEN}.
Send commentary LEAKRET_M4_INTERMEDIATE {TOKEN}.
Run printf 'LEAKRET_M4_SHELL_OK {TOKEN}\\n' in shell.
Run printf 'LEAKRET_M4_SHELL_ERROR {TOKEN}\\n'; exit 7 in shell, keeping the intentional failure.
Call spillcheck_synthetic.synthetic_output with fail=false, then fail=true.
Finish with LEAKRET_M4_FINAL {TOKEN}. Do not read files or browse. Keep responses short."""
            ready.update(command=command, directory=str(root), finishFile=str(root/"provider-finished"),
                fixturePrompt=prompt, trustInstruction="Run /hooks and explicitly review/trust the installed Spillcheck definition; then submit verificationPrompt exactly.")
            path = pathlib.Path(args.ready); path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(ready, indent=2)+"\n")
            print(json.dumps({"ready": True, "readyReport": str(path), "command": command}), flush=True)
            stdout_thread = threading.Thread(target=consume, args=(driver.stdout, reports), daemon=True)
            stderr_thread = threading.Thread(target=consume, args=(driver.stderr, errors), daemon=True)
            stdout_thread.start(); stderr_thread.start()
            driver.wait(timeout=args.duration + 60)
            stdout_thread.join(timeout=2); stderr_thread.join(timeout=2)
            final = next((x for x in reversed(reports) if x.get("finished")), None)
            expected = {"PROMPT", "INTERMEDIATE", "FINAL", "SHELL_OK", "SHELL_ERROR", "MCP_OK", "MCP_ERROR"}
            passed = bool(final and driver.returncode == 0 and final["setupState"] == "connected"
                and expected <= set(final["typedCommitted"]) and final["syntheticValuePresent"]
                and final["queueCount"] == 0 and final["replayStable"] and final["ciphertextMarkerInspectionPassed"])
            report = {"schemaVersion": 1, "hookTrustBypassed": False, "existingConfigurationModified": False,
                "driverExitCode": driver.returncode, "diagnosticBytes": len(errors), "result": final, "passed": passed}
            path = pathlib.Path(args.report); path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(report, indent=2)+"\n")
            print(json.dumps({"finished": True, "passed": passed, "report": str(path)}), flush=True)
        finally:
            try:
                os.killpg(driver.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            driver.wait(timeout=5)
            driver.stdout.close(); driver.stderr.close()

if __name__ == "__main__":
    main()
