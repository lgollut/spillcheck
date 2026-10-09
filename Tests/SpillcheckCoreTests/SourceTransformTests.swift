import Foundation
import Testing
@testable import SpillcheckCore

@Suite("Declared credential field mapping")
struct SourceTransformTests {
    @Test func decodesOnlyPasswordAndPreservesOriginalByteCoordinates() throws {
        let uri = "postgresql://user:p%C3%A4ss+%40%2B@localhost/db"
        let prefix = "🔐 "
        let source = try sourceRecord(text: prefix + uri + " trailing context")
        let bytes = source.segments[0].utf8
        let fieldRange = try #require(bytes.range(of: Data("p%C3%A4ss+%40%2B".utf8)))
        let field = try CanonicalLocation(segmentID: "text", range: UTF8Range(fieldRange.lowerBound, fieldRange.upperBound))
        let context = try CanonicalLocation(segmentID: "text", range: UTF8Range(prefix.utf8.count, prefix.utf8.count + uri.utf8.count))
        let extraction = try ExactExtraction.declaredURIPassword(location: field, context: context, in: source)
        #expect(extraction.valueUTF8 == Data("päss+@+".utf8))
        #expect(try extraction.location.extract(from: source) == Data("p%C3%A4ss+%40%2B".utf8))
        try extraction.validate(in: source)
        let finding = try LocatedDetection(extraction: extraction, in: source, fingerprint: fingerprint(),
            evidence: [evidence(category: .connectionCredential)], protectedValue: ProtectedPayloadReference())
        #expect(finding.location == field)
        #expect(throws: ContractError.valueDoesNotMatchSource) {
            try ExactExtraction(valueUTF8: extraction.valueUTF8, location: field, in: source)
        }
    }

    @Test func equalUsernameCannotBeSubstitutedForDeclaredPassword() throws {
        let source = try sourceRecord(text: "https://abc%20def:abc%20def@host")
        let raw = source.segments[0].utf8
        let username = try #require(raw.range(of: Data("abc%20def".utf8)))
        let field = try CanonicalLocation(segmentID: "text", range: UTF8Range(username.lowerBound, username.upperBound))
        let context = try CanonicalLocation(segmentID: "text", range: UTF8Range(0, raw.count))
        #expect(throws: ContractError.valueDoesNotMatchSource) {
            try ExactExtraction.declaredURIPassword(location: field, context: context, in: source)
        }
    }

    @Test(arguments: ["abc%", "abc%Q1", "abc%FF"])
    func invalidEscapesAndInvalidDecodedUTF8FailClosed(password: String) throws {
        let text = "https://user:\(password)@host"
        let source = try sourceRecord(text: text)
        let bytes = source.segments[0].utf8
        let range = try #require(bytes.range(of: Data(password.utf8)))
        let field = try CanonicalLocation(segmentID: "text", range: UTF8Range(range.lowerBound, range.upperBound))
        let context = try CanonicalLocation(segmentID: "text", range: UTF8Range(0, bytes.count))
        #expect(throws: (any Error).self) {
            try ExactExtraction.declaredURIPassword(location: field, context: context, in: source)
        }
    }

    @Test func ordinaryAssignmentsAndChangedSourceDoNotAuthorizeDecoding() throws {
        let text = "password = abc%20def"
        let source = try sourceRecord(text: text)
        let range = try #require(source.segments[0].utf8.range(of: Data("abc%20def".utf8)))
        let field = try CanonicalLocation(segmentID: "text", range: UTF8Range(range.lowerBound, range.upperBound))
        let context = try CanonicalLocation(segmentID: "text", range: UTF8Range(0, text.utf8.count))
        #expect(throws: ContractError.valueDoesNotMatchSource) {
            try ExactExtraction.declaredURIPassword(location: field, context: context, in: source)
        }
        let original = try sourceRecord(text: "ssh://u:abc%20def@host")
        let originalBytes = original.segments[0].utf8
        let password = try #require(originalBytes.range(of: Data("abc%20def".utf8)))
        let location = try CanonicalLocation(segmentID: "text", range: UTF8Range(password.lowerBound, password.upperBound))
        let whole = try CanonicalLocation(segmentID: "text", range: UTF8Range(0, originalBytes.count))
        let verified = try ExactExtraction.declaredURIPassword(location: location, context: whole, in: original)
        let changed = try sourceRecord(text: "ssh://u:abc%21def@host", revision: 2)
        #expect(throws: ContractError.valueDoesNotMatchSource) { try verified.validate(in: changed) }
    }
}
