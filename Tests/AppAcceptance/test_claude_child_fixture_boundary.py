"""Constructed fixture and cleanup gates only; no signed app, provider or Keychain."""
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

SPEC = importlib.util.spec_from_file_location("claude_signed_child_fixture", Path(__file__).with_name("run-app-claude-child-fixture.py"))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


def complete_report():
    return {"storageReady": True, "collectionConfigured": True, "syntheticValuePresent": True,
        "queueCount": 0, "gapReasons": [], "coverageReportTruncated": False, "valueCount": 1,
        "occurrenceCount": 12, "syntheticOccurrenceCount": 12, "syntheticSessionCount": 2,
        "syntheticNativeChildOccurrenceCount": 5, "alertCount": 0,
        "syntheticOccurrencesByContentType": RUNNER.EXPECTED_COUNTS.copy(),
        "observedAgentVersions": [RUNNER.VERSION], "newVaultCleanupPassed": True,
        "claudeIndividualRoleCoverageMeasured": True, "claudeIndividualRoleCoveragePassed": True,
        "claudeNativeParentChildLinkVerified": True, "claudeRoleEvidenceWithinBudget": True,
        "claudeCommittedNativeParentChildPairCountByProducer": {RUNNER.VERSION: 1},
        "claudeTypedCommittedMarkersByRole": {role: {marker: 1 for marker in RUNNER.live.fixture.EXPECTED_MARKERS
            if marker.startswith("CHILD_") == (role == "child")} for role in ("parent", "child")},
        "claudeCommittedContentTypesByRole": {role: sorted(RUNNER.EXPECTED_COUNTS) for role in ("parent", "child")}}


