"""Selected host acceptance gates only; no app, provider or Keychain is invoked."""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("signed_claude_selected", Path(__file__).with_name("run-app-claude-selected.py"))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
VERSION = "2.1.296"


def evidence():
    result = {"claudeIndividualRoleCoverageMeasured": True, "claudeIndividualRoleCoveragePassed": True,
        "claudeNativeParentChildLinkVerified": True, "claudeRoleEvidenceWithinBudget": True,
        "claudeCommittedNativeParentChildPairCountByProducer": {VERSION: 1},
        "claudeTypedCommittedMarkersByRole": {role: {marker: 1 for marker in RUNNER.MARKERS
            if marker.startswith("CHILD_") == (role == "child")} for role in ("parent", "child")},
        "claudeCommittedContentTypesByRole": {role: sorted(RUNNER.REQUIRED) for role in ("parent", "child")},
        "observedAgentVersions": [VERSION]}
    native = {"requiredNativeFieldsValid": True, "completeJSONLFraming": True,
        "exactParentAndOwnChildFilesOnly": True, "individualNativeRoleCoverageComplete": True,
        "completeNativeParentChildPairCountByProducer": {VERSION: 1}, "typedMarkers": sorted(RUNNER.MARKERS),
        "childTypedMarkers": sorted(marker for marker in RUNNER.MARKERS if marker.startswith("CHILD_")),
        "producerVersions": [VERSION]}
    return result, native


