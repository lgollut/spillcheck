"""Acceptance-boundary tests; no real credentials, providers, or Keychain access."""
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("claude_live_runner", pathlib.Path(__file__).with_name("run.py"))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
STOPPED = {"grace_ms":200,"term_permission_denied":False,"kill_permission_denied":False}


class CoverageBoundaryTests(unittest.TestCase):
    def test_requires_explicit_complete_report_and_no_required_gaps(self):
        self.assertTrue(RUNNER.required_coverage_complete({"gapReasons":[],"coverageReportTruncated":False}))
        for report in ({}, {"gapReasons":[]}, {"coverageReportTruncated":False},
                       {"gapReasons":[],"coverageReportTruncated":True},
                       {"gapReasons":["malformedSource"],"coverageReportTruncated":False},
                       {"gapReasons":[],"coverageReportTruncated":0}):
            with self.subTest(report=report):
                self.assertFalse(RUNNER.required_coverage_complete(report))

    def test_explicit_media_exclusions_are_not_required_content_gaps(self):
        self.assertTrue(RUNNER.required_coverage_complete({"gapReasons":[],"coverageReportTruncated":False,
                                                         "excludedMediaCount":3}))


class RoleEvidenceBoundaryTests(unittest.TestCase):
    def complete(self):
        return {"roleEvidenceWithinBudget": True,
            "nativeSourceRoles": {"verifiedParentSourceCount": 1, "verifiedOwnChildSourceCount": 1,
                "conflictingSourceIdentityCount": 0},
            "typedCommittedByRole": {role: {marker: 1 for marker in RUNNER.EXPECTED_MARKERS
                if marker.startswith("CHILD_") == (role == "child")} for role in ("parent", "child")}}

    def test_requires_all_five_child_types_and_seven_parent_markers(self):
        full = self.complete()
        self.assertTrue(RUNNER.typed_role_coverage_complete(full))
        for marker in RUNNER.EXPECTED_MARKERS:
            report = self.complete()
            del report["typedCommittedByRole"]["child" if marker.startswith("CHILD_") else "parent"][marker]
            self.assertFalse(RUNNER.typed_role_coverage_complete(report))
        self.assertFalse(RUNNER.typed_role_coverage_complete({"typedCommitted": {marker: 1 for marker in RUNNER.EXPECTED_MARKERS}}))

    def test_role_metadata_must_be_explicit_bounded_and_without_conflict(self):
        for field, value in (("verifiedParentSourceCount", 0), ("verifiedOwnChildSourceCount", 0),
                             ("verifiedOwnChildSourceCount", True), ("conflictingSourceIdentityCount", False), ("conflictingSourceIdentityCount", 1)):
            report = self.complete()
            report["nativeSourceRoles"][field] = value
            self.assertFalse(RUNNER.typed_role_coverage_complete(report))
        report = self.complete(); report["roleEvidenceWithinBudget"] = False
        self.assertFalse(RUNNER.typed_role_coverage_complete(report))
        report = self.complete(); report["typedCommittedByRole"]["child"]["CHILD_PROMPT"] = True
        self.assertFalse(RUNNER.typed_role_coverage_complete(report))


