import base64
import copy
import hashlib
import unittest

import codex_upgrade_state as state

OLD, NEW = "0.160.1", "0.162.1"


def digest(label):
    return base64.b64encode(hashlib.sha256(label.encode()).digest()).decode()


def rows(domain, count, prefix="old"):
    return [digest(f"{prefix}/{domain}/{number}") for number in range(count)]


def baseline(kind="live"):
    counts = dict.fromkeys(state.DOMAINS, 0)
    counts.update(records=1, occurrences=7, analysisReceipts=9, locationReceipts=7,
        strongSignalReceipts=1, sourceKinds=9, sourceTimes=9, conversationLabels=1, valueLabels=1)
    counts["alerts" if kind == "live" else "historicalNotifications"] = 1
    digests = {key: rows(key, count) for key, count in counts.items()}
    inventory = {"measured": True, "truncated": False, "phase": "baseline", "counts": counts,
        "digests": digests, "reviewCounts": {"unreviewed": 7}, "deliveryCounts": {"pending": 1},
        "payloadRowCount": 17, "referencedPayloadCount": 17, "availableReferencedPayloadCount": 17,
        "nextValueLabel": 2, "schemaVersion": 1, "removedLocationReceiptCount": 0, "revokedMarkerCount": 0,
        "systemNotificationDeliveryEstablished": False, "actualNotificationDeliverySuppressed": True,
        "upgrade": {"enabled": True, "recordStableDigests": rows("stable-records", 1),
            "recordTimesMatchOccurrences": True, "classificationCounts": {"ordinary": 7},
            "producerClassificationCounts": {OLD: {"ordinary": 7}},
            "producerReviewCounts": {OLD: {"unreviewed": 7}},
            "producerOccurrenceDigests": {OLD: list(digests["occurrences"])}}}
    return {"recoveryInventoryStateEnabled": True, "recoveryInventoryUpgradeStateEnabled": True,
        "recoveryInventoryControlFailure": None, "recoveryInventoryRemovalApplied": False,
        "recoveryManifestDigest": digest("manifest"), "recoveryInventoryState": inventory,
        "recoveryOccurrenceDigests": rows("occurrence-ids", 7),
        "recoveryReceiptDigests": rows("receipt-identities", 9),
        "recoveryAlertDigests": rows("alert-ids", counts["alerts"]),
        "valueCount": 1, "occurrenceCount": 7, "syntheticOccurrenceCount": 7, "syntheticSessionCount": 1,
        "observedAgentVersions": [OLD], "syntheticOccurrencesByContentType": dict(state.TYPES),
        "syntheticOccurrencesByProducerVersionAndContentType": {OLD: dict(state.TYPES)}}


def reviewed(kind="live"):
    report = baseline(kind)
    inventory = report["recoveryInventoryState"]
    inventory["phase"] = "reviewed"
    inventory["reviewCounts"] = dict(state.REVIEWED)
    inventory["deliveryCounts"] = {"delivered": 1}
    inventory["digests"]["occurrences"][:2] = rows("changed-review", 2)
    domain = "alerts" if kind == "live" else "historicalNotifications"
    inventory["digests"][domain] = rows("delivered-" + domain, 1)
    inventory["upgrade"]["producerReviewCounts"][OLD] = dict(state.REVIEWED)
    inventory["upgrade"]["producerOccurrenceDigests"][OLD] = list(inventory["digests"]["occurrences"])
    report.update(recoveryInventoryReviewControlConsumed=True, recoveryInventoryReviewApplied=True,
        recoveryInventoryStoreReceiptSeeded=True, recoveryInventorySeededReceiptKind=kind)
    return report


def acknowledged(kind="live"):
    report = reviewed(kind)
    inventory = report["recoveryInventoryState"]
    inventory["phase"] = "reviewed-revoked7"
    inventory["counts"]["obsoleteMarkers"] = 1
    inventory["digests"]["obsoleteMarkers"] = rows("revoked-marker", 1)
    inventory["revokedMarkerCount"] = 1
    report.update(recoveryInventoryAcknowledgementControlConsumed=True, recoveryInventoryAcknowledgementApplied=True)
    return report


