"""Pure, bounded inventory-state gates for the signed Codex upgrade runner.

Queue, executable, source ownership and process-lifecycle checks belong to the
runner. These predicates never run tools or import the runner they validate.
"""
import base64
import binascii
import copy

DOMAINS = {"records", "occurrences", "obsoleteMarkers", "obsoleteAppearances", "alerts",
    "historicalNotifications", "unlocatedResults", "analysisReceipts", "locationReceipts",
    "strongSignalReceipts", "unlocatedReceipts", "sourceKinds", "sourceTimes", "conversationLabels",
    "valueLabels", "unlocatedLabels"}
NUMERIC = ("payloadRowCount", "referencedPayloadCount", "availableReferencedPayloadCount",
    "nextValueLabel", "removedLocationReceiptCount", "revokedMarkerCount", "schemaVersion")
PHASES = {"baseline", "reviewed", "reviewed-revoked7", "reviewed-revoked14"}
TYPES = {"userPrompt": 3, "intermediateResponse": 1, "finalResponse": 1, "toolOutput": 1, "toolError": 1}
REVIEWED = {"confirmedSecret": 1, "falsePositive": 1, "unreviewed": 5}
TOP_DIGESTS = ("recoveryOccurrenceDigests", "recoveryReceiptDigests", "recoveryAlertDigests")
EMPTY_DOMAINS = {"obsoleteAppearances", "unlocatedResults", "unlocatedReceipts", "unlocatedLabels"}


def _digests(values):
    if not isinstance(values, list) or len(values) > 128:
        return None
    result = set()
    for value in values:
        if not isinstance(value, str) or len(value) != 44 or value in result:
            return None
        try:
            decoded = base64.b64decode(value, validate=True)
        except (ValueError, binascii.Error):
            return None
        if len(decoded) != 32 or base64.b64encode(decoded).decode() != value:
            return None
        result.add(value)
    return result


def _number(value, expected):
    return type(value) is int and value == expected


def _counts(value, expected):
    return (isinstance(value, dict) and value == expected
        and all(type(number) is int for number in value.values()))


def _versions(versions):
    if not isinstance(versions, (list, tuple)) or not 1 <= len(versions) <= 2:
        return False
    try:
        return (all(isinstance(value, str) and 0 < len(value.encode()) <= 256 and "\0" not in value for value in versions)
            and len(set(versions)) == len(versions))
    except UnicodeError:
        return False


def _state(report):
    if not isinstance(report, dict):
        return None
    state = report.get("recoveryInventoryState")
    if (report.get("recoveryInventoryStateEnabled") is not True
            or report.get("recoveryInventoryUpgradeStateEnabled") is not True
            or report.get("recoveryInventoryControlFailure") is not None
            or report.get("recoveryInventoryRemovalApplied") is not False
            or not isinstance(state, dict) or state.get("measured") is not True
            or state.get("truncated") is not False or not isinstance(state.get("phase"), str)
            or state["phase"] not in PHASES
            or state.get("systemNotificationDeliveryEstablished") is not False
            or state.get("actualNotificationDeliverySuppressed") is not True):
        return None
    counts, digests, upgrade = state.get("counts"), state.get("digests"), state.get("upgrade")
    if (not isinstance(counts, dict) or set(counts) != DOMAINS
            or not isinstance(digests, dict) or set(digests) != DOMAINS
            or not isinstance(upgrade, dict) or upgrade.get("enabled") is not True
            or upgrade.get("recordTimesMatchOccurrences") is not True
            or _digests(upgrade.get("recordStableDigests")) is None
            or len(upgrade["recordStableDigests"]) != 1):
        return None
    for key in DOMAINS:
        identities = _digests(digests[key])
        if type(counts[key]) is not int or not 0 <= counts[key] <= 128 or identities is None or len(identities) != counts[key]:
            return None
    if (any(type(state.get(key)) is not int or not 0 <= state[key] <= 128 for key in NUMERIC)
            or state["schemaVersion"] != 1 or state["nextValueLabel"] != 2
            or not 0 < state["payloadRowCount"] == state["referencedPayloadCount"] == state["availableReferencedPayloadCount"]
            or state["removedLocationReceiptCount"] != 0):
        return None
    if _digests([report.get("recoveryManifestDigest")]) is None:
        return None
    for key, domain in zip(TOP_DIGESTS, ("occurrences", "analysisReceipts", "alerts")):
        identities = _digests(report.get(key))
        if identities is None or len(identities) != counts[domain]:
            return None
    return state


