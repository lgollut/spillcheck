"""Synthetic cleanup boundaries; no provider, app, vault or Keychain is launched."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("signed_claude_live", Path(__file__).with_name("run-app-claude-live.py"))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
VERSION = "2.1.296"
AUTH = "fake-private-authentication-must-not-be-exported"
SOURCE = '{"synthetic_source":"retained original bytes"}\n'
CLEANUP = {"grace_ms": 200, "term_permission_denied": False, "kill_permission_denied": False}


def strict_role_report():
    return {"claudeIndividualRoleCoverageMeasured": True, "claudeIndividualRoleCoveragePassed": True,
        "claudeNativeParentChildLinkVerified": True, "claudeRoleEvidenceWithinBudget": True,
        "claudeCommittedNativeParentChildPairCountByProducer": {VERSION: 1},
        "claudeTypedCommittedMarkersByRole": {role: {marker: 1 for marker in RUNNER.fixture.EXPECTED_MARKERS
            if marker.startswith("CHILD_") == (role == "child")} for role in ("parent", "child")},
        "claudeCommittedContentTypesByRole": {role: sorted(set(RUNNER.fixture.EXPECTED_MARKERS.values()))
            for role in ("parent", "child")}}

class SignedRoleEvidenceTests(unittest.TestCase):
    def test_requires_explicit_complete_individual_role_evidence(self):
        self.assertTrue(RUNNER.strict_role_coverage_complete(strict_role_report()))
        for key in strict_role_report():
            report = strict_role_report(); report.pop(key)
            self.assertFalse(RUNNER.strict_role_coverage_complete(report))
        self.assertFalse(RUNNER.strict_role_coverage_complete({"syntheticNativeChildContentTypes":
            ["userPrompt", "finalResponse"], "syntheticNativeChildOccurrenceCount": 2}))

    def test_boolean_missing_or_duplicate_marker_counts_cannot_pass(self):
        for count in (0, True, 2):
            report = strict_role_report()
            report["claudeTypedCommittedMarkersByRole"]["child"]["CHILD_TOOL_ERROR"] = count
            self.assertFalse(RUNNER.strict_role_coverage_complete(report))
        report = strict_role_report(); report["claudeCommittedContentTypesByRole"]["child"].remove("toolError")
        self.assertFalse(RUNNER.strict_role_coverage_complete(report))


class CandidateBoundaryTests(unittest.TestCase):
    def test_manifest_and_bundle_digest_must_be_selected_together(self):
        import argparse
        for options in (["--candidate-manifest", "/fake.json"], ["--expected-bundle-sha256", "a" * 64]):
            parser = argparse.ArgumentParser()
            parser.add_argument("--output", type=Path, default=Path("/nonexistent-synthetic-report.json"))
            RUNNER.candidate_arguments(parser)
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                RUNNER.candidate_admission(parser, parser.parse_args(options))

    def test_manifest_requires_exact_bundle_sources_signature_and_stable_bytes(self):
        manifest = {"bundleSHA256": "a" * 64, "executableSHA256": "b" * 64}
        with mock.patch.object(RUNNER.preflight, "read_manifest", return_value=manifest), \
             mock.patch.object(RUNNER.preflight, "hash_file", return_value="c" * 64), \
             mock.patch.object(RUNNER.preflight, "check", return_value={"consistent": True}):
            pinned = RUNNER.candidate_snapshot(Path("/fake-manifest.json"), "a" * 64, Path("/fake.app"))
            self.assertEqual(pinned["bundleSHA256"], "a" * 64)
            self.assertFalse(pinned["completeBuildProvenanceVerified"])
            with self.assertRaises(ValueError):
                RUNNER.candidate_snapshot(Path("/fake-manifest.json"), "d" * 64, Path("/fake.app"))
            with mock.patch.object(RUNNER.preflight, "check", return_value={"consistent": False}), self.assertRaises(ValueError):
                RUNNER.candidate_snapshot(Path("/fake-manifest.json"), "a" * 64, Path("/fake.app"))
            with mock.patch.object(RUNNER.preflight, "hash_file", side_effect=["c" * 64, "d" * 64]), self.assertRaises(ValueError):
                RUNNER.candidate_snapshot(Path("/fake-manifest.json"), "a" * 64, Path("/fake.app"))
        self.assertIsNone(RUNNER.candidate_snapshot(None, None, Path("/fake.app")))

    def test_existing_report_or_symlink_is_not_overwritten(self):
        import argparse
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            output.write_text("retained evidence")
            parser = argparse.ArgumentParser()
            for selected in (output, Path(directory) / "pointer"):
                if selected != output:
                    selected.symlink_to(Path(directory) / "absent")
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    RUNNER.candidate_admission(parser, argparse.Namespace(output=selected,
                        candidate_manifest=None, expected_bundle_sha256=None))
            self.assertEqual(output.read_text(), "retained evidence")


class ProviderAuthenticationCleanupTests(unittest.TestCase):
    def test_only_projects_survive_and_token_is_removed(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "claude"
            projects = config / "projects"
            projects.mkdir(parents=True)
            source = projects / "owned.jsonl"
            source.write_text(SOURCE)
            (config / ".credentials.json").write_text(AUTH)
            (config / "settings.json").write_text("{}")
            refreshed = config / "refreshed-auth"
            refreshed.mkdir()
            (refreshed / "token").write_text(AUTH)
            env = {"CLAUDE_CODE_OAUTH_TOKEN": AUTH}
            self.assertTrue(RUNNER.remove_provider_authentication(config, env))
            self.assertEqual(list(config.iterdir()), [projects])
            self.assertEqual(source.read_text(), SOURCE)
            self.assertNotIn("CLAUDE_CODE_OAUTH_TOKEN", env)

    def test_projects_symlink_is_unlinked_without_touching_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            outside.mkdir()
            sentinel = outside / "untouched"
            sentinel.write_text("external fixture")
            config = root / "claude"
            config.mkdir()
            (config / "projects").symlink_to(outside, target_is_directory=True)
            self.assertTrue(RUNNER.remove_provider_authentication(config, {}))
            self.assertFalse((config / "projects").exists())
            self.assertEqual(sentinel.read_text(), "external fixture")

    def test_configuration_symlink_is_unlinked_without_touching_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            outside.mkdir()
            sentinel = outside / ".credentials.json"
            sentinel.write_text(AUTH)
            config = root / "claude"
            config.symlink_to(outside, target_is_directory=True)
            self.assertTrue(RUNNER.remove_provider_authentication(config, {}))
            self.assertFalse(config.is_symlink())
            self.assertEqual(sentinel.read_text(), AUTH)

    def test_cleanup_failure_returns_false_and_still_clears_environment_token(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "claude"
            config.mkdir()
            credential = config / ".credentials.json"
            credential.write_text(AUTH)
            env = {"CLAUDE_CODE_OAUTH_TOKEN": AUTH}
            with mock.patch.object(Path, "unlink", side_effect=PermissionError("private detail")):
                self.assertFalse(RUNNER.remove_provider_authentication(config, env))
            self.assertTrue(credential.exists())
            self.assertNotIn("CLAUDE_CODE_OAUTH_TOKEN", env)


class SignedRunnerRetentionTests(unittest.TestCase):
    def drive(self, root, *, gap=False, authentication_failure=False, cleanup_failure=False, provider_failure=False):
        owned = root / "owned"
        owned.mkdir()
        output = root / "report.json"
        envs = []
        kinds = {kind: 1 for kind in ("userPrompt", "intermediateResponse", "finalResponse", "toolOutput", "toolError")}
        app_report = {**strict_role_report(), "storageReady": True, "collectionConfigured": True, "queueCount": 0,
                      "gapReasons": ["unsupportedContent"] if gap else [], "coverageReportTruncated": False,
                      "syntheticValuePresent": True, "syntheticSessionCount": 2,
                      "syntheticOccurrencesByContentType": kinds, "syntheticNativeChildOccurrenceCount": 2,
                      "syntheticNativeChildContentTypes": ["userPrompt", "finalResponse"],
                      "observedAgentVersions": [VERSION], "newVaultCleanupPassed": True,
                      "occurrenceCount": 5, "alertCount": 2, "syntheticOccurrenceCount": 5}

        def authentication(env, config):
            env["CLAUDE_CODE_OAUTH_TOKEN"] = AUTH
            envs.append(env)
            (config / ".credentials.json").write_text(AUTH)
            (config / "settings.json").write_text("{}")
            (config / "projects" / "owned.jsonl").write_text(SOURCE)
            if authentication_failure:
                raise ValueError(AUTH)

        def check_output(command, **kwargs):
            if len(command) == 2 and command[1] == "--version":
                return VERSION + " (Claude Code)"
            return json.dumps({"installed": True, "verificationPrompt": "fake one-use verification"})

        def run(command, **kwargs):
            return subprocess.CompletedProcess(command, 1 if command[0] == "/usr/bin/pgrep" else 0, b"", b"")

        class FakeApp:
            returncode = 0

            def __init__(self, command, **kwargs):
                assert "--acceptance-claude-role-evidence" in command
                store = Path(command[command.index("--store-directory") + 1])
                store.mkdir()
                (store / "ciphertext").write_bytes(b"fake encrypted database")
                Path(command[command.index("--acceptance-report") + 1]).write_text(json.dumps(app_report))

            def poll(self):
                return self.returncode

            def wait(self, **kwargs):
                return self.returncode

        native = {"typedMarkers": list(RUNNER.fixture.EXPECTED_MARKERS), "completeJSONLFraming": True,
                  "requiredNativeFieldsValid": True, "producerVersions": [VERSION],
                  "individualNativeRoleCoverageComplete": True, "completeNativeParentChildPairCountByProducer": {VERSION: 1}}
        history = {"contentTypesByProducer": {VERSION: list(kinds)},
                   "typedMarkersByProducer": {VERSION: list(RUNNER.fixture.EXPECTED_MARKERS)}}
        argv = ["run-app-claude-live.py", "--output", str(output), "--app", str(root / "fake.app"),
                "--executable", str(root / "fake-claude"), "--expected-version", VERSION,
                "--configuration-executable", str(root / "fake-configuration")]
        stdout, stderr = io.StringIO(), io.StringIO()
        old_umask = os.umask(0o077)
        try:
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(RUNNER.sys, "argv", argv))
                stack.enter_context(mock.patch("Support.acceptance_artifacts.tempfile.mkdtemp", return_value=str(owned)))
                stack.enter_context(mock.patch.object(RUNNER.fixture, "authentication", side_effect=authentication))
                stack.enter_context(mock.patch.object(RUNNER.fixture, "run_provider", return_value={
                    "exitCode": 1 if provider_failure else 0, "processGroupCleanup": CLEANUP,
                    **({"failureCategory": "sessionLimit", "failureClassificationTruncated": False} if provider_failure else {})}))
                stack.enter_context(mock.patch.object(RUNNER.fixture, "native_history_evidence", return_value=({}, history)))
                stack.enter_context(mock.patch.object(RUNNER, "native_evidence", return_value=([(owned / "claude/projects/owned.jsonl", "fake-owned-session")], native)))
                stack.enter_context(mock.patch.object(RUNNER, "wait_for_report", return_value=app_report))
                stack.enter_context(mock.patch.object(RUNNER, "settled_report", return_value=app_report))
                stack.enter_context(mock.patch.object(RUNNER, "stop_group", return_value=CLEANUP))
                stack.enter_context(mock.patch.object(RUNNER.subprocess, "check_output", side_effect=check_output))
                stack.enter_context(mock.patch.object(RUNNER.subprocess, "run", side_effect=run))
                stack.enter_context(mock.patch.object(RUNNER.subprocess, "Popen", side_effect=FakeApp))
                if cleanup_failure:
                    stack.enter_context(mock.patch.object(Path, "unlink", side_effect=PermissionError("private detail")))
                stack.enter_context(contextlib.redirect_stdout(stdout))
                stack.enter_context(contextlib.redirect_stderr(stderr))
                code = RUNNER.main()
        finally:
            os.umask(old_umask)
        report = json.loads(output.read_text())
        for content in (stdout.getvalue(), stderr.getvalue(), output.read_text()):
            self.assertNotIn(AUTH, content)
            self.assertNotIn(SOURCE, content)
            self.assertNotIn("private detail", content)
        self.assertTrue(all("CLAUDE_CODE_OAUTH_TOKEN" not in env for env in envs))
        return code, report, owned

    def test_failed_required_gap_preserves_original_sources_after_auth_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            code, report, owned = self.drive(Path(temporary), gap=True)
            self.assertEqual(code, 1)
            self.assertFalse(report["passed"])
            self.assertTrue(report["cleanupPending"])
            self.assertTrue(report["result"]["newVaultCleanupPassed"])
            self.assertTrue(report["providerAuthenticationRemoved"])
            self.assertEqual(list((owned / "claude").iterdir()), [owned / "claude/projects"])
            self.assertEqual((owned / "claude/projects/owned.jsonl").read_text(), SOURCE)
            self.assertEqual(owned.stat().st_mode & 0o777, 0o700)
            self.assertEqual((owned / "acceptance-run-private.json").stat().st_mode & 0o777, 0o600)

    def test_passing_run_still_removes_entire_disposable_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            code, report, owned = self.drive(Path(temporary))
            self.assertEqual(code, 0)
            self.assertTrue(report["passed"])
            self.assertFalse(report["cleanupPending"])
            self.assertTrue(report["providerAuthenticationRemoved"])
            self.assertFalse(owned.exists())

    def test_setup_failure_also_preserves_sources_after_auth_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            code, report, owned = self.drive(Path(temporary), authentication_failure=True)
            self.assertEqual(code, 1)
            self.assertTrue(report["runException"])
            self.assertTrue(report["providerAuthenticationRemoved"])
            self.assertEqual(list((owned / "claude").iterdir()), [owned / "claude/projects"])
            self.assertEqual((owned / "claude/projects/owned.jsonl").read_text(), SOURCE)

    def test_auth_cleanup_failure_cannot_pass_or_delete_retained_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            code, report, owned = self.drive(Path(temporary), cleanup_failure=True)
            self.assertEqual(code, 1)
            self.assertFalse(report["passed"])
            self.assertFalse(report["providerAuthenticationRemoved"])
            self.assertTrue(report["cleanupPending"])
            self.assertTrue((owned / "claude/.credentials.json").exists())
            self.assertEqual((owned / "claude/projects/owned.jsonl").read_text(), SOURCE)

    def test_provider_failure_stops_later_sessions_and_reports_controlled_category(self):
        with tempfile.TemporaryDirectory() as temporary:
            code, report, owned = self.drive(Path(temporary), provider_failure=True)
            self.assertEqual(code, 1)
            self.assertFalse(report["passed"])
            self.assertEqual(report["unmetGate"], "providerRunFailed")
            self.assertEqual(report["providerFailureCategory"], "sessionLimit")
            self.assertEqual(len(report["providerRuns"]), 1)
            self.assertEqual(report["providerRuns"][0]["failureCategory"], "sessionLimit")
            self.assertTrue(report["providerAuthenticationRemoved"])
            self.assertTrue((owned / "claude/projects/owned.jsonl").exists())


if __name__ == "__main__":
    unittest.main()
