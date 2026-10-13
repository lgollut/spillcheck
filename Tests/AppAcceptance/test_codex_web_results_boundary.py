import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("web_results_runner", Path(__file__).with_name("run-app-codex-web-results.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
NATIVE = "11111111-1111-4111-8111-111111111111"
VERSION = "0.162.1"


def digest(number):
    return base64.b64encode(bytes([number]) * 32).decode()


def empty():
    state = {"measured": True, "truncated": False, "initialStoreEmpty": True,
        "nativeKindEvidence": "pinned-codex-results-root", "parserContract": runner.PARSER,
        "detectorVersion": runner.DETECTOR, "cleanInventory": True, "allObservedWebSourcesCommitted": False,
        "readerVersions": [], "producerVersions": [], "payloadRowCount": 0}
    state.update({key: [] for key in (*runner.STATE_DIGESTS, *runner.WEB_DIGESTS, "initialReceiptDigests", "initialSourceKindDigests")})
    state.update({key: 0 for key in ("receiptCount", "sourceCount", "sessionCount", "observedWebSourceCount",
        "committedWebSourceCount", "batchCount", "resultSegmentCount", "resultTextBytes", "resultPointerBytes")})
    return {"storageReady": True, "collectionConfigured": True, "recoveryLoadedExistingManifest": True,
        "recoveryManifestDigest": digest(1), "recoveryCodexPollingStopped": True, "coverageReportTruncated": False,
        "queueCount": 0, "recoveryQueueClaimedCount": 0, "recoveryCaptureIdentityMeasurementAvailable": True,
        "recoveryPendingCaptureDigests": [], "recoveryConsumedCaptureDigests": [],
        "recoverySuccessfullyProcessedCaptureDigests": [], "recoveryReceiptDigests": [],
        "recoveryOccurrenceDigests": [], "recoveryAlertDigests": [], "gapReasons": [], "valueCount": 0,
        "occurrenceCount": 0, "recoveryWebResultsEnabled": True, "recoveryWebResultState": state}


def baseline():
    report = empty()
    value = report["recoveryWebResultState"]
    value.update(receiptCount=3, sourceCount=3, sessionCount=1, observedWebSourceCount=1, committedWebSourceCount=1,
        batchCount=1, resultSegmentCount=12, resultTextBytes=1024, resultPointerBytes=64,
        readerVersions=[VERSION], producerVersions=[VERSION], allObservedWebSourcesCommitted=True,
        receiptDigests=[digest(i) for i in range(10, 13)], sourceKindDigests=[digest(i) for i in range(20, 23)],
        sourceTimeDigests=[digest(i) for i in range(30, 33)], webSourceDigests=[digest(40)],
        webResultDigests=[digest(41)], webReceiptDigests=[digest(42)])
    report.update(recoveryReceiptDigests=[digest(i) for i in range(50, 53)],
        recoveryConsumedCaptureDigests=[digest(60)], recoverySuccessfullyProcessedCaptureDigests=[digest(60)])
    return report


def cold():
    report = baseline()
    value = report["recoveryWebResultState"]
    value.update(initialStoreEmpty=False, initialReceiptDigests=list(value["receiptDigests"]),
        initialSourceKindDigests=list(value["sourceKindDigests"]), observedWebSourceCount=0, committedWebSourceCount=0,
        batchCount=0, resultSegmentCount=0, resultTextBytes=0, resultPointerBytes=0,
        readerVersions=[], producerVersions=[], allObservedWebSourcesCommitted=False)
    for key in runner.WEB_DIGESTS:
        value[key] = []
    report.update(recoveryConsumedCaptureDigests=[], recoverySuccessfullyProcessedCaptureDigests=[])
    report["recoveryWebResultReplay"] = {"controlConsumed": False, "queued": False}
    return report


def replayed():
    report = baseline()
    value = report["recoveryWebResultState"]
    value.update(initialStoreEmpty=False, initialReceiptDigests=list(value["receiptDigests"]),
        initialSourceKindDigests=list(value["sourceKindDigests"]))
    report.update(recoveryConsumedCaptureDigests=[digest(61)], recoverySuccessfullyProcessedCaptureDigests=[digest(61)])
    report["recoveryWebResultReplay"] = {"controlConsumed": True, "queued": True, "auditDigest": digest(62),
        "captureDigest": digest(61), "batchCount": 1, "cleanBatches": True, "expectedSourceCount": 3,
        "observedSourceCount": 3, "allExpectedSourcesObserved": True, "completeProgress": True,
        "bytesRead": 5000, "completionObserved": True, "workCompleted": True, "successfulReadMatched": True}
    return report


def events():
    return [{"type": "thread.started", "thread_id": NATIVE}, {"type": "turn.started"},
        {"type": "item.completed", "item": {"type": "web_search", "id": "search-1", "query": runner.PUBLIC_QUERY,
            "action": {"type": "search", "query": runner.PUBLIC_QUERY}}},
        {"type": "item.completed", "item": {"type": "agent_message", "text": "SPILLCHECK_WEB_PROBE_DONE"}},
        {"type": "turn.completed"}]


def output(values):
    return b"\n".join(json.dumps(value).encode() for value in values) + b"\n"


class WebResultsBoundaryTests(unittest.TestCase):
    def test_runner_fingerprint_detects_changes_to_shared_inventory_evidence(self):
        helper = "Tests/Support/inventory_evidence.py"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in (*runner.RUNNER_INPUTS, helper):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"original fixture bytes")
            with patch.object(runner, "ROOT", root):
                before = runner.runner_hashes()
                (root / helper).write_bytes(b"changed evidence checks")
                after = runner.runner_hashes()
            self.assertIn(helper, before)
            self.assertNotEqual(before, after)
            self.assertEqual({name for name in before if before[name] != after[name]}, {helper})

    def test_worker_route_has_only_exact_cli_selection_without_discovery_or_key_cleanup(self):
        for name in ("worker1", "worker2"):
            command = runner.worker_command(Path("/app"), Path("/owned"), name, home=Path("/owned/home"),
                native=NATIVE, reader=Path("/codex"), version=VERSION)
            self.assertEqual(command[command.index("--acceptance-web-source") + 1], NATIVE)
            self.assertEqual(command[command.index("--codex-authorized-host") + 1], "standalone-cli")
            self.assertEqual(command.count("--codex-authorized-host"), 1)
            self.assertIn("--acceptance-no-profile-catchup", command)
            self.assertEqual("--acceptance-allow-history-request" in command, name == "worker1")
            self.assertNotIn("--codex-active-thread", command)
            self.assertNotIn("--codex-t3-version", command)
            self.assertFalse(any("cleanup-new-vault" in value or "vault-owner" in value or "install-profile" in value for value in command))
        with self.assertRaises(runner.shared.GateFailure):
            runner.worker_command(Path("/app"), Path("/owned"), "worker1", home=Path("/personal/home"),
                native=NATIVE, reader=Path("/codex"), version=VERSION)

    def test_public_prompt_contains_marker_only_in_final_instruction_not_query(self):
        lines = runner.PROMPT.splitlines()
        self.assertEqual(lines[1], "Perform exactly one built-in web search for: site:developers.openai.com Codex app-server")
        self.assertEqual(sum("SPILLCHECK_" in line for line in lines), 1)
        command = runner.producer_command(Path("/codex"), Path("/owned/work"))
        self.assertIn("--no-daemon", command)
        self.assertEqual(command[command.index("-s") + 1], "read-only")
        self.assertEqual(command[-1], "-")

    def test_producer_identity_needs_one_completed_search_turn_and_exact_final(self):
        self.assertEqual(runner.producer_identity(output(events())), NATIVE)
        for change in (lambda e: e.append(e[0]), lambda e: e.append(e[2]), lambda e: e.pop(2),
                lambda e: e.append({"type": "turn.failed"}),
                lambda e: e[2]["item"].update(type="command_execution"),
                lambda e: e[3]["item"].update(text="echo of search, not done")):
            value = events()
            change(value)
            with self.assertRaises((runner.shared.GateFailure, ValueError)):
                runner.producer_identity(output(value))
        with self.assertRaises(runner.shared.GateFailure):
            runner.producer_identity(b'{"type":"thread.started","type":"turn.completed"}\n')
        with self.assertRaises(runner.shared.GateFailure):
            runner.exec_event(json.dumps({str(index): index for index in range(257)}))
        with self.assertRaises(runner.shared.GateFailure):
            runner.exec_event(json.dumps({"oversize": [0] * 1025}))

    def test_completed_search_rejects_query_changes_and_other_web_actions(self):
        for mutation in (lambda item: item.update(query="private test marker"),
                lambda item: item.update(action={"type": "open_page"}),
                lambda item: item.update(action={"type": "search", "query": "other"}),
                lambda item: item.update(action={"type": "search", "queries": [runner.PUBLIC_QUERY, "other"]}),
                lambda item: item.pop("action")):
            value = events()
            mutation(value[2]["item"])
            with self.assertRaises(runner.shared.GateFailure):
                runner.producer_identity(output(value))

    def test_pinned_flattened_web_ids_are_kept_distinct_only_at_event_item(self):
        serialized = ('{"type":"item.completed","item":{"id":"item_2","type":"web_search",'
            '"id":"ws_native_owned","query":' + json.dumps(runner.PUBLIC_QUERY) + ',"action":{"type":"search"}}}')
        parsed = runner.exec_event(serialized)
        self.assertEqual(parsed["item"].exec_item_id, "item_2")
        self.assertEqual(parsed["item"]["id"], "ws_native_owned")
        lines = [json.dumps(value) for value in events()]
        lines[2] = serialized
        self.assertEqual(runner.producer_identity("\n".join(lines).encode()), NATIVE)
        for bad in (serialized.replace('"item":', '"elsewhere":'),
                serialized.replace('"item_2"', '"ws_native_owned"', 1),
                serialized.replace('"id":"ws_native_owned"', '"id":""'),
                serialized.replace('"id":"ws_native_owned"', '"id":"ws_native_owned","id":"third"'),
                serialized.replace('"type":"web_search"', '"type":"web_search","type":"web_search"'),
                serialized.replace('"query":', '"query":"other","query":'),
                '{"type":"thread.started","thread_id":"one","thread_id":"two"}',
                '{"type":"item.completed","item":{"type":"web_search","action":{"id":"item_2","type":"web_search","id":"native"}}}'):
            with self.assertRaises(runner.shared.GateFailure):
                runner.exec_event(bad)

    def test_fresh_worker_requires_empty_receipts_and_sources_before_admission(self):
        self.assertTrue(runner.fresh(empty()))
        for key in (*runner.STATE_DIGESTS, *runner.WEB_DIGESTS, "initialReceiptDigests", "initialSourceKindDigests"):
            value = empty()
            value["recoveryWebResultState"][key] = [digest(9)]
            self.assertFalse(runner.fresh(value), key)
        value = empty()
        value["recoveryReceiptDigests"] = [digest(9)]
        self.assertFalse(runner.fresh(value))

    def test_positive_result_bytes_need_exact_full_detector_receipt_and_native_parser(self):
        self.assertTrue(runner.scanned(baseline(), VERSION))
        for key, bad in (("detectorVersion", runner.DETECTOR + "+partial"),
                ("detectorVersion", runner.DETECTOR + "+reduced"), ("parserContract", "older"),
                ("nativeKindEvidence", "query-echo"), ("resultSegmentCount", 0), ("resultTextBytes", 0),
                ("resultPointerBytes", 0), ("allObservedWebSourcesCommitted", False),
                ("cleanInventory", False), ("payloadRowCount", 1), ("readerVersions", ["old"]), ("producerVersions", ["other"]),
                ("webReceiptDigests", []), ("webResultDigests", []), ("sessionCount", 2), ("truncated", True)):
            value = baseline()
            value["recoveryWebResultState"][key] = bad
            self.assertFalse(runner.scanned(value, VERSION), (key, bad))

    def test_counts_and_digest_sets_reject_duplicates_missing_and_bool_counts(self):
        for key, bad in (("receiptCount", True), ("receiptCount", 4), ("sourceTimeDigests", []),
                ("receiptDigests", [digest(10)] * 3), ("webResultDigests", ["not-a-digest"])):
            value = baseline()
            value["recoveryWebResultState"][key] = bad
            self.assertIsNone(runner.state(value), key)

    def test_cold_restart_restores_full_state_before_any_native_read(self):
        self.assertTrue(runner.cold_restored(baseline(), cold()))
        for key in (*runner.STATE_DIGESTS, "initialReceiptDigests", "initialSourceKindDigests"):
            value = cold()
            value["recoveryWebResultState"][key][0] = digest(99)
            self.assertFalse(runner.cold_restored(baseline(), value), key)
        self.assertFalse(runner.cold_restored(baseline(), baseline()))
        value = cold()
        value["recoveryManifestDigest"] = digest(99)
        self.assertFalse(runner.cold_restored(baseline(), value))

    def test_actual_reread_requires_new_successful_capture_and_complete_positive_audit(self):
        self.assertTrue(runner.replayed(baseline(), cold(), replayed(), VERSION))
        for key in ("controlConsumed", "queued", "cleanBatches", "allExpectedSourcesObserved",
                "completeProgress", "completionObserved", "workCompleted", "successfulReadMatched"):
            value = replayed()
            value["recoveryWebResultReplay"][key] = False
            self.assertFalse(runner.replayed(baseline(), cold(), value, VERSION), key)
        for key, bad in (("bytesRead", 0), ("observedSourceCount", 2), ("expectedSourceCount", 4),
                ("captureDigest", digest(80)), ("auditDigest", digest(61))):
            value = replayed()
            value["recoveryWebResultReplay"][key] = bad
            self.assertFalse(runner.replayed(baseline(), cold(), value, VERSION), key)
        value = replayed()
        value["recoverySuccessfullyProcessedCaptureDigests"] = []
        self.assertFalse(runner.replayed(baseline(), cold(), value, VERSION))

    def test_reread_rejects_changed_result_bytes_revision_receipt_or_inventory(self):
        for key in (*runner.WEB_DIGESTS, *runner.STATE_DIGESTS):
            value = replayed()
            value["recoveryWebResultState"][key][0] = digest(99)
            self.assertFalse(runner.replayed(baseline(), cold(), value, VERSION), key)
        for key, bad in (("gapReasons", ["captureRejected"]), ("queueCount", 1),
                ("recoveryAlertDigests", [digest(99)]), ("valueCount", 1), ("recoveryReceiptDigests", ["bad"])):
            value = replayed()
            value[key] = bad
            self.assertFalse(runner.replayed(baseline(), cold(), value, VERSION), key)

    def test_owned_source_hash_refuses_foreign_or_additional_rollouts_and_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "home"
            home.mkdir()
            identity = (home.stat().st_dev, home.stat().st_ino)
            directory = home / "sessions/2026/10/12"
            directory.mkdir(parents=True)
            source = directory / ("rollout-owned-" + NATIVE + ".jsonl")
            source.write_bytes(b'{"fake":"public-only"}\n')
            before = runner.source_snapshot(home, identity, NATIVE)
            source.write_bytes(b'{"fake":"changed"}\n')
            self.assertNotEqual(before, runner.source_snapshot(home, identity, NATIVE))
            extra = directory / "foreign.jsonl"
            extra.write_bytes(b"{}")
            with self.assertRaises(runner.shared.GateFailure):
                runner.source_snapshot(home, identity, NATIVE)
            extra.unlink()
            source.unlink()
            source.symlink_to("/unowned/missing")
            with self.assertRaises((OSError, ValueError, runner.shared.GateFailure)):
                runner.source_snapshot(home, identity, NATIVE)

    def test_auth_cleanup_does_not_follow_replaced_home_or_auth_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "home"
            home.mkdir()
            identity = (home.stat().st_dev, home.stat().st_ino)
            auth = home / "auth.json"
            auth.write_bytes(b"owned fake auth")
            self.assertTrue(runner.remove_auth(home, identity))
            auth.symlink_to("/unowned/missing")
            with self.assertRaises(runner.shared.GateFailure):
                runner.remove_auth(home, identity)
            auth.unlink()
            home.rmdir()
            home.symlink_to("/unowned/missing")
            with self.assertRaises(runner.shared.GateFailure):
                runner.remove_auth(home, identity)

    def test_helper_exit_zero_without_successful_capture_is_not_proof(self):
        value = baseline()
        value["recoverySuccessfullyProcessedCaptureDigests"] = []
        self.assertFalse(runner.inventory.new_single_processed_capture(empty(), value))
        lifetime = {"stopped": True}
        def call(*args, **kwargs):
            kwargs["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=False)
            return 0, b"{}\n", 1
        with patch.object(runner.shared.live, "bounded", side_effect=call) as bounded:
            runner.deliver(Path("/helper"), Path("/owned"), NATIVE, lifetime)
        payload = json.loads(bounded.call_args.kwargs["input_bytes"])
        self.assertEqual(payload["threads"], [NATIVE])
        self.assertTrue(payload["selectedSourceOnly"])
        self.assertFalse(payload["discovering"])
        self.assertEqual(payload["children"], [])
        self.assertEqual(payload["audit"]["end"] - payload["audit"]["start"], 604800)

    def test_producer_shutdown_is_attempted_before_pipe_close_even_on_handoff_failure(self):
        order = []
        process = Mock(pid=123)
        process.poll.return_value = 0
        for key in ("stdin", "stdout", "stderr"):
            getattr(process, key).close.side_effect = lambda key=key: order.append(key + "-close")
        lifetime = {"stopped": True}
        def stop(_):
            order.append("stop")
            return {"term_permission_denied": False, "kill_permission_denied": False}
        with patch.object(runner.subprocess, "Popen", return_value=process), \
                patch.object(runner.lifecycle, "process_handoff", side_effect=OSError()), \
                patch.object(runner.shared, "stop_group", side_effect=stop):
            with self.assertRaises(OSError):
                runner.run_producer(Path("/codex"), Path("/owned/home"), Path("/owned/work"), Path("/owned"), lifetime)
        self.assertEqual(order[0], "stop")
        self.assertTrue(lifetime["stopped"])

    def test_pre_spawn_failure_has_no_unstopped_process_or_stranded_selector(self):
        lifetime = {"stopped": True}
        selector = Mock()
        with patch.object(runner.selectors, "DefaultSelector", return_value=selector), \
                patch.object(runner.subprocess, "Popen", side_effect=OSError()), \
                patch.object(runner.shared, "stop_group") as stop:
            with self.assertRaises(OSError):
                runner.run_producer(Path("/codex"), Path("/owned/home"), Path("/owned/work"), Path("/owned"), lifetime)
        self.assertTrue(lifetime["stopped"])
        selector.close.assert_called_once()
        stop.assert_not_called()

    def test_final_pass_needs_every_fixed_gate_and_boolean_true(self):
        checks = dict.fromkeys(runner.REQUIRED_CHECKS, True)
        self.assertTrue(runner.completed_checks(checks))
        for key in runner.REQUIRED_CHECKS:
            missing = dict(checks)
            del missing[key]
            self.assertFalse(runner.completed_checks(missing))
        checks[next(iter(checks))] = "passed"
        self.assertFalse(runner.completed_checks(checks))

    def test_uncertain_cleanup_preserves_ready_creator_and_never_grants_worker_deletion(self):
        owner = Mock(process=Mock(pid=123))
        owner.process.poll.return_value = None
        report = {"createdFreshVault": True, "ownerReady": True, "cleanupPassed": False}
        with patch.object(runner.shared, "private_json", return_value=report), \
                patch.object(runner.shared, "write_json") as handoff, patch.object(runner.shared, "write_new") as finish:
            result = runner.inventory.finish_creator(owner, Path("/owned"), b"x" * 32,
                ready_observed=True, authorized=False, groups=[])
        self.assertTrue(result[1])
        self.assertFalse(result[2])
        owner.stop.assert_not_called()
        finish.assert_not_called()
        self.assertFalse(handoff.call_args.args[1]["loadedWorkerCleanupAuthorized"])

    def test_unavailable_owner_stops_before_authentication_copy_or_provider_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            root = directory / "owned"
            root.mkdir()
            app, executable, manifest = directory / "app", directory / "codex", directory / "manifest.json"
            app.mkdir()
            executable.write_bytes(b"fake executable, never launched")
            manifest.write_text("{}")
            args = SimpleNamespace(app=app, executable=executable, candidate_manifest=manifest,
                expected_bundle_sha256="f" * 64, expected_version=VERSION, model="fake-model",
                auth_file=directory / "auth-must-not-be-read", output=directory / "report.json",
                private_control=directory / "control.json")
            class Artifacts:
                def __init__(self):
                    self.directory, self.report, self.passed = root, {}, False
                def __enter__(self):
                    return self
                def __exit__(self, *args):
                    return False
            artifacts, order = Artifacts(), []
            owner = Mock(process=Mock(pid=123), counts={"stdoutBytes": 0, "diagnosticBytes": 0})
            owner.process.poll.return_value = 1
            def observe(*args, **kwargs):
                order.append("version")
                kwargs["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=False)
                return VERSION
            def unavailable(*args, **kwargs):
                order.append("owner-readiness")
                raise runner.shared.GateFailure("fresh-owner-unavailable")
            owner.wait_report.side_effect = unavailable
            with patch.object(runner.shared, "AcceptanceArtifacts", return_value=artifacts), \
                    patch.object(runner.shared.preflight, "read_manifest", return_value={"bundleSHA256": "f" * 64}), \
                    patch.object(runner.shared.preflight, "hash_file", return_value="f" * 64), \
                    patch.object(runner.shared.preflight, "check", return_value={"consistent": True}), \
                    patch.object(runner.shared.live, "observe_version", side_effect=observe), \
                    patch.object(runner.setup, "ReportProcess", return_value=owner) as process, \
                    patch.object(runner.lifecycle, "process_handoff"), \
                    patch.object(runner.shared, "private_bytes", side_effect=AssertionError("auth read before owner ready")) as auth_read, \
                    patch.object(runner, "run_producer") as producer, \
                    patch.object(runner, "source_snapshot") as source, \
                    patch.object(runner.inventory, "cleanup_workers", return_value=([], [])), \
                    patch.object(runner.inventory, "finish_creator", return_value=(
                        {"createdFreshVault": False, "cleanupPassed": False}, False, True, False)) as finish:
                self.assertEqual(runner.run(args), 1)
            self.assertEqual(order, ["version", "owner-readiness"])
            process.assert_called_once()
            self.assertIn("--acceptance-vault-owner", process.call_args.args[0])
            auth_read.assert_not_called()
            producer.assert_not_called()
            source.assert_not_called()
            self.assertFalse((root / "home/auth.json").exists())
            self.assertFalse((root / "home/config.toml").exists())
            self.assertEqual(artifacts.report["providerLaunchCount"], 0)
            self.assertEqual(artifacts.report["selectedThreadCount"], 0)
            self.assertEqual(artifacts.report["unmetGate"], "fresh-owner-unavailable")
            self.assertTrue(artifacts.report["temporaryAuthenticationRemoved"])
            self.assertFalse(finish.call_args.kwargs["ready_observed"])
            self.assertTrue(artifacts.report["ownedProtectionCleanupPending"])
            self.assertFalse(artifacts.report["passed"])


if __name__ == "__main__":
    unittest.main()
