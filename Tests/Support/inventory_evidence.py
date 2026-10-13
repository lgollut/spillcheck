"""Evidence gates for the fixed seven-appearance inventory acceptance scenario.

The two provider runners keep their own source-readiness and process controls.
This module compares report values only; it never reads files or runs a worker.
"""
DOMAINS = {"records", "occurrences", "obsoleteMarkers", "obsoleteAppearances", "alerts",
    "historicalNotifications", "unlocatedResults", "analysisReceipts", "locationReceipts",
    "strongSignalReceipts", "unlocatedReceipts", "sourceKinds", "sourceTimes", "conversationLabels",
    "valueLabels", "unlocatedLabels"}
NUMERIC_STATE = ("payloadRowCount", "referencedPayloadCount", "availableReferencedPayloadCount",
    "nextValueLabel", "removedLocationReceiptCount", "revokedMarkerCount")
REVIEW_STATES = {"unreviewed", "confirmedSecret", "falsePositive"}
DELIVERY_STATES = {"pending", "delivered", "permissionDenied", "cancelled"}


class InventoryEvidence:
    """Bind shared report primitives to one provider's source-readiness gate."""

    def __init__(self, shared, counts, source_ready):
        self.shared = shared
        self.counts = counts
        self.source_ready = source_ready

    def digest_values(self, values):
        return self.shared.digest_set({"values": values}, "values", empty=True)

    def counted_states(self, value, allowed, total):
        return (isinstance(value, dict) and set(value) <= allowed
            and all(type(count) is int and count > 0 for count in value.values())
            and sum(value.values()) == total)

    def inventory_state(self, report):
        state = report.get("recoveryInventoryState")
        if (report.get("recoveryInventoryStateEnabled") is not True or not isinstance(state, dict)
                or state.get("measured") is not True or state.get("truncated") is not False
                or state.get("phase") not in ("baseline", "reviewed", "removed")
                or not self.shared.exact_int(state.get("schemaVersion"), 1)
                or state.get("systemNotificationDeliveryEstablished") is not False
                or state.get("actualNotificationDeliverySuppressed") is not True):
            return None
        counts, digests = state.get("counts"), state.get("digests")
        if not isinstance(counts, dict) or set(counts) != DOMAINS or not isinstance(digests, dict) or set(digests) != DOMAINS:
            return None
        for domain in DOMAINS:
            values = self.digest_values(digests[domain])
            if type(counts[domain]) is not int or not 0 <= counts[domain] <= 128 or values is None or len(values) != counts[domain]:
                return None
        if (any(type(state.get(key)) is not int or not 0 <= state[key] <= 8192 for key in NUMERIC_STATE)
                or state["nextValueLabel"] < 1
                or state["availableReferencedPayloadCount"] != state["referencedPayloadCount"]
                or state["referencedPayloadCount"] > state["payloadRowCount"]
                or not self.counted_states(state.get("reviewCounts"), REVIEW_STATES, counts["occurrences"])
                or not self.counted_states(state.get("deliveryCounts"), DELIVERY_STATES, counts["alerts"] + counts["historicalNotifications"])):
            return None
        return state

    def state_unchanged(self, before, after):
        left, right = self.inventory_state(before), self.inventory_state(after)
        return (left is not None and right is not None
            and self.shared.manifest_digest(before) is not None and self.shared.manifest_digest(before) == self.shared.manifest_digest(after)
            and all(left.get(key) == right.get(key) for key in
                ("phase", "counts", "reviewCounts", "deliveryCounts", "schemaVersion", *NUMERIC_STATE))
            and all(self.digest_values(left["digests"][domain]) == self.digest_values(right["digests"][domain]) for domain in DOMAINS))

    def retained(self, report, producer, phase):
        state = self.inventory_state(report)
        return (state is not None and state["phase"] == phase and self.source_ready(report)
            and self.shared.collected(report, self.counts, producer)
            and state["counts"]["records"] == 1 and state["counts"]["occurrences"] == 7
            and state["counts"]["locationReceipts"] == 7 and state["counts"]["analysisReceipts"] >= 5
            and state["counts"]["sourceKinds"] >= 5
            and state["counts"]["conversationLabels"] == state["counts"]["valueLabels"] == 1
            and state["counts"]["alerts"] + state["counts"]["historicalNotifications"] == 1
            and all(state["counts"][key] == 0 for key in
                ("obsoleteMarkers", "obsoleteAppearances", "unlocatedResults", "unlocatedReceipts", "unlocatedLabels"))
            and state["payloadRowCount"] == state["referencedPayloadCount"] > 0
            and state["removedLocationReceiptCount"] == state["revokedMarkerCount"] == 0
            and state["reviewCounts"] == ({"unreviewed": 7} if phase == "baseline"
                else {"confirmedSecret": 1, "falsePositive": 1, "unreviewed": 5})
            and state["deliveryCounts"] == ({"pending": 1} if phase == "baseline" else {"delivered": 1}))

    def reviewed_transition(self, before, after, producer):
        if not self.retained(before, producer, "baseline") or not self.retained(after, producer, "reviewed"):
            return False
        left, right = self.inventory_state(before), self.inventory_state(after)
        kind = after.get("recoveryInventorySeededReceiptKind")
        receipt_domain = {"live": "alerts", "historical": "historicalNotifications"}.get(kind)
        if (receipt_domain is None or left["counts"][receipt_domain] != 1
                or after.get("recoveryInventoryReviewControlConsumed") is not True
                or after.get("recoveryInventoryReviewApplied") is not True
                or after.get("recoveryInventoryStoreReceiptSeeded") is not True
                or after.get("recoveryInventoryControlFailure") is not None
                or not self.shared.inventory_unchanged(before, after) or left["counts"] != right["counts"]
                or any(left[key] != right[key] for key in NUMERIC_STATE)):
            return False
        changed_occurrences = self.digest_values(left["digests"]["occurrences"]) ^ self.digest_values(right["digests"]["occurrences"])
        return (len(changed_occurrences) == 4
            and self.digest_values(left["digests"][receipt_domain]).isdisjoint(self.digest_values(right["digests"][receipt_domain]))
            and all(self.digest_values(left["digests"][domain]) == self.digest_values(right["digests"][domain])
                for domain in DOMAINS - {"occurrences", receipt_domain}))

    def removed(self, report):
        state = self.inventory_state(report)
        return (state is not None and state["phase"] == "removed" and self.source_ready(report)
            and report.get("gapReasons") == []
            and all(self.shared.exact_int(report.get(key), 0) for key in ("valueCount", "occurrenceCount",
                "syntheticOccurrenceCount", "syntheticSessionCount"))
            and report.get("syntheticOccurrencesByContentType") == {} and report.get("observedAgentVersions") == []
            and all(state["counts"][key] == 0 for key in ("records", "occurrences", "obsoleteAppearances",
                "alerts", "unlocatedResults", "strongSignalReceipts", "unlocatedReceipts", "unlocatedLabels"))
            and state["counts"]["obsoleteMarkers"] == state["revokedMarkerCount"] == 1
            and state["counts"]["locationReceipts"] == state["removedLocationReceiptCount"] == 7
            and state["counts"]["analysisReceipts"] >= 5 and state["counts"]["sourceKinds"] >= 5
            and state["counts"]["conversationLabels"] == state["counts"]["valueLabels"] == 1
            and state["payloadRowCount"] == state["referencedPayloadCount"] == state["availableReferencedPayloadCount"] == 0
            and state["reviewCounts"] == {} and state["deliveryCounts"] in ({}, {"delivered": 1})
            and self.shared.digest_set(report, "recoveryOccurrenceDigests", empty=True) == set()
            and self.shared.digest_set(report, "recoveryAlertDigests", empty=True) == set())

    def removed_transition(self, before, after, producer):
        if not self.retained(before, producer, "reviewed") or not self.removed(after):
            return False
        left, right = self.inventory_state(before), self.inventory_state(after)
        stable = DOMAINS - {"records", "occurrences", "obsoleteMarkers", "alerts", "locationReceipts", "strongSignalReceipts"}
        return (after.get("recoveryInventoryRemovalControlConsumed") is True
            and after.get("recoveryInventoryRemovalApplied") is True and after.get("recoveryInventoryControlFailure") is None
            and self.shared.manifest_digest(before) == self.shared.manifest_digest(after)
            and left["nextValueLabel"] == right["nextValueLabel"]
            and self.shared.digest_set(before, "recoveryReceiptDigests") == self.shared.digest_set(after, "recoveryReceiptDigests")
            and self.digest_values(left["digests"]["locationReceipts"]).isdisjoint(self.digest_values(right["digests"]["locationReceipts"]))
            and all(left["counts"][domain] == right["counts"][domain]
                and self.digest_values(left["digests"][domain]) == self.digest_values(right["digests"][domain]) for domain in stable))

    def fresh_ready(self, report):
        return (self.source_ready(report) and report.get("gapReasons") == []
            and report.get("recoveryInventoryStateEnabled") is True
            and isinstance(report.get("recoveryInventoryState"), dict)
            and report["recoveryInventoryState"].get("actualNotificationDeliverySuppressed") is True
            and all(self.shared.exact_int(report.get(key), 0) for key in ("valueCount", "occurrenceCount"))
            and all(self.shared.digest_set(report, key, empty=True) == set() for key in
                (*self.shared.DIGEST_KEYS, "recoveryConsumedCaptureDigests", "recoverySuccessfullyProcessedCaptureDigests")))

    def new_single_processed_capture(self, before, after):
        """No active source exists, so one helper submission must have one completed receipt."""
        old_consumed = self.shared.digest_set(before, "recoveryConsumedCaptureDigests", empty=True)
        old_processed = self.shared.digest_set(before, "recoverySuccessfullyProcessedCaptureDigests", empty=True)
        consumed = self.shared.digest_set(after, "recoveryConsumedCaptureDigests", empty=True)
        processed = self.shared.digest_set(after, "recoverySuccessfullyProcessedCaptureDigests", empty=True)
        if any(value is None for value in (old_consumed, old_processed, consumed, processed)):
            return False
        new_consumed, new_processed = consumed - old_consumed, processed - old_processed
        return (self.source_ready(after) and self.shared.manifest_digest(before) == self.shared.manifest_digest(after)
            and old_consumed <= consumed and old_processed <= processed
            and len(new_consumed) == 1 and new_consumed == new_processed
            and not new_consumed.intersection(old_consumed | old_processed))

    def exact_source_replayed(self, before, after):
        replay = after.get("recoveryInventoryReplay")
        state = self.inventory_state(before)
        if (state is None or not isinstance(replay, dict) or not self.state_unchanged(before, after)
                or not self.new_single_processed_capture(before, after)
                or after.get("recoveryInventoryControlFailure") is not None
                or not all(replay.get(key) is True for key in ("controlConsumed", "queued", "cleanBatches",
                    "allExpectedSourcesObserved", "completeProgress", "completionObserved", "workCompleted", "successfulReadMatched"))
                or type(replay.get("batchCount")) is not int or not 0 < replay["batchCount"] <= 128
                or type(replay.get("bytesRead")) is not int or replay["bytesRead"] <= 0
                or not self.shared.exact_int(replay.get("expectedSourceCount"), state["counts"]["sourceKinds"])
                or not self.shared.exact_int(replay.get("observedSourceCount"), state["counts"]["sourceKinds"])
                or replay.get("observedContentTypes") != sorted(self.counts)):
            return False
        capture = self.digest_values([replay.get("captureDigest")])
        audit = self.digest_values([replay.get("auditDigest")])
        return (capture is not None and audit is not None and capture.isdisjoint(audit)
            and capture == (self.shared.digest_set(after, "recoverySuccessfullyProcessedCaptureDigests", empty=True)
                - self.shared.digest_set(before, "recoverySuccessfullyProcessedCaptureDigests", empty=True)))