def successor(kind="live"):
    report = acknowledged(kind)
    inventory, upgrade = report["recoveryInventoryState"], report["recoveryInventoryState"]["upgrade"]
    inventory["phase"] = "reviewed-revoked14"
    additions = {"occurrences": 7, "analysisReceipts": 9, "locationReceipts": 7,
        "sourceKinds": 9, "sourceTimes": 9, "conversationLabels": 1}
    for key, count in additions.items():
        inventory["counts"][key] += count
        inventory["digests"][key].extend(rows(key, count, "new"))
    inventory["digests"]["records"] = rows("later-lastOccurrenceAt", 1)
    inventory["reviewCounts"]["unreviewed"] += 7
    for key in ("payloadRowCount", "referencedPayloadCount", "availableReferencedPayloadCount"):
        inventory[key] += 17
    upgrade["classificationCounts"]["obsolete"] = 7
    upgrade["producerClassificationCounts"][NEW] = {"obsolete": 7}
    upgrade["producerReviewCounts"][NEW] = {"unreviewed": 7}
    upgrade["producerOccurrenceDigests"][NEW] = rows("occurrences", 7, "new")
    report["recoveryOccurrenceDigests"].extend(rows("occurrence-ids", 7, "new"))
    report["recoveryReceiptDigests"].extend(rows("receipt-identities", 9, "new"))
    report.update(occurrenceCount=14, syntheticOccurrenceCount=14, syntheticSessionCount=2,
        observedAgentVersions=sorted([OLD, NEW]),
        syntheticOccurrencesByContentType={key: value * 2 for key, value in state.TYPES.items()},
        syntheticOccurrencesByProducerVersionAndContentType={OLD: dict(state.TYPES), NEW: dict(state.TYPES)})
    return report


def removed_mode_baseline(kind="live", reviewed_state=False):
    report = reviewed(kind) if reviewed_state else baseline(kind)
    inventory = report["recoveryInventoryState"]
    del inventory["upgrade"]
    inventory["removedUpgrade"] = {"enabled": True, "protectedRecordCount": 1, "metadataOnlyRecordCount": 0,
        "recordTimesMatchObsoleteAppearances": False, "removedLocationDigests": [],
        "obsoleteAppearanceContentTypeCounts": {}}
    report.update(recoveryInventoryRemovedUpgradeStateEnabled=True, gapReasons=[], coverageReportTruncated=False)
    report["recoveryInventoryRemovedUpgradeWitness"] = {"measured": True, "truncated": False,
        "observedSourceCount": 9, "observedBatchCount": 2, "matchedAppearanceCount": 0,
        "allAppearancesHaveCommittedNativeSource": False, "readerVersions": [OLD],
        **{key: {} for key in state.WITNESS_MAPS}}
    return report


def removed7(kind="live"):
    """Complete removed-state report, also usable with a paused pending capture."""
    report = removed_mode_baseline(kind, reviewed_state=True)
    inventory = report["recoveryInventoryState"]
    inventory["phase"] = "removed-upgrade7"
    for domain in ("records", "occurrences", "alerts", "strongSignalReceipts"):
        inventory["counts"][domain] = 0
        inventory["digests"][domain] = []
    inventory["counts"]["obsoleteMarkers"] = 1
    inventory["digests"]["obsoleteMarkers"] = rows("removed-revoked-marker", 1)
    inventory["digests"]["locationReceipts"] = rows("removed-locations", 7)
    inventory.update(reviewCounts={}, deliveryCounts={"delivered": 1} if kind == "historical" else {},
        payloadRowCount=0, referencedPayloadCount=0, availableReferencedPayloadCount=0,
        removedLocationReceiptCount=7, revokedMarkerCount=1)
    inventory["removedUpgrade"].update(protectedRecordCount=0, recordTimesMatchObsoleteAppearances=True,
        removedLocationDigests=list(inventory["digests"]["locationReceipts"]))
    report.update(valueCount=0, occurrenceCount=0, syntheticOccurrenceCount=0, syntheticSessionCount=0,
        observedAgentVersions=[], syntheticOccurrencesByContentType={},
        syntheticOccurrencesByProducerVersionAndContentType={}, recoveryOccurrenceDigests=[], recoveryAlertDigests=[],
        recoveryInventoryRemovalControlConsumed=True, recoveryInventoryRemovalApplied=True)
    return report