class SelectedRoleBoundaryTests(unittest.TestCase):
    def test_complete_current_source_pair_passes(self):
        result, native = evidence()
        self.assertTrue(RUNNER.strict_selected_role_coverage(result, native, VERSION))
        self.assertEqual(len(RUNNER.MARKERS), 12)

    def test_legacy_child_prompt_and_final_cannot_pass(self):
        result, native = evidence()
        legacy = {"syntheticNativeChildOccurrenceCount": 2,
            "syntheticNativeChildContentTypes": ["userPrompt", "finalResponse"],
            "observedAgentVersions": [VERSION]}
        self.assertFalse(RUNNER.strict_selected_role_coverage(legacy, native, VERSION))
        for marker in ("CHILD_INTERMEDIATE", "CHILD_TOOL_OUTPUT", "CHILD_TOOL_ERROR", "MCP_OK", "MCP_ERROR"):
            result, native = evidence()
            native["typedMarkers"].remove(marker)
            self.assertFalse(RUNNER.strict_selected_role_coverage(result, native, VERSION))

    def test_role_receipts_and_native_source_pair_are_independent_requirements(self):
        for field in ("claudeIndividualRoleCoverageMeasured", "claudeIndividualRoleCoveragePassed",
                      "claudeNativeParentChildLinkVerified", "claudeRoleEvidenceWithinBudget"):
            result, native = evidence()
            result[field] = False
            self.assertFalse(RUNNER.strict_selected_role_coverage(result, native, VERSION))
        for field in ("requiredNativeFieldsValid", "completeJSONLFraming", "exactParentAndOwnChildFilesOnly",
                      "individualNativeRoleCoverageComplete"):
            result, native = evidence()
            native[field] = False
            self.assertFalse(RUNNER.strict_selected_role_coverage(result, native, VERSION))
        result, native = evidence()
        del result["claudeTypedCommittedMarkersByRole"]["child"]["CHILD_TOOL_ERROR"]
        self.assertFalse(RUNNER.strict_selected_role_coverage(result, native, VERSION))

    def test_wrong_producer_or_pooled_child_types_cannot_pass(self):
        for count in (0, True, None):
            result, native = evidence()
            result["claudeCommittedNativeParentChildPairCountByProducer"][VERSION] = count
            self.assertFalse(RUNNER.strict_selected_role_coverage(result, native, VERSION))
            result, native = evidence()
            native["completeNativeParentChildPairCountByProducer"][VERSION] = count
            self.assertFalse(RUNNER.strict_selected_role_coverage(result, native, VERSION))
        result, native = evidence()
        self.assertFalse(RUNNER.strict_selected_role_coverage(result, native, "2.1.295"))

    def test_collector_pins_exact_source_and_overlapping_test_routes(self):
        source = Path("/fake/claude/projects/owned/00000000-0000-7000-8000-000000000001.jsonl")
        command = RUNNER.collector_command(Path("/fake/Spillcheck.app"), Path("/fake/vault"),
            Path("/fake/report.json"), Path("/fake/finish"), "owned-t3", source, source.stem, VERSION)
        self.assertEqual(command[command.index("--claude-active-source") + 1], str(source))
        self.assertEqual(command[command.index("--claude-source-root") + 1], str(source.parent))
        self.assertEqual(command[command.index("--claude-session") + 1], source.stem)
        self.assertEqual(command[command.index("--claude-interface") + 1], "t3")
        self.assertEqual({command[index + 1] for index, value in enumerate(command)
            if value == "--claude-authorized-host"}, {"t3", "standalone-cli"})
        for flag in ("--acceptance-no-profile-catchup", "--acceptance-cleanup-new-vault", "--acceptance-claude-role-evidence"):
            self.assertIn(flag, command)
        self.assertNotIn("--acceptance-allow-history-request", command)

    def test_desktop_collector_and_replay_route_do_not_authorize_t3(self):
        source = Path("/fake/claude/projects/owned/00000000-0000-7000-8000-000000000001.jsonl")
        command = RUNNER.collector_command(Path("/fake/Spillcheck.app"), Path("/fake/vault"),
            Path("/fake/report.json"), Path("/fake/finish"), "owned-desktop", source, source.stem,
            VERSION, "desktop-code")
        self.assertEqual(command[command.index("--claude-interface") + 1], "desktop-code")
        self.assertEqual({command[index + 1] for index, value in enumerate(command)
            if value == "--claude-authorized-host"}, {"desktop-code", "standalone-cli"})
        self.assertNotIn("t3", command)
        with self.assertRaises(ValueError):
            RUNNER.collector_command(Path("/fake.app"), Path("/fake"), Path("/fake/report"),
                Path("/fake/finish"), "owned", source, source.stem, VERSION, "unknown")

    def test_saved_source_requires_complete_current_pair_before_app_launch(self):
        _, native = evidence()
        self.assertTrue(RUNNER.complete_selected_native_pair(native, VERSION))
        for marker in ("MCP_OK", "MCP_ERROR", "CHILD_TOOL_ERROR"):
            _, native = evidence()
            native["typedMarkers"].remove(marker)
            self.assertFalse(RUNNER.complete_selected_native_pair(native, VERSION))
        _, native = evidence()
        self.assertFalse(RUNNER.complete_selected_native_pair(native, "2.1.295"))
        native["completeNativeParentChildPairCountByProducer"][VERSION] = True
        self.assertFalse(RUNNER.complete_selected_native_pair(native, VERSION))


class RegistrationBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.project = self.root / "work"
        self.project.mkdir(mode=0o700)
        self.identity = self.project / "selected-session-private.json"
        self.authorized = self.root / "projects"
        self.authorized.mkdir(mode=0o700)
        self.session = "00000000-0000-7000-8000-000000000001"
        self.source = self.authorized / (self.session + ".jsonl")
        self.row = {"type": "user", "sessionId": self.session, "cwd": str(self.project), "version": VERSION,
            "uuid": "00000000-0000-7000-8000-000000000002", "timestamp": "2026-10-12T00:00:00Z",
            "message": {"role": "user", "content": "LEAKRET_M3_PROMPT " + RUNNER.live.fixture.SECRET}}
        self.source.write_text(json.dumps(self.row) + "\n")
        self.source.chmod(0o600)
        self.runtime = {"schemaVersion": 1, "nativeSessionID": self.session,
            "identitySource": "own-runtime-CLAUDE_CODE_SESSION_ID", "workingDirectory": str(self.project)}
        self.write_json(self.identity, self.runtime)
        self.manifest_path = self.root / "manifest.json"
        self.manifest = {"schemaVersion": 2, "nativeSessionId": self.session,
            "originalTranscriptPath": str(self.source), "workingDirectory": str(self.project),
            "sourceInterface": "desktop-code", "producerVersion": VERSION, "hostVersion": "fake-host",
            "identitySource": self.runtime["identitySource"], "originalTranscriptPathDerivedThenVerified": True,
            "runtimeIdentityPath": str(self.identity), "runtimeIdentitySHA256": self.digest(self.identity),
            "sourceRegistrationByteCount": self.source.stat().st_size, "sourceRegistrationSHA256": self.digest(self.source)}
        self.write_json(self.manifest_path, self.manifest)

    def write_json(self, path, value):
        path.write_text(json.dumps(value) + "\n")
        path.chmod(0o600)

    def digest(self, path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def inspect(self):
        return RUNNER.registration_snapshot(self.manifest_path, "desktop-code", self.authorized)

    def test_exact_runtime_source_registration_is_bounded_and_private(self):
        manifest, report = self.inspect()
        self.assertEqual(manifest, self.manifest)
        self.assertTrue(report["runtimeIdentitySourcePrefixBindingPassed"])
        self.assertFalse(report["hostOriginIndependentlyVerified"])
        rendered = json.dumps(report)
        for private in (str(self.project), str(self.source), self.session, RUNNER.live.fixture.SECRET):
            self.assertNotIn(private, rendered)

    def test_append_preserves_registration_but_prefix_change_does_not(self):
        _, before = self.inspect()
        original = self.source.read_bytes()
        self.source.write_bytes(original + json.dumps({"type": "system"}).encode() + b"\n")
        self.assertEqual(self.inspect()[1], before)
        self.source.write_bytes(original.replace(b"LEAKRET", b"CHANGED", 1))
        with self.assertRaises(ValueError):
            self.inspect()

    def test_host_declaration_and_required_provenance_cannot_be_relabelled(self):
        for field in ("sourceInterface", "identitySource", "originalTranscriptPathDerivedThenVerified",
                      "hostVersion", "runtimeIdentitySHA256", "sourceRegistrationSHA256"):
            changed = dict(self.manifest)
            changed.pop(field)
            self.write_json(self.manifest_path, changed)
            with self.assertRaises((ValueError, KeyError)):
                self.inspect()
        self.write_json(self.manifest_path, dict(self.manifest, sourceInterface="t3"))
        with self.assertRaises(ValueError):
            self.inspect()

    def test_unbound_or_changed_runtime_identity_is_rejected(self):
        self.write_json(self.identity, dict(self.runtime, nativeSessionID="00000000-0000-7000-8000-000000000003"))
        self.write_json(self.manifest_path, dict(self.manifest, runtimeIdentitySHA256=self.digest(self.identity)))
        with self.assertRaises(ValueError):
            self.inspect()

    def test_native_rows_must_match_runtime_workspace_identity_and_producer(self):
        for field, value in (("cwd", "/unrelated"), ("sessionId", "unrelated"), ("version", "2.1.295")):
            self.write_json(self.source, dict(self.row, **{field: value}))
            self.write_json(self.manifest_path, dict(self.manifest,
                sourceRegistrationByteCount=self.source.stat().st_size, sourceRegistrationSHA256=self.digest(self.source)))
            with self.assertRaises(ValueError):
                self.inspect()

    def test_public_symlink_or_oversized_registration_artifacts_are_rejected(self):
        self.manifest_path.chmod(0o644)
        with self.assertRaises(ValueError):
            self.inspect()
        self.manifest_path.chmod(0o600)
        link = self.root / "manifest-link.json"
        link.symlink_to(self.manifest_path)
        with self.assertRaises(OSError):
            RUNNER.registration_snapshot(link, "desktop-code", self.authorized)
        self.manifest_path.write_bytes(b" " * (64 * 1024 + 1))
        with self.assertRaises(ValueError):
            self.inspect()

    def test_source_outside_authority_or_linked_source_is_rejected(self):
        other = self.root / (self.session + ".jsonl")
        other.write_bytes(self.source.read_bytes())
        self.write_json(self.manifest_path, dict(self.manifest, originalTranscriptPath=str(other)))
        with self.assertRaises(ValueError):
            self.inspect()
        self.write_json(self.manifest_path, self.manifest)
        self.source.unlink()
        self.source.symlink_to(other)
        with self.assertRaises(ValueError):
            self.inspect()

    def test_source_symlink_parent_and_unbound_runtime_path_are_rejected(self):
        other = self.root / "linked-projects"
        other.symlink_to(self.authorized)
        self.write_json(self.manifest_path, dict(self.manifest, originalTranscriptPath=str(other / self.source.name)))
        with self.assertRaises(OSError):
            self.inspect()
        self.write_json(self.manifest_path, dict(self.manifest, runtimeIdentityPath=str(self.root / "other.json")))
        with self.assertRaises(ValueError):
            self.inspect()

    def test_registered_prefix_must_be_complete_nonempty_native_content(self):
        for size in (0, True, self.source.stat().st_size - 1, self.source.stat().st_size + 1):
            self.write_json(self.manifest_path, dict(self.manifest, sourceRegistrationByteCount=size))
            with self.assertRaises(ValueError):
                self.inspect()
        self.write_json(self.source, {"type": "system"})
        self.write_json(self.manifest_path, dict(self.manifest,
            sourceRegistrationByteCount=self.source.stat().st_size, sourceRegistrationSHA256=self.digest(self.source)))
        with self.assertRaises(ValueError):
            self.inspect()

    def test_duplicate_manifest_keys_are_rejected(self):
        self.manifest_path.write_text('{"schemaVersion": 1, "schemaVersion": 2}\n')
        with self.assertRaises(ValueError):
            self.inspect()

    def test_saved_source_snapshot_detects_changes_without_publishing_paths(self):
        paths = [(self.source, self.session)]
        before = RUNNER.source_bytes_snapshot(paths)
        self.assertEqual(RUNNER.source_bytes_snapshot(paths), before)
        self.source.write_bytes(self.source.read_bytes() + b"{}\n")
        self.assertNotEqual(RUNNER.source_bytes_snapshot(paths), before)

    def test_live_source_requires_append_and_preserves_every_existing_prefix(self):
        paths = [(self.source, self.session)]
        baseline = RUNNER.source_state_snapshot(paths)
        self.assertFalse(RUNNER.source_appended_since(baseline, paths))
        original = self.source.read_bytes()
        self.source.write_bytes(original + b'{"type":"system"}\n')
        self.assertTrue(RUNNER.source_appended_since(baseline, paths))
        self.source.write_bytes(original.replace(b'LEAKRET', b'CHANGED', 1) + b'{}\n')
        self.assertFalse(RUNNER.source_appended_since(baseline, paths))
        self.assertFalse(RUNNER.source_appended_since(baseline, []))

    def test_growing_inventory_or_delayed_done_cannot_prove_new_native_commit(self):
        result, complete = evidence()
        for count in (1, 2, 12):
            result['syntheticOccurrenceCount'] = count
            self.assertFalse(RUNNER.new_committed_native_marker(result, complete, complete))
        baseline = dict(complete, typedMarkers=['PROMPT'])
        self.assertTrue(RUNNER.new_committed_native_marker(result, baseline, complete))
        self.assertFalse(RUNNER.new_committed_native_marker({'syntheticOccurrenceCount': 12}, baseline, complete))
        result['claudeRoleEvidenceWithinBudget'] = False
        self.assertFalse(RUNNER.new_committed_native_marker(result, baseline, complete))

    def test_completed_saved_source_is_rejected_by_live_mode_before_app_launch(self):
        _, native = evidence()
        arguments = ['selected', '--manifest', str(self.manifest_path), '--output', str(self.root / 'report.json'),
            '--ready', str(self.root / 'ready'), '--producer-done', str(self.root / 'done'),
            '--candidate-manifest', '/fake.json', '--expected-bundle-sha256', 'a' * 64]
        with mock.patch.object(RUNNER.sys, 'argv', arguments), \
             mock.patch.object(RUNNER, 'registration_snapshot', return_value=(self.manifest, {})), \
             mock.patch.object(RUNNER, 'inspect_selected_native_source', return_value=([(self.source, self.session)], native)), \
             mock.patch.object(RUNNER.subprocess, 'Popen') as launch, \
             contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            RUNNER.main()
        launch.assert_not_called()

    def test_ready_checkpoint_requires_matching_bytes_around_native_read(self):
        before = RUNNER.source_state_snapshot([(self.source, self.session)])
        with mock.patch.object(RUNNER, 'source_state_snapshot', side_effect=[before, {}]), self.assertRaises(ValueError):
            RUNNER.native_checkpoint(self.source, self.session)


class CandidateBoundaryTests(unittest.TestCase):
    def test_binding_reuses_live_source_signature_and_bundle_checks(self):
        manifest = {"bundleSHA256": "a" * 64, "executableSHA256": "b" * 64}
        with mock.patch.object(RUNNER.live.preflight, "read_manifest", return_value=manifest), \
             mock.patch.object(RUNNER.live.preflight, "hash_file", return_value="c" * 64), \
             mock.patch.object(RUNNER.live.preflight, "check", return_value={"consistent": True}):
            bound = RUNNER.live.candidate_snapshot(Path("/fake.json"), "a" * 64, Path("/fake.app"))
            self.assertTrue(bound["recordedCandidateConsistencyPassed"])
            with self.assertRaises(ValueError):
                RUNNER.live.candidate_snapshot(Path("/fake.json"), "d" * 64, Path("/fake.app"))
            with mock.patch.object(RUNNER.live.preflight, "check", return_value={"consistent": False}), self.assertRaises(ValueError):
                RUNNER.live.candidate_snapshot(Path("/fake.json"), "a" * 64, Path("/fake.app"))
            with mock.patch.object(RUNNER.live.preflight, "hash_file", side_effect=["c" * 64, "d" * 64]), self.assertRaises(ValueError):
                RUNNER.live.candidate_snapshot(Path("/fake.json"), "a" * 64, Path("/fake.app"))

    def test_missing_candidate_or_live_sentinels_fail_before_manifest_wait(self):
        base = ["selected", "--manifest", "/absent/manifest", "--output", "/absent/output"]
        for arguments in ([], ["--candidate-manifest", "/fake.json"],
                          ["--candidate-manifest", "/fake.json", "--expected-bundle-sha256", "a" * 64]):
            with mock.patch.object(RUNNER.sys, "argv", base + arguments), \
                 contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit), \
                 mock.patch.object(RUNNER.subprocess, "Popen") as launch:
                RUNNER.main()
            launch.assert_not_called()

    def test_saved_source_rejects_live_sentinels_before_launch(self):
        arguments = ["selected", "--manifest", "/absent/manifest", "--output", "/absent/output",
            "--observation", "saved-source", "--ready", "/absent/ready", "--candidate-manifest", "/fake.json",
            "--expected-bundle-sha256", "a" * 64]
        with mock.patch.object(RUNNER.sys, "argv", arguments), contextlib.redirect_stderr(io.StringIO()), \
             self.assertRaises(SystemExit), mock.patch.object(RUNNER.subprocess, "Popen") as launch:
            RUNNER.main()
        launch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