def validate(report, versions, phase):
    """Validate a complete inventory report; versions are [old] or [old, new]."""
    if (not _versions(versions) or not isinstance(phase, str) or phase not in PHASES
            or len(versions) != (2 if phase == "reviewed-revoked14" else 1)):
        return False
    state = _state(report)
    if state is None or state["phase"] != phase:
        return False
    counts, upgrade = state["counts"], state["upgrade"]
    n, revoked = len(versions), phase.startswith("reviewed-revoked")
    if (counts["records"] != 1 or counts["occurrences"] != 7 * n or counts["locationReceipts"] != 7 * n
            or counts["conversationLabels"] != n or counts["valueLabels"] != 1
            or counts["strongSignalReceipts"] != 1 or counts["obsoleteMarkers"] != int(revoked)
            or state["revokedMarkerCount"] != int(revoked)
            or any(counts[key] != 0 for key in EMPTY_DOMAINS)
            or counts["alerts"] + counts["historicalNotifications"] != 1
            or not counts["analysisReceipts"] >= counts["sourceKinds"] == counts["sourceTimes"] >= 5 * n):
        return False
    reviewed = phase != "baseline"
    reviews = {"unreviewed": 7} if not reviewed else {**REVIEWED, "unreviewed": 5 + 7 * (n - 1)}
    if (not _counts(state.get("reviewCounts"), reviews)
            or not _counts(state.get("deliveryCounts"), {"delivered" if reviewed else "pending": 1})
            or not _counts(upgrade.get("classificationCounts"), {"ordinary": 7, **({"obsolete": 7} if n == 2 else {})})):
        return False
    classifications, producer_reviews, occurrences = (upgrade.get(key) for key in
        ("producerClassificationCounts", "producerReviewCounts", "producerOccurrenceDigests"))
    if any(not isinstance(value, dict) or set(value) != set(versions) for value in (classifications, producer_reviews, occurrences)):
        return False
    combined = set()
    for index, version in enumerate(versions):
        expected_review = REVIEWED if index == 0 and reviewed else {"unreviewed": 7}
        identities = _digests(occurrences[version])
        if (not _counts(classifications[version], {"ordinary" if index == 0 else "obsolete": 7})
                or not _counts(producer_reviews[version], expected_review)
                or identities is None or len(identities) != 7 or combined.intersection(identities)):
            return False
        combined.update(identities)
    if combined != _digests(state["digests"]["occurrences"]):
        return False
    grouped = report.get("syntheticOccurrencesByProducerVersionAndContentType")
    return (all(_number(report.get(key), value) for key, value in (("valueCount", 1), ("occurrenceCount", 7 * n),
            ("syntheticOccurrenceCount", 7 * n), ("syntheticSessionCount", n)))
        and report.get("observedAgentVersions") == sorted(versions)
        and _counts(report.get("syntheticOccurrencesByContentType"), {key: value * n for key, value in TYPES.items()})
        and isinstance(grouped, dict) and set(grouped) == set(versions)
        and all(_counts(grouped[version], TYPES) for version in versions))