class ConstructedChildFixtureTests(unittest.TestCase):
    def fixture(self, root):
        source, session, child, child_session = RUNNER.create_fixture(root)
        paths, native = RUNNER.selected.inspect_selected_native_source(source, RUNNER.live.fixture.SECRET, session)
        return source, session, child, child_session, paths, native

    def test_fixture_has_exact_own_child_with_distinct_uuid_and_all_twelve_typed_markers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source, session, child, child_session, paths, native = self.fixture(root)
            self.assertNotEqual(session, child_session)
            self.assertEqual(paths, [(source, session), (child, child_session)])
            self.assertEqual(native["nativeSessionCount"], 2)
            self.assertEqual(native["nativeTranscriptCount"], 2)
            self.assertTrue(RUNNER.selected.complete_selected_native_pair(native, RUNNER.VERSION))
            self.assertEqual(native["completeNativeParentChildPairCountByProducer"], {RUNNER.VERSION: 1})
            self.assertEqual(len(native["typedMarkersByRole"]["parent"]), 7)
            self.assertEqual(len(native["typedMarkersByRole"]["child"]), 5)
            for path, native_session in paths:
                rows = [json.loads(line) for line in path.read_text().splitlines()]
                self.assertTrue(all(row["sessionId"] == native_session and row["cwd"] == str(root / "project") for row in rows))
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                calls = {block["id"] for row in rows for block in row["message"]["content"] if block["type"] == "tool_use"}
                results = {block["tool_use_id"] for row in rows for block in row["message"]["content"] if block["type"] == "tool_result"}
                self.assertEqual(calls, results)
            for private in (session, child_session, str(root), RUNNER.live.fixture.SECRET):
                self.assertNotIn(private, json.dumps(native))

    def test_exact_counts_cannot_replace_strict_receipts_or_child_roles(self):
        with tempfile.TemporaryDirectory() as directory:
            *_, native = self.fixture(Path(directory).resolve())
            self.assertTrue(RUNNER.complete_report(complete_report(), native))
            for change in ({"syntheticSessionCount": 1}, {"occurrenceCount": 11},
                           {"syntheticNativeChildOccurrenceCount": 0}, {"queueCount": 1},
                           {"gapReasons": ["unresolvedCorrelation"]}, {"claudeIndividualRoleCoveragePassed": False}):
                self.assertFalse(RUNNER.complete_report({**complete_report(), **change}, native))
            report = complete_report()
            report["claudeTypedCommittedMarkersByRole"]["child"].pop("CHILD_TOOL_ERROR")
            self.assertFalse(RUNNER.complete_report(report, native))
            report = complete_report()
            report["claudeCommittedNativeParentChildPairCountByProducer"] = {}
            self.assertFalse(RUNNER.complete_report(report, native))

    def test_admission_requires_both_candidate_bindings_before_any_app(self):
        with tempfile.TemporaryDirectory() as directory:
            base = ["--output", str(Path(directory) / "report.json")]
            for options in ([], ["--candidate-manifest", "/fake-manifest.json"], ["--expected-bundle-sha256", "a" * 64]):
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    RUNNER.parse_arguments(base + options)
            args = RUNNER.parse_arguments(base + ["--candidate-manifest", "/fake-manifest.json", "--expected-bundle-sha256", "a" * 64])
            self.assertEqual(args.expected_bundle_sha256, "a" * 64)

    def drive(self, root, *, child_missing=False, cleanup_passed=True):
        owned = root / "owned"
        owned.mkdir()
        output = root / "report.json"
        report = complete_report()
        report["newVaultCleanupPassed"] = cleanup_passed
        if child_missing:
            report["syntheticNativeChildOccurrenceCount"] = 0
            report["claudeIndividualRoleCoveragePassed"] = False
        commands, private_sessions = [], []

        class FakeApp:
            returncode = 0

            def __init__(self, command, **kwargs):
                commands.append(command)
                private_sessions.append(command[command.index("--claude-session") + 1])
                store = Path(command[command.index("--store-directory") + 1])
                store.mkdir()
                (store / "ciphertext").write_bytes(b"fake protected store bytes")
                Path(command[command.index("--acceptance-report") + 1]).write_text(json.dumps(report))

            def poll(self):
                return self.returncode

            def wait(self, **kwargs):
                return self.returncode

        def run(command, **kwargs):
            commands.append(command)
            if "input" in kwargs:
                private_sessions.append(json.loads(kwargs["input"])["session_id"])
            return subprocess.CompletedProcess(command, 1 if command[0] == "/usr/bin/pgrep" else 0)

        argv = ["runner", "--output", str(output), "--app", str(root / "fake.app"),
            "--candidate-manifest", str(root / "manifest.json"), "--expected-bundle-sha256", "a" * 64]
        mask = os.umask(0o077)
        stdout = io.StringIO()
        try:
            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(RUNNER.live.sys, "argv", argv))
                stack.enter_context(mock.patch("Support.acceptance_artifacts.tempfile.mkdtemp", return_value=str(owned)))
                stack.enter_context(mock.patch.object(RUNNER.live, "candidate_snapshot", return_value={"bundleSHA256": "a" * 64}))
                stack.enter_context(mock.patch.object(RUNNER.subprocess, "Popen", side_effect=FakeApp))
                stack.enter_context(mock.patch.object(RUNNER.subprocess, "run", side_effect=run))
                stack.enter_context(mock.patch.object(RUNNER.live, "wait_for_report", return_value=report))
                stack.enter_context(mock.patch.object(RUNNER.live, "settled_report", return_value=report))
                stack.enter_context(mock.patch.object(RUNNER.selected, "stop_group", return_value={
                    "term_permission_denied": False, "kill_permission_denied": False}))
                authentication = stack.enter_context(mock.patch.object(RUNNER.live.fixture, "authentication"))
                provider = stack.enter_context(mock.patch.object(RUNNER.live.fixture, "run_provider"))
                stack.enter_context(contextlib.redirect_stdout(stdout))
                stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
                code = RUNNER.main()
                authentication.assert_not_called()
                provider.assert_not_called()
        finally:
            os.umask(mask)
        result = json.loads(output.read_text())
        for private in (*private_sessions, RUNNER.live.fixture.SECRET, str(owned)):
            self.assertNotIn(private, stdout.getvalue())
            self.assertNotIn(private, output.read_text())
        self.assertFalse(any("--claude-configure-hook" in command for command in commands))
        return code, result, owned, commands

    def test_signed_simulation_requires_cleanup_and_never_claims_genuine_host_acceptance(self):
        with tempfile.TemporaryDirectory() as directory:
            code, report, owned, commands = self.drive(Path(directory))
            self.assertEqual(code, 0)
            self.assertTrue(report["passed"])
            self.assertTrue(report["signedConstructedChildRegressionEstablished"])
            self.assertFalse(report["sourceIsGenuineProviderOutput"])
            self.assertFalse(report["hostAcceptanceEstablished"])
            self.assertTrue(report["fixtureIsConstructed"])
            self.assertEqual(len(report["replayRuns"]), 4)
            self.assertFalse(owned.exists())
            launched = next(command for command in commands if "--claude-active-source" in command)
            self.assertEqual(launched.count("--claude-active-source"), 1)
            self.assertIn("--acceptance-no-profile-catchup", launched)

    def test_missing_child_or_unconfirmed_key_cleanup_retains_exact_private_artifacts(self):
        for options in ({"child_missing": True}, {"cleanup_passed": False}):
            with tempfile.TemporaryDirectory() as directory:
                code, report, owned, _ = self.drive(Path(directory), **options)
                self.assertEqual(code, 1)
                self.assertFalse(report["passed"])
                self.assertTrue(report["cleanupPending"])
                self.assertFalse(report["signedConstructedChildRegressionEstablished"])
                self.assertTrue((owned / "acceptance-run-private.json").is_file())
                self.assertEqual(len(list((owned / "sources").rglob("*.jsonl"))), 2)


if __name__ == "__main__":
    unittest.main()
