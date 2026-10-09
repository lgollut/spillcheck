"""Constructed settlement and settings-preservation checks, not provider evidence."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("claude_gui_gate_test", Path(__file__).with_name("run.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
REGISTRATION = "00000000-0000-0000-0000-000000000001"

def settled_report():
    return {"coldHistoryDelivery": {"exitCode": 0, "selectedSourceCount": 2},
        "coldCatchUpCore": {"exitCode": 0, "result": {
            "historicalQueueAdmissionCount": 1, "historicalSettledAdmissionCount": 1,
            "historicalProgressCount": 1, "historicalAdmissionsSettled": True,
            "occurrencesByContentType": {kind: 1 for kind in probe.REQUIRED},
            "typedCommitted": {marker: 1 for marker in probe.MAIN_MARKERS},
            "sourceLatency": {"historical": {"committedSourceRevisionCount": 2}},
            "queueCount": 0, "gapReasons": [], "replayStable": True,
            "ciphertextMarkerInspectionPassed": True}}}

def installed(value):
    result = copy.deepcopy(value)
    result.setdefault("hooks", {}).setdefault("Stop", []).append({"hooks": [{
        "type": "command", "statusMessage": "Spillcheck hook " + REGISTRATION, "command": "private-owned-command"}]})
    return result

class ProbeGateBoundaries(unittest.TestCase):
    def test_committed_content_and_empty_queue_without_audit_do_not_pass(self):
        report = settled_report()
        result = report["coldCatchUpCore"]["result"]
        for key in ("historicalQueueAdmissionCount", "historicalSettledAdmissionCount", "historicalProgressCount", "historicalAdmissionsSettled"):
            result.pop(key)
        result["gapReasons"] = ["captureRejected"]
        gate = probe.cold_gate(report)
        self.assertTrue(gate["coldRequiredContentAndChildObserved"])
        self.assertFalse(gate["coldHistoricalAuditSettlementEstablished"])
        self.assertFalse(gate["coldRequiredContentAndChildCommitted"])

    def test_complete_audit_content_replay_and_ciphertext_pass_together(self):
        self.assertTrue(probe.cold_gate(settled_report())["coldRequiredContentAndChildCommitted"])
        for field, value in (("historicalQueueAdmissionCount", True), ("historicalSettledAdmissionCount", True),
                ("historicalSettledAdmissionCount", 0), ("historicalProgressCount", 0), ("queueCount", False),
                ("ciphertextMarkerInspectionPassed", False)):
            report = settled_report()
            report["coldCatchUpCore"]["result"][field] = value
            self.assertFalse(probe.cold_gate(report)["coldRequiredContentAndChildCommitted"], field)

    def test_zero_required_marker_is_not_coverage(self):
        report = settled_report()
        report["coldCatchUpCore"]["result"]["typedCommitted"]["CHILD_PROMPT"] = 0
        self.assertFalse(probe.cold_gate(report)["coldRequiredContentAndChildCommitted"])

    def test_external_permission_addition_is_preserved_without_attributing_actor(self):
        original = {"permissions": {"allow": ["private-existing-permission"]}}
        post_install = installed(original)
        pre_remove = copy.deepcopy(post_install)
        pre_remove["permissions"]["allow"].append("private-new-permission")
        after = probe.without_registration(pre_remove, REGISTRATION)
        evidence = probe.settings_evidence(original, post_install, pre_remove, after, REGISTRATION)
        self.assertTrue(evidence["ownedInstallPreservedUnownedSettings"])
        self.assertTrue(evidence["ownedRemovalPreservedCurrentUnownedSettings"])
        self.assertTrue(evidence["onlyPermissionAdditionsBeforeOwnedRemoval"])
        self.assertEqual(evidence["settingsMismatchClassification"], "permissionAdditionsBeforeOwnedRemoval")
        self.assertFalse(evidence["settingsChangeActorEstablished"])
        self.assertNotIn("private-new-permission", str(evidence))

    def test_unowned_hook_or_permission_loss_is_not_successful_preservation(self):
        original = {"permissions": {"allow": ["private-existing-permission"]}, "hooks": {"Stop": [{
            "matcher": "*", "hooks": [{"type": "command", "command": "private-unowned-command"}]}]}}
        post_install = installed(original)
        after = {"permissions": {"allow": []}}
        evidence = probe.settings_evidence(original, post_install, post_install, after, REGISTRATION)
        self.assertFalse(evidence["ownedRemovalPreservedCurrentUnownedSettings"])
        self.assertEqual(evidence["settingsMismatchClassification"], "ownedEditChangedUnownedSettings")

    def test_initial_empty_hooks_normalization_is_distinct_from_external_change(self):
        original = {"hooks": {}}
        post_install = installed(original)
        after = probe.without_registration(post_install, REGISTRATION)
        evidence = probe.settings_evidence(original, post_install, post_install, after, REGISTRATION)
        self.assertTrue(evidence["initialEmptyHookContainerNormalized"])
        self.assertEqual(evidence["settingsMismatchClassification"], "emptyHookContainerNormalized")
        self.assertFalse(evidence["unownedSettingsChangedBeforeOwnedRemoval"])

if __name__ == "__main__":
    unittest.main()