def _report_versions(report):
    state = _state(report)
    if state is None:
        return None
    groups = state["upgrade"].get("producerClassificationCounts")
    if not isinstance(groups, dict) or not 1 <= len(groups) <= 2:
        return None
    ordinary = [version for version, counts in groups.items() if _counts(counts, {"ordinary": 7})]
    obsolete = [version for version, counts in groups.items() if _counts(counts, {"obsolete": 7})]
    return ordinary + obsolete if len(ordinary) == 1 and len(ordinary) + len(obsolete) == len(groups) else None


def _same_manifest(before, after):
    return before.get("recoveryManifestDigest") == after.get("recoveryManifestDigest")


def _domain_equal(before, after, domains):
    return all(_digests(before["digests"][key]) == _digests(after["digests"][key]) for key in domains)


def _normalized(state):
    result = copy.deepcopy(state)
    result["digests"] = {key: sorted(value) for key, value in result["digests"].items()}
    result["upgrade"]["recordStableDigests"].sort()
    result["upgrade"]["producerOccurrenceDigests"] = {
        key: sorted(value) for key, value in result["upgrade"]["producerOccurrenceDigests"].items()}
    return result


def unchanged(before, after):
    """Full state equality across reader refresh, queued work or an orderly restart."""
    versions = _report_versions(before)
    left, right = _state(before), _state(after)
    return (left is not None and right is not None and validate(before, versions, left["phase"])
        and validate(after, versions, left["phase"]) and _same_manifest(before, after)
        and _normalized(left) == _normalized(right)
        and all(_digests(before[key]) == _digests(after[key]) for key in TOP_DIGESTS))


def reviewed_transition(before, after, old):
    if not validate(before, [old], "baseline") or not validate(after, [old], "reviewed") or not _same_manifest(before, after):
        return False
    left, right = _state(before), _state(after)
    kind = after.get("recoveryInventorySeededReceiptKind")
    domain = {"live": "alerts", "historical": "historicalNotifications"}.get(kind) if isinstance(kind, str) else None
    return (domain is not None and left["counts"][domain] == 1
        and all(after.get(key) is True for key in ("recoveryInventoryReviewControlConsumed",
            "recoveryInventoryReviewApplied", "recoveryInventoryStoreReceiptSeeded"))
        and left["counts"] == right["counts"] and all(left[key] == right[key] for key in NUMERIC)
        and _domain_equal(left, right, DOMAINS - {"occurrences", domain})
        and len(_digests(left["digests"]["occurrences"]) ^ _digests(right["digests"]["occurrences"])) == 4
        and _digests(left["digests"][domain]).isdisjoint(_digests(right["digests"][domain]))
        and left["upgrade"]["recordStableDigests"] == right["upgrade"]["recordStableDigests"]
        and all(_digests(before[key]) == _digests(after[key]) for key in TOP_DIGESTS))


def acknowledged_transition(before, after, old):
    if not validate(before, [old], "reviewed") or not validate(after, [old], "reviewed-revoked7") or not _same_manifest(before, after):
        return False
    left, right = _state(before), _state(after)
    return (after.get("recoveryInventoryAcknowledgementControlConsumed") is True
        and after.get("recoveryInventoryAcknowledgementApplied") is True
        and _domain_equal(left, right, DOMAINS - {"obsoleteMarkers"})
        and all(left[key] == right[key] for key in NUMERIC if key != "revokedMarkerCount")
        and left["reviewCounts"] == right["reviewCounts"] and left["deliveryCounts"] == right["deliveryCounts"]
        and _normalized(left)["upgrade"] == _normalized(right)["upgrade"]
        and all(_digests(before[key]) == _digests(after[key]) for key in TOP_DIGESTS))


