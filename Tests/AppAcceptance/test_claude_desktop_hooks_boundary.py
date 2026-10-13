"""Fake-only Desktop hook coordinator boundaries; no app/provider/Keychain."""
import argparse
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

SPEC = importlib.util.spec_from_file_location("desktop_hooks", Path(__file__).with_name("run-app-claude-desktop-hooks.py"))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
VERSION = "2.1.295"


def complete_evidence():
    result = {"storageReady": True, "collectionConfigured": True, "queueCount": 0,
        "gapReasons": [], "transportRejectionCountsByStageAndReason": {}, "coverageReportTruncated": False,
        "claudeIndividualRoleCoverageMeasured": True, "claudeIndividualRoleCoveragePassed": True,
        "claudeNativeParentChildLinkVerified": True, "claudeRoleEvidenceWithinBudget": True,
        "claudeCommittedNativeParentChildPairCountByProducer": {VERSION: 1},
        "claudeTypedCommittedMarkersByRole": {role: {marker: 1 for marker in RUNNER.selected.MARKERS
            if marker.startswith("CHILD_") == (role == "child")} for role in ("parent", "child")},
        "claudeCommittedContentTypesByRole": {role: sorted(RUNNER.selected.REQUIRED) for role in ("parent", "child")},
        "observedAgentVersions": [VERSION]}
    native = {"requiredNativeFieldsValid": True, "completeJSONLFraming": True,
        "exactParentAndOwnChildFilesOnly": True, "individualNativeRoleCoverageComplete": True,
        "completeNativeParentChildPairCountByProducer": {VERSION: 1},
        "typedMarkers": sorted(RUNNER.selected.MARKERS),
        "childTypedMarkers": sorted(marker for marker in RUNNER.selected.MARKERS if marker.startswith("CHILD_")),
        "producerVersions": [VERSION]}
    return result, native


