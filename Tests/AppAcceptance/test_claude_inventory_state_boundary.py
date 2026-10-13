import copy
import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


runner = module("claude_inventory_runner", "run-app-claude-inventory-state.py")
fixtures = module("inventory_boundary_fixtures", "test_codex_inventory_state_boundary.py")


def report(shape):
    value = getattr(fixtures, shape)()
    value.pop("recoveryCodexPollingStopped")
    value.update(recoveryClaudePollingStopped=True, recoveryClaudeInventoryFixtureEnabled=True,
                 transportRejectionCountsByStageAndReason={})
    if value["observedAgentVersions"]:
        value["observedAgentVersions"] = [runner.VERSION]
    return value


def replay(before):
    value = fixtures.replayed(before)
    value["recoveryProcessingStopped"] = False
    return value


class ClaudeInventoryBoundaryTests(unittest.TestCase):
    def test_fixed_fixture_contains_one_original_session_seven_appearances_and_paired_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            descriptor = runner.create_fixture(root)
            self.assertTrue(runner.source_unchanged(root, descriptor))
            self.assertEqual(set(descriptor), {"schemaVersion", "sessionID", "sourcePath", "sourceSHA256"})
            source = Path(descriptor["sourcePath"])
            self.assertEqual(source, root / "claude/projects/inventory" / (descriptor["sessionID"] + ".jsonl"))
            data = source.read_bytes()
            self.assertEqual(data.count(runner.shared.TOKEN), 7)
            rows = [json.loads(line) for line in data.splitlines()]
            self.assertEqual(len(rows), 7)
            self.assertEqual({row["sessionId"] for row in rows}, {descriptor["sessionID"]})
            self.assertEqual({row["version"] for row in rows}, {runner.VERSION})
            self.assertEqual(len({row["uuid"] for row in rows}), 7)
            self.assertEqual(sum(row["type"] == "user" and row["message"]["content"][0]["type"] == "text" for row in rows), 3)
            tools = rows[3]["message"]["content"][1:]
            results = [rows[index]["message"]["content"][0] for index in (4, 5)]
            self.assertEqual([tool["id"] for tool in tools], [result["tool_use_id"] for result in results])
            self.assertEqual([result["is_error"] for result in results], [False, True])
            self.assertEqual(rows[3]["message"]["stop_reason"], "tool_use")
            self.assertEqual(rows[6]["message"]["stop_reason"], "end_turn")
            self.assertEqual(source.stat().st_mode & 0o777, 0o600)
            self.assertFalse((root / "claude/settings.json").exists())

    def test_commands_select_only_fixed_claude_route_and_never_grant_cleanup(self):
        for name in ("worker1", "worker2", "worker3"):
            command = runner.worker_command(Path("/signed/app"), Path("/owned/root"), name)
            self.assertIn("--acceptance-claude-inventory", command)
            self.assertIn("--acceptance-no-profile-catchup", command)
            self.assertEqual(command[command.index("--claude-source-root") + 1], "/owned/root/claude/projects")
            self.assertEqual(command[command.index("--claude-authorized-host") + 1], "standalone-cli")
            self.assertEqual(command[command.index("--claude-profile") + 1], runner.PROFILE)
            self.assertEqual(command.count("--claude-authorized-host"), 1)
            self.assertEqual("--acceptance-allow-history-request" in command, name == "worker1")
            self.assertFalse(any("codex" in value or "active-source" in value or "install-profile" in value
                or "vault-owner" in value or "cleanup-new-vault" in value or "executable" in value for value in command))
        with self.assertRaises(runner.shared.GateFailure):
            runner.worker_command(Path("/app"), Path("/owned"), "other")

    def test_initial_admission_is_bounded_exact_source_and_not_discovery_or_provider_hook(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            descriptor = runner.create_fixture(root)
            with patch.object(runner.time, "time", return_value=1791720000.875):
                payload = runner.initial_history_request(root, descriptor)
                second = runner.initial_history_request(root, descriptor)
            self.assertLessEqual(len(payload), 4096)
            value = json.loads(payload)
            self.assertEqual(value["pending"], [descriptor["sourcePath"]])
            self.assertEqual(value["restartSources"], value["pending"])
            self.assertEqual(value["selectedSessionID"], descriptor["sessionID"])
            self.assertEqual(value["directories"], [])
            self.assertEqual(value["deferred"], [])
            self.assertFalse(value["partial"])
            self.assertEqual(value["audit"]["end"] - value["audit"]["start"], 604800)
            self.assertNotEqual(value["audit"]["id"], json.loads(second)["audit"]["id"])
            self.assertNotIn("hook_event_name", value)

    def test_changed_original_descriptor_or_symlink_cannot_be_delivered(self):
        for mode in ("bytes", "descriptor", "symlink", "hardlink", "oversized"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                descriptor = runner.create_fixture(root)
                source = Path(descriptor["sourcePath"])
                if mode == "bytes":
                    source.write_bytes(b"changed fake content\n")
                elif mode == "descriptor":
                    (root / "claude-inventory.json").write_text("{}")
                elif mode == "oversized":
                    source.write_bytes(b"A" * (65536 + 1))
                else:
                    copied = root / "fake-copy"
                    copied.write_bytes(source.read_bytes())
                    os.chmod(copied, 0o600)
                    source.unlink()
                    if mode == "symlink":
                        source.symlink_to(copied)
                    else:
                        os.link(copied, source)
                with patch.object(runner.shared.live, "bounded") as execute:
                    with self.assertRaises((OSError, RuntimeError)):
                        runner.deliver(Path("/signed/helper"), root, descriptor, {"stopped": True})
                    execute.assert_not_called()

    def test_helper_has_exact_claude_envelope_and_bounded_lifetime(self):
        def bounded(command, **kwargs):
            self.assertEqual(command[-6:], ["--agent", "claude-code", "--interface", "standalone-cli", "--profile-id", runner.PROFILE])
            self.assertEqual(kwargs["timeout"], 5)
            self.assertEqual(kwargs["maximum_bytes"], 1024)
            kwargs["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=False)
            return 0, b"{}\n", b""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            descriptor = runner.create_fixture(root)
            lifetime = {"stopped": False}
            with patch.object(runner.shared.live, "bounded", side_effect=bounded):
                runner.deliver(Path("/helper"), root, descriptor, lifetime)
            self.assertTrue(lifetime["stopped"])

    def test_claude_monitor_and_fixed_fixture_witness_are_mandatory_without_widening_codex(self):
        value = report("baseline")
        self.assertTrue(runner.retained(value, runner.VERSION, "baseline"))
        self.assertFalse(runner.inventory.source_ready(value))
        self.assertFalse(runner.source_ready(fixtures.baseline()))
        for field, replacement in (("recoveryClaudePollingStopped", False), ("recoveryClaudeInventoryFixtureEnabled", False),
                ("recoveryInventoryControlFailure", "unexpectedInventory"), ("queueCount", 1),
                ("transportRejectionCountsByStageAndReason", {"receive.invalidPacket": 1}),
                ("transportRejectionCountsByStageAndReason", None)):
            self.assertFalse(runner.source_ready({**value, field: replacement}))

    def test_review_and_removal_compare_full_domain_values_not_counts(self):
        before, reviewed, removed = (report(shape) for shape in ("baseline", "reviewed", "removed"))
        self.assertTrue(runner.reviewed_transition(before, reviewed, runner.VERSION))
        self.assertTrue(runner.removed_transition(reviewed, removed, runner.VERSION))
        for domain in runner.DOMAINS:
            if reviewed["recoveryInventoryState"]["digests"][domain]:
                changed = copy.deepcopy(reviewed)
                changed["recoveryInventoryState"]["digests"][domain][0] = fixtures.digest(255)
                self.assertFalse(runner.state_unchanged(reviewed, changed), domain)
        for change in ({"payloadRowCount": 1}, {"revokedMarkerCount": 0}, {"removedLocationReceiptCount": 6}):
            changed = copy.deepcopy(removed)
            changed["recoveryInventoryState"].update(change)
            self.assertFalse(runner.removed_transition(reviewed, changed, runner.VERSION))

    def test_replay_requires_fresh_completed_work_positive_read_and_exact_identities_after_removal(self):
        for phase in ("reviewed", "removed"):
            before = report(phase)
            after = replay(before)
            self.assertTrue(runner.exact_source_replayed(before, after))
            for key, replacement in (("bytesRead", 0), ("allExpectedSourcesObserved", False),
                    ("workCompleted", False), ("successfulReadMatched", False), ("completionObserved", False),
                    ("completeProgress", False), ("observedSourceCount", 8), ("observedContentTypes", ["userPrompt"])):
                changed = copy.deepcopy(after)
                changed["recoveryInventoryReplay"][key] = replacement
                self.assertFalse(runner.exact_source_replayed(before, changed), (phase, key))
            for key in ("recoveryConsumedCaptureDigests", "recoverySuccessfullyProcessedCaptureDigests"):
                changed = copy.deepcopy(after)
                changed[key] = before[key]
                self.assertFalse(runner.exact_source_replayed(before, changed))

    def test_cleanup_still_requires_original_owner_and_normal_worker_shutdown(self):
        self.assertIs(runner.finish_creator, runner.inventory.finish_creator)
        self.assertIs(runner.cleanup_workers, runner.inventory.cleanup_workers)
        good = [{"exitCode": 0, "shutdownPhase": "shutdown-complete", "groupStopped": True}]
        self.assertTrue(runner.shared.safe_creator_cleanup(good, helper_stopped=True, socket_absent=True))
        for key, value in (("exitCode", 1), ("shutdownPhase", "working"), ("groupStopped", False)):
            self.assertFalse(runner.shared.safe_creator_cleanup([{**good[0], key: value}], helper_stopped=True, socket_absent=True))
        self.assertFalse(runner.shared.safe_creator_cleanup(good, helper_stopped=False, socket_absent=True))
        self.assertFalse(runner.shared.safe_creator_cleanup(good, helper_stopped=True, socket_absent=False))

    def test_three_worker_lifecycle_orders_durable_manifest_replays_and_exact_creator_cleanup(self):
        events, created = [], []
        class Journal:
            def __init__(self, root, output):
                self.directory = root / "diagnostics"
            def require_manifest(self):
                events.append("manifest-durable")
            def snapshot(self, **kwargs):
                events.append("snapshot-before-cleanup")
                return True
        class Artifacts:
            def __init__(self, prefix, output, diagnostic_journal_factory):
                self.directory = output.parent / "owned"
                self.directory.mkdir(mode=0o700)
                self.diagnostic_journal = diagnostic_journal_factory(self.directory, output)
                self.report, self.passed = {}, False
                created.append(self)
            def __enter__(self):
                return self
            def __exit__(self, kind, error, traceback):
                self.passed = kind is None and self.report["passed"] is True
                self.report["testException"] = kind is not None
                return False
        class Process:
            def __init__(self, command):
                self.root = Path(command[command.index("--acceptance-recovery-root") + 1])
                self.path = Path(command[command.index("--acceptance-report") + 1])
                self.name = self.path.name.split("-")[0]
                self.exit_code, self.state = None, {}
                self.counts = {"stdoutBytes": 0, "diagnosticBytes": 0}
                self.process = SimpleNamespace(pid=100 + len(events), poll=lambda: self.exit_code)
                if self.name != "owner":
                    assert "manifest-durable" in events
                    assert "--acceptance-vault-owner" not in command
                events.append("launch-" + self.name)
            def write(self, state):
                self.state = copy.deepcopy(state)
                self.path.unlink(missing_ok=True)
                runner.shared.write_json(self.path, self.state)
                return self.state
            def wait_report(self, path, predicate, gate, **kwargs):
                if gate == "fresh-owner-unavailable":
                    state = {"ownerReady": True, "createdFreshVault": True}
                elif gate == "empty-source-worker-unavailable":
                    state = report("baseline")
                    for key in ("valueCount", "occurrenceCount"):
                        state[key] = 0
                    for key in (*runner.shared.DIGEST_KEYS, "recoveryConsumedCaptureDigests", "recoverySuccessfullyProcessedCaptureDigests"):
                        state[key] = []
                elif gate in ("baseline-five-types-not-collected", "baseline-pending-receipt-state-unavailable"):
                    state = report("baseline")
                elif gate in ("review-processing-barrier-unavailable", "removal-processing-barrier-unavailable"):
                    state = {**self.state, "recoveryProcessingStopped": True}
                elif gate == "review-or-store-receipt-not-saved":
                    state = {**report("reviewed"), "recoveryProcessingStopped": True}
                elif gate in ("reviewed-state-not-restored", "removed-state-not-restored"):
                    state = report("reviewed" if self.name == "worker2" else "removed")
                    state.update(recoveryProcessingStopped=False,
                        recoveryInventoryReplay={"controlConsumed": False, "queued": False})
                elif gate == "exact-whole-source-replay-unverified":
                    state = replay(self.state)
                    events.append("replay-" + self.name)
                elif gate == "obsolete-content-removal-unverified":
                    state = {**report("removed"), "recoveryProcessingStopped": True}
                    events.append("remove-content")
                else:
                    raise AssertionError(gate)
                assert predicate(state), gate
                return self.write(state)
            def wait_exit(self):
                if self.name == "owner":
                    assert "snapshot-before-cleanup" in events
                    assert all("exit-" + name in events for name in ("worker1", "worker2", "worker3"))
                    self.write({**self.state, "cleanupPassed": True})
                else:
                    self.write({**self.state, "acceptancePhase": "shutdown-complete"})
                self.exit_code = 0
                events.append("exit-" + self.name)
            def stop(self):
                assert self.exit_code == 0
                return {"term_permission_denied": False, "kill_permission_denied": False}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app = root / "app"; app.mkdir()
            args = SimpleNamespace(candidate_manifest=root / "manifest.json", expected_bundle_sha256="a" * 64,
                output=root / "out.json", private_control=root / "control.json", app=app)
            with patch.object(runner.shared, "AcceptanceArtifacts", Artifacts), patch.object(runner, "InventoryJournal", Journal), \
                    patch.object(runner.setup, "ReportProcess", Process), \
                    patch.object(runner.lifecycle, "process_handoff"), patch.object(runner, "deliver"), \
                    patch.object(runner.shared, "marker_free", return_value=True), \
                    patch.object(runner.live, "candidate_snapshot", return_value={"fixed": True}), \
                    patch.object(runner.subprocess, "run", return_value=SimpleNamespace(returncode=1)):
                self.assertEqual(runner.run(args), 0)
            self.assertTrue(created[0].report["passed"])
            self.assertFalse(created[0].report["genuineProviderAcceptanceEstablished"])
            self.assertFalse(created[0].report["systemNotificationDeliveryEstablished"])
            self.assertEqual([item for item in events if item.startswith("launch-")],
                ["launch-owner", "launch-worker1", "launch-worker2", "launch-worker3"])
            self.assertLess(events.index("replay-worker2"), events.index("remove-content"))
            self.assertLess(events.index("remove-content"), events.index("replay-worker3"))
            self.assertLess(events.index("exit-worker3"), events.index("exit-owner"))

    def test_missing_candidate_or_nonfresh_output_prevents_app_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            args = SimpleNamespace(candidate_manifest=None, expected_bundle_sha256=None,
                output=root / "out.json", private_control=root / "control.json", app=root / "not-app")
            with patch.object(runner.setup, "ReportProcess") as launch:
                with self.assertRaises(runner.shared.GateFailure):
                    runner.run(args)
                args.output.touch()
                with self.assertRaises(runner.shared.GateFailure):
                    runner.run(args)
                launch.assert_not_called()

    def test_process_inventory_error_prevents_owner_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app = root / "app"
            app.mkdir()
            args = SimpleNamespace(candidate_manifest=root / "manifest.json", expected_bundle_sha256="a" * 64,
                output=root / "out.json", private_control=root / "control.json", app=app)
            for code in (0, 2):
                with self.subTest(code=code), patch.object(runner.setup, "ReportProcess") as launch, \
                        patch.object(runner.live, "candidate_snapshot", return_value={"fixed": True}), \
                        patch.object(runner.subprocess, "run", return_value=SimpleNamespace(returncode=code)):
                    with self.assertRaises(runner.shared.GateFailure):
                        runner.run(args)
                    launch.assert_not_called()
            self.assertFalse(args.private_control.exists())


if __name__ == "__main__":
    unittest.main()
