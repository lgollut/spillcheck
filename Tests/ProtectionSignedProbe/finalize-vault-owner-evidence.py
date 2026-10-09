#!/usr/bin/env python3
"""Capture masked launch receipts, then verify the signed restart/offline evidence."""
import argparse
import json
import os
from pathlib import Path
import shlex

ROOT = Path(__file__).resolve().parents[2]
OFFLINE_MODE = "network-denied-trusted-scanner-bootstrap"
DELIVERY_STATES = {"pending", "delivered", "permissionDenied", "cancelled"}
COUNT_FIELDS = {"processID", "queueCount", "valueCount", "occurrenceCount", "alertCount",
                "syntheticOccurrenceCount", "syntheticSessionCount", "revealedValueCount",
                "revealedExcerptCount", "revealedSourceMetadataCount", "runCount", "markerCount",
                "obsoleteAppearanceCount", "analysisReceiptCount", "rememberedPayloadReferences",
                "inaccessibleRememberedPayloadReferences", "ciphertextInspectedBytes",
                "retainedValueCount", "retainedExcerptCount"}
BOOL_FIELDS = {"storageReady", "collectionConfigured", "monitoringEnabled", "viewingAuthorized",
               "windowVisible", "syntheticValuePresent", "sameManifest", "recordPresent",
               "ciphertextMarkerInspectionPassed"}
NATIVE_BOOL_FIELDS = {"removedValueAndOccurrenceAbsent", "noObsoleteAcknowledgementBeforeRemoval",
                      "noDetections", "oldSourceDidNotRestoreRemovedEntry", "maskedRetainedValue",
                      "markerRow", "noRetainedValue", "noRetainedValueOrExcerpt", "revealControlAbsent",
                      "obsoleteAppearanceLabel", "notificationIndicatorAbsent", "visibleOSNotification",
                      "notificationClicked", "navigationRemainedMasked", "notificationTextMasked",
                      "reviewChanged", "occurrenceScoped", "markerAbsent", "acknowledgementAbsent", "sameConversationLabel",
                      "selectedReplacementOccurrence"}
WORKFLOW_EVENTS = {"content-removed", "marker-forgotten", "acknowledge-rotated", "acknowledge-revoked",
                   "review-confirmedSecret", "review-falsePositive", "review-unreviewed",
                   "notification-navigation", "mask-userMask", "mask-windowClose", "mask-sleep",
                   "mask-sessionLock", "mask-inactivity", "mask-authorizationFailure"}
STEPS = {"plain-content-removal", "plain-removal-reopen", "new-original-after-plain-removal",
         "rotated-acknowledgement-content-removal", "obsolete-marker-reopen",
         "reopened-marker-new-original-metadata-only", "replacement-normal-alert", "offline-native-review",
         "offline-os-notification", "forget-obsolete-marker", "later-original-after-forgetting", "offline-lifecycle"}


def count(value):
    return value if type(value) is int and value >= 0 else None


def array(value):
    return value if isinstance(value, list) else []


def read(path):
    data = path.read_bytes()
    if len(data) > 2 * 1024 * 1024:
        raise ValueError("Evidence input exceeds its bound")
    value = json.loads(data)
    if not isinstance(value, dict):
        raise ValueError("Evidence input must be a JSON object")
    return value


