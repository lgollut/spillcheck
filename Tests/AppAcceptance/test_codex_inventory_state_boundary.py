import base64
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("inventory_state_runner", Path(__file__).with_name("run-app-codex-inventory-state.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def digest(value):
    return base64.b64encode(bytes([value]) * 32).decode()


def baseline():
    counts = dict.fromkeys(runner.DOMAINS, 0)
    counts.update(records=1, occurrences=7, alerts=1, analysisReceipts=9, locationReceipts=7,
        strongSignalReceipts=1, sourceKinds=9, sourceTimes=9, conversationLabels=1, valueLabels=1)
    digests, counter = {}, 10
    for key in sorted(runner.DOMAINS):
        digests[key] = [digest(number) for number in range(counter, counter + counts[key])]
        counter += counts[key]
    state = {"measured": True, "truncated": False, "phase": "baseline", "counts": counts, "digests": digests,
        "reviewCounts": {"unreviewed": 7}, "deliveryCounts": {"pending": 1}, "payloadRowCount": 17,
        "referencedPayloadCount": 17, "availableReferencedPayloadCount": 17, "nextValueLabel": 2,
        "removedLocationReceiptCount": 0, "revokedMarkerCount": 0, "schemaVersion": 1,
        "systemNotificationDeliveryEstablished": False, "actualNotificationDeliverySuppressed": True}
    return {"storageReady": True, "collectionConfigured": True, "recoveryLoadedExistingManifest": True,
        "recoveryManifestDigest": digest(1), "syntheticOccurrencesByContentType": dict(runner.COUNTS),
        "syntheticOccurrenceCount": 7, "occurrenceCount": 7, "valueCount": 1, "syntheticSessionCount": 1,
        "observedAgentVersions": ["producer"], "gapReasons": [], "coverageReportTruncated": False,
        "recoveryOccurrenceDigests": [digest(number) for number in range(190, 197)],
        "recoveryReceiptDigests": [digest(198)], "recoveryAlertDigests": [digest(199)],
        "recoveryCaptureIdentityMeasurementAvailable": True, "queueCount": 0, "recoveryQueueClaimedCount": 0,
        "recoveryPendingCaptureDigests": [], "recoveryConsumedCaptureDigests": [digest(200)],
        "recoverySuccessfullyProcessedCaptureDigests": [digest(200)], "recoveryCodexPollingStopped": True,
        "recoveryInventoryStateEnabled": True, "recoveryInventoryState": state}


def reviewed():
    report = baseline()
    state = report["recoveryInventoryState"]
    state["phase"] = "reviewed"
    state["reviewCounts"] = {"confirmedSecret": 1, "falsePositive": 1, "unreviewed": 5}
    state["deliveryCounts"] = {"delivered": 1}
    state["digests"]["occurrences"][:2] = [digest(80), digest(81)]
    state["digests"]["alerts"] = [digest(82)]
    report.update(recoveryInventoryReviewControlConsumed=True, recoveryInventoryReviewApplied=True,
        recoveryInventoryStoreReceiptSeeded=True, recoveryInventorySeededReceiptKind="live")
    return report


def removed():
    report = reviewed()
    state = report["recoveryInventoryState"]
    state["phase"] = "removed"
    for key in ("records", "occurrences", "alerts", "strongSignalReceipts"):
        state["counts"][key] = 0
        state["digests"][key] = []
    state["counts"]["obsoleteMarkers"] = 1
    state["digests"]["obsoleteMarkers"] = [digest(83)]
    state["digests"]["locationReceipts"] = [digest(number) for number in range(84, 91)]
    state.update(reviewCounts={}, deliveryCounts={}, payloadRowCount=0, referencedPayloadCount=0,
        availableReferencedPayloadCount=0, removedLocationReceiptCount=7, revokedMarkerCount=1)
    report.update(valueCount=0, occurrenceCount=0, syntheticOccurrenceCount=0, syntheticSessionCount=0,
        syntheticOccurrencesByContentType={}, observedAgentVersions=[], gapReasons=[],
        recoveryOccurrenceDigests=[], recoveryAlertDigests=[], recoveryInventoryRemovalControlConsumed=True,
        recoveryInventoryRemovalApplied=True)
    return report


def replayed(before):
    report = copy.deepcopy(before)
    for key in ("recoveryConsumedCaptureDigests", "recoverySuccessfullyProcessedCaptureDigests"):
        report[key].append(digest(201))
    report["recoveryInventoryReplay"] = {"controlConsumed": True, "queued": True, "cleanBatches": True,
        "allExpectedSourcesObserved": True, "completeProgress": True, "completionObserved": True,
        "workCompleted": True, "successfulReadMatched": True, "batchCount": 1, "bytesRead": 1000,
        "expectedSourceCount": 9, "observedSourceCount": 9, "observedContentTypes": sorted(runner.COUNTS),
        "captureDigest": digest(201), "auditDigest": digest(202)}
    return report


class InventoryStateBoundaryTests(unittest.TestCase):
    def test_workers_have_one_authorized_route_no_discovery_and_no_cleanup_authority(self):
        selected = {"home": Path("/owned/original-home"), "native": "11111111-1111-4111-8111-111111111111"}
        for name in ("worker1", "worker2", "worker3"):
            command = runner.worker_command(Path("/signed/app"), Path("/owned/root"), name,
                selection=selected, reader=Path("/real/codex"), version="reader", host="host")
            self.assertIn("--acceptance-recovery-inventory-state", command)
            self.assertIn("--acceptance-recovery-worker", command)
            self.assertIn("--acceptance-no-profile-catchup", command)
            self.assertEqual("--acceptance-allow-history-request" in command, name == "worker1")
            self.assertEqual(command.count("--codex-authorized-host"), 1)
            self.assertEqual(command[command.index("--codex-authorized-host") + 1], "t3")
            self.assertNotIn("--codex-active-thread", command)
            self.assertNotIn(selected["native"], command)
            self.assertFalse(any("install-profile" in part or "cleanup-new-vault" in part or "vault-owner" in part for part in command))
        with self.assertRaises(runner.shared.GateFailure):
            runner.worker_command(Path("/app"), Path("/owned"), "arbitrary", selection=selected,
                reader=Path("/reader"), version="reader", host="host")

    def test_initial_audit_selects_only_owned_native_source_with_fresh_identity_and_exact_swift_window(self):
        native = "11111111-1111-4111-8111-111111111111"
        with patch.object(runner.time, "time", return_value=1791720000.875):
            first = runner.initial_history_request(native)
            second = runner.initial_history_request(native)
        value, next_value = json.loads(first), json.loads(second)
        self.assertLessEqual(len(first), 4096)
        self.assertEqual(set(value), {"kind", "audit", "threads", "discovering", "selectedSourceOnly", "children", "visited", "archived"})
        self.assertEqual(value["kind"], "leakret-codex-history-v1")
        self.assertEqual(value["threads"], [native])
        self.assertFalse(value["discovering"])
        self.assertTrue(value["selectedSourceOnly"])
        self.assertEqual(value["children"], [])
        self.assertEqual(value["visited"], [])
        self.assertFalse(value["archived"])
        audit = value["audit"]
        self.assertEqual(set(audit), {"id", "reason", "start", "end"})
        self.assertEqual(audit["reason"], "restart")
        self.assertEqual(audit["end"], 1791720000 - 978307200)
        self.assertEqual(audit["start"], audit["end"] - 604800)
        self.assertIs(type(audit["end"]), int)
        self.assertIs(type(audit["start"]), int)
        self.assertEqual(str(uuid.UUID(audit["id"])), audit["id"])
        self.assertEqual(uuid.UUID(audit["id"]).version, 4)
        self.assertNotEqual(audit["id"], next_value["audit"]["id"])
        self.assertNotIn("hook_event_name", value)
        self.assertNotIn("transcriptPath", value)

    def test_initial_audit_rejects_malformed_identity_and_nonfinite_or_inexact_time(self):
        for native in (None, [], "", "arbitrary-source", "../other", "A" * 36):
            with self.subTest(native=native), self.assertRaises((runner.shared.GateFailure, ValueError, TypeError)):
                runner.initial_history_request(native)
        native = "11111111-1111-4111-8111-111111111111"
        for now in (float("nan"), float("inf"), float("-inf"), True, 2 ** 54):
            with self.subTest(now=now), patch.object(runner.time, "time", return_value=now), self.assertRaises(runner.shared.GateFailure):
                runner.initial_history_request(native)

    def test_bundled_helper_receives_only_bounded_audit_with_fixed_t3_route(self):
        captured = {}
        def bounded(command, **kwargs):
            captured.update(command=command, **kwargs)
            kwargs["cleanup_report"].update(leaderExited=True, groupKillPermissionDenied=False)
            return 0, b"{}\n", b""
        lifecycle = {"stopped": True}
        native = "11111111-1111-4111-8111-111111111111"
        with patch.object(runner.shared.live, "bounded", side_effect=bounded):
            runner.deliver(Path("/signed/helper"), Path("/owned/root"), native, lifecycle)
        self.assertTrue(lifecycle["stopped"])
        self.assertEqual(captured["command"], ["/signed/helper", "--socket", "/owned/root/protected-store/capture.sock",
            "--agent", "codex", "--interface", "t3", "--profile-id", runner.shared.PROFILE])
        self.assertEqual(json.loads(captured["input_bytes"])["threads"], [native])
        self.assertEqual(captured["timeout"], 5)
        self.assertEqual(captured["maximum_bytes"], 1024)

    def test_current_candidate_baseline_is_required_before_any_signed_launch(self):
        args = SimpleNamespace(candidate_baseline_directory=None)
        with patch.object(runner.shared, "parse_arguments", return_value=args), self.assertRaises(runner.shared.GateFailure):
            runner.arguments([])
        with patch.object(runner.setup, "ReportProcess") as process, self.assertRaises(runner.shared.GateFailure):
            runner.run(args)
        process.assert_not_called()

    def test_complete_measured_domain_values_are_required_not_only_identity_sets(self):
        valid = baseline()
        self.assertIsNotNone(runner.inventory_state(valid))
        for key, value in [("measured", False), ("truncated", True), ("phase", "unexpected"),
            ("actualNotificationDeliverySuppressed", False), ("systemNotificationDeliveryEstablished", True),
            ("schemaVersion", True), ("payloadRowCount", True), ("availableReferencedPayloadCount", 16)]:
            changed = copy.deepcopy(valid)
            changed["recoveryInventoryState"][key] = value
            with self.subTest(key=key):
                self.assertIsNone(runner.inventory_state(changed))
        for domain in runner.DOMAINS:
            changed = copy.deepcopy(valid)
            del changed["recoveryInventoryState"]["digests"][domain]
            self.assertIsNone(runner.inventory_state(changed))
        for values in (["PRIVATE RAW CONTENT"], [digest(1), digest(1)]):
            changed = copy.deepcopy(valid)
            changed["recoveryInventoryState"]["digests"]["records"] = values
            self.assertIsNone(runner.inventory_state(changed))

    def test_review_transition_changes_only_two_distinct_full_rows_and_one_delivery_receipt(self):
        old, current = baseline(), reviewed()
        self.assertTrue(runner.reviewed_transition(old, current, "producer"))
        for key, replacement in [("recoveryInventoryStoreReceiptSeeded", False),
            ("recoveryInventoryReviewApplied", False), ("recoveryInventorySeededReceiptKind", "os-delivery"),
            ("recoveryInventoryControlFailure", "postconditionFailed")]:
            self.assertFalse(runner.reviewed_transition(old, {**current, key: replacement}, "producer"))
        for domain in ("records", "analysisReceipts", "sourceTimes", "valueLabels"):
            changed = copy.deepcopy(current)
            changed["recoveryInventoryState"]["digests"][domain][0] = digest(250)
            self.assertFalse(runner.reviewed_transition(old, changed, "producer"))
        changed = copy.deepcopy(current)
        changed["recoveryInventoryState"]["digests"]["occurrences"][2] = digest(249)
        self.assertFalse(runner.reviewed_transition(old, changed, "producer"))
        self.assertFalse(runner.reviewed_transition(old, current, "wrong-producer"))

    def test_restart_compares_full_values_even_when_all_ids_and_counts_match(self):
        old = reviewed()
        self.assertTrue(runner.state_unchanged(old, copy.deepcopy(old)))
        rebooted = copy.deepcopy(old)
        rebooted["recoveryInventoryReviewApplied"] = False
        rebooted["recoveryInventoryStoreReceiptSeeded"] = False
        self.assertTrue(runner.state_unchanged(old, rebooted))
        for domain in runner.DOMAINS:
            if old["recoveryInventoryState"]["digests"][domain]:
                changed = copy.deepcopy(old)
                changed["recoveryInventoryState"]["digests"][domain][0] = digest(250)
                self.assertFalse(runner.state_unchanged(old, changed), domain)
        for key, value in [("reviewCounts", {"confirmedSecret": 2, "unreviewed": 5}),
            ("deliveryCounts", {"pending": 1}), ("nextValueLabel", 3)]:
            changed = copy.deepcopy(old)
            changed["recoveryInventoryState"][key] = value
            self.assertFalse(runner.state_unchanged(old, changed))
        self.assertFalse(runner.state_unchanged(old, {**old, "recoveryManifestDigest": digest(251)}))

    def test_removal_preserves_only_revoked_recognition_and_processed_source_receipts(self):
        old, current = reviewed(), removed()
        self.assertTrue(runner.removed_transition(old, current, "producer"))
        self.assertTrue(runner.removed(current))
        for key, value in [("payloadRowCount", 1), ("revokedMarkerCount", 0), ("removedLocationReceiptCount", 6)]:
            changed = copy.deepcopy(current)
            changed["recoveryInventoryState"][key] = value
            self.assertFalse(runner.removed(changed))
        for domain in ("analysisReceipts", "sourceKinds", "conversationLabels", "valueLabels"):
            changed = copy.deepcopy(current)
            changed["recoveryInventoryState"]["digests"][domain][0] = digest(252)
            self.assertFalse(runner.removed_transition(old, changed, "producer"))
        for gaps in (["captureRejected"], ["sourceUnavailable"], ["captureRejected", "sourceUnavailable"]):
            self.assertFalse(runner.removed({**current, "gapReasons": gaps}))

    def test_completed_source_removal_must_not_report_lost_pending_work(self):
        before, after = reviewed(), removed()
        self.assertTrue(runner.removed_transition(before, after, "producer"))
        self.assertEqual(after["gapReasons"], [])
        # Completed captures no longer have capture_value_links: their FK cascades
        # when consumeCapture removes the queue row. This fixture has no lost retry.
        rejected = {**after, "gapReasons": ["captureRejected"]}
        self.assertFalse(runner.removed(rejected))
        self.assertFalse(runner.removed_transition(before, rejected, "producer"))

    def test_single_admission_requires_same_new_digest_consumed_and_successfully_processed(self):
        old, current = reviewed(), reviewed()
        for key in ("recoveryConsumedCaptureDigests", "recoverySuccessfullyProcessedCaptureDigests"):
            current[key].append(digest(201))
        self.assertTrue(runner.new_single_processed_capture(old, current))
        for key, value in [("recoverySuccessfullyProcessedCaptureDigests", old["recoverySuccessfullyProcessedCaptureDigests"]),
            ("recoverySuccessfullyProcessedCaptureDigests", [digest(200), digest(202)]),
            ("recoveryConsumedCaptureDigests", [digest(200), digest(201), digest(202)]),
            ("recoveryPendingCaptureDigests", [digest(201)]), ("recoveryCodexPollingStopped", False), ("queueCount", 1)]:
            self.assertFalse(runner.new_single_processed_capture(old, {**current, key: value}), key)

    def test_exact_replay_requires_completed_whole_source_read_not_an_empty_poll(self):
        for before in (reviewed(), removed()):
            current = replayed(before)
            self.assertTrue(runner.exact_source_replayed(before, current))
            for key, value in [("controlConsumed", False), ("queued", False), ("cleanBatches", False),
                ("allExpectedSourcesObserved", False), ("completeProgress", False), ("completionObserved", False),
                ("workCompleted", False), ("successfulReadMatched", False), ("batchCount", 0), ("bytesRead", 0),
                ("expectedSourceCount", 8), ("observedSourceCount", 8), ("observedSourceCount", 10),
                ("observedContentTypes", ["userPrompt"]), ("captureDigest", digest(203)), ("auditDigest", digest(201))]:
                changed = copy.deepcopy(current)
                changed["recoveryInventoryReplay"][key] = value
                self.assertFalse(runner.exact_source_replayed(before, changed), key)
            changed = copy.deepcopy(current)
            changed["recoveryInventoryState"]["digests"]["analysisReceipts"][0] = digest(254)
            self.assertFalse(runner.exact_source_replayed(before, changed))
            del current["recoveryInventoryReplay"]
            self.assertFalse(runner.exact_source_replayed(before, current))

    def test_replay_control_rejects_a_consumed_control_or_stopped_pipeline(self):
        report = reviewed()
        report.update(recoveryProcessingStopped=False, recoveryInventoryReplay={"controlConsumed": False, "queued": False})
        worker = SimpleNamespace(wait_report=Mock(return_value={"result": True}))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = runner.replay_source(worker, root, "worker2", b"opaque-token", report, lambda value: True)
            self.assertEqual(result, {"result": True})
            self.assertEqual((root / runner.REPLAY_CONTROL).read_bytes(), b"opaque-token")
            with self.assertRaises(FileExistsError):
                runner.replay_source(worker, root, "worker2", b"opaque-token", report, lambda value: True)
        for update in ({"recoveryProcessingStopped": True},
            {"recoveryInventoryReplay": {"controlConsumed": True, "queued": False}}):
            with self.assertRaises(runner.shared.GateFailure):
                runner.replay_source(worker, Path("/unused"), "worker2", b"token", {**report, **update}, lambda value: True)

    def test_live_creator_is_retained_when_cleanup_cannot_be_authorized(self):
        owner = SimpleNamespace(process=SimpleNamespace(pid=42, poll=lambda: None), stop=Mock(), wait_exit=Mock())
        report = {"ownerReady": True, "createdFreshVault": True, "cleanupPassed": False}
        with tempfile.TemporaryDirectory() as directory, patch.object(runner.shared, "private_json", return_value=report):
            root = Path(directory)
            value, retained, stopped, failed = runner.finish_creator(owner, root, b"token",
                ready_observed=True, authorized=False, groups=[])
            self.assertEqual(value, report)
            self.assertTrue(retained)
            self.assertFalse(stopped)
            self.assertFalse(failed)
            self.assertFalse((root / "owner-finish").exists())
            handoff = json.loads((root / "owner-retained-private.json").read_text())
            self.assertEqual(handoff["pid"], 42)
            self.assertFalse(handoff["loadedWorkerCleanupAuthorized"])
            owner.stop.assert_not_called()
            owner.wait_exit.assert_not_called()

    def test_creator_timeout_retains_authority_even_if_report_temporarily_unreadable(self):
        owner = SimpleNamespace(process=SimpleNamespace(pid=43, poll=lambda: None), stop=Mock(),
            wait_exit=Mock(side_effect=runner.shared.GateFailure("owned-process-exit-unconfirmed")))
        with tempfile.TemporaryDirectory() as directory, patch.object(runner.shared, "private_json", side_effect=OSError):
            root = Path(directory)
            value, retained, stopped, failed = runner.finish_creator(owner, root, b"opaque-token",
                ready_observed=True, authorized=True, groups=[])
            self.assertEqual(value, {})
            self.assertTrue(retained)
            self.assertFalse(stopped)
            self.assertFalse(failed)
            self.assertEqual((root / "owner-finish").read_bytes(), b"opaque-token")
            self.assertTrue((root / "owner-retained-private.json").is_file())
            owner.stop.assert_not_called()

    def test_worker_stop_failure_cannot_authorize_creator_cleanup(self):
        worker = SimpleNamespace(process=SimpleNamespace(poll=lambda: 0), stop=Mock(side_effect=OSError("PRIVATE ERROR")))
        with patch.object(runner.shared, "private_json", return_value={"acceptancePhase": "shutdown-complete"}):
            groups, shutdowns = runner.cleanup_workers([worker], Path("/owned/root"))
        self.assertEqual(groups, [])
        self.assertFalse(shutdowns[0]["groupStopped"])
        self.assertFalse(runner.shared.safe_creator_cleanup(shutdowns, helper_stopped=True, socket_absent=True))

    def test_creator_cleanup_must_be_confirmed_before_stopping_original_owner(self):
        owner = SimpleNamespace(process=SimpleNamespace(poll=lambda: 0), stop=Mock(return_value={
            "term_permission_denied": False, "kill_permission_denied": False}))
        report = {"ownerReady": True, "createdFreshVault": True, "cleanupPassed": True}
        groups = []
        with patch.object(runner.shared, "private_json", return_value=report):
            _, retained, stopped, failed = runner.finish_creator(owner, Path("/owned/root"), b"token",
                ready_observed=True, authorized=True, groups=groups)
        self.assertFalse(retained)
        self.assertTrue(stopped)
        self.assertFalse(failed)
        owner.stop.assert_called_once()


if __name__ == "__main__":
    unittest.main()
