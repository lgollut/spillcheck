#!/usr/bin/env python3
"""Prepare and statically validate an owned Mod copy. Does not install or load it."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent

def run(args):
    os.umask(0o077)
    session = str(uuid.UUID(args.session))
    if session != args.session:
        raise ValueError("selectedSessionMustBeCanonicalUUID")
    directory = args.directory.absolute()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    plugin = directory / "plugin"
    shutil.copytree(ROOT / "plugin", plugin)
    shutil.copyfile(ROOT / "journal.py", directory / "journal.py")
    key = os.urandom(32).hex()
    scope = {"selectedSessionID": session, "comparisonKey": key,
        "writerPath": str(directory / "journal.py"), "journalPath": str(directory / "mod-summary.jsonl")}
    (plugin / "hooks/scope.js").write_text("\n".join("export const " + key + " = " + json.dumps(value) + ";"
        for key, value in scope.items()) + "\n")
    marketplace_name = "spillcheck-side-probe-" + os.urandom(4).hex()
    (directory / ".claude-plugin").mkdir()
    (directory / ".claude-plugin/marketplace.json").write_text(json.dumps({
        "name": marketplace_name, "description": "Owned exact-session passive side-chat probe",
        "owner": {"name": "Spillcheck"},
        "plugins": [{"name": "spillcheck-side-probe", "source": "./plugin"}]}, indent=2) + "\n")
    # Plugin source and the scope key remain private inside this disposable root.
    for path in directory.rglob("*"):
        path.chmod(0o700 if path.is_dir() else 0o600)
    environment = os.environ.copy()
    report = {"schemaVersion": 1, "providerLaunchCount": 0, "pluginInstalled": False, "pluginLoaded": False,
        "globalConfigurationChanged": False, "sourceAuthorityEstablished": False,
        "exactRuntimeDeclarationsGenerated": False, "exactSessionGuardRequired": True,
        "journalContainsRawProviderText": False, "journalContainsRawNativeIdentities": False,
        "maximumJournalRows": 256, "maximumJournalBytes": 1048576,
        "ownedMarketplaceName": marketplace_name}
    config = Path(tempfile.mkdtemp(prefix="spillcheck-mod-validate-config-", dir="/tmp")).resolve()
    environment["CLAUDE_CONFIG_DIR"] = str(config)
    try:
        version = subprocess.run([str(args.claude_executable.resolve()), "--version"], env=environment,
            cwd=config, capture_output=True, timeout=10)
        observed = re.search(rb"(?<![0-9])([0-9]+\.[0-9]+\.[0-9]+)(?![0-9])", version.stdout)
        report["observedProducerVersion"] = observed.group(1).decode() if observed else None
        report["versionMatchesExpectation"] = version.returncode == 0 and report["observedProducerVersion"] == args.expected_version
        if not report["versionMatchesExpectation"]:
            report["controlledFailure"] = "versionMismatch"
        else:
            result = subprocess.run([str(args.claude_executable.resolve()), "plugin", "validate", "--strict", str(plugin)],
                env=environment, cwd=config, capture_output=True, timeout=20)
            (directory / "validation-private.log").write_bytes(result.stdout + result.stderr)
            text = (result.stdout + result.stderr).decode(errors="replace")
            events = ["session.start", "prompt.submit", "command.run", "turn.start", "turn.step", "turn.complete", "ui.render"]
            report["validationExitCode"] = result.returncode
            report["recognizedEvents"] = [event for event in events if event in text]
            report["recognizedAPICalls"] = [call for call in ["$.session.id", "$.process.run"] if call in text]
            report["staticValidationPassed"] = result.returncode == 0 and "Validation passed" in text
            report["validationOutputBytes"] = len(result.stdout) + len(result.stderr)
            market = subprocess.run([str(args.claude_executable.resolve()), "plugin", "validate", "--strict", str(directory)],
                env=environment, cwd=config, capture_output=True, timeout=20)
            (directory / "marketplace-validation-private.log").write_bytes(market.stdout + market.stderr)
            report["marketplaceValidationExitCode"] = market.returncode
            report["marketplaceStaticValidationPassed"] = market.returncode == 0 and b"Validation passed" in market.stdout + market.stderr
    finally:
        shutil.rmtree(config)
    report["isolatedValidationConfigRemoved"] = not config.exists()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)
    return 0 if report.get("staticValidationPassed") and report.get("marketplaceStaticValidationPassed") else 1

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", required=True)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--claude-executable", required=True, type=Path)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--output", required=True, type=Path)
    return run(parser.parse_args())

if __name__ == "__main__":
    raise SystemExit(main())