def write(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    os.chmod(path, 0o600)


def counters(value, allowed):
    if not isinstance(value, dict):
        return {}
    return {key: number for key, raw in value.items() if key in allowed and (number := count(raw)) is not None}


def safe_report(value, *, snapshot=False):
    if not isinstance(value, dict):
        return {}
    result = {key: number for key in COUNT_FIELDS if (number := count(value.get(key))) is not None}
    result.update({key: value[key] for key in BOOL_FIELDS if type(value.get(key)) is bool})
    acknowledgement = value.get("acknowledgement")
    if "acknowledgement" in value and (acknowledgement is None or
            type(acknowledgement) is str and acknowledgement in {"rotated", "revoked"}):
        result["acknowledgement"] = acknowledgement
    result["alertsByDeliveryState"] = counters(value.get("alertsByDeliveryState"), DELIVERY_STATES)
    result["workflowEvents"] = counters(value.get("workflowEvents"), WORKFLOW_EVENTS)
    if value.get("acceptancePhase") == "shutdown-complete":
        result["acceptancePhase"] = "shutdown-complete"
    if isinstance(value.get("gapReasons"), list):
        # Only the emptiness is needed. Untrusted reason strings are never copied.
        result["coverageGapCount"] = len(value["gapReasons"])
    if snapshot:
        result["original"] = safe_report(value.get("original"))
        result["replacement"] = safe_report(value.get("replacement"))
    return result


def safe_native(value):
    if not isinstance(value, dict):
        return {}
    result = {key: value[key] for key in NATIVE_BOOL_FIELDS if type(value.get(key)) is bool}
    for key in ["occurrenceCount", "notificationIndicatorCount"]:
        if (number := count(value.get(key))) is not None:
            result[key] = number
    if type(value.get("acknowledgement")) is str and value["acknowledgement"] in {"rotated", "revoked"}:
        result["acknowledgement"] = value["acknowledgement"]
    if type(value.get("review")) is str and value["review"] in {"unreviewed", "confirmedSecret", "falsePositive"}:
        result["review"] = value["review"]
    return result


def safe_launch(value):
    if not isinstance(value, dict) or count(value.get("runIndex")) in {None, 0} \
            or count(value.get("processID")) in {None, 0} \
            or type(value.get("sandboxMode")) is not str or value["sandboxMode"] not in {"unsandboxed", OFFLINE_MODE}:
        return None
    return {"runIndex": value["runIndex"], "processID": value["processID"], "sandboxMode": value["sandboxMode"]}


def capture(args):
    launches = []
    for path in sorted(args.responses.glob("*.json")):
        value = read(path)
        if value.get("success") is True and (launch := safe_launch(value)) is not None:
            launches.append(launch)
    launches.sort(key=lambda launch: launch["runIndex"])
    if len({launch["runIndex"] for launch in launches}) != len(launches):
        raise ValueError("Duplicate launch run indices")
    write(args.output, {"schemaVersion": 1, "capturedFromOwnedResponses": True, "launches": launches})
    print(json.dumps({"capturedLaunchCount": len(launches), "maskedOnly": True}, sort_keys=True))


def verify(owner, observations, receipts=None):
    snapshots = [safe_report(value, snapshot=True) for value in array(owner.get("snapshots")) if isinstance(value, dict)]
    app_reports = [safe_report(value) for value in array(owner.get("appReports")) if isinstance(value, dict)]
    native_launches = [launch for value in array(observations.get("launches")) if (launch := safe_launch(value)) is not None]
    receipts_launches = [launch for value in array((receipts or {}).get("launches")) if (launch := safe_launch(value)) is not None]
    launches = receipts_launches if receipts is not None else native_launches
    launch_map = {launch["runIndex"]: launch for launch in launches}
    apps_by_pid = {report["processID"]: report for report in app_reports if report.get("processID")}
    stages = {}
    stage_order = []
    duplicate_steps = False
    for value in array(observations.get("observations")):
        if not isinstance(value, dict) or type(value.get("step")) is not str or value["step"] not in STEPS:
            continue
        if value["step"] in stages:
            duplicate_steps = True
            continue
        stage = {"runIndex": count(value.get("runIndex")), "native": safe_native(value.get("observedNativeUI"))}
        if isinstance(value.get("appAcceptanceReport"), dict):
            stage["app"] = safe_report(value["appAcceptanceReport"])
        stages[value["step"]] = stage
        stage_order.append(value["step"])

    def snapshot(run):
        return next((value for value in snapshots if value.get("runCount") == run), {})

    def native(step):
        return stages.get(step, {}).get("native", {})

    def stage_app(step):
        return stages.get(step, {}).get("app", {})

    def event_total(name):
        return sum(report.get("workflowEvents", {}).get(name, 0) for report in app_reports)

    def joined(step, offline=False):
        stage = stages.get(step, {})
        launch = launch_map.get(stage.get("runIndex"), {})
        embedded = stage.get("app", {})
        return bool(launch and launch.get("processID") in apps_by_pid and
                    (not embedded or embedded.get("processID") == launch["processID"]) and
                    (not offline or launch.get("sandboxMode") == OFFLINE_MODE))

    def absent(summary):
        return summary.get("recordPresent") is False and all(summary.get(key) == 0 for key in
            ["retainedValueCount", "retainedExcerptCount", "occurrenceCount"])

    def masked(report):
        return report.get("viewingAuthorized") is False and all(report.get(key) == 0 for key in
            ["revealedValueCount", "revealedExcerptCount", "revealedSourceMetadataCount"])

    baseline, deleted, acknowledged = [snapshot(run) for run in [1, 2, 3]]
    final = snapshots[-1] if snapshots else {}
    replacement = native("replacement-normal-alert")
    metadata = native("reopened-marker-new-original-metadata-only")
    metadata_app = stage_app("reopened-marker-new-original-metadata-only")
    later_app = stage_app("later-original-after-forgetting")
    notification = native("offline-os-notification")
    lifecycle_app = stage_app("offline-lifecycle")
    offline_runs = [launch for launch in launches if launch["sandboxMode"] == OFFLINE_MODE]
    offline_apps = [apps_by_pid[launch["processID"]] for launch in offline_runs if launch["processID"] in apps_by_pid]
    all_joins = bool(launches) and len(launch_map) == len(launches) and len(apps_by_pid) == len(app_reports) and \
        len(launches) == len(app_reports) and all(launch["processID"] in apps_by_pid for launch in launches)
    receipt_match = receipts is not None and receipts.get("capturedFromOwnedResponses") is True and \
        sorted(receipts_launches, key=lambda launch: launch["runIndex"]) == sorted(native_launches, key=lambda launch: launch["runIndex"])
    transition_order = ["plain-content-removal", "plain-removal-reopen", "new-original-after-plain-removal",
                        "rotated-acknowledgement-content-removal", "obsolete-marker-reopen",
                        "reopened-marker-new-original-metadata-only", "replacement-normal-alert",
                        "forget-obsolete-marker", "later-original-after-forgetting"]
    recorded_order = [stage_order.index(step) for step in transition_order if step in stage_order]
    observation_scope = observations.get("scope") if isinstance(observations.get("scope"), dict) else {}
    preferences = observations.get("postTestPreferences")
    preferences = preferences if isinstance(preferences, dict) else {}
    safe_preferences = {key: preferences[key] for key in ["notificationsRestoredToDisabled",
        "notificationSettingVerifiedWithNativeUI", "launchAtLoginLeftOff"] if type(preferences.get(key)) is bool}
    provenance = observations.get("notificationConfirmationProvenance")
    provenance = provenance if isinstance(provenance, dict) else {}
    user_confirmation_source = provenance.get("notificationVisibleAndClicked") == "user confirmation"
    native_confirmation_source = provenance.get("selectedMatchingReplacementAndMaskedState") == \
        "native accessibility state plus actual AppRuntime notification-navigation event"
    text_confirmation_source = provenance.get("notificationTextMasked") == \
        "controlled production notification construction and user response to masked-notification test"

    checks = {
        "ownerCleanupCompleted": owner.get("passed") is True and owner.get("cleanupPending") is False and
            owner.get("ownedArtifactsRemoved") is True and owner.get("ownedChildStillRunning") is False and
            owner.get("stage") == "completed",
        "originalCreationAuthorityRetained": owner.get("createdNewManifest") is True and owner.get("bootstrapAttempted") is True,
        "allAppRunsNormalAndMasked": bool(app_reports) and owner.get("normalExitedRunCount") == len(app_reports) == owner.get("runCount") and
            all(report.get("acceptancePhase") == "shutdown-complete" and report.get("queueCount") == 0 and masked(report) for report in app_reports),
        "launchReceiptAndProcessJoins": all_joins and receipt_match,
        "sameManifestAcrossRestartInspections": {1, 2, 3, 4}.issubset({value.get("runCount") for value in snapshots}) and
            all(value.get("sameManifest") is True for value in snapshots),
        "baselineProtectedContentRemembered": baseline.get("original", {}).get("retainedValueCount") == 1 and
            baseline.get("original", {}).get("retainedExcerptCount", 0) >= 1 and baseline.get("rememberedPayloadReferences", 0) >= 3 and
            baseline.get("inaccessibleRememberedPayloadReferences") == 0,
        "plainDeletionHasNoAcknowledgement": native("plain-content-removal").get("noObsoleteAcknowledgementBeforeRemoval") is True and
            deleted.get("markerCount") == 0 and deleted.get("original", {}).get("acknowledgement") is None,
        "plainDeletionRemovesActiveProtectedContent": absent(deleted.get("original", {})) and
            deleted.get("rememberedPayloadReferences", 0) >= baseline.get("rememberedPayloadReferences", 3) and
            deleted.get("inaccessibleRememberedPayloadReferences") == deleted.get("rememberedPayloadReferences") and
            native("plain-content-removal").get("removedValueAndOccurrenceAbsent") is True and joined("plain-content-removal"),
        "plainDeletionReplayAddsNothing": native("plain-removal-reopen").get("noDetections") is True and
            native("plain-removal-reopen").get("oldSourceDidNotRestoreRemovedEntry") is True and joined("plain-removal-reopen") and
            deleted.get("analysisReceiptCount", 0) >= baseline.get("analysisReceiptCount", 1),
        "newAppearanceAfterPlainDeletionDetectable": native("new-original-after-plain-removal").get("maskedRetainedValue") is True and
            native("new-original-after-plain-removal").get("occurrenceCount", 0) >= 1 and joined("new-original-after-plain-removal") and
            acknowledged.get("analysisReceiptCount", 0) > deleted.get("analysisReceiptCount", 0),
        "acknowledgementAndRemovalPersist": acknowledged.get("markerCount") == 1 and
            acknowledged.get("original", {}).get("acknowledgement") == "rotated" and absent(acknowledged.get("original", {})) and
            event_total("acknowledge-rotated") >= 1 and event_total("content-removed") >= 2,
        "obsoleteMarkerReplayAddsNothing": native("obsolete-marker-reopen").get("markerRow") is True and
            native("obsolete-marker-reopen").get("acknowledgement") == "rotated" and
            native("obsolete-marker-reopen").get("noRetainedValue") is True and
            native("obsolete-marker-reopen").get("occurrenceCount") == 0 and joined("obsolete-marker-reopen", offline=True),
        "newObsoleteAppearanceMetadataOnlyAndSilent": all(metadata.get(key) is True for key in
            ["noRetainedValueOrExcerpt", "revealControlAbsent", "obsoleteAppearanceLabel", "notificationIndicatorAbsent"]) and
            metadata.get("acknowledgement") == "rotated" and metadata.get("occurrenceCount") == 1 and
            metadata_app.get("alertCount") == 0 and metadata_app.get("occurrenceCount") == 0 and
            metadata_app.get("queueCount") == 0 and metadata_app.get("storageReady") is True and
            metadata_app.get("collectionConfigured") is True and
            metadata_app.get("syntheticValuePresent") is True and masked(metadata_app) and
            final.get("original", {}).get("obsoleteAppearanceCount", 0) >= 1 and
            joined("reopened-marker-new-original-metadata-only", offline=True),
        "differentReplacementNormallyDetectedAndAlerted": replacement.get("maskedRetainedValue") is True and
            replacement.get("occurrenceCount", 0) >= 1 and joined("replacement-normal-alert", offline=True) and
            final.get("replacement", {}).get("retainedValueCount") == 1 and
            final.get("replacement", {}).get("occurrenceCount", 0) >= 1 and final.get("replacement", {}).get("alertCount", 0) >= 1,
        "replacementInSameConversation": replacement.get("sameConversationLabel") is True and joined("replacement-normal-alert", offline=True),
        "explicitForgettingRemovesOnlyMarker": native("forget-obsolete-marker").get("markerAbsent") is True and
            native("forget-obsolete-marker").get("acknowledgementAbsent") is True and event_total("marker-forgotten") >= 1 and
            final.get("markerCount") == 0 and final.get("original", {}).get("acknowledgement") is None and
            final.get("original", {}).get("obsoleteAppearanceCount", 0) >= 1 and joined("forget-obsolete-marker", offline=True),
        "laterAppearanceAfterForgettingOrdinary": native("later-original-after-forgetting").get("maskedRetainedValue") is True and
            native("later-original-after-forgetting").get("acknowledgementAbsent") is True and
            later_app.get("syntheticOccurrenceCount", 0) >= 1 and joined("later-original-after-forgetting", offline=True) and
            final.get("original", {}).get("retainedValueCount") == 1 and final.get("original", {}).get("retainedExcerptCount", 0) >= 1 and
            final.get("original", {}).get("occurrenceCount", 0) >= 1,
        "offlinePolicyJoinedToSignedGUIRun": bool(offline_runs) and len(offline_apps) == len(offline_runs) and receipt_match,
        "offlineCollectionScanningInventoryComplete": bool(offline_apps) and all(report.get("storageReady") is True and
            report.get("collectionConfigured") is True and report.get("queueCount") == 0 and report.get("coverageGapCount") == 0 and
            report.get("occurrenceCount", 0) >= 1 for report in offline_apps),
        "offlineNativeReview": native("offline-native-review").get("reviewChanged") is True and
            native("offline-native-review").get("occurrenceScoped") is True and joined("offline-native-review", offline=True) and
            any(sum(report.get("workflowEvents", {}).get(event, 0) for event in
                ["review-confirmedSecret", "review-falsePositive", "review-unreviewed"]) >= 1 for report in offline_apps),
        "offlineOSNotificationRequestAccepted": bool(offline_apps) and
            any(report.get("alertsByDeliveryState", {}).get("delivered", 0) >= 1 for report in offline_apps),
        "offlineOSNotificationVisibleAndMasked": notification.get("visibleOSNotification") is True and
            notification.get("notificationTextMasked") is True and joined("offline-os-notification", offline=True),
        "offlineOSNotificationClickedToMaskedInventory": notification.get("notificationClicked") is True and
            notification.get("navigationRemainedMasked") is True and joined("offline-os-notification", offline=True) and
            any(report.get("workflowEvents", {}).get("notification-navigation", 0) >= 1 for report in offline_apps),
        "ciphertextInspectionsClean": bool(snapshots) and all(value.get("ciphertextMarkerInspectionPassed") is True for value in snapshots),
        "syntheticOnlyWithoutPrivateDecryption": observations.get("disposableWorkflow") is True and
            observation_scope.get("privateValueDecryptionRequested") is False and
            observation_scope.get("providerSessionInvoked") is False and
            observation_scope.get("userHistoriesOrHookSettingsTouched") is False and
            count(owner.get("privateValueDecryptions")) == 0 and owner.get("existingUserHooksOrHistoriesModified") is False,
        "observationsUnambiguous": not duplicate_steps,
        "nativeTransitionOrderRecorded": len(recorded_order) == len(transition_order) and recorded_order == sorted(recorded_order),
    }
    criteria = {
        "8": ["plainDeletionHasNoAcknowledgement", "baselineProtectedContentRemembered", "plainDeletionRemovesActiveProtectedContent",
              "plainDeletionReplayAddsNothing", "newAppearanceAfterPlainDeletionDetectable", "sameManifestAcrossRestartInspections"],
        "9": ["offlinePolicyJoinedToSignedGUIRun", "offlineCollectionScanningInventoryComplete", "offlineNativeReview",
              "offlineOSNotificationRequestAccepted", "offlineOSNotificationVisibleAndMasked", "offlineOSNotificationClickedToMaskedInventory"],
        "11": ["acknowledgementAndRemovalPersist", "obsoleteMarkerReplayAddsNothing", "newObsoleteAppearanceMetadataOnlyAndSilent",
               "differentReplacementNormallyDetectedAndAlerted", "replacementInSameConversation", "explicitForgettingRemovesOnlyMarker", "laterAppearanceAfterForgettingOrdinary"],
    }
    user_click_verified = user_confirmation_source and checks["offlineOSNotificationVisibleAndMasked"] and \
        checks["offlineOSNotificationClickedToMaskedInventory"]
    native_navigation_verified = native_confirmation_source and notification.get("selectedReplacementOccurrence") is True and \
        checks["offlineOSNotificationClickedToMaskedInventory"] and native("offline-native-review").get("review") == "confirmedSecret"
    notification_text_verified = text_confirmation_source and checks["offlineOSNotificationVisibleAndMasked"]
    return {"schemaVersion": 1, "passed": all(checks.values()), "checks": checks,
            "pendingOrFailedChecks": [key for key, passed in checks.items() if not passed],
            "criteria": {key: {"scopedChecksPassed": all(checks[name] for name in names), "checks": names} for key, names in criteria.items()},
            "owner": {"cleanupPassed": checks["ownerCleanupCompleted"], "runCount": count(owner.get("runCount")),
                      "normalExitedRunCount": count(owner.get("normalExitedRunCount")), "privateValueDecryptions": count(owner.get("privateValueDecryptions"))},
            "launches": sorted(launches, key=lambda launch: launch["runIndex"]), "appReports": app_reports,
            "snapshots": snapshots, "nativeObservations": stages,
            "postTestPreferences": safe_preferences,
            "notificationEvidenceProvenance": {
                "userConfirmedVisibleNotificationClick": user_click_verified,
                "matchingReviewedReplacementSelectedAndMasked": native_navigation_verified,
                "appNotificationNavigationEventCount": sum(report.get("workflowEvents", {}).get("notification-navigation", 0) for report in offline_apps),
                "textMaskEvidenceValidated": notification_text_verified,
                "bannerTextIndependentlyReadThroughAccessibility": False,
                "clickSummary": "The user confirmed clicking the notification and opening a masked Token entry." if user_click_verified else None,
                "navigationSummary": "Native accessibility showed the reviewed replacement occurrence selected with value and context masked. The production app recorded notification navigation." if native_navigation_verified else None,
                "textSummary": "Masked notification text is established by controlled production notification construction and the user's response to the masked-notification test." if notification_text_verified else None},
            "postForgetAlerts": {"decisionCount": final.get("original", {}).get("alertCount"),
                                 "deliveryStates": final.get("original", {}).get("alertsByDeliveryState", {}),
                                 "meaning": "Forgetting restores ordinary evaluation and normal alert eligibility. A pre-existing per-session strong-signal receipt may suppress another alert; this check does not require an extra notification."},
            "additionalLifecycleObservation": {"present": "offline-lifecycle" in stages,
                "joinedToOfflineRun": joined("offline-lifecycle", offline=True),
                "sessionLockInvalidationRecorded": lifecycle_app.get("workflowEvents", {}).get("mask-sessionLock", 0) >= 1,
                "sleepInvalidationRecorded": lifecycle_app.get("workflowEvents", {}).get("mask-sleep", 0) >= 1,
                "cachesMaskedAtObservation": masked(lifecycle_app),
                "authenticatedRevealInvalidationEstablished": False,
                "scope": "This workflow remained masked. Recorded lifecycle events do not establish invalidation of authenticated revealed content."},
            "scope": {"source": "One disposable synthetic Claude 2.1.293 transcript, user-prompt content, same conversation.",
                      "application": "Existing installed development-signed Spillcheck.app; unchanged production scanner and vault.",
                      "acknowledgementTested": "rotated", "nativeObservationMethod": "Root-recorded accessibility and OS notification observations.",
                      "allSupportedInterfacesOfflineTested": False, "systemWideOfflinePolicy": False,
                      "allDescendantsNetworkDenied": False, "actualProviderSessionInvoked": False,
                      "notificationReceiptMeaning": "Delivered is UserNotifications request acceptance or an existing OS request; visible notification and click require separate native observations.",
                      "activeStorageDeletionMeaning": "Remembered payload lookups are absent after removal; this is not forensic erasure from SQLite pages, snapshots or backups."},
            "offlinePolicy": {"mode": OFFLINE_MODE, "exercisedRunVerified": checks["offlinePolicyJoinedToSignedGUIRun"],
                              "policyDefinesExternalAppAndOrdinaryChildNetworkDenial": True,
                              "ownedUnixException": "Exact canonical owned-store/capture.sock only.",
                              "bootstrapException": "Literal /usr/bin/sandbox-exec may run without the inherited sandbox, then apply the unchanged production scanner policy.",
                              "genericBootstrapEscapeExists": True,
                              "policyControlsReport": "docs/implementation/m6-parent-sandbox-bootstrap.json"},
            "limits": ["This is a cooperative test-only parent policy. The bootstrap executable exception does not constrain argv and is not a secure all-descendant policy.",
                       "Local OS notification services run outside the app process; system-wide networking was not disabled.",
                       "The source transcript is synthetic. No real provider generation, T3 or Codex offline workflow ran in this check.",
                       "Metadata-only retention and visible OS delivery include explicit native observations. Counts alone do not prove either claim."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture_parser = commands.add_parser("capture-launches")
    capture_parser.add_argument("--responses", type=Path, required=True)
    capture_parser.add_argument("--output", type=Path, required=True)
    finalizer = commands.add_parser("finalize")
    finalizer.add_argument("--owner-report", type=Path, help="Completed external owner report; omit for an explicitly incomplete preview.")
    finalizer.add_argument("--observations", type=Path, required=True)
    finalizer.add_argument("--launch-receipts", type=Path)
    finalizer.add_argument("--output", type=Path, default=ROOT / "docs/implementation/m6-signed-restart-offline.json")
    args = parser.parse_args()
    try:
        if args.command == "capture-launches":
            capture(args)
            return
        report = verify(read(args.owner_report) if args.owner_report else {}, read(args.observations),
                        read(args.launch_receipts) if args.launch_receipts else None)
        reproduce = ["python3", "Tests/ProtectionSignedProbe/finalize-vault-owner-evidence.py", "finalize"]
        for flag, path in [("--owner-report", args.owner_report), ("--observations", args.observations),
                           ("--launch-receipts", args.launch_receipts), ("--output", args.output)]:
            if path is not None:
                reproduce += [flag, os.path.relpath(path.resolve(), ROOT)]
        report["command"] = shlex.join(reproduce)
        write(args.output, report)
        print(json.dumps({"passed": report["passed"], "checkCount": len(report["checks"]),
                          "pendingOrFailedChecks": report["pendingOrFailedChecks"]}, sort_keys=True))
        raise SystemExit(0 if report["passed"] else 1)
    except (OSError, ValueError, TypeError) as error:
        parser.exit(2, type(error).__name__ + ": evidence could not be finalized\n")


if __name__ == "__main__":
    main()
