"""Check that missing, mismatched or unsafe evidence cannot produce a pass."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("finalizer", Path(__file__).with_name("finalize-vault-owner-evidence.py"))
finalizer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(finalizer)


def fixture():
    def summary(retained=0, obsolete=0, acknowledgement=None, alerts=0):
        return {"recordPresent": retained > 0 or obsolete > 0, "retainedValueCount": retained,
                "retainedExcerptCount": retained, "occurrenceCount": retained,
                "obsoleteAppearanceCount": obsolete, "acknowledgement": acknowledgement, "alertCount": alerts}

    def snapshot(run, original, replacement=None, receipts=1, markers=0, inaccessible=3):
        return {"runCount": run, "sameManifest": True, "queueCount": 0,
                "original": original, "replacement": replacement or summary(), "analysisReceiptCount": receipts,
                "markerCount": markers, "rememberedPayloadReferences": 3,
                "inaccessibleRememberedPayloadReferences": inaccessible, "ciphertextMarkerInspectionPassed": True}

    def app(pid, occurrences, alerts=0, events=None):
        return {"processID": pid, "acceptancePhase": "shutdown-complete", "storageReady": True,
                "collectionConfigured": True, "queueCount": 0, "occurrenceCount": occurrences, "alertCount": alerts,
                "alertsByDeliveryState": {"delivered": alerts}, "gapReasons": [], "viewingAuthorized": False,
                "revealedValueCount": 0, "revealedExcerptCount": 0, "revealedSourceMetadataCount": 0,
                "workflowEvents": events or {}}

    app_reports = [app(101, 1), app(102, 0, events={"content-removed": 1}),
                   app(103, 0, events={"acknowledge-rotated": 1, "content-removed": 1}),
                   app(104, 2, 2, {"review-confirmedSecret": 1, "marker-forgotten": 1, "notification-navigation": 1})]
    launches = [{"runIndex": index, "processID": 100 + index,
                 "sandboxMode": "unsandboxed" if index < 4 else finalizer.OFFLINE_MODE} for index in range(1, 5)]
    owner = {"passed": True, "cleanupPending": False, "ownedArtifactsRemoved": True, "ownedChildStillRunning": False,
             "stage": "completed", "createdNewManifest": True, "bootstrapAttempted": True,
             "normalExitedRunCount": 4, "runCount": 4, "appReports": app_reports,
             "snapshots": [snapshot(1, summary(1), inaccessible=0), snapshot(2, summary()),
                           snapshot(3, summary(acknowledgement="rotated"), receipts=2, markers=1),
                           snapshot(4, summary(1, obsolete=1, alerts=1), summary(1, alerts=1), receipts=5)],
             "privateValueDecryptions": 0, "existingUserHooksOrHistoriesModified": False}
    stages = []

    def stage(step, run, native, report=None):
        value = {"step": step, "runIndex": run, "observedNativeUI": native}
        if report is not None:
            value["appAcceptanceReport"] = report
        stages.append(value)

    stage("plain-content-removal", 2, {"noObsoleteAcknowledgementBeforeRemoval": True, "removedValueAndOccurrenceAbsent": True})
    stage("plain-removal-reopen", 3, {"noDetections": True, "oldSourceDidNotRestoreRemovedEntry": True})
    stage("new-original-after-plain-removal", 3, {"maskedRetainedValue": True, "occurrenceCount": 1})
    stage("rotated-acknowledgement-content-removal", 3, {"acknowledgement": "rotated"})
    stage("obsolete-marker-reopen", 4, {"markerRow": True, "acknowledgement": "rotated", "noRetainedValue": True, "occurrenceCount": 0})
    metadata_report = app(104, 0)
    metadata_report["syntheticValuePresent"] = True
    stage("reopened-marker-new-original-metadata-only", 4,
          {"noRetainedValueOrExcerpt": True, "revealControlAbsent": True, "obsoleteAppearanceLabel": True,
           "notificationIndicatorAbsent": True, "acknowledgement": "rotated", "occurrenceCount": 1}, metadata_report)
    stage("replacement-normal-alert", 4, {"maskedRetainedValue": True, "occurrenceCount": 1, "sameConversationLabel": True}, app(104, 1, 1))
    stage("offline-native-review", 4, {"reviewChanged": True, "occurrenceScoped": True})
    stage("offline-os-notification", 4, {"visibleOSNotification": True, "notificationTextMasked": True,
          "notificationClicked": True, "navigationRemainedMasked": True})
    stage("forget-obsolete-marker", 4, {"markerAbsent": True, "acknowledgementAbsent": True})
    ordinary_report = app(104, 2, 2)
    ordinary_report["syntheticOccurrenceCount"] = 1
    stage("later-original-after-forgetting", 4, {"maskedRetainedValue": True, "acknowledgementAbsent": True}, ordinary_report)
    observations = {"disposableWorkflow": True, "launches": launches, "observations": stages,
                    "scope": {"privateValueDecryptionRequested": False, "providerSessionInvoked": False,
                              "userHistoriesOrHookSettingsTouched": False}}
    receipts = {"capturedFromOwnedResponses": True, "launches": copy.deepcopy(launches)}
    return owner, observations, receipts


class EvidenceTests(unittest.TestCase):
    def test_complete_scoped_evidence_passes(self):
        report = finalizer.verify(*fixture())
        self.assertTrue(report["passed"], report["pendingOrFailedChecks"])

    def test_request_acceptance_cannot_claim_visible_or_clicked_notification(self):
        owner, observations, receipts = fixture()
        observations["observations"] = [stage for stage in observations["observations"] if stage["step"] != "offline-os-notification"]
        report = finalizer.verify(owner, observations, receipts)
        self.assertTrue(report["checks"]["offlineOSNotificationRequestAccepted"])
        self.assertFalse(report["checks"]["offlineOSNotificationVisibleAndMasked"])
        self.assertFalse(report["checks"]["offlineOSNotificationClickedToMaskedInventory"])
        self.assertFalse(report["passed"])

    def test_partial_owner_and_pending_steps_stay_incomplete(self):
        _, observations, receipts = fixture()
        observations["observations"] = observations["observations"][:6]
        report = finalizer.verify({}, observations, receipts)
        self.assertFalse(report["passed"])
        self.assertFalse(report["checks"]["ownerCleanupCompleted"])
        self.assertFalse(report["checks"]["laterAppearanceAfterForgettingOrdinary"])

    def test_payload_still_accessible_fails_deletion(self):
        owner, observations, receipts = fixture()
        owner["snapshots"][1]["inaccessibleRememberedPayloadReferences"] = 2
        report = finalizer.verify(owner, observations, receipts)
        self.assertFalse(report["checks"]["plainDeletionRemovesActiveProtectedContent"])
        self.assertFalse(report["passed"])

    def test_changed_pid_or_policy_fails_offline_join(self):
        owner, observations, receipts = fixture()
        receipts["launches"][3]["processID"] = 999
        report = finalizer.verify(owner, observations, receipts)
        self.assertFalse(report["checks"]["launchReceiptAndProcessJoins"])
        self.assertFalse(report["checks"]["offlinePolicyJoinedToSignedGUIRun"])
        self.assertFalse(report["passed"])

    def test_raw_input_fields_are_not_exported(self):
        owner, observations, receipts = fixture()
        marker = "PRIVATE_MATERIAL_MUST_NOT_BE_EXPORTED"
        owner["nonce"] = marker
        owner["snapshots"][0]["original"]["exactValue"] = marker
        owner["appReports"][3]["workflowEvents"][marker] = 1
        observations["observations"][0]["observedNativeUI"]["sourceTitle"] = marker
        observations["scope"]["source"] = marker
        receipts["launches"][3]["sourcePath"] = marker
        report = finalizer.verify(owner, observations, receipts)
        self.assertTrue(report["passed"])
        self.assertNotIn(marker, json.dumps(report))

    def test_reordered_transitions_cannot_pass(self):
        owner, observations, receipts = fixture()
        observations["observations"][-1], observations["observations"][-2] = observations["observations"][-2], observations["observations"][-1]
        report = finalizer.verify(owner, observations, receipts)
        self.assertFalse(report["checks"]["nativeTransitionOrderRecorded"])
        self.assertFalse(report["passed"])

    def test_ordinary_evaluation_does_not_require_a_duplicate_alert(self):
        owner, observations, receipts = fixture()
        owner["snapshots"][-1]["original"]["alertCount"] = 0
        report = finalizer.verify(owner, observations, receipts)
        self.assertTrue(report["checks"]["laterAppearanceAfterForgettingOrdinary"])
        self.assertTrue(report["passed"])

    def test_already_masked_lifecycle_observation_is_scoped(self):
        owner, observations, receipts = fixture()
        report = copy.deepcopy(owner["appReports"][-1])
        report["workflowEvents"] = {"mask-sessionLock": 1, "mask-sleep": 1}
        observations["observations"].append({"step": "offline-lifecycle", "runIndex": 4, "appAcceptanceReport": report})
        evidence = finalizer.verify(owner, observations, receipts)
        lifecycle = evidence["additionalLifecycleObservation"]
        self.assertTrue(lifecycle["joinedToOfflineRun"])
        self.assertTrue(lifecycle["cachesMaskedAtObservation"])
        self.assertTrue(lifecycle["sessionLockInvalidationRecorded"])
        self.assertTrue(lifecycle["sleepInvalidationRecorded"])
        self.assertFalse(lifecycle["authenticatedRevealInvalidationEstablished"])


if __name__ == "__main__":
    unittest.main()
