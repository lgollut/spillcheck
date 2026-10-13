import base64
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("omission", Path(__file__).with_name("run-app-codex-omission-recovery.py"))
omission = importlib.util.module_from_spec(spec)
spec.loader.exec_module(omission)


def digest(value):
    return base64.b64encode(bytes([value]) * 32).decode()


def report():
    return {"recoveryWorkMeasurementAvailable": True, "recoveryOmissionMeasurementAvailable": True,
        "recoveryWorkTruncated": False, "recoveryOmissionTruncated": False, "recoveryWorkRecords": [],
        "recoveryOmissionRecords": [], "recoveryCaptureIdentityMeasurementAvailable": True,
        "queueCount": 0, "recoveryQueueClaimedCount": 0, "recoveryPendingCaptureDigests": []}


def failed(value, start=1000, end=1000 + 7 * 86400 + 12):
    return {"workDigest": digest(value), "omissionDigest": digest(value + 10), "retrySelectionDigest": digest(90),
        "operation": "liveRead", "state": "terminal", "auditWindowPresent": True,
        "contentIntervalStart": start, "contentIntervalEnd": end}


def with_failures(*rows):
    return {**report(), "recoveryWorkRecords": list(rows), "recoveryOmissionRecords": [
        {"omissionDigest": row["omissionDigest"], "state": "blocked", "reason": "sourceUnavailable"} for row in rows]}


def recovered():
    older, selected = failed(1), failed(2)
    result = with_failures(older, selected)
    result.update(recoveryCodexRetryControlConsumed=True, recoveryCodexRetryActionAvailable=True,
        recoveryCodexRetryInvoked=True, recoveryCodexRetryTargetWorkDigest=selected["workDigest"],
        recoveryCodexRetryTargetOmissionDigest=selected["omissionDigest"])
    result["recoveryOmissionRecords"][1]["state"] = "recovered"
    # Copy rows because the immutable pre-retry selection must remain terminal.
    result["recoveryWorkRecords"] = copy.deepcopy(result["recoveryWorkRecords"])
    result["recoveryWorkRecords"][1]["state"] = "recovered"
    result["gapReasons"] = ["sourceUnavailable"]
    # Two overlapping genuine seven-day certificates cover the original live interval.
    for number, end in [(3, selected["contentIntervalEnd"]), (4, selected["contentIntervalStart"] + 7 * 86400)]:
        result["recoveryWorkRecords"].append({"workDigest": digest(number), "state": "completed",
            "operation": "historicalRead", "auditWindowPresent": True, "recoveryOfDigest": selected["workDigest"],
            "retrySelectionDigest": selected["retrySelectionDigest"], "certificateTargetDigest": selected["workDigest"],
            "certificateWindowStart": end - 7 * 86400, "certificateWindowEnd": end,
            "certificateCompletedAt": selected["contentIntervalEnd"] + 20})
    return older, selected, result


