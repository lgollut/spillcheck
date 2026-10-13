import Foundation
@_spi(Testing) import SpillcheckCore

enum DesktopBetaAssertionFailure: Error { case failed(String) }
@MainActor
func desktopBetaAcceptanceAssertions() throws -> [String] {
    func check(_ value: Bool, _ label: String) throws {
        guard value else { throw DesktopBetaAssertionFailure.failed(label) }
    }
    func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }
    func omission(_ object: [String: Any]) throws -> CoverageOmission {
        try JSONDecoder().decode(CoverageOmission.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    let earlier = Date(timeIntervalSinceReferenceDate: 1100)
    let latest = Date(timeIntervalSinceReferenceDate: 1500)
    let interval = DateInterval(start: Date(timeIntervalSinceReferenceDate: 1450),
        end: Date(timeIntervalSinceReferenceDate: 1550))
    let scope = CollectionScope(provider: .codex, profileID: "owned-signed-codex-desktop-beta",
        interface: .desktopCode, path: .publicHistory)
    let session = try SessionIdentity(provider: .codex, profileID: scope.profileID,
        sessionID: "22222222-2222-4222-8222-222222222222")
    let gap = CoverageGap(reason: .unsupportedContent, scope: scope, contentType: .userPrompt,
        operation: .historicalRead,
        recovery: .init(session: session, itemID: "codex-native-child-input", parserContract: CodexAdapter.parserContract),
        isRequiredFormatFailure: true, diagnosticCode: .nativeChildInputUnavailable, observedAt: earlier)
    guard let gapObject = try json(gap) as? [String: Any] else {
        throw DesktopBetaAssertionFailure.failed("desktop-beta-gap-json")
    }
    let oldObject: [String: Any] = ["id": "11111111-1111-4111-8111-111111111111", "gap": gapObject,
        "firstObservedAt": 1000, "state": CoverageOmissionState.blocked.rawValue]
    let old = try omission(oldObject)
    var newGap = gapObject; newGap["observedAt"] = try json(latest)
    var newObject = oldObject; newObject["gap"] = newGap
    let current = try omission(newObject)
    let emission = current.gap
    try check(DesktopBetaAcceptance.omissionRereadMatchesForTesting(old, old, emittedGap: emission, observedDuring: interval),
        "desktop-beta-durable-omission-exact-with-fresh-emission")
    try check(!DesktopBetaAcceptance.omissionRereadMatchesForTesting(current, old, emittedGap: emission, observedDuring: interval),
        "desktop-beta-durable-observation-must-not-advance")
    try check(!DesktopBetaAcceptance.omissionRereadMatchesForTesting(old, old, emittedGap: old.gap, observedDuring: interval),
        "desktop-beta-reread-needs-fresh-observation")
    for time in [1000.0, 1100.0, 1449.0, 1551.0] {
        var changedGap = newGap; changedGap["observedAt"] = time
        var changed = newObject; changed["gap"] = changedGap
        try check(!DesktopBetaAcceptance.omissionRereadMatchesForTesting(old, old,
            emittedGap: omission(changed).gap, observedDuring: interval),
            "desktop-beta-observation-must-be-within-replay")
    }
    for removeFromOld in [false, true] {
        var changedGap = removeFromOld ? gapObject : newGap; changedGap.removeValue(forKey: "observedAt")
        var changed = removeFromOld ? oldObject : newObject; changed["gap"] = changedGap
        let changedOmission = try omission(changed)
        try check(!DesktopBetaAcceptance.omissionRereadMatchesForTesting(
            removeFromOld ? changedOmission : old, removeFromOld ? changedOmission : old,
            emittedGap: removeFromOld ? emission : changedOmission.gap, observedDuring: interval),
            "desktop-beta-missing-observation-rejected")
    }
    let changedFields: [(String, Any)] = [("id", "33333333-3333-4333-8333-333333333333"),
        ("firstObservedAt", 1001), ("state", CoverageOmissionState.retryable.rawValue), ("resolvedAt", 1500)]
    for (key, value) in changedFields {
        var changed = oldObject; changed[key] = value
        try check(!DesktopBetaAcceptance.omissionRereadMatchesForTesting(omission(changed), old,
            emittedGap: emission, observedDuring: interval),
            "desktop-beta-omission-fields-unchanged")
    }
    let changedGapFields: [(String, Any)] = [("reason", CoverageGapReason.malformedSource.rawValue),
        ("contentType", ContentType.toolOutput.rawValue), ("operation", CollectionOperation.liveRead.rawValue),
        ("isRequiredFormatFailure", false), ("excludedContent", true),
        ("capabilityID", "44444444-4444-4444-8444-444444444444"),
        ("interval", try json(DateInterval(start: earlier, end: latest))),
        ("scope", try json(CollectionScope(provider: .codex, profileID: "other-profile", interface: .desktopCode, path: .publicHistory)))]
    for (key, value) in changedGapFields {
        var changedGap = newGap; changedGap[key] = value
        var changed = newObject; changed["gap"] = changedGap
        try check(!DesktopBetaAcceptance.omissionRereadMatchesForTesting(old, old,
            emittedGap: omission(changed).gap, observedDuring: interval), "desktop-beta-emission-fields-match")
        var changedDurableGap = gapObject; changedDurableGap[key] = value
        var changedDurable = oldObject; changedDurable["gap"] = changedDurableGap
        try check(!DesktopBetaAcceptance.omissionRereadMatchesForTesting(omission(changedDurable), old,
            emittedGap: emission, observedDuring: interval), "desktop-beta-durable-gap-fields-unchanged")
    }
    guard let recovery = newGap["recovery"] as? [String: Any] else {
        throw DesktopBetaAssertionFailure.failed("desktop-beta-recovery-json")
    }
    for (key, value) in [("itemID", "different-item"), ("parserContract", "old-parser")] {
        var changedRecovery = recovery; changedRecovery[key] = value
        var changedGap = newGap; changedGap["recovery"] = changedRecovery
        var changed = newObject; changed["gap"] = changedGap
        try check(!DesktopBetaAcceptance.omissionRereadMatchesForTesting(old, old,
            emittedGap: omission(changed).gap, observedDuring: interval),
            "desktop-beta-recovery-coordinates-unchanged")
    }
    try check(!DesktopBetaAcceptance.omissionRereadMatchesForTesting(old, old, emittedGap: emission,
        observedDuring: DateInterval(start: earlier, end: latest)), "desktop-beta-replay-interval-bounded")
    return ["desktop-beta-durable-omission-exact-with-fresh-emission", "desktop-beta-durable-observation-must-not-advance",
        "desktop-beta-reread-needs-fresh-observation",
        "desktop-beta-observation-must-be-within-replay", "desktop-beta-missing-observation-rejected",
        "desktop-beta-omission-fields-unchanged", "desktop-beta-emission-fields-match", "desktop-beta-durable-gap-fields-unchanged",
        "desktop-beta-recovery-coordinates-unchanged", "desktop-beta-replay-interval-bounded"]
}