def new_content_preserves_original(before, after, old, new):
    """Allow seven new obsolete appearances while preserving every original full row."""
    if (not validate(before, [old], "reviewed-revoked7") or not validate(after, [old, new], "reviewed-revoked14")
            or not _same_manifest(before, after)):
        return False
    left, right = _state(before), _state(after)
    growing = {"occurrences", "analysisReceipts", "locationReceipts", "sourceKinds", "sourceTimes", "conversationLabels"}
    if (not _domain_equal(left, right, DOMAINS - growing - {"records"})
            or any(not _digests(left["digests"][key]) < _digests(right["digests"][key]) for key in growing)
            or any(right["counts"][key] - left["counts"][key] < 5 for key in ("analysisReceipts", "sourceKinds", "sourceTimes"))
            or left["upgrade"]["recordStableDigests"] != right["upgrade"]["recordStableDigests"]
            or _digests(left["upgrade"]["producerOccurrenceDigests"][old]) != _digests(right["upgrade"]["producerOccurrenceDigests"][old])
            or any(left[key] != right[key] for key in ("nextValueLabel", "schemaVersion", "removedLocationReceiptCount", "revokedMarkerCount"))
            or right["payloadRowCount"] <= left["payloadRowCount"]
            or left["deliveryCounts"] != right["deliveryCounts"]):
        return False
    return (_digests(before["recoveryOccurrenceDigests"]) < _digests(after["recoveryOccurrenceDigests"])
        and _digests(before["recoveryReceiptDigests"]) < _digests(after["recoveryReceiptDigests"])
        and _digests(before["recoveryAlertDigests"]) == _digests(after["recoveryAlertDigests"]))


# Deletion is a separate acceptance contract. In particular, it must never make
# the retained-value predicates accept missing reviews, alerts or payloads.
REMOVED_PHASES = {"baseline", "reviewed", "removed-upgrade7", "removed-upgrade14"}
WITNESS_MAPS = ("producerAppearanceCounts", "producerContentTypeCounts", "producerSessionCounts",
    "producerSourceDigests", "producerReceiptDigests", "producerAppearanceDigests")


def _removed_state(report):
    if not isinstance(report, dict):
        return None
    value = report.get("recoveryInventoryState")
    if (any(report.get(key) is not True for key in ("recoveryInventoryStateEnabled",
            "recoveryInventoryUpgradeStateEnabled", "recoveryInventoryRemovedUpgradeStateEnabled"))
            or report.get("recoveryInventoryControlFailure") is not None
            or type(report.get("recoveryInventoryRemovalApplied")) is not bool
            or not isinstance(value, dict) or value.get("measured") is not True
            or value.get("truncated") is not False or not isinstance(value.get("phase"), str)
            or value["phase"] not in REMOVED_PHASES or value.get("upgrade") is not None
            or value.get("systemNotificationDeliveryEstablished") is not False
            or value.get("actualNotificationDeliverySuppressed") is not True
            or report.get("gapReasons") != [] or report.get("coverageReportTruncated") is not False):
        return None
    counts, digests, removed = value.get("counts"), value.get("digests"), value.get("removedUpgrade")
    if (not isinstance(counts, dict) or set(counts) != DOMAINS
            or not isinstance(digests, dict) or set(digests) != DOMAINS
            or not isinstance(removed, dict) or removed.get("enabled") is not True):
        return None
    for key in DOMAINS:
        identities = _digests(digests[key])
        if type(counts[key]) is not int or not 0 <= counts[key] <= 128 or identities is None or len(identities) != counts[key]:
            return None
    if (any(type(value.get(key)) is not int or not 0 <= value[key] <= 128 for key in NUMERIC)
            or value["schemaVersion"] != 1 or value["nextValueLabel"] != 2
            or _digests([report.get("recoveryManifestDigest")]) is None):
        return None
    removed_locations = _digests(removed.get("removedLocationDigests"))
    if (removed_locations is None or len(removed_locations) != value["removedLocationReceiptCount"]
            or not removed_locations <= _digests(digests["locationReceipts"])):
        return None
    for key, domain in zip(TOP_DIGESTS, ("occurrences", "analysisReceipts", "alerts")):
        identities = _digests(report.get(key))
        if identities is None or len(identities) != counts[domain]:
            return None
    return value


