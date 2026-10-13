import Foundation
@_spi(Testing) import SpillcheckCore

enum ReviewAssertionFailure: Error { case failed(String) }
@MainActor
func reviewAcceptanceAssertions() throws -> [String] {
    func check(_ value: Bool, _ label: String) throws {
        guard value else { throw ReviewAssertionFailure.failed(label) }
    }
    let descriptor = ReviewAcceptance.Descriptor(schemaVersion: 1,
        threadID: "11111111-1111-4111-8111-111111111111", turnID: "actual-native-review-turn",
        inputID: "original-input", outputID: "original-output", inputSHA256: String(repeating: "a", count: 64),
        outputSHA256: String(repeating: "b", count: 64), inputBytes: 100, outputBytes: 200, producerVersion: "0.162.1")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(descriptor)
    try check(ReviewAcceptance.Descriptor.decode(bytes) == descriptor, "review-canonical-descriptor-original-identities")
    let text = String(decoding: bytes, as: UTF8.self)
    let invalid = [bytes + Data([10]), Data("{}".utf8),
        Data(text.replacingOccurrences(of: "original-output", with: "original-input").utf8),
        Data(text.replacingOccurrences(of: "0.162.1", with: "0.162.2").utf8),
        Data(text.replacingOccurrences(of: "actual-native-review-turn", with: "").utf8),
        Data(text.replacingOccurrences(of: "actual-native-review-turn", with: String(repeating: "x", count: 257)).utf8),
        Data(text.replacingOccurrences(of: ":100", with: ":0").utf8),
        Data(text.replacingOccurrences(of: ":200", with: ":16385").utf8),
        Data(text.replacingOccurrences(of: String(repeating: "a", count: 64), with: "bad").utf8),
        Data(text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8)]
    for candidate in invalid {
        var rejected = false
        do { _ = try ReviewAcceptance.Descriptor.decode(candidate) } catch { rejected = true }
        try check(rejected, "review-invalid-descriptor-rejected")
    }
    return ["review-canonical-descriptor-original-identities", "review-invalid-descriptor-rejected"]
}