def removed14(kind="live"):
    report = removed7(kind)
    inventory = report["recoveryInventoryState"]
    inventory["phase"] = "removed-upgrade14"
    for domain, count in {"records": 1, "obsoleteAppearances": 7, "analysisReceipts": 9,
            "locationReceipts": 7, "sourceKinds": 9, "sourceTimes": 9, "conversationLabels": 1}.items():
        inventory["counts"][domain] += count
        inventory["digests"][domain].extend(rows(domain, count, "metadata-only-new"))
    inventory["removedUpgrade"].update(metadataOnlyRecordCount=1, recordTimesMatchObsoleteAppearances=True,
        obsoleteAppearanceContentTypeCounts=dict(state.TYPES))
    report.update(valueCount=1, recoveryInventoryRemovalApplied=False)
    report["recoveryReceiptDigests"].extend(rows("receipt-identities", 9, "metadata-only-new"))
    report["recoveryInventoryRemovedUpgradeWitness"] = {"measured": True, "truncated": False,
        "observedSourceCount": 9, "observedBatchCount": 3, "matchedAppearanceCount": 7,
        "allAppearancesHaveCommittedNativeSource": True, "readerVersions": [NEW],
        "producerAppearanceCounts": {NEW: 7}, "producerContentTypeCounts": {NEW: dict(state.TYPES)},
        "producerSessionCounts": {NEW: 1},
        "producerSourceDigests": {NEW: rows("sourceKinds", 5, "metadata-only-new")},
        "producerReceiptDigests": {NEW: rows("analysisReceipts", 5, "metadata-only-new")},
        "producerAppearanceDigests": {NEW: list(inventory["digests"]["obsoleteAppearances"])}}
    return report