def _removed_witness(report, state, new=None):
    witness = report.get("recoveryInventoryRemovedUpgradeWitness")
    if (not isinstance(witness, dict) or witness.get("measured") is not True
            or witness.get("truncated") is not False or witness.get("failure") is not None
            or any(type(witness.get(key)) is not int or not 0 <= witness[key] <= 128
                for key in ("observedSourceCount", "observedBatchCount", "matchedAppearanceCount"))
            or any(not isinstance(witness.get(key), dict) for key in WITNESS_MAPS)
            or not isinstance(witness.get("readerVersions"), list)
            or (witness["readerVersions"] and not _versions(witness["readerVersions"]))):
        return False
    if new is None:
        return (witness["matchedAppearanceCount"] == 0
            and witness.get("allAppearancesHaveCommittedNativeSource") is False
            and all(witness[key] == {} for key in WITNESS_MAPS))
    if (witness["observedSourceCount"] == 0 or witness["observedBatchCount"] == 0
            or witness["matchedAppearanceCount"] != 7
            or witness.get("allAppearancesHaveCommittedNativeSource") is not True
            or witness["readerVersions"] != [new]
            or not _counts(witness["producerAppearanceCounts"], {new: 7})
            or not _counts(witness["producerSessionCounts"], {new: 1})
            or set(witness["producerContentTypeCounts"]) != {new}
            or not _counts(witness["producerContentTypeCounts"][new], TYPES)):
        return False
    groups = {}
    for key in ("producerSourceDigests", "producerReceiptDigests", "producerAppearanceDigests"):
        if set(witness[key]) != {new}:
            return False
        identities = _digests(witness[key][new])
        if identities is None:
            return False
        groups[key] = identities
    return (5 <= len(groups["producerSourceDigests"]) <= 7
        and len(groups["producerSourceDigests"]) <= len(groups["producerReceiptDigests"]) <= 4 * len(groups["producerSourceDigests"])
        and groups["producerSourceDigests"] <= _digests(state["digests"]["sourceKinds"])
        and groups["producerReceiptDigests"] <= _digests(state["digests"]["analysisReceipts"])
        and groups["producerAppearanceDigests"] == _digests(state["digests"]["obsoleteAppearances"]))


def validate_removed(report, versions, phase):
    """Validate deleted-state phases; old version stays bound by the prior review.

    The new producer version comes from the transient native-source/receipt join,
    never from the configured executable or a metadata-only appearance itself.
    """
    if (not _versions(versions) or not isinstance(phase, str) or phase not in REMOVED_PHASES
            or len(versions) != (2 if phase == "removed-upgrade14" else 1)):
        return False
    return _validate_removed_contents(report, phase, old=versions[0], new=versions[1] if len(versions) == 2 else None)


