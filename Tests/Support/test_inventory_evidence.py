"""Offline checks for shared inventory evidence and independent provider gates."""
import base64
import copy
import importlib.util
from pathlib import Path
import sys
import unittest

TESTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TESTS))
from Support.inventory_evidence import InventoryEvidence

spec = importlib.util.spec_from_file_location(
    "inventory_evidence_recovery", TESTS / "AppAcceptance/run-app-codex-recovery.py")
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)


def digest(value):
    return base64.b64encode(bytes([value]) * 32).decode()


def empty_report():
    return {"recoveryManifestDigest": digest(1), "providerStopped": "codex",
        "gapReasons": [], "recoveryInventoryStateEnabled": True,
        "recoveryInventoryState": {"actualNotificationDeliverySuppressed": True},
        "valueCount": 0, "occurrenceCount": 0,
        **{key: [] for key in (*shared.DIGEST_KEYS, "recoveryConsumedCaptureDigests",
            "recoverySuccessfullyProcessedCaptureDigests")}}


class InventoryEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.codex = InventoryEvidence(shared, {}, lambda value: value.get("providerStopped") == "codex")
        self.claude = InventoryEvidence(shared, {}, lambda value: value.get("providerStopped") == "claude")

    def test_provider_readiness_stays_independent_for_empty_state_and_new_capture(self):
        for provider, accepted, rejected in (("codex", self.codex, self.claude),
                ("claude", self.claude, self.codex)):
            with self.subTest(provider=provider):
                before = {**empty_report(), "providerStopped": provider}
                after = {**before, "recoveryConsumedCaptureDigests": [digest(2)],
                    "recoverySuccessfullyProcessedCaptureDigests": [digest(2)]}
                self.assertTrue(accepted.fresh_ready(before))
                self.assertFalse(rejected.fresh_ready(before))
                self.assertTrue(accepted.new_single_processed_capture(before, after))
                self.assertFalse(rejected.new_single_processed_capture(before, after))

    def test_a_previously_consumed_capture_cannot_count_as_a_fresh_submission(self):
        before = {**empty_report(), "recoveryConsumedCaptureDigests": [digest(2)]}
        for consumed, processed in (([digest(2)], [digest(2)]),
                ([digest(2), digest(3)], [digest(2), digest(3)])):
            with self.subTest(consumed=consumed, processed=processed):
                after = {**before, "recoveryConsumedCaptureDigests": consumed,
                    "recoverySuccessfullyProcessedCaptureDigests": processed}
                self.assertFalse(self.codex.new_single_processed_capture(before, after))

    def test_single_capture_keeps_all_prior_receipts_and_the_same_manifest(self):
        before = {**empty_report(), "recoveryConsumedCaptureDigests": [digest(2)],
            "recoverySuccessfullyProcessedCaptureDigests": [digest(2)]}
        after = {**before, "recoveryConsumedCaptureDigests": [digest(2), digest(3)],
            "recoverySuccessfullyProcessedCaptureDigests": [digest(2), digest(3)]}
        self.assertTrue(self.codex.new_single_processed_capture(before, after))
        for key, value in (("recoveryConsumedCaptureDigests", [digest(3)]),
                ("recoverySuccessfullyProcessedCaptureDigests", [digest(3)]),
                ("recoveryConsumedCaptureDigests", [digest(2), digest(3), digest(3)]),
                ("recoverySuccessfullyProcessedCaptureDigests", [digest(2), "invalid"]),
                ("recoveryManifestDigest", digest(4))):
            with self.subTest(field=key, value=value):
                self.assertFalse(self.codex.new_single_processed_capture(before, {**after, key: value}))

    def test_empty_state_requires_explicit_empty_evidence_and_notification_suppression(self):
        report = empty_report()
        self.assertTrue(self.codex.fresh_ready(report))
        for key in (*shared.DIGEST_KEYS, "recoveryConsumedCaptureDigests",
                "recoverySuccessfullyProcessedCaptureDigests"):
            for replacement in (None, [digest(2)]):
                with self.subTest(field=key, value=replacement):
                    self.assertFalse(self.codex.fresh_ready({**report, key: replacement}))
        for replacement in (False, None, 1):
            changed = copy.deepcopy(report)
            changed["recoveryInventoryState"]["actualNotificationDeliverySuppressed"] = replacement
            self.assertFalse(self.codex.fresh_ready(changed))


if __name__ == "__main__":
    unittest.main()
