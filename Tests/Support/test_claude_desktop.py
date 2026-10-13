"""Owned Desktop bootstrap and settings checks; no provider or app launch."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import claude_desktop as desktop


class Bootstrap(unittest.TestCase):
    def test_ancestor_repository_is_refused_before_git_runs(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(desktop.prepare(Path(temporary) / "parent")["project"])
            project = parent / "nested-work"
            project.mkdir()
            with mock.patch.object(desktop.subprocess, "run") as process:
                with self.assertRaisesRegex(ValueError, "ownedProjectRootRequired"):
                    desktop.require_owned_project_root(project)
            process.assert_not_called()

    def test_git_symlink_worktree_file_and_settings_directory_symlink_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            owner = Path(desktop.prepare(Path(temporary) / "owner")["project"])
            for kind in ("git-symlink", "worktree-file", "settings-symlink"):
                with self.subTest(kind=kind):
                    project = Path(temporary) / kind
                    project.mkdir()
                    if kind == "git-symlink":
                        (project / ".git").symlink_to(owner / ".git", target_is_directory=True)
                    elif kind == "worktree-file":
                        (project / ".git").write_text("gitdir: " + str(owner / ".git") + "\n")
                    else:
                        (project / ".git").mkdir()
                        (project / ".claude").symlink_to(owner, target_is_directory=True)
                    with self.assertRaisesRegex(ValueError, "ownedProjectRootRequired"):
                        desktop.require_owned_project_root(project)

    def test_nested_fixture_is_its_own_root_without_configured_templates(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(desktop.prepare(Path(temporary) / "parent")["project"])
            template = Path(temporary) / "template"
            (template / "hooks").mkdir(parents=True)
            (template / "hooks/post-checkout").write_text("unowned template hook")
            global_config = Path(temporary) / "gitconfig"
            global_config.write_text('[init]\n\ttemplateDir = ' + str(template) + '\n')
            with mock.patch.dict(os.environ, {"GIT_TEMPLATE_DIR": str(template),
                    "GIT_CONFIG_GLOBAL": str(global_config), "GIT_DIR": str(parent / ".git")}):
                prepared = desktop.prepare(parent / "nested")
                work = Path(prepared["project"])
                self.assertEqual(desktop.require_owned_project_root(work), work.resolve())
            self.assertTrue(prepared["exactOwnedProjectRootMeasured"])
            self.assertTrue((work / ".git").is_dir())
            self.assertFalse((work / ".git/hooks").exists())

    def test_failed_git_initialization_does_not_issue_a_gui_prompt(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "owned"
            with mock.patch.object(desktop.subprocess, "run",
                    return_value=subprocess.CompletedProcess([], 1, b"", b"")):
                with self.assertRaisesRegex(ValueError, "ownedProjectRootInitializationFailed"):
                    desktop.prepare(directory)
            self.assertFalse((directory / "GUI_BOOTSTRAP.txt").exists())

    def test_only_selected_runtime_identity_is_recorded_privately(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "owned"
            prepared = desktop.prepare(directory)
            work = Path(prepared["project"])
            session = "00000000-0000-0000-0000-000000000001"
            result = subprocess.run([sys.executable, str(work / "bootstrap.py"), "record", "--directory", str(work)],
                cwd=work, env={"PATH": os.defpath, "CLAUDE_CODE_SESSION_ID": session,
                    "UNRELATED_PRIVATE_ENV": "NEVER_READ"}, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0)
            self.assertNotIn(session.encode(), result.stdout)
            source = work / "selected-session-private.json"
            self.assertEqual(source.stat().st_mode & 0o777, 0o600)
            raw = source.read_text()
            self.assertEqual(json.loads(raw)["nativeSessionID"], session)
            self.assertNotIn("NEVER_READ", raw)

    def test_missing_identity_never_writes_manifest_or_guesses(self):
        with tempfile.TemporaryDirectory() as temporary:
            prepared = desktop.prepare(Path(temporary) / "owned")
            work = Path(prepared["project"])
            result = subprocess.run([sys.executable, str(work / "bootstrap.py"), "record", "--directory", str(work)],
                cwd=work, env={"PATH": os.defpath}, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)["reason"], "ownRuntimeSessionIdentityUnavailable")
            self.assertFalse((work / "selected-session-private.json").exists())

REGISTRATION = "00000000-0000-0000-0000-000000000001"


def installed(value):
    result = copy.deepcopy(value)
    result.setdefault("hooks", {}).setdefault("Stop", []).append({"hooks": [{
        "type": "command", "statusMessage": "Spillcheck hook " + REGISTRATION, "command": "private-owned-command"}]})
    return result


class SettingsPreservation(unittest.TestCase):
    def test_external_permission_addition_is_preserved_without_attributing_actor(self):
        original = {"permissions": {"allow": ["private-existing-permission"]}}
        post_install = installed(original)
        pre_remove = copy.deepcopy(post_install)
        pre_remove["permissions"]["allow"].append("private-new-permission")
        after = desktop.without_registration(pre_remove, REGISTRATION)
        evidence = desktop.settings_evidence(original, post_install, pre_remove, after, REGISTRATION)
        self.assertTrue(evidence["ownedInstallPreservedUnownedSettings"])
        self.assertTrue(evidence["ownedRemovalPreservedCurrentUnownedSettings"])
        self.assertTrue(evidence["onlyPermissionAdditionsBeforeOwnedRemoval"])
        self.assertEqual(evidence["settingsMismatchClassification"], "permissionAdditionsBeforeOwnedRemoval")
        self.assertFalse(evidence["settingsChangeActorEstablished"])
        self.assertNotIn("private-new-permission", str(evidence))

    def test_unowned_hook_or_permission_loss_is_not_successful_preservation(self):
        original = {"permissions": {"allow": ["private-existing-permission"]}, "hooks": {"Stop": [{
            "matcher": "*", "hooks": [{"type": "command", "command": "private-unowned-command"}]}]}}
        post_install = installed(original)
        after = {"permissions": {"allow": []}}
        evidence = desktop.settings_evidence(original, post_install, post_install, after, REGISTRATION)
        self.assertFalse(evidence["ownedRemovalPreservedCurrentUnownedSettings"])
        self.assertEqual(evidence["settingsMismatchClassification"], "ownedEditChangedUnownedSettings")

    def test_initial_empty_hooks_normalization_is_distinct_from_external_change(self):
        original = {"hooks": {}}
        post_install = installed(original)
        after = desktop.without_registration(post_install, REGISTRATION)
        evidence = desktop.settings_evidence(original, post_install, post_install, after, REGISTRATION)
        self.assertTrue(evidence["initialEmptyHookContainerNormalized"])
        self.assertEqual(evidence["settingsMismatchClassification"], "emptyHookContainerNormalized")
        self.assertFalse(evidence["unownedSettingsChangedBeforeOwnedRemoval"])

if __name__ == "__main__": unittest.main()