class UpgradeStateBoundaryTests(unittest.TestCase):
    def test_all_four_phases_and_both_receipt_kinds_are_supported(self):
        for kind in ("live", "historical"):
            before, review, revoked, expanded = baseline(kind), reviewed(kind), acknowledged(kind), successor(kind)
            for report, versions, phase in [(before, [OLD], "baseline"), (review, [OLD], "reviewed"),
                    (revoked, [OLD], "reviewed-revoked7"), (expanded, [OLD, NEW], "reviewed-revoked14")]:
                self.assertTrue(state.validate(report, versions, phase), (kind, phase))
            self.assertTrue(state.reviewed_transition(before, review, OLD))
            self.assertTrue(state.acknowledged_transition(review, revoked, OLD))
            self.assertTrue(state.new_content_preserves_original(revoked, expanded, OLD, NEW))

    def test_reports_require_complete_bounded_canonical_commitments(self):
        for domain in state.DOMAINS:
            changed = baseline()
            del changed["recoveryInventoryState"]["digests"][domain]
            self.assertFalse(state.validate(changed, [OLD], "baseline"), domain)
        for invalid in (["private content"], [digest("same")] * 2, rows("oversized", 129),
                [base64.b64encode(b"short").decode()], [digest("noncanonical")[:-2] + "B="]):
            changed = baseline()
            changed["recoveryInventoryState"]["digests"]["records"] = invalid
            self.assertFalse(state.validate(changed, [OLD], "baseline"))
        for key, value in [("measured", False), ("truncated", True), ("phase", []), ("schemaVersion", True),
                ("actualNotificationDeliverySuppressed", False), ("systemNotificationDeliveryEstablished", True),
                ("payloadRowCount", 0), ("availableReferencedPayloadCount", 16), ("removedLocationReceiptCount", 1)]:
            changed = baseline()
            changed["recoveryInventoryState"][key] = value
            self.assertFalse(state.validate(changed, [OLD], "baseline"), key)

    def test_versions_phases_and_per_producer_partitions_fail_closed(self):
        for versions in (None, [], [OLD, OLD], [NEW], [OLD, NEW, "third"], ["\ud800"], ["a" * 257], ["\0"]):
            self.assertFalse(state.validate(baseline(), versions, "baseline"))
        for phase in (None, [], "removed", "unknown"):
            self.assertFalse(state.validate(baseline(), [OLD], phase))
        changed = successor()
        changed["recoveryInventoryState"]["upgrade"]["producerOccurrenceDigests"][NEW][0] = \
            changed["recoveryInventoryState"]["upgrade"]["producerOccurrenceDigests"][OLD][0]
        self.assertFalse(state.validate(changed, [OLD, NEW], "reviewed-revoked14"))
        changed = successor()
        changed["syntheticOccurrencesByProducerVersionAndContentType"][NEW]["toolError"] = 0
        self.assertFalse(state.validate(changed, [OLD, NEW], "reviewed-revoked14"))

    def test_review_changes_exactly_two_full_occurrence_rows_and_one_store_receipt(self):
        before, after = baseline(), reviewed()
        for key, value in [("recoveryInventoryReviewControlConsumed", False), ("recoveryInventoryReviewApplied", False),
                ("recoveryInventoryStoreReceiptSeeded", False), ("recoveryInventorySeededReceiptKind", "OS"),
                ("recoveryInventorySeededReceiptKind", []), ("recoveryInventoryControlFailure", "postconditionFailed")]:
            self.assertFalse(state.reviewed_transition(before, {**after, key: value}, OLD), key)
        for index in (1, 2):
            changed = reviewed()
            occurrences = changed["recoveryInventoryState"]["digests"]["occurrences"]
            occurrences[index] = (before["recoveryInventoryState"]["digests"]["occurrences"][index]
                if index == 1 else digest("unexpected-third-review"))
            changed["recoveryInventoryState"]["upgrade"]["producerOccurrenceDigests"][OLD] = list(occurrences)
            self.assertFalse(state.reviewed_transition(before, changed, OLD))
        for domain in ("records", "analysisReceipts", "sourceTimes", "locationReceipts", "valueLabels"):
            changed = reviewed()
            changed["recoveryInventoryState"]["digests"][domain][0] = digest("replacement")
            self.assertFalse(state.reviewed_transition(before, changed, OLD), domain)

    def test_acknowledgement_only_adds_one_revoked_marker_without_removing_content(self):
        before, after = reviewed(), acknowledged()
        for key in ("recoveryInventoryAcknowledgementControlConsumed", "recoveryInventoryAcknowledgementApplied"):
            self.assertFalse(state.acknowledged_transition(before, {**after, key: False}, OLD))
        for domain in state.DOMAINS - {"obsoleteMarkers"}:
            changed = acknowledged()
            if changed["recoveryInventoryState"]["digests"][domain]:
                changed["recoveryInventoryState"]["digests"][domain][0] = digest("replacement")
                self.assertFalse(state.acknowledged_transition(before, changed, OLD), domain)
        for key, value in [("payloadRowCount", 0), ("revokedMarkerCount", 0), ("removedLocationReceiptCount", 7)]:
            changed = acknowledged()
            changed["recoveryInventoryState"][key] = value
            self.assertFalse(state.acknowledged_transition(before, changed, OLD), key)

    def test_restart_checks_full_values_but_not_reset_control_flags_or_pending_queue(self):
        before, after = acknowledged(), acknowledged()
        after.update(recoveryInventoryReviewApplied=False, recoveryInventoryStoreReceiptSeeded=False,
            recoveryInventoryAcknowledgementApplied=False, recoveryInventoryAcknowledgementControlConsumed=False,
            queueCount=1, recoveryPendingCaptureDigests=[digest("pending")])
        for domain in state.DOMAINS:
            after["recoveryInventoryState"]["digests"][domain].reverse()
        after["recoveryInventoryState"]["upgrade"]["producerOccurrenceDigests"][OLD].reverse()
        self.assertTrue(state.unchanged(before, after))
        for domain in state.DOMAINS:
            changed = acknowledged()
            if changed["recoveryInventoryState"]["digests"][domain]:
                changed["recoveryInventoryState"]["digests"][domain][0] = digest("replacement")
                self.assertFalse(state.unchanged(before, changed), domain)
        self.assertFalse(state.unchanged(before, {**after, "recoveryManifestDigest": digest("different-vault")}))

    def test_original_source_receipts_times_and_locations_must_remain_exact(self):
        before = acknowledged()
        for domain in ("analysisReceipts", "sourceTimes", "sourceKinds", "locationReceipts", "conversationLabels"):
            changed = successor()
            changed["recoveryInventoryState"]["digests"][domain][0] = digest("replacement-original")
            self.assertTrue(state.validate(changed, [OLD, NEW], "reviewed-revoked14"))
            self.assertFalse(state.new_content_preserves_original(before, changed, OLD, NEW), domain)
        changed = successor()
        for key in ("recoveryOccurrenceDigests", "recoveryReceiptDigests"):
            changed[key][0] = digest("replacement-id-" + key)
        self.assertFalse(state.new_content_preserves_original(before, changed, OLD, NEW))

    def test_new_content_preserves_original_full_reviews_and_has_only_obsolete_unreviewed_new_rows(self):
        before, changed = acknowledged(), successor()
        replacement = digest("edited-original-occurrence")
        changed["recoveryInventoryState"]["digests"]["occurrences"][0] = replacement
        changed["recoveryInventoryState"]["upgrade"]["producerOccurrenceDigests"][OLD][0] = replacement
        self.assertTrue(state.validate(changed, [OLD, NEW], "reviewed-revoked14"))
        self.assertFalse(state.new_content_preserves_original(before, changed, OLD, NEW))
        for key, value in [("producerClassificationCounts", {OLD: {"ordinary": 7}, NEW: {"ordinary": 7}}),
                ("producerReviewCounts", {OLD: dict(state.REVIEWED), NEW: {"confirmedSecret": 1, "unreviewed": 6}}),
                ("classificationCounts", {"ordinary": 14})]:
            changed = successor()
            changed["recoveryInventoryState"]["upgrade"][key] = value
            self.assertFalse(state.new_content_preserves_original(before, changed, OLD, NEW), key)


    def test_record_can_advance_last_time_only_with_stable_record_and_actual_occurrence_time_proof(self):
        before, after = acknowledged(), successor()
        self.assertNotEqual(before["recoveryInventoryState"]["digests"]["records"],
            after["recoveryInventoryState"]["digests"]["records"])
        self.assertTrue(state.new_content_preserves_original(before, after, OLD, NEW))
        for key, value in [("recordStableDigests", rows("changed-protected-value", 1)), ("recordTimesMatchOccurrences", False)]:
            changed = successor()
            changed["recoveryInventoryState"]["upgrade"][key] = value
            self.assertFalse(state.new_content_preserves_original(before, changed, OLD, NEW), key)

    def test_new_content_cannot_realert_change_revocation_or_lose_payloads(self):
        before = acknowledged()
        for domain in ("alerts", "obsoleteMarkers", "strongSignalReceipts", "valueLabels"):
            changed = successor()
            changed["recoveryInventoryState"]["digests"][domain][0] = digest("changed-" + domain)
            self.assertFalse(state.new_content_preserves_original(before, changed, OLD, NEW), domain)
        changed = successor("historical")
        changed["recoveryInventoryState"]["digests"]["historicalNotifications"][0] = digest("second-delivery")
        self.assertFalse(state.new_content_preserves_original(acknowledged("historical"), changed, OLD, NEW))
        for key, value in [("availableReferencedPayloadCount", 33), ("nextValueLabel", 3),
                ("deliveryCounts", {"pending": 1}), ("revokedMarkerCount", 0)]:
            changed = successor()
            changed["recoveryInventoryState"][key] = value
            self.assertFalse(state.new_content_preserves_original(before, changed, OLD, NEW), key)


