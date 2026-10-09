#!/usr/bin/env python3
"""Owned local Mod install, bounded manual wait, exact removal. No provider/GUI launch."""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import time

MAX_SETTINGS_BYTES = 1024 * 1024

def read_owned(path):
    if not path.exists():
        return None
    file = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(file)
        if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode) or info.st_size > MAX_SETTINGS_BYTES:
            raise ValueError("settingsOwnershipTypeOrBudget")
        value = json.loads(os.read(file, MAX_SETTINGS_BYTES + 1))
        if not isinstance(value, dict):
            raise ValueError("settingsShape")
        return value
    finally:
        os.close(file)

def without_owned(value, marketplace, plugin):
    value = copy.deepcopy(value) if value is not None else {}
    value.pop(marketplace, None)
    for field in ("extraKnownMarketplaces", "enabledPlugins", "plugins", "pluginConfigs"):
        entries = value.get(field)
        if isinstance(entries, dict):
            entries.pop(marketplace, None)
            entries.pop(plugin, None)
            if not entries:
                value.pop(field)
    return value

def comparison(before, after, marketplace, plugin):
    return {label: without_owned(before[label], marketplace, plugin) == without_owned(after[label], marketplace, plugin)
        for label in before}

def snapshot(paths):
    return {label: read_owned(path) for label, path in paths.items()}

def write_private(path, value):
    if path.exists():
        raise ValueError("privateControlAlreadyExists")
    file = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.write(file, (json.dumps(value, indent=2) + "\n").encode())
    finally:
        os.close(file)

def invoke(args, command):
    try:
        result = subprocess.run([str(args.claude_executable.resolve()), "plugin"] + command + ["--json"],
            cwd=args.project.resolve(), capture_output=True, timeout=25)
    except (OSError, subprocess.SubprocessError) as error:
        return {"exitCode": None, "outcome": "failed", "controlledFailure": type(error).__name__}
    try:
        controlled = json.loads(result.stdout.splitlines()[-1])
    except (ValueError, IndexError):
        controlled = {}
    return {"exitCode": result.returncode, "outcome": controlled.get("outcome")
        if controlled.get("outcome") in {"ok", "failed"} else "unrecognized",
        "diagnosticBytes": len(result.stderr), "outputBytes": len(result.stdout)}