def _validate_removed_contents(report, phase, *, old=None, new=None):
    value = _removed_state(report)
    if value is None or value["phase"] != phase:
        return False
    counts, removed = value["counts"], value["removedUpgrade"]
    if (any(counts[key] != 0 for key in ("unlocatedResults", "unlocatedReceipts", "unlocatedLabels"))
            or counts["valueLabels"] != 1
            or not counts["analysisReceipts"] >= counts["sourceKinds"] == counts["sourceTimes"] >= 5):
        return False
    if phase in ("baseline", "reviewed"):
        reviewed = phase == "reviewed"
        return (report.get("recoveryInventoryRemovalApplied") is False
            and all(counts[key] == number for key, number in (("records", 1), ("occurrences", 7),
                ("locationReceipts", 7), ("conversationLabels", 1), ("strongSignalReceipts", 1),
                ("obsoleteMarkers", 0), ("obsoleteAppearances", 0)))
            and counts["alerts"] + counts["historicalNotifications"] == 1
            and _counts(value.get("reviewCounts"), REVIEWED if reviewed else {"unreviewed": 7})
            and _counts(value.get("deliveryCounts"), {"delivered" if reviewed else "pending": 1})
            and value["removedLocationReceiptCount"] == value["revokedMarkerCount"] == 0
            and 0 < value["payloadRowCount"] == value["referencedPayloadCount"] == value["availableReferencedPayloadCount"]
            and _number(removed.get("protectedRecordCount"), 1) and _number(removed.get("metadataOnlyRecordCount"), 0)
            and removed.get("recordTimesMatchObsoleteAppearances") is False
            and _counts(removed.get("obsoleteAppearanceContentTypeCounts"), {})
            and all(_number(report.get(key), number) for key, number in (("valueCount", 1), ("occurrenceCount", 7),
                ("syntheticOccurrenceCount", 7), ("syntheticSessionCount", 1)))
            and report.get("observedAgentVersions") == [old]
            and _counts(report.get("syntheticOccurrencesByContentType"), TYPES)
            and isinstance(report.get("syntheticOccurrencesByProducerVersionAndContentType"), dict)
            and set(report["syntheticOccurrencesByProducerVersionAndContentType"]) == {old}
            and _counts(report["syntheticOccurrencesByProducerVersionAndContentType"][old], TYPES)
            and _removed_witness(report, value))
    expanded = phase == "removed-upgrade14"
    return (all(counts[key] == number for key, number in (("records", int(expanded)), ("occurrences", 0),
            ("obsoleteAppearances", 7 if expanded else 0), ("locationReceipts", 14 if expanded else 7),
            ("conversationLabels", 2 if expanded else 1), ("strongSignalReceipts", 0), ("obsoleteMarkers", 1), ("alerts", 0)))
        and counts["sourceKinds"] >= (10 if expanded else 5)
        and counts["historicalNotifications"] in (0, 1)
        and _counts(value.get("reviewCounts"), {})
        and _counts(value.get("deliveryCounts"), {"delivered": 1} if counts["historicalNotifications"] else {})
        and value["payloadRowCount"] == value["referencedPayloadCount"] == value["availableReferencedPayloadCount"] == 0
        and value["removedLocationReceiptCount"] == 7 and value["revokedMarkerCount"] == 1
        and _number(removed.get("protectedRecordCount"), 0)
        and _number(removed.get("metadataOnlyRecordCount"), int(expanded))
        and removed.get("recordTimesMatchObsoleteAppearances") is True
        and _counts(removed.get("obsoleteAppearanceContentTypeCounts"), TYPES if expanded else {})
        and all(_number(report.get(key), number) for key, number in (("valueCount", int(expanded)),
            ("occurrenceCount", 0), ("syntheticOccurrenceCount", 0), ("syntheticSessionCount", 0)))
        and report.get("observedAgentVersions") == []
        and report.get("syntheticOccurrencesByContentType") == {}
        and report.get("syntheticOccurrencesByProducerVersionAndContentType") == {}
        and _removed_witness(report, value, new if expanded else None))


def _normalized_removed(state):
    result = copy.deepcopy(state)
    result["digests"] = {key: sorted(value) for key, value in result["digests"].items()}
    result["removedUpgrade"]["removedLocationDigests"].sort()
    return result


def removed_unchanged(before, after):
    """Compare all durable state, excluding only the separate live batch witness."""
    left, right = _removed_state(before), _removed_state(after)
    if left is None or right is None or left["phase"] != right["phase"]:
        return False
    # Deleted old-source attribution was proved before removal and is retained by
    # this exact same-vault comparison; it cannot be reconstructed from no rows.
    versions = before.get("observedAgentVersions") if left["phase"] in ("baseline", "reviewed") else None
    new = None
    if left["phase"] == "removed-upgrade14":
        witness = before.get("recoveryInventoryRemovedUpgradeWitness")
        groups = witness.get("producerAppearanceCounts") if isinstance(witness, dict) else None
        if not isinstance(groups, dict) or len(groups) != 1:
            return False
        new = next(iter(groups))
        if not _versions([new]):
            return False
    valid = (validate_removed(before, versions, left["phase"]) and validate_removed(after, versions, left["phase"])) \
        if versions is not None else (_validate_removed_contents(before, left["phase"], new=new)
            and _validate_removed_contents(after, left["phase"], new=new))
    return (valid
        and _same_manifest(before, after) and _normalized_removed(left) == _normalized_removed(right)
        and all(_digests(before[key]) == _digests(after[key]) for key in TOP_DIGESTS))