class OmissionRecoveryBoundaryTests(unittest.TestCase):
    def test_saved_profile_command_uses_production_install_without_collection_override(self):
        command = omission.worker_command(Path("/owned/app"), Path("/private/tmp/owned"), "0.162.1")
        self.assertIn("--acceptance-recovery-install-codex-profile", command)
        self.assertIn("--acceptance-recovery-worker", command)
        self.assertIn("--acceptance-no-profile-catchup", command)
        for flag in ("--codex-profile", "--codex-home", "--codex-active-thread", "--acceptance-cleanup-new-vault",
                     "--acceptance-vault-owner", "--acceptance-recovery-install-profile"):
            self.assertNotIn(flag, command)

    def test_setup_requires_real_connection_and_durable_binding(self):
        value = {"recoveryCodexSetupConnected": True, "recoveryCodexProfileInstalled": True,
            "recoveryCodexObservedExecutableVersion": "version", "recoveryCodexRegistrationDigest": digest(1),
            "recoveryCodexConnectionProofDigest": digest(2)}
        self.assertTrue(omission.saved_setup(value, "version"))
        for field in value:
            changed = dict(value)
            del changed[field]
            self.assertFalse(omission.saved_setup(changed, "version"))
        self.assertFalse(omission.same_saved_setup(value, {**value, "recoveryCodexConnectionProofDigest": digest(3)}))

    def test_measurement_rejects_truncation_duplicate_or_missing_identity(self):
        first = failed(1)
        valid = with_failures(first)
        omission.diagnostic_rows(valid)
        for field in ("recoveryWorkMeasurementAvailable", "recoveryOmissionMeasurementAvailable",
                      "recoveryWorkTruncated", "recoveryOmissionTruncated"):
            with self.assertRaises(omission.shared.GateFailure):
                omission.diagnostic_rows({**valid, field: not valid[field]})
        with self.assertRaises(omission.shared.GateFailure):
            omission.diagnostic_rows({**valid, "recoveryWorkRecords": [first, first]})
        with self.assertRaises(omission.shared.GateFailure):
            omission.diagnostic_rows({**valid, "recoveryOmissionRecords": [{}]})

    def test_two_failed_captures_cannot_be_one_omission_or_a_different_source(self):
        first, second = failed(1), failed(2)
        self.assertEqual(omission.terminal_addition(report(), with_failures(first)), first)
        self.assertEqual(omission.terminal_addition(with_failures(first), with_failures(first, second)), second)
        self.assertTrue(omission.both_unresolved(with_failures(first, second), first, second))
        for key in ("workDigest", "omissionDigest"):
            self.assertFalse(omission.distinct_failures(first, {**second, key: first[key]}))
        self.assertFalse(omission.distinct_failures(first, {**second, "retrySelectionDigest": digest(91)}))
        self.assertIsNone(omission.terminal_addition(report(), with_failures(first, second)))
        self.assertIsNone(omission.terminal_addition(report(), {**with_failures(first), "queueCount": 1}))

    def test_original_live_failure_requires_frozen_interval_and_real_omission(self):
        first = failed(1)
        for key, value in [("operation", "historicalRead"), ("state", "completed"), ("auditWindowPresent", False),
            ("contentIntervalStart", None), ("contentIntervalEnd", float("inf")), ("contentIntervalEnd", 999),
            ("recoveryOfDigest", digest(5)), ("certificateTargetDigest", digest(5))]:
            self.assertIsNone(omission.terminal_addition(report(), with_failures({**first, key: value})))
        changed = with_failures(first)
        changed["recoveryOmissionRecords"][0]["state"] = "recovered"
        self.assertIsNone(omission.terminal_addition(report(), changed))

    def test_selected_recovery_requires_guard_action_target_and_both_certificates(self):
        older, selected, valid = recovered()
        self.assertTrue(omission.selected_recovery(valid, older, selected))
        for key in ("recoveryCodexRetryControlConsumed", "recoveryCodexRetryActionAvailable", "recoveryCodexRetryInvoked"):
            self.assertFalse(omission.selected_recovery({**valid, key: False}, older, selected))
        for key in ("recoveryCodexRetryTargetWorkDigest", "recoveryCodexRetryTargetOmissionDigest"):
            self.assertFalse(omission.selected_recovery({**valid, key: digest(50)}, older, selected))
        missing = copy.deepcopy(valid)
        missing["recoveryWorkRecords"].pop()
        self.assertFalse(omission.selected_recovery(missing, older, selected))

    def test_ordinary_completion_or_unlinked_wrong_source_cannot_certify_recovery(self):
        older, selected, valid = recovered()
        for key, value in [("state", "terminal"), ("operation", "liveRead"), ("auditWindowPresent", False),
            ("retrySelectionDigest", digest(91)), ("certificateTargetDigest", digest(50)),
            ("certificateWindowStart", None), ("certificateCompletedAt", -1), ("recoveryOfDigest", None)]:
            changed = copy.deepcopy(valid)
            changed["recoveryWorkRecords"][2][key] = value
            self.assertFalse(omission.selected_recovery(changed, older, selected), key)

    def test_other_omission_must_stay_unresolved_and_unlinked(self):
        older, selected, valid = recovered()
        for state in ("recovered", "unrecoverable"):
            changed = copy.deepcopy(valid)
            changed["recoveryOmissionRecords"][0]["state"] = state
            self.assertFalse(omission.selected_recovery(changed, older, selected))
        changed = copy.deepcopy(valid)
        changed["recoveryWorkRecords"].append({"workDigest": digest(99), "recoveryOfDigest": older["workDigest"]})
        self.assertFalse(omission.selected_recovery(changed, older, selected))

    def test_completed_continuation_is_allowed_but_never_replaces_coverage_certificate(self):
        older, selected, valid = recovered()
        continuation = {"workDigest": digest(7), "state": "completed", "operation": "historicalRead",
            "auditWindowPresent": True, "retrySelectionDigest": selected["retrySelectionDigest"],
            "recoveryOfDigest": selected["workDigest"]}
        valid["recoveryWorkRecords"].append(continuation)
        self.assertTrue(omission.selected_recovery(valid, older, selected))
        continuation["state"] = "processing"
        self.assertFalse(omission.selected_recovery(valid, older, selected))
        for gap in ([], ["sourceUnavailable", "unsupportedContent"]):
            older, selected, valid = recovered()
            valid["gapReasons"] = gap
            self.assertFalse(omission.selected_recovery(valid, older, selected))

    def test_terminal_state_and_actions_never_return_terminal_text(self):
        labels = omission.terminal_labels("PRIVATE_ACCOUNT 8 hooks need review t trust all · enter review · esc close".encode())
        self.assertTrue(labels["eightHooksNeedReview"])
        self.assertNotIn("PRIVATE", json.dumps(labels))
        class Running:
            def poll(self):
                return None
        provider = omission.Provider.__new__(omission.Provider)
        provider.process, provider.master, provider.actions = Running(), -1, []
        provider.labels, provider.connected = {}, False
        provider.action_memory, provider.action_labels, provider.post_trust_details = b"", {}, False
        provider.memory, provider.total = b"", 0
        provider.root, provider.challenge = Path("/synthetic/work"), "exact verification challenge"
        with self.assertRaises(omission.shared.GateFailure):
            provider.action("trust")
        provider.labels = labels
        with patch.object(omission.os, "write") as write:
            with self.assertRaises(omission.shared.GateFailure):
                provider.action("trust")  # A historical footer is not the current action response.
            provider.action_labels = labels
            provider.action("trust")
            with self.assertRaises(omission.shared.GateFailure):
                provider.action("verify")  # The keypress alone does not establish trust.
            provider.observe(b"enter details - esc close")
            provider.action("verify")
            self.assertIn(b"exact verification challenge", write.call_args.args[1])
            with self.assertRaises(omission.shared.GateFailure):
                provider.action("fixture")
        with self.assertRaises(omission.shared.GateFailure):
            provider.action("arbitrary shell")

    def test_startup_and_browser_controls_remain_distinct_across_styled_redraws(self):
        startup = omission.terminal_labels(b"Hooks need review 8 hooks are new or changed. "
            b"1. Review hooks 2. Trust all and continue 3. Continue without trusting enter confirm esc skip")
        self.assertTrue(startup["startupHooksReviewMenu"])
        self.assertFalse(startup["trustAllControl"])
        browser = omission.terminal_labels(b"Lifecycle\x1b[1Chooks\x1b[1Cfrom\x1b[1Cconfig and enabled plugins. "
            b"T\x1b[1Ctrust\x1b[1Call - ENTER\x1b[1Creview - ESC\x1b[1Cclose")
        self.assertTrue(browser["hookEventsPage"])
        self.assertTrue(browser["trustAllControl"])
        self.assertFalse(browser["startupHooksReviewMenu"])
        self.assertFalse(browser["trustedDetailsControl"])
        self.assertFalse(omission.terminal_labels(b"t trust - esc back")["trustAllControl"])

    def test_review_action_requires_current_startup_menu(self):
        class Running:
            def poll(self):
                return None
        provider = omission.Provider.__new__(omission.Provider)
        provider.process, provider.master, provider.actions = Running(), -1, []
        provider.action_labels = {}
        with self.assertRaises(omission.shared.GateFailure):
            provider.action("review")
        provider.action_labels = {"startupHooksReviewMenu": True}
        with patch.object(omission.os, "write") as write:
            provider.action("review")
            self.assertEqual(write.call_args.args[1], b"1")
            self.assertEqual(provider.action_labels, {})

    def test_fixture_has_exact_fake_count_and_no_provider_child_request(self):
        prompt = omission.fixture_prompt(Path("/owned/work"))
        self.assertEqual(prompt.count(omission.TOKEN), 3)
        self.assertIn("identity exactly once", prompt)
        self.assertIn("Do not read other files", prompt)
        self.assertNotIn("spawn_agent", prompt)

    def test_owner_failure_export_retains_only_observed_controlled_diagnostics(self):
        value = {"failureCategory": "protection", "startupFailure": {"phase": "loadingDeviceKeys",
            "reason": "keyUnusable", "component": "queue", "nativeStatusCode": -25291,
            "privateError": "PRIVATE_OWNER_DATA"}, "keyID": "PRIVATE_KEY"}
        result = omission.owner_failure_summary(value)
        self.assertEqual(result["startupFailure"]["nativeStatusCode"], -25291)
        self.assertNotIn("PRIVATE", json.dumps(result))
        self.assertEqual(omission.owner_failure_summary({"failureCategory": "protection"}), {"failureCategory": "protection"})
        value["startupFailure"]["reason"] = "unknown"
        result = omission.owner_failure_summary(value)
        self.assertNotIn("nativeStatusCode", result["startupFailure"])
        self.assertNotIn("component", result["startupFailure"])

    def test_dangling_provider_home_does_not_claim_authentication_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / "codex-home"
            self.assertTrue(omission.provider_home_absent(home))
            home.symlink_to(Path(directory) / "missing")
            self.assertFalse(omission.provider_home_absent(home))
            home.unlink()
            home.mkdir(mode=0o700)
            self.assertFalse(omission.provider_home_absent(home))

    def test_live_report_replacement_retries_without_stale_provider_status(self):
        observed = []
        provider = SimpleNamespace(connected=True, fixture_collected=True)
        provider.pump = lambda: observed.append((provider.connected, provider.fixture_collected))
        running = SimpleNamespace(poll=lambda: None)
        worker = SimpleNamespace(process=running, pump=lambda: None)
        owner = SimpleNamespace(process=running)
        failures = [omission.shared.GateFailure("private-file-changed"),
            omission.shared.GateFailure("private-file-boundary"), FileNotFoundError(),
            json.JSONDecodeError("changing snapshot", "", 0), {"validated": True}]
        with patch.object(omission.shared, "private_json", side_effect=failures) as read, \
                patch.object(omission.time, "monotonic", side_effect=[0, 0.1, 0.2, 0.3, 0.4, 0.5]), \
                patch.object(omission, "saved_setup", return_value=True), \
                patch.object(omission.shared, "collected", return_value=True):
            omission.refresh_provider_status(provider, worker, owner, Path("/owned/report"), "version")
        self.assertEqual(read.call_count, 5)
        self.assertEqual(observed, [(False, False)] * 4)
        self.assertTrue(provider.connected)
        self.assertTrue(provider.fixture_collected)

    def test_persistent_or_nontransient_report_failure_stays_closed(self):
        provider = SimpleNamespace(connected=True, fixture_collected=True, pump=lambda: None)
        running = SimpleNamespace(poll=lambda: None)
        worker = SimpleNamespace(process=running, pump=lambda: None)
        owner = SimpleNamespace(process=running)
        with patch.object(omission.shared, "private_json", side_effect=omission.shared.GateFailure("private-file-boundary")), \
                patch.object(omission.time, "monotonic", side_effect=[0, 0.5, 1, 1.5, 2]):
            with self.assertRaises(omission.shared.GateFailure) as error:
                omission.refresh_provider_status(provider, worker, owner, Path("/owned/report"), "version")
        self.assertEqual(error.exception.gate, "private-report-snapshot-unavailable")
        self.assertFalse(provider.connected)
        self.assertFalse(provider.fixture_collected)
        with patch.object(omission.shared, "private_json", side_effect=omission.shared.GateFailure("duplicate-json-key")):
            with self.assertRaises(omission.shared.GateFailure) as error:
                omission.refresh_provider_status(provider, worker, owner, Path("/owned/report"), "version")
        self.assertEqual(error.exception.gate, "duplicate-json-key")

    def test_wait_report_retries_replacement_but_bounds_persistent_failure(self):
        process = omission.ReportProcess.__new__(omission.ReportProcess)
        process.process = SimpleNamespace(poll=lambda: None)
        pumps = []
        process.pump = lambda: pumps.append(True)
        predicate_inputs = []
        def predicate(value):
            predicate_inputs.append(value)
            return value.get("ready") is True
        with patch.object(omission.shared, "private_json", side_effect=[
                omission.shared.GateFailure("private-file-boundary"), {"ready": False},
                omission.shared.GateFailure("private-file-changed"), {"ready": True}]), \
                patch.object(omission.time, "sleep"), \
                patch.object(omission.time, "monotonic", side_effect=[0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6]):
            self.assertEqual(process.wait_report(Path("/owned/report"), predicate, "not-ready"), {"ready": True})
        self.assertEqual(predicate_inputs, [{"ready": False}, {"ready": True}])
        self.assertEqual(len(pumps), 4)
        with patch.object(omission.shared, "private_json", side_effect=[
                omission.shared.GateFailure("private-file-boundary"), FileNotFoundError(), FileNotFoundError()]), \
                patch.object(omission.time, "sleep"), \
                patch.object(omission.time, "monotonic", side_effect=[0, 0.1, 0.2, 1, 1.1, 2.2, 2.3]):
            with self.assertRaises(omission.shared.GateFailure) as error:
                process.wait_report(Path("/owned/report"), predicate, "not-ready")
        self.assertEqual(error.exception.gate, "private-report-snapshot-unavailable")
        self.assertEqual(predicate_inputs, [{"ready": False}, {"ready": True}])
        with patch.object(omission.shared, "private_json", side_effect=omission.shared.GateFailure("duplicate-json-key")):
            with self.assertRaises(omission.shared.GateFailure) as error:
                process.wait_report(Path("/owned/report"), predicate, "not-ready")
        self.assertEqual(error.exception.gate, "duplicate-json-key")

    def test_cold_report_absence_keeps_original_stage_deadline(self):
        process = omission.ReportProcess.__new__(omission.ReportProcess)
        process.process = SimpleNamespace(poll=lambda: None)
        process.pump = lambda: None
        with patch.object(omission.shared, "private_json", side_effect=[
                FileNotFoundError(), FileNotFoundError(), {"ready": True}]), \
                patch.object(omission.time, "sleep"), \
                patch.object(omission.time, "monotonic", side_effect=[0, 0.1, 5, 12]):
            result = process.wait_report(Path("/owned/report"), lambda row: row.get("ready"), "not-ready")
        self.assertEqual(result, {"ready": True})
        with patch.object(omission.shared, "private_json", side_effect=FileNotFoundError()), \
                patch.object(omission.time, "sleep"), \
                patch.object(omission.time, "monotonic", side_effect=[0, 0.1, 20, 40]):
            with self.assertRaises(omission.shared.GateFailure) as error:
                process.wait_report(Path("/owned/report"), lambda row: False, "not-ready")
        self.assertEqual(error.exception.gate, "not-ready")


if __name__ == "__main__":
    unittest.main()