class DesktopGateTests(unittest.TestCase):
    def gate(self, result, native, **changes):
        args = dict(baseline_empty=True, before_final=True, producer_finished=True)
        args.update(changes)
        return RUNNER.ordinary_gate(result, native, VERSION, **args)

    def test_fresh_discovery_command_has_no_source_prime_or_history_escape(self):
        command = RUNNER.collector_command(Path("/owned/fake"), {"app": "/fixed/Spillcheck.app",
            "producerVersion": VERSION}, Path("/exact/fake/project"))
        for argument in ("--claude-active-source", "--claude-session", "--acceptance-allow-history-request"):
            self.assertNotIn(argument, command)
        self.assertIn("--acceptance-no-profile-catchup", command)
        self.assertIn("--acceptance-cleanup-new-vault", command)
        self.assertEqual(command[command.index("--claude-source-root") + 1], "/exact/fake/project")
        self.assertEqual({command[index + 1] for index, part in enumerate(command)
            if part == "--claude-authorized-host"}, {"standalone-cli", "desktop-code"})

    def test_complete_pair_needs_empty_start_live_growth_and_completion(self):
        result, native = complete_evidence()
        self.assertTrue(self.gate(result, native))
        for field in ("baseline_empty", "before_final", "producer_finished"):
            self.assertFalse(self.gate(result, native, **{field: False}))
        for field, value in (("queueCount", True), ("queueCount", 1), ("gapReasons", ["unsupportedContent"]),
                ("transportRejectionCountsByStageAndReason", {"frameHeader": {"invalidFrame": 1}}),
                ("coverageReportTruncated", True)):
            changed = dict(result, **{field: value})
            self.assertFalse(self.gate(changed, native))

    def test_pooled_or_legacy_child_counts_cannot_replace_complete_individual_roles(self):
        for marker in ("CHILD_INTERMEDIATE", "CHILD_TOOL_ERROR", "MCP_ERROR"):
            result, native = complete_evidence()
            native["typedMarkers"].remove(marker)
            self.assertFalse(self.gate(result, native))
        result, native = complete_evidence()
        del result["claudeTypedCommittedMarkersByRole"]["child"]["CHILD_TOOL_OUTPUT"]
        self.assertFalse(self.gate(result, native))
        result, native = complete_evidence()
        self.assertFalse(self.gate({"syntheticOccurrenceCount": 100, "syntheticNativeChildOccurrenceCount": 10}, native))

    def test_late_operator_finish_cannot_fake_pre_final_collection(self):
        result, native = complete_evidence()
        baseline = {"typedMarkers": ["PROMPT"]}
        self.assertFalse(RUNNER.new_marker_before_final(result, baseline, native, True))
        native["typedMarkers"].remove("FINAL")
        self.assertTrue(RUNNER.new_marker_before_final(result, baseline, native, True))
        self.assertFalse(RUNNER.new_marker_before_final(result, baseline, native, False))

    def test_empty_baseline_is_strict_and_unmeasured_counters_do_not_pass(self):
        report = {"storageReady": True, "collectionConfigured": True, "queueCount": 0,
            "syntheticOccurrenceCount": 0, "syntheticSessionCount": 0,
            "occurrenceCount": 0, "valueCount": 0, "alertCount": 0, "coverageReportTruncated": False,
            "gapReasons": [], "transportRejectionCountsByStageAndReason": {}}
        self.assertTrue(RUNNER.empty_baseline(report))
        for field in ("queueCount", "syntheticOccurrenceCount", "syntheticSessionCount", "occurrenceCount", "valueCount", "alertCount"):
            for value in (True, None, 1):
                self.assertFalse(RUNNER.empty_baseline(dict(report, **{field: value})))
        for value in (True, None):
            self.assertFalse(RUNNER.empty_baseline(dict(report, coverageReportTruncated=value)))

    def test_shutdown_counts_require_exact_integers_and_equal_inventory(self):
        result, native = complete_evidence()
        result.update(valueCount=1, occurrenceCount=28, alertCount=1,
            syntheticOccurrenceCount=28, syntheticSessionCount=2)
        proof = {"passed": True, "result": result, "nativeSourceEvidence": native,
            "emptyCollectorBaseline": True, "newNativeMarkerCommittedBeforeFinal": True, "producerOutcome": "complete"}
        self.assertTrue(all(RUNNER.final_collection_checks(proof, result, VERSION).values()))
        for field in RUNNER.FINAL_COUNTS:
            for changed in (True, None, result[field] + 1):
                checks = RUNNER.final_collection_checks(proof, dict(result, **{field: changed}), VERSION)
                self.assertFalse(checks["postShutdownInventoryStable"])


class PreparedProjectTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.directory = self.root / "owned"
        self.configuration = self.root / "spillcheck-storage-acceptance"
        self.calls = []
        self.real_run = subprocess.run
        self.args = argparse.Namespace(directory=self.directory, app=self.root / "Spillcheck.app",
            configuration_executable=self.configuration, producer_version=VERSION,
            candidate_manifest=self.root / "candidate.json", expected_bundle_sha256="a" * 64)
        self.binding = {"bundleSHA256": "a" * 64, "recordedCandidateConsistencyPassed": True}

    def configuration_run(self, command, **kwargs):
        self.calls.append(command)
        if command[0] != str(self.configuration):
            self.assertEqual(command[0], "/usr/bin/git")
            return self.real_run(command, **kwargs)
        path = Path(command[command.index("--settings") + 1])
        self.assertEqual(path, self.directory / "work/.claude/settings.local.json")
        state = json.loads((self.directory / "preparation-private.json").read_text())
        if "--remove-hook" in command:
            settings = json.loads(path.read_text())
            settings = RUNNER.claude_desktop.without_registration(settings, state["registrationID"])
        else:
            handler = {"type": "command", "command": str(self.args.app / "Contents/Helpers/spillcheck-hook"),
                "args": ["--socket", str(self.directory / "store/capture.sock"), "--agent", "claude-code",
                    "--interface", "standalone-cli", "--profile-id", RUNNER.PROFILE],
                "timeout": 2, "statusMessage": "Spillcheck hook " + state["registrationID"]}
            settings = {"hooks": {event: [{"hooks": [dict(handler)]}] for event in RUNNER.EVENTS}}
        path.write_text(json.dumps(settings))
        path.chmod(0o600)
        return subprocess.CompletedProcess(command, 0, b"{}", b"")

    def prepare(self):
        with mock.patch.object(RUNNER.live, "candidate_snapshot", return_value=self.binding), \
                mock.patch.object(RUNNER.subprocess, "run", side_effect=self.configuration_run):
            return RUNNER.prepare(self.args)

    def test_preparation_owns_only_new_project_and_production_hook_registration(self):
        sentinel = self.root / "unrelated-settings.json"
        sentinel.write_text("unrelated fixture")
        result = self.prepare()
        self.assertTrue(result["prepared"])
        self.assertEqual(result["ownedHookCount"], 9)
        self.assertFalse(result["signedAppLaunched"])
        self.assertFalse(result["providerLaunched"])
        self.assertEqual(sentinel.read_text(), "unrelated fixture")
        state = RUNNER.state_for(self.directory)
        settings = json.loads((self.directory / "work/.claude/settings.local.json").read_text())
        self.assertTrue(RUNNER.owned_hooks_exact(settings, state, self.directory))
        self.assertFalse((self.directory / "store").exists())
        self.assertNotIn("LEAKRET_M3_PROMPT " + RUNNER.live.fixture.SECRET, (self.directory / "MAIN.txt").read_text())
        self.assertIn("LEAKRET_M3_PROMPT " + RUNNER.live.fixture.SECRET, (self.directory / "REGISTER_MAIN.txt").read_text())
        self.assertEqual(len([c for c in self.calls if c[0] == str(self.configuration)]), 1)

    def test_existing_directory_long_socket_and_linked_root_are_rejected_before_mutation(self):
        self.directory.mkdir()
        with self.assertRaises(ValueError):
            RUNNER.prepare(self.args)
        self.directory.rmdir()
        self.args.directory = self.root / ("x" * 100)
        with self.assertRaises(ValueError):
            RUNNER.prepare(self.args)
        link = self.root / "link"
        link.symlink_to(self.root, target_is_directory=True)
        self.args.directory = link / "fresh"
        with self.assertRaises(ValueError):
            RUNNER.prepare(self.args)
        self.assertFalse((self.root / "fresh").exists())

    def test_hook_cleanup_preserves_new_permission_and_unowned_handlers(self):
        self.prepare()
        state = RUNNER.state_for(self.directory)
        path = self.directory / "work/.claude/settings.local.json"
        value = json.loads(path.read_text())
        value["permissions"] = {"allow": ["Bash(fake)"]}
        other = {"type": "command", "command": "unrelated-test-hook", "statusMessage": "other"}
        value["hooks"]["Stop"].append({"hooks": [other]})
        path.write_text(json.dumps(value))
        with mock.patch.object(RUNNER.subprocess, "run", side_effect=self.configuration_run):
            result = RUNNER.remove_hooks(self.directory, state)
        self.assertTrue(result["removed"])
        after = json.loads(path.read_text())
        self.assertEqual(after["permissions"], value["permissions"])
        self.assertEqual(after["hooks"], {"Stop": [{"hooks": [other]}]})

    def test_cleanup_handles_interrupted_install_before_snapshot(self):
        self.prepare()
        (self.directory / "installed-settings-private.json").unlink()
        with mock.patch.object(RUNNER.subprocess, "run", side_effect=self.configuration_run):
            self.assertTrue(RUNNER.remove_hooks(self.directory, RUNNER.state_for(self.directory))["removed"])
        self.assertFalse((self.directory / "work/.claude/settings.local.json").exists())

    def test_changed_mcp_configuration_is_preserved(self):
        self.prepare()
        path = self.directory / "work/.mcp.json"
        path.write_text('{"changed":"preserve"}')
        self.assertFalse(RUNNER.remove_mcp(self.directory))
        self.assertEqual(path.read_text(), '{"changed":"preserve"}')

    def test_duplicate_or_changed_owned_hook_registration_cannot_pass(self):
        self.prepare()
        state = RUNNER.state_for(self.directory)
        settings = json.loads((self.directory / "work/.claude/settings.local.json").read_text())
        settings["hooks"]["Stop"] *= 2
        self.assertFalse(RUNNER.owned_hooks_exact(settings, state, self.directory))
        settings["hooks"]["Stop"] = settings["hooks"]["Stop"][:1]
        settings["hooks"]["Stop"][0]["hooks"][0]["args"][-1] = "wrong-profile"
        self.assertFalse(RUNNER.owned_hooks_exact(settings, state, self.directory))

    def test_malformed_hook_containers_and_handlers_return_false(self):
        self.prepare()
        state = RUNNER.state_for(self.directory)
        for settings in ([], {"hooks": []}, {"hooks": {"Stop": [None]}},
                         {"hooks": {"Stop": [{"hooks": [None]}]}}):
            self.assertFalse(RUNNER.owned_hooks_exact(settings, state, self.directory))

    def test_partial_preparation_failure_removes_owned_hooks_and_mcp(self):
        original = Path.write_text
        def write(path, *args, **kwargs):
            if path.name == "MAIN.txt":
                raise OSError("private failure detail must not be exported")
            return original(path, *args, **kwargs)
        with mock.patch.object(Path, "write_text", autospec=True, side_effect=write):
            result = self.prepare()
        self.assertFalse(result["prepared"])
        self.assertTrue(result["configurationCleanup"]["cleaned"])
        self.assertFalse((self.directory / "work/.claude/settings.local.json").exists())
        self.assertFalse((self.directory / "work/.mcp.json").exists())
        self.assertTrue((self.directory / "preparation-failure.json").is_file())
        self.assertNotIn("private failure detail", json.dumps(result))

    def test_preparation_copy_failure_removes_hooks_before_mcp_exists(self):
        original = RUNNER.shutil.copyfile
        def copy(source, target, *args, **kwargs):
            if Path(target).name == "mcp_fixture.py":
                raise OSError("fixture copy denied")
            return original(source, target, *args, **kwargs)
        with mock.patch.object(RUNNER.shutil, "copyfile", side_effect=copy):
            result = self.prepare()
        self.assertFalse(result["prepared"])
        self.assertTrue(result["configurationCleanup"]["cleaned"])
        self.assertFalse((self.directory / "work/.claude/settings.local.json").exists())

    def test_interrupted_installed_snapshot_does_not_prevent_exact_owned_removal(self):
        original = RUNNER.exclusive_json
        def write(path, value):
            if path.name == "installed-settings-private.json":
                path.write_text("{")
                path.chmod(0o600)
                raise OSError("partial snapshot")
            return original(path, value)
        with mock.patch.object(RUNNER, "exclusive_json", side_effect=write):
            result = self.prepare()
        self.assertFalse(result["prepared"])
        self.assertTrue(result["configurationCleanup"]["cleaned"])
        hooks = result["configurationCleanup"]["hookCleanup"]
        self.assertFalse(hooks["installedSnapshotAvailable"])
        self.assertIsNone(hooks["ownedInstallPreservedUnownedSettings"])
        self.assertFalse((self.directory / "work/.claude/settings.local.json").exists())

    def test_one_owned_cleanup_failure_does_not_skip_the_other(self):
        self.prepare()
        with mock.patch.object(RUNNER, "remove_hooks", side_effect=RUNNER.selected.NativeEvidenceFailure("private path")):
            result = RUNNER.cleanup_configuration(self.directory, RUNNER.state_for(self.directory))
        self.assertFalse(result["cleaned"])
        self.assertFalse(result["hookCleanup"]["removed"])
        self.assertTrue(result["ownedMCPConfigurationRemoved"])
        self.assertNotIn("private path", json.dumps(result))

    def test_full_cleanup_command_removes_both_owned_registrations(self):
        self.prepare()
        with mock.patch.object(RUNNER.subprocess, "run", side_effect=self.configuration_run), \
                mock.patch.object(RUNNER.sys, "argv", ["runner", "cleanup", "--directory", str(self.directory)]), \
                contextlib.redirect_stdout(io.StringIO()):
            code = RUNNER.main()
        self.assertEqual(code, 0)
        self.assertFalse((self.directory / "work/.claude/settings.local.json").exists())
        self.assertFalse((self.directory / "work/.mcp.json").exists())

    def test_native_ownership_failure_is_a_closed_cli_error(self):
        output = io.StringIO()
        with mock.patch.object(RUNNER, "private_root", side_effect=RUNNER.selected.NativeEvidenceFailure("private source")), \
                mock.patch.object(RUNNER.sys, "argv", ["runner", "cleanup", "--directory", str(self.directory)]), \
                contextlib.redirect_stdout(output):
            code = RUNNER.main()
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(output.getvalue()), {"passed": False, "controlledFailureType": "NativeEvidenceFailure"})

    def test_successful_cleanup_does_not_turn_failed_observation_into_success_exit(self):
        with mock.patch.object(RUNNER, "observe", return_value={"passed": False, "cleaned": True}), \
                mock.patch.object(RUNNER.sys, "argv", ["runner", "observe", "--directory", str(self.directory),
                    "--output", str(self.root / "failed.json")]), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(RUNNER.main(), 1)

    def run_observe(self, *, outcome="complete", cleanup_passed=True, early_final=False, baseline_bad=False,
                    stop_failure=False, finish_failure=False, wait_failure=False, ciphertext_failure=False,
                    process_inventory=1, final_changes=None):
        self.prepare()
        complete, native = complete_evidence()
        complete.update(newVaultCleanupPassed=cleanup_passed, syntheticOccurrenceCount=28,
            syntheticSessionCount=2, valueCount=1, occurrenceCount=28, alertCount=1)
        ready = {"storageReady": True, "collectionConfigured": True, "queueCount": 0,
            "syntheticOccurrenceCount": 1 if baseline_bad else 0, "syntheticSessionCount": 0,
            "occurrenceCount": 0, "valueCount": 0, "alertCount": 0, "coverageReportTruncated": False,
            "gapReasons": [], "transportRejectionCountsByStageAndReason": {}}
        initial = dict(native, typedMarkers=["PROMPT"], individualNativeRoleCoverageComplete=False)
        middle = dict(native, typedMarkers=["PROMPT", "INTERMEDIATE"] + (["FINAL"] if early_final else []))
        source = self.directory / "native/fake-session.jsonl"
        manifest = {"originalTranscriptPath": str(source), "nativeSessionId": "fake-session", "hostVersion": "fake-host"}
        command_seen = []
        checkpoints = iter([(None, initial, {"prefix": "digest"}), (None, initial, {"prefix": "digest"}),
            ([], middle, {}), ([], native, {})])
        process = mock.Mock()
        process.returncode = None
        process.poll.side_effect = lambda: process.returncode

        def launch(command, **kwargs):
            command_seen.append(command)
            (self.directory / "store").mkdir(mode=0o700)
            (self.directory / "store/fake-ciphertext").write_bytes(b"encrypted test material")
            return process

        def wait(**kwargs):
            if not baseline_bad:
                self.assertTrue((self.directory / "ordinary-hook-proof.json").is_file())
            if not finish_failure:
                self.assertTrue((self.directory / "collector-finish").is_file())
            if wait_failure:
                raise OSError("private wait failure")
            process.returncode = 0

        process.wait.side_effect = wait
        original_write = RUNNER.exclusive_json
        def write(path, value):
            if finish_failure and path.name == "collector-finish":
                raise OSError("private finish failure")
            return original_write(path, value)

        def stop(_):
            if stop_failure:
                raise RuntimeError("private process group timeout")
            process.returncode = 0
            return {"term_permission_denied": False, "kill_permission_denied": False}

        original_inspect = RUNNER.ciphertext_clean
        def inspect(store):
            if ciphertext_failure:
                raise OSError("private ciphertext read failure")
            return original_inspect(store)

        def complete_after_observation(_):
            RUNNER.exclusive_json(self.directory / "producer-finished.json", {"outcome": outcome})

        def run(command, **kwargs):
            if command[:2] == ["/usr/bin/pgrep", "-x"]:
                return subprocess.CompletedProcess(command, process_inventory, b"", b"")
            return self.configuration_run(command, **kwargs)

        def app_report(_):
            return dict(complete, **(final_changes or {})) if process.returncode is not None else complete

        with mock.patch.object(RUNNER.subprocess, "run", side_effect=run), \
                mock.patch.object(RUNNER.subprocess, "Popen", side_effect=launch), \
                mock.patch.object(RUNNER.claude_desktop, "require_owned_project_root", return_value=self.directory / "work"), \
                mock.patch.object(RUNNER.live, "candidate_snapshot", return_value=self.binding), \
                mock.patch.object(RUNNER.selected, "registration_snapshot", return_value=(manifest, {"binding": True})), \
                mock.patch.object(RUNNER.selected, "native_checkpoint", side_effect=lambda *args: next(checkpoints)), \
                mock.patch.object(RUNNER.selected, "source_appended_since", return_value=True), \
                mock.patch.object(RUNNER.live, "wait_for_report", return_value=ready), \
                mock.patch.object(RUNNER.live, "read_report", side_effect=app_report), \
                mock.patch.object(RUNNER.live, "settled_report", return_value=complete), \
                mock.patch.object(RUNNER.time, "sleep", side_effect=complete_after_observation), \
                mock.patch.object(RUNNER, "exclusive_json", side_effect=write), \
                mock.patch.object(RUNNER, "ciphertext_clean", side_effect=inspect), \
                mock.patch.object(RUNNER, "stop_group", side_effect=stop) as stopped:
            if process_inventory != 1:
                with self.assertRaises(ValueError):
                    RUNNER.observe(argparse.Namespace(directory=self.directory, output=self.root / "result.json", duration=30))
                self.assertFalse(command_seen)
                self.assertEqual(stopped.call_count, 0)
                return None
            result = RUNNER.observe(argparse.Namespace(directory=self.directory, output=self.root / "result.json", duration=30))
        self.assertEqual(stopped.call_count, 1)
        self.assertEqual(len(command_seen), 1)
        self.assertNotIn("--claude-active-source", command_seen[0])
        self.assertNotIn("--acceptance-allow-history-request", command_seen[0])
        self.assertFalse((self.directory / "ready.json").exists())
        self.assertFalse((self.directory / "work/.claude/settings.local.json").exists())
        self.assertFalse((self.directory / "work/.mcp.json").exists())
        self.assertEqual(result["hookTransportInterface"], "standalone-cli")
        self.assertEqual(result["sourceHost"], "desktop-code")
        rendered = json.dumps(result)
        for private in (str(source), RUNNER.live.fixture.SECRET, "fake-session"):
            self.assertNotIn(private, rendered)
        return result

    def test_process_inventory_failure_never_launches_collector(self):
        self.run_observe(process_inventory=2)

    def test_late_shutdown_gap_fails_without_rewriting_successful_ordinary_proof(self):
        result = self.run_observe(final_changes={"gapReasons": ["unsupportedContent"]})
        self.assertTrue(result["ordinaryHookProof"]["passed"])
        self.assertFalse(result["finalOrdinaryHookGatePassed"])
        self.assertFalse(result["passed"])

    def test_late_shutdown_transport_rejection_fails(self):
        result = self.run_observe(final_changes={"transportRejectionCountsByStageAndReason": {"frameHeader": {"invalidFrame": 1}}})
        self.assertTrue(result["ordinaryHookProof"]["passed"])
        self.assertFalse(result["finalOrdinaryHookGatePassed"])
        self.assertFalse(result["passed"])

    def test_late_shutdown_occurrence_change_fails(self):
        result = self.run_observe(final_changes={"occurrenceCount": 29})
        self.assertTrue(result["ordinaryHookProof"]["passed"])
        self.assertTrue(result["finalOrdinaryHookGatePassed"])
        self.assertFalse(result["postShutdownInventoryStable"])
        self.assertFalse(result["passed"])

    def test_late_shutdown_queued_work_fails(self):
        result = self.run_observe(final_changes={"queueCount": 1})
        self.assertFalse(result["finalOrdinaryHookGatePassed"])
        self.assertFalse(result["passed"])

    def test_late_shutdown_loss_of_strict_role_evidence_fails(self):
        result = self.run_observe(final_changes={"claudeIndividualRoleCoveragePassed": False})
        self.assertTrue(result["ordinaryHookProof"]["passed"])
        self.assertFalse(result["finalOrdinaryHookGatePassed"])
        self.assertFalse(result["passed"])

    def test_process_group_timeout_still_removes_hooks_mcp_and_emits_failure_report(self):
        result = self.run_observe(stop_failure=True)
        self.assertFalse(result["passed"])
        self.assertEqual(result["termination"]["processGroupFailureType"], "RuntimeError")
        self.assertTrue(result["hookCleanup"]["removed"])
        self.assertTrue((self.root / "result.json").is_file())

    def test_finish_signal_failure_still_attempts_wait_stop_and_owned_configuration_cleanup(self):
        result = self.run_observe(finish_failure=True)
        self.assertFalse(result["passed"])
        self.assertFalse(result["termination"]["finishSignalWritten"])
        self.assertTrue(result["termination"]["normalWaitCompleted"])
        self.assertTrue(result["termination"]["processGroupStopped"])

    def test_normal_wait_failure_still_stops_group_and_removes_owned_configuration(self):
        result = self.run_observe(wait_failure=True)
        self.assertFalse(result["passed"])
        self.assertEqual(result["termination"]["normalWaitFailureType"], "OSError")
        self.assertTrue(result["termination"]["processGroupStopped"])

    def test_ciphertext_read_failure_preserves_report_and_blocks_pass(self):
        result = self.run_observe(ciphertext_failure=True)
        self.assertFalse(result["passed"])
        self.assertFalse(result["ciphertextMarkerInspectionPassed"])
        self.assertEqual(result["ciphertextInspectionFailureType"], "OSError")

    def test_observe_freezes_genuine_hook_proof_before_shutdown_and_cleans_owned_state(self):
        result = self.run_observe()
        self.assertTrue(result["passed"])
        self.assertTrue(result["ordinaryHookProof"]["passed"])
        self.assertFalse(result["manualCaptureInjected"])

    def test_session_limit_cannot_pass_and_still_cleans_up(self):
        result = self.run_observe(outcome="limit")
        self.assertFalse(result["passed"])
        self.assertTrue(result["hookCleanup"]["removed"])
        self.assertTrue(result["newVaultCleanupConfirmed"])

    def test_late_collection_cannot_pass_even_with_complete_content(self):
        result = self.run_observe(early_final=True)
        self.assertFalse(result["passed"])
        self.assertFalse(result["ordinaryHookProof"]["newNativeMarkerCommittedBeforeFinal"])

    def test_creator_cleanup_failure_keeps_ordinary_proof_but_blocks_overall_pass(self):
        result = self.run_observe(cleanup_passed=False)
        self.assertTrue(result["ordinaryHookProof"]["passed"])
        self.assertFalse(result["passed"])
        self.assertFalse(result["newVaultCleanupConfirmed"])

    def test_nonempty_baseline_aborts_before_ready_and_still_cleans_up(self):
        result = self.run_observe(baseline_bad=True)
        self.assertFalse(result["passed"])
        self.assertNotIn("ordinaryHookProof", result)


if __name__ == "__main__":
    unittest.main()