def removed_reviewed_transition(before, after, old):
    if (not validate_removed(before, [old], "baseline") or not validate_removed(after, [old], "reviewed")
            or not _same_manifest(before, after)):
        return False
    left, right = _removed_state(before), _removed_state(after)
    kind = after.get("recoveryInventorySeededReceiptKind")
    domain = {"live": "alerts", "historical": "historicalNotifications"}.get(kind) if isinstance(kind, str) else None
    return (domain is not None and left["counts"][domain] == 1
        and all(after.get(key) is True for key in ("recoveryInventoryReviewControlConsumed",
            "recoveryInventoryReviewApplied", "recoveryInventoryStoreReceiptSeeded"))
        and left["counts"] == right["counts"] and all(left[key] == right[key] for key in NUMERIC)
        and left["removedUpgrade"] == right["removedUpgrade"]
        and _domain_equal(left, right, DOMAINS - {"occurrences", domain})
        and len(_digests(left["digests"]["occurrences"]) ^ _digests(right["digests"]["occurrences"])) == 4
        and _digests(left["digests"][domain]).isdisjoint(_digests(right["digests"][domain]))
        and all(_digests(before[key]) == _digests(after[key]) for key in TOP_DIGESTS))


def removed_transition(before, after, old):
    if (not validate_removed(before, [old], "reviewed") or not validate_removed(after, [old], "removed-upgrade7")
            or not _same_manifest(before, after)):
        return False
    left, right = _removed_state(before), _removed_state(after)
    changed = {"records", "occurrences", "obsoleteMarkers", "alerts", "strongSignalReceipts", "locationReceipts"}
    return (after.get("recoveryInventoryRemovalControlConsumed") is True
        and after.get("recoveryInventoryRemovalApplied") is True
        and _domain_equal(left, right, DOMAINS - changed)
        and _digests(left["digests"]["locationReceipts"]).isdisjoint(_digests(right["digests"]["locationReceipts"]))
        and _digests(right["removedUpgrade"]["removedLocationDigests"]) == _digests(right["digests"]["locationReceipts"])
        and _digests(before["recoveryReceiptDigests"]) == _digests(after["recoveryReceiptDigests"]))


def new_metadata_preserves_removal(before, after, old, new):
    if (not validate_removed(before, [old], "removed-upgrade7")
            or not validate_removed(after, [old, new], "removed-upgrade14") or not _same_manifest(before, after)):
        return False
    left, right = _removed_state(before), _removed_state(after)
    growing = {"records", "obsoleteAppearances", "analysisReceipts", "locationReceipts", "sourceKinds", "sourceTimes", "conversationLabels"}
    return (_domain_equal(left, right, DOMAINS - growing)
        and all(_digests(left["digests"][key]) < _digests(right["digests"][key]) for key in growing)
        and all(right["counts"][key] - left["counts"][key] >= 5 for key in ("analysisReceipts", "sourceKinds", "sourceTimes"))
        and _digests(left["removedUpgrade"]["removedLocationDigests"]) == _digests(right["removedUpgrade"]["removedLocationDigests"])
        and all(left[key] == right[key] for key in NUMERIC)
        and left["deliveryCounts"] == right["deliveryCounts"]
        and _digests(before["recoveryReceiptDigests"]) < _digests(after["recoveryReceiptDigests"]))
