#!/usr/bin/env python3
"""Owned project bootstrap and settings comparisons for Desktop hook acceptance."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import uuid


def git_environment():
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
        GIT_CONFIG_SYSTEM=os.devnull)
    return environment


def require_owned_project_root(project):
    project = project.resolve()
    try:
        for path in (project, project / ".git", project / ".claude"):
            try:
                info = path.lstat()
            except FileNotFoundError:
                if path.name == ".claude":
                    continue
                raise ValueError("ownedProjectRootRequired")
            if info.st_uid != os.getuid() or not stat.S_ISDIR(info.st_mode):
                raise ValueError("ownedProjectRootRequired")
        if project == Path.home().resolve():
            raise ValueError("ownedProjectRootRequired")
        result = subprocess.run(["/usr/bin/git", "rev-parse", "--show-toplevel",
            "--absolute-git-dir", "--git-common-dir"], cwd=project,
            env=git_environment(), capture_output=True, timeout=10)
        locations = result.stdout.decode().splitlines()
        expected = (project, project / ".git", project / ".git")
        if result.returncode or len(locations) != 3 or any(
                (project / location).resolve() != target for location, target in zip(locations, expected)):
            raise ValueError("ownedProjectRootRequired")
    except (OSError, UnicodeError, subprocess.SubprocessError):
        raise ValueError("ownedProjectRootUnavailable") from None
    return project


def record(project):
    project = project.resolve()
    if Path.cwd().resolve() != project:
        return {"recorded": False, "reason": "ownedProjectMismatch"}
    value = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    try:
        if str(uuid.UUID(value)) != value: raise ValueError()
    except ValueError:
        return {"recorded": False, "reason": "ownRuntimeSessionIdentityUnavailable"}
    record = {"schemaVersion": 1, "nativeSessionID": value,
        "identitySource": "own-runtime-CLAUDE_CODE_SESSION_ID", "workingDirectory": str(project)}
    descriptor = os.open(project / "selected-session-private.json",
        os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try: os.write(descriptor, (json.dumps(record) + "\n").encode())
    finally: os.close(descriptor)
    return {"recorded": True, "nativeIdentityPublished": False,
        "historyRead": False, "pluginInstalled": False}


def prepare(directory):
    directory = directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    project = directory / "work"; project.mkdir(mode=0o700)
    try:
        initialized = subprocess.run(["/usr/bin/git", "init", "--quiet", "--template=",
            "--initial-branch=spillcheck-probe", str(project)], cwd=project,
            env=git_environment(), capture_output=True, timeout=10)
        if initialized.returncode:
            raise ValueError("ownedProjectRootInitializationFailed")
    except (OSError, subprocess.SubprocessError):
        raise ValueError("ownedProjectRootInitializationFailed") from None
    require_owned_project_root(project)
    helper = project / "bootstrap.py"
    shutil.copyfile(__file__, helper); helper.chmod(0o600)
    (project / "README.md").write_text("# Disposable Claude GUI source probe\n\nOwned identity-only bootstrap. No provider configuration or credentials are copied here.\n")
    command = shlex.join(["python3", str(helper), "record", "--directory", str(project)])
    prompt = ("This is a disposable Spillcheck source probe in a newly created official Claude local Code GUI chat. "
        "Use this original local folder. Do not create a worktree, CLI session, child or side chat. "
        "Do not read histories, configuration, authentication, environment listings, or unrelated files. "
        "Run only this owned command: " + command + ". "
        "The helper reads only your own CLAUDE_CODE_SESSION_ID and writes it privately in this project. "
        "If it reports unavailable identity, stop without searching for it. Reply only with the controlled result.\n")
    target = directory / "GUI_BOOTSTRAP.txt"; target.write_text(prompt); target.chmod(0o600)
    return {"prepared": True, "project": str(project), "promptFile": str(target),
        "exactOwnedProjectRootMeasured": True,
        "providerSessionCreated": False, "pluginInstalled": False}



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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("prepare", "record"))
    parser.add_argument("--directory", required=True, type=Path)
    args = parser.parse_args()
    try:
        report = prepare(args.directory) if args.operation == "prepare" else record(args.directory)
    except OSError:
        report = {"recorded": False, "reason": "ownedBootstrapFileUnavailable"}
    except ValueError as error:
        report = {"prepared": False, "reason": str(error)}
    print(json.dumps(report))
    return 0 if report.get("prepared") or report.get("recorded") else 1


if __name__ == "__main__": raise SystemExit(main())