class RemovedUpgradeStateBoundaryTests(unittest.TestCase):
    def test_removed_mode_has_separate_baseline_review_removal_and_metadata_contracts(self):
        for kind in ("live", "historical"):
            before = removed_mode_baseline(kind)
            review = removed_mode_baseline(kind, reviewed_state=True)
            empty, metadata = removed7(kind), removed14(kind)
            for report, versions, phase in ((before, [OLD], "baseline"), (review, [OLD], "reviewed"),
                    (empty, [OLD], "removed-upgrade7"), (metadata, [OLD, NEW], "removed-upgrade14")):
                self.assertTrue(state.validate_removed(report, versions, phase), (kind, phase))
                self.assertFalse(state.validate(report, versions, phase), "retained contract must stay strict")
            self.assertTrue(state.removed_reviewed_transition(before, review, OLD))
            self.assertTrue(state.removed_transition(review, empty, OLD))
            self.assertTrue(state.new_metadata_preserves_removal(empty, metadata, OLD, NEW))
        self.assertFalse(state.validate_removed(acknowledged(), [OLD], "removed-upgrade7"))

    def test_removed_reviews_still_require_two_exact_rows_and_a_seeded_stored_receipt(self):
        before = removed_mode_baseline()
        for key in ("recoveryInventoryReviewControlConsumed", "recoveryInventoryReviewApplied", "recoveryInventoryStoreReceiptSeeded"):
            changed = removed_mode_baseline(reviewed_state=True)
            changed[key] = False
            self.assertFalse(state.removed_reviewed_transition(before, changed, OLD), key)
        changed = removed_mode_baseline(reviewed_state=True)
        changed["recoveryInventoryState"]["digests"]["occurrences"][2] = digest("third-review-change")
        self.assertFalse(state.removed_reviewed_transition(before, changed, OLD))
        changed = removed_mode_baseline(reviewed_state=True)
        changed["recoveryInventoryState"]["digests"]["sourceTimes"][0] = digest("old-time-change")
        self.assertFalse(state.removed_reviewed_transition(before, changed, OLD))

    def test_removed7_can_stay_exact_with_pending_work_and_after_cold_restart(self):
        before, after = removed7(), removed7()
        after.update(queueCount=1, recoveryPendingCaptureDigests=[digest("paused-capture")],
            recoveryInventoryRemovalApplied=False, recoveryInventoryRemovalControlConsumed=False,
            recoveryInventoryStoreReceiptSeeded=False, recoveryInventoryReviewApplied=False)
        witness = after["recoveryInventoryRemovedUpgradeWitness"]
        witness.update(observedSourceCount=0, observedBatchCount=0, readerVersions=[])
        self.assertTrue(state.removed_unchanged(before, after))
        for domain in state.DOMAINS:
            changed = copy.deepcopy(after)
            if changed["recoveryInventoryState"]["digests"][domain]:
                changed["recoveryInventoryState"]["digests"][domain][0] = digest("changed-" + domain)
                self.assertFalse(state.removed_unchanged(before, changed), domain)
        self.assertFalse(state.removed_unchanged(before, {**after, "recoveryManifestDigest": digest("another-vault")}))

    def test_removal_keeps_processed_sources_and_historical_receipt_but_deletes_live_alert(self):
        for kind in ("live", "historical"):
            before = removed_mode_baseline(kind, reviewed_state=True)
            after = removed7(kind)
            self.assertEqual(after["recoveryInventoryState"]["counts"]["alerts"], 0)
            self.assertEqual(after["recoveryInventoryState"]["counts"]["historicalNotifications"], int(kind == "historical"))
            for domain in ("analysisReceipts", "sourceKinds", "sourceTimes", "conversationLabels", "valueLabels"):
                changed = copy.deepcopy(after)
                changed["recoveryInventoryState"]["digests"][domain][0] = digest("changed-" + domain)
                self.assertFalse(state.removed_transition(before, changed, OLD), domain)
            for key in ("recoveryInventoryRemovalApplied", "recoveryInventoryRemovalControlConsumed"):
                self.assertFalse(state.removed_transition(before, {**after, key: False}, OLD), key)
        changed = removed7("historical")
        changed["recoveryInventoryState"]["digests"]["historicalNotifications"] = rows("changed-historical-delivery", 1)
        self.assertFalse(state.removed_transition(removed_mode_baseline("historical", True), changed, OLD))

    def test_removed_state_rejects_any_restored_payload_review_alert_or_missing_removed_location(self):
        for create, versions, phase in ((removed7, [OLD], "removed-upgrade7"), (removed14, [OLD, NEW], "removed-upgrade14")):
            for key, value in (("payloadRowCount", 1), ("referencedPayloadCount", 1),
                    ("availableReferencedPayloadCount", 1), ("removedLocationReceiptCount", 6),
                    ("revokedMarkerCount", 0), ("reviewCounts", {"unreviewed": 1}), ("deliveryCounts", {"pending": 1})):
                changed = create()
                changed["recoveryInventoryState"][key] = value
                self.assertFalse(state.validate_removed(changed, versions, phase), (phase, key))
            changed = create()
            changed["recoveryInventoryState"]["counts"]["alerts"] = 1
            changed["recoveryInventoryState"]["digests"]["alerts"] = rows("new-alert", 1)
            changed["recoveryAlertDigests"] = rows("new-alert-id", 1)
            self.assertFalse(state.validate_removed(changed, versions, phase))
            for gaps in (["captureRejected"], ["sourceUnavailable"]):
                self.assertFalse(state.validate_removed({**create(), "gapReasons": gaps}, versions, phase))

    def test_new_metadata_needs_actual_native_producer_reader_and_full_committed_receipt_join(self):
        for key, value in (("measured", False), ("truncated", True), ("failure", "missingSource"),
                ("observedSourceCount", 0), ("observedBatchCount", 0), ("observedBatchCount", 129),
                ("matchedAppearanceCount", 6), ("allAppearancesHaveCommittedNativeSource", False),
                ("readerVersions", [OLD]), ("producerAppearanceCounts", {OLD: 7}),
                ("producerSessionCounts", {NEW: 2}), ("producerContentTypeCounts", {NEW: {"userPrompt": 7}})):
            changed = removed14()
            changed["recoveryInventoryRemovedUpgradeWitness"][key] = value
            self.assertFalse(state.validate_removed(changed, [OLD, NEW], "removed-upgrade14"), key)
        for key in ("producerSourceDigests", "producerReceiptDigests", "producerAppearanceDigests"):
            changed = removed14()
            changed["recoveryInventoryRemovedUpgradeWitness"][key][NEW][0] = digest("uncommitted-" + key)
            self.assertFalse(state.validate_removed(changed, [OLD, NEW], "removed-upgrade14"), key)

    def test_new_metadata_preserves_all_old_removed_locations_receipts_times_and_revocation(self):
        before = removed7()
        for domain in ("analysisReceipts", "sourceKinds", "sourceTimes", "locationReceipts", "conversationLabels", "obsoleteMarkers", "valueLabels"):
            changed = removed14()
            changed["recoveryInventoryState"]["digests"][domain][0] = digest("replaced-original-" + domain)
            if domain == "locationReceipts":
                changed["recoveryInventoryState"]["removedUpgrade"]["removedLocationDigests"][0] = digest("replaced-original-" + domain)
            self.assertFalse(state.new_metadata_preserves_removal(before, changed, OLD, NEW), domain)
        changed = removed14()
        changed["recoveryReceiptDigests"][0] = digest("replaced-receipt-id")
        self.assertFalse(state.new_metadata_preserves_removal(before, changed, OLD, NEW))

    def test_metadata_only_record_requires_zero_protected_records_and_actual_appearance_times(self):
        valid = removed14()
        self.assertEqual(valid["valueCount"], 1)
        self.assertEqual(valid["occurrenceCount"], 0)
        self.assertEqual(valid["recoveryInventoryState"]["counts"]["obsoleteAppearances"], 7)
        for key, value in (("protectedRecordCount", 1), ("metadataOnlyRecordCount", 0),
                ("recordTimesMatchObsoleteAppearances", False), ("obsoleteAppearanceContentTypeCounts", {"userPrompt": 7})):
            changed = removed14()
            changed["recoveryInventoryState"]["removedUpgrade"][key] = value
            self.assertFalse(state.validate_removed(changed, [OLD, NEW], "removed-upgrade14"), key)

    def test_metadata_replays_keep_full_state_exact_while_transient_batch_counts_may_grow(self):
        before, after = removed14(), removed14()
        after["recoveryInventoryRemovedUpgradeWitness"].update(observedBatchCount=8, observedSourceCount=18)
        after["recoveryInventoryRemovalApplied"] = False
        after["recoveryInventoryState"]["removedUpgrade"]["removedLocationDigests"].reverse()
        self.assertTrue(state.removed_unchanged(before, after))
        changed = copy.deepcopy(after)
        changed["recoveryInventoryState"]["digests"]["records"] = rows("record-mutated-after-resume", 1)
        self.assertFalse(state.removed_unchanged(before, changed))
        changed = copy.deepcopy(after)
        changed["recoveryInventoryState"]["digests"]["obsoleteAppearances"][0] = digest("changed-appearance")
        changed["recoveryInventoryRemovedUpgradeWitness"]["producerAppearanceDigests"][NEW][0] = digest("changed-appearance")
        self.assertFalse(state.removed_unchanged(before, changed))

    def test_removed_witness_and_state_reject_malformed_or_swapped_commitments(self):
        for phase, versions, create in (("removed-upgrade7", [OLD], removed7), ("removed-upgrade14", [OLD, NEW], removed14)):
            for domain in state.DOMAINS:
                changed = create()
                del changed["recoveryInventoryState"]["digests"][domain]
                self.assertFalse(state.validate_removed(changed, versions, phase), domain)
            changed = create()
            changed["recoveryInventoryState"]["removedUpgrade"]["removedLocationDigests"] = rows("unlinked-location", 7)
            self.assertFalse(state.validate_removed(changed, versions, phase))
            for versions_invalid in (None, [], [OLD, OLD], ["\ud800"]):
                self.assertFalse(state.validate_removed(create(), versions_invalid, phase))



if __name__ == "__main__":
    unittest.main()