def run(args):
    os.umask(0o077)
    directory = args.directory.resolve()
    info = directory.lstat()
    if info.st_uid != os.getuid() or not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError("ownedProbeDirectoryRequired")
    manifest = read_owned(directory / ".claude-plugin/marketplace.json")
    marketplace = manifest["name"]
    if not re.fullmatch(r"spillcheck-side-probe-[0-9a-f]{8}", marketplace):
        raise ValueError("ownedMarketplaceIdentityRequired")
    plugin = "spillcheck-side-probe@" + marketplace
    project = args.project.resolve()
    paths = {"userSettings": Path.home() / ".claude/settings.json",
        "marketplaceRegistry": Path.home() / ".claude/plugins/known_marketplaces.json",
        "pluginRegistry": Path.home() / ".claude/plugins/installed_plugins.json",
        "localSettings": project / ".claude/settings.local.json", "projectSettings": project / ".claude/settings.json"}
    original = snapshot(paths)
    if any(marketplace in json.dumps(value) or plugin in json.dumps(value) for value in original.values()):
        raise ValueError("ownedIdentityAlreadyExists")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    control = directory / "manual-finished.json"
    report = {"schemaVersion": 1, "phase0Passed": False, "providerLaunchCount": 0,
        "actualGUILoadMeasured": False, "canonicalSideAuthorityEstablished": False,
        "initialOwnedIdentitiesAbsent": True, "rawSettingsArchived": False,
        "rawProviderTextArchived": False, "installationScope": "local", "userEnablementRequested": False,
        "ownedMarketplaceUserSettingsDeclarationRequired": True}
    interrupted = False
    def interrupt(_signal, _frame):
        nonlocal interrupted
        interrupted = True
    for event in (signal.SIGTERM, signal.SIGINT):
        signal.signal(event, interrupt)
    try:
        version = subprocess.run([str(args.claude_executable.resolve()), "--version"], cwd=project,
            capture_output=True, timeout=10)
        match = re.search(rb"(?<![0-9])([0-9]+\.[0-9]+\.[0-9]+)(?![0-9])", version.stdout)
        report["observedProducerVersion"] = match.group(1).decode() if match else None
        if version.returncode or report["observedProducerVersion"] != args.expected_version:
            raise ValueError("producerVersionMismatch")
        report["marketplaceAdd"] = invoke(args, ["marketplace", "add", str(directory)])
        if report["marketplaceAdd"]["exitCode"] != 0:
            raise ValueError("marketplaceAddFailed")
        report["localInstall"] = invoke(args, ["install", plugin, "--scope", "local"])
        installed = snapshot(paths)
        report["ownedInstallPreservedUnownedSettingsByFile"] = comparison(original, installed, marketplace, plugin)
        local_enabled = (installed["localSettings"] or {}).get("enabledPlugins", {}).get(plugin) is True
        no_global = all(plugin not in (installed[label] or {}).get("enabledPlugins", {})
            for label in ("userSettings", "projectSettings"))
        records = (installed["pluginRegistry"] or {}).get("plugins", {}).get(plugin, [])
        report["localEnablementMeasured"] = local_enabled
        report["noUserOrSharedProjectEnablementMeasured"] = no_global
        report["exactLocalInstallRecordMeasured"] = isinstance(records, list) and bool(records) and all(
            isinstance(record, dict) and record.get("scope") == "local"
            and Path(record.get("projectPath", "")).resolve() == project for record in records)
        if (report["localInstall"]["exitCode"] != 0 or not local_enabled or not no_global
                or not report["exactLocalInstallRecordMeasured"]
                or not all(report["ownedInstallPreservedUnownedSettingsByFile"].values())):
            raise ValueError("ownedLocalInstallBoundaryFailed")
        print(json.dumps({"ready": True, "actualGUILoadMeasured": False, "ownedMarketplace": marketplace,
            "ownedPlugin": plugin, "scope": "local", "maximumWaitSeconds": args.duration,
            "finishCommand": "python3 Tests/ClaudeGUIModProbe/install.py finish --directory " + str(directory)}), flush=True)
        deadline = time.monotonic() + args.duration
        while time.monotonic() < deadline and not control.exists() and not interrupted:
            time.sleep(0.2)
        report["manualCompletionSignaled"] = control.exists()
        report["interrupted"] = interrupted
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        report["controlledFailure"] = str(error) if type(error) is ValueError else type(error).__name__
    finally:
        before_remove = snapshot(paths)
        # An install may partly succeed before its command returns. Remove only measured owned entries.
        if plugin in (before_remove["pluginRegistry"] or {}).get("plugins", {}) or plugin in (before_remove["localSettings"] or {}).get("enabledPlugins", {}):
            report["localUninstall"] = invoke(args, ["uninstall", plugin, "--scope", "local"])
        if marketplace in (before_remove["marketplaceRegistry"] or {}) or marketplace in (before_remove["userSettings"] or {}).get("extraKnownMarketplaces", {}):
            report["marketplaceRemove"] = invoke(args, ["marketplace", "remove", marketplace])
        after_remove = snapshot(paths)
        report["ownedRemovalPreservedCurrentUnownedSettingsByFile"] = comparison(before_remove, after_remove, marketplace, plugin)
        report["initialUnownedSettingsEqualAfterRemovalByFile"] = comparison(original, after_remove, marketplace, plugin)
        report["ownedPluginAndMarketplaceAbsentAfterRemoval"] = all(marketplace not in json.dumps(value)
            and plugin not in json.dumps(value) for value in after_remove.values())
        report["ownedCleanupPassed"] = (report["ownedPluginAndMarketplaceAbsentAfterRemoval"]
            and all(report["ownedRemovalPreservedCurrentUnownedSettingsByFile"].values()))
        report["privateProbeRootRetainedForControlledJournal"] = True
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report), flush=True)
    return 0 if report.get("ownedCleanupPassed") and not report.get("controlledFailure") else 1

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    install = commands.add_parser("collect")
    for name in ("directory", "project", "claude-executable", "output"):
        install.add_argument("--" + name, required=True, type=Path)
    install.add_argument("--expected-version", required=True)
    install.add_argument("--duration", type=int, default=600)
    finish = commands.add_parser("finish")
    finish.add_argument("--directory", required=True, type=Path)
    args = parser.parse_args()
    if args.command == "finish":
        write_private(args.directory / "manual-finished.json", {"finished": True})
        return 0
    if not 30 <= args.duration <= 900:
        parser.error("duration must be between 30 and 900 seconds")
    return run(args)

if __name__ == "__main__":
    raise SystemExit(main())