class ArtifactBoundaryTests(unittest.TestCase):
    def test_failure_retains_sources_after_removing_all_auth_config(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            root = base / "owned"
            config = root / "claude"
            sources = config / "projects"
            sources.mkdir(parents=True)
            (sources / "fake.jsonl").write_text('{"synthetic":true}\n')
            (config / ".credentials.json").write_text("fake auth fixture")
            (config / "refreshed-auth").mkdir()
            (config / "refreshed-auth" / "token").write_text("fake auth fixture")
            pointer = base / "private.json"
            outcome = RUNNER.finalize_artifacts(root, False, pointer)
            self.assertTrue(outcome["temporaryAuthenticationRemoved"])
            self.assertTrue(outcome["failedArtifactsRetained"])
            self.assertEqual(list(config.iterdir()), [sources])
            self.assertTrue((sources / "fake.jsonl").is_file())
            self.assertEqual(os.stat(pointer).st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(pointer.read_text())["ownedArtifactRoot"], str(root))

    def test_success_removes_entire_fixture(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            root = base / "owned"
            root.mkdir()
            pointer = base / "private.json"
            outcome = RUNNER.finalize_artifacts(root, True, pointer)
            self.assertTrue(outcome["disposableRootRemoved"])
            self.assertFalse(pointer.exists())

    def test_auth_enumeration_failure_retains_root_and_reports_incomplete_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            root = base / "owned"
            config = root / "claude"
            config.mkdir(parents=True)
            credential = config / ".credentials.json"
            credential.write_text("fake auth fixture")
            pointer = base / "private.json"
            with mock.patch.object(pathlib.Path, "iterdir", side_effect=PermissionError("private detail")):
                outcome = RUNNER.finalize_artifacts(root, True, pointer)
            self.assertFalse(outcome["temporaryAuthenticationRemoved"])
            self.assertFalse(outcome["cleanupComplete"])
            self.assertTrue(outcome["failedArtifactsRetained"])
            self.assertTrue(credential.exists())
            self.assertTrue(outcome["artifactPointerWritten"])
            private = json.loads(pointer.read_text())
            self.assertEqual(private["ownedArtifactRoot"], str(root))
            self.assertFalse(private["temporaryAuthenticationRemoved"])
            self.assertNotIn("private detail", json.dumps(outcome))

    def test_root_deletion_failure_scrubs_auth_and_preserves_private_handoff(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            root = base / "owned"
            config = root / "claude"
            config.mkdir(parents=True)
            credential = config / ".credentials.json"
            credential.write_text("fake auth fixture")
            pointer = base / "private.json"
            with mock.patch.object(RUNNER.shutil, "rmtree", side_effect=PermissionError("private detail")):
                outcome = RUNNER.finalize_artifacts(root, True, pointer)
            self.assertTrue(outcome["temporaryAuthenticationRemoved"])
            self.assertFalse(credential.exists())
            self.assertFalse(outcome["cleanupComplete"])
            self.assertTrue(outcome["rootDeletionFailed"])
            self.assertTrue(outcome["failedArtifactsRetained"])
            self.assertEqual(json.loads(pointer.read_text())["ownedArtifactRoot"], str(root))

    def test_existing_pointer_is_preserved_and_exclusive_recovery_pointer_is_written(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            root = base / "owned"
            root.mkdir()
            pointer = base / "private.json"
            pointer.write_text("earlier owned artifact reference")
            outcome = RUNNER.finalize_artifacts(root, False, pointer)
            self.assertEqual(pointer.read_text(), "earlier owned artifact reference")
            self.assertTrue(outcome["artifactPointerWritten"])
            self.assertTrue(outcome["artifactPointerUsedFallback"])
            recovery = pointer.with_name(pointer.stem + ".recovery.json")
            self.assertEqual(json.loads(recovery.read_text())["ownedArtifactRoot"], str(root))
            self.assertEqual(recovery.stat().st_mode & 0o777, 0o600)

    def test_pointer_write_failure_keeps_controlled_report_and_private_stderr_handoff(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            root = base / "owned"
            root.mkdir()
            pointer = base / "private.json"
            with mock.patch.object(RUNNER.os, "open", side_effect=PermissionError("private detail")), \
                 contextlib.redirect_stderr(io.StringIO()) as stderr:
                outcome = RUNNER.finalize_artifacts(root, False, pointer)
            self.assertFalse(outcome["cleanupComplete"])
            self.assertTrue(outcome["artifactPointerWriteFailed"])
            self.assertTrue(outcome["privateStderrHandoffWritten"])
            self.assertTrue(root.exists())
            self.assertEqual(stderr.getvalue(), "Private acceptance artifacts retained: " + str(root) + "\n")
            self.assertNotIn(str(root), json.dumps(outcome))
            self.assertNotIn("private detail", json.dumps(outcome))

    def test_cleanup_does_not_follow_a_source_symlink(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            outside = base / "outside"
            outside.mkdir()
            sentinel = outside / "untouched"
            sentinel.write_text("untouched")
            config = base / "owned" / "claude"
            config.mkdir(parents=True)
            (config / "projects").symlink_to(outside, target_is_directory=True)
            self.assertTrue(RUNNER.remove_temporary_authentication(config))
            self.assertEqual(sentinel.read_text(), "untouched")
            self.assertFalse((config / "projects").exists())

    def test_cleanup_does_not_follow_a_config_symlink(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            outside = base / "outside"
            outside.mkdir()
            credential = outside / ".credentials.json"
            credential.write_text("external fixture must remain untouched")
            config = base / "claude"
            config.symlink_to(outside, target_is_directory=True)
            self.assertTrue(RUNNER.remove_temporary_authentication(config))
            self.assertTrue(credential.exists())
            self.assertFalse(config.exists())

    def test_config_symlink_unlink_failure_is_reported_without_following_it(self):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            outside = base / "outside"
            outside.mkdir()
            config = base / "claude"
            config.symlink_to(outside, target_is_directory=True)
            with mock.patch.object(pathlib.Path, "unlink", side_effect=PermissionError("private detail")):
                self.assertFalse(RUNNER.remove_temporary_authentication(config))
            self.assertTrue(config.is_symlink())
            self.assertTrue(outside.exists())

    def _run_failure(self, phase):
        with tempfile.TemporaryDirectory() as temp:
            base = pathlib.Path(temp)
            root = base / "owned"
            root.mkdir()
            binary = base / "fake-binary"
            binary.write_bytes(b"fixture only")
            output = base / "report.json"
            arguments = ["run.py","--output",str(output),"--acceptance-executable",str(binary),
                         "--helper-executable",str(binary)]
            if phase == "historical":
                arguments += ["--historical-producer-executable",str(binary)]
            def fake_auth(env, config):
                (config / ".credentials.json").write_text("fake auth fixture")
                if phase == "setup":
                    raise RuntimeError("must not disclose fake auth fixture")
            with mock.patch.object(sys, "argv", arguments), \
                 mock.patch.object(RUNNER.tempfile, "mkdtemp", return_value=str(root)), \
                 mock.patch.object(RUNNER.subprocess, "check_output", return_value="2.1.296 (Claude Code)"), \
                 mock.patch.object(RUNNER, "authentication", side_effect=fake_auth), \
                 mock.patch.object(RUNNER, "run_provider", return_value={"exitCode":1,"processGroupCleanup":STOPPED}), \
                 mock.patch.object(RUNNER, "drive_collection") as driver, \
                 contextlib.redirect_stdout(io.StringIO()) as stdout:
                self.assertEqual(RUNNER.main(), 1)
            driver.assert_not_called()
            report = json.loads(output.read_text())
            self.assertFalse(report["passed"])
            self.assertTrue(report["cleanup"]["temporaryAuthenticationRemoved"])
            self.assertTrue(report["cleanup"]["failedArtifactsRetained"])
            self.assertFalse((root / "claude" / ".credentials.json").exists())
            self.assertTrue(output.with_suffix(".private-artifacts.json").is_file())
            self.assertNotIn("fake auth fixture", stdout.getvalue())
            return report

    def test_setup_exception_still_scrubs_auth_and_preserves_failure(self):
        self.assertEqual(self._run_failure("setup")["unmetGate"], "fixtureSetupFailed")

    def test_historical_provider_failure_still_scrubs_auth_and_preserves_failure(self):
        self.assertEqual(self._run_failure("historical")["unmetGate"], "historicalProviderRunFailed")

    def test_provider_timeout_keeps_safe_counts_and_process_cleanup(self):
        process = mock.Mock()
        process.communicate.side_effect = subprocess.TimeoutExpired(["fixture"],1,
            output=b"fake private output",stderr=b"fake private diagnostic")
        with mock.patch.object(RUNNER.subprocess, "Popen", return_value=process), \
             mock.patch.object(RUNNER, "stop_group", return_value=STOPPED) as stop:
            result = RUNNER.run_provider("fake", "synthetic", {}, "/tmp", "fake-config", timeout=1)
        stop.assert_called_once_with(process)
        self.assertTrue(result["timedOut"])
        self.assertIsNone(result["exitCode"])
        self.assertNotIn("fake private", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
