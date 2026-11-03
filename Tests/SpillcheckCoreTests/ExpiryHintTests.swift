import Foundation
import Testing
@testable import SpillcheckCore

/// Values here are placeholders: the detector is told which value to look for, so nothing needs to
/// look like a real credential. The token is assembled at runtime for the same reason.
@Suite("Expiry hints read from revealed content")
struct ExpiryHintTests {
    private let value = "placeholder-value-0001"
    private let seen = Date(timeIntervalSince1970: 1_793_000_000)

    private func appearance(_ text: String, at time: Date? = nil) -> ExpiryDetector.Appearance {
        ExpiryDetector.Appearance(text: text, observedAt: time ?? seen)
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func token(claims: [String: Any]) throws -> String {
        func encode(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return try encode(["alg": "none"]) + "." + encode(claims) + ".sig"
    }

    @Test func sessionFieldNextToTheValueIsProbablyExpired() throws {
        let expires = seen.addingTimeInterval(7 * 86_400)
        let text = #"{"getSession":{"status":200,"body":{"session":{"expiresAt":"\#(iso(expires))","token":"\#(value)","ipAddress":"127.0.0.1"},"user":{"id":"u1"}}}}"#
        let hint = try #require(ExpiryDetector.hint(for: value, in: [appearance(text)]))
        #expect(hint.source == .field("expiresAt"))
        #expect(abs(hint.expiresAt!.timeIntervalSince(expires)) < 0.01)
        #expect(hint.state(at: expires.addingTimeInterval(60)) == .probablyExpired(hint.expiresAt))
        #expect(hint.state(at: seen) == .expires(hint.expiresAt!))
    }

    @Test func fieldOfAnotherObjectOrCredentialDoesNotCount() {
        let past = iso(seen.addingTimeInterval(-3600))
        // The expiry belongs to a nested object, not to the value's own object.
        let nested = #"{"token":"\#(value)","plan":{"expiresAt":"\#(past)"}}"#
        #expect(ExpiryDetector.hint(for: value, in: [appearance(nested)]) == nil)
        // A refresh token outlives the access token's expiry.
        let refresh = #"{"access_token":"other","refresh_token":"\#(value)","expires_in":3600}"#
        #expect(ExpiryDetector.hint(for: value, in: [appearance(refresh)]) == nil)
        // An expiry named for another credential.
        let named = #"{"accessToken":"\#(value)","refreshTokenExpiresAt":"\#(past)"}"#
        #expect(ExpiryDetector.hint(for: value, in: [appearance(named)]) == nil)
        // The value inside a longer string is not the field's value.
        let partial = #"{"note":"prefix \#(value) suffix","expiresAt":"\#(past)"}"#
        #expect(ExpiryDetector.hint(for: value, in: [appearance(partial)]) == nil)
    }

    @Test func expiryNamedForTheValuesOwnFieldWins() throws {
        let own = seen.addingTimeInterval(3600), other = seen.addingTimeInterval(30 * 86_400)
        let text = #"{"accessToken":"\#(value)","accessTokenExpiresAt":"\#(iso(own))","refreshTokenExpiresAt":"\#(iso(other))","expires":"\#(iso(other))"}"#
        let hint = try #require(ExpiryDetector.hint(for: value, in: [appearance(text)]))
        #expect(hint.source == .field("accessTokenExpiresAt"))
        #expect(abs(hint.expiresAt!.timeIntervalSince(own)) < 0.01)
    }

    @Test func relativeExpiryCountsFromTheAppearance() throws {
        let text = #"{"access_token":"\#(value)","token_type":"bearer","expires_in": 3600}"#
        let hint = try #require(ExpiryDetector.hint(for: value, in: [appearance(text)]))
        #expect(hint.source == .field("expires_in"))
        #expect(hint.expiresAt == seen.addingTimeInterval(3600))
    }

    @Test func clippedOrEscapedJSONStillReadsTheObject() throws {
        let expires = iso(seen.addingTimeInterval(60))
        // The excerpt starts in the middle of an earlier string, with an unbalanced quote.
        let clipped = #"l text with a stray " quote {"x":1} then {"expires_at":"\#(expires)","token":"\#(value)"}"#
        #expect(ExpiryDetector.hint(for: value, in: [appearance(clipped)])?.source == .field("expires_at"))
        let escaped = #"{\"session\":{\"token\":\"\#(value)\",\"expiresAt\":\"\#(expires)\"}}"#
        #expect(ExpiryDetector.hint(for: value, in: [appearance(escaped)])?.source == .field("expiresAt"))
    }

    @Test func latestDateAcrossAppearancesWins() throws {
        let first = #"{"token":"\#(value)","expiresAt":"\#(iso(seen.addingTimeInterval(60)))"}"#
        let renewed = #"{"token":"\#(value)","expiresAt":"\#(iso(seen.addingTimeInterval(7 * 86_400)))"}"#
        let hint = try #require(ExpiryDetector.hint(for: value, in: [appearance(renewed, at: seen.addingTimeInterval(3600)), appearance(first)]))
        #expect(hint.state(at: seen.addingTimeInterval(7200)) == .expires(hint.expiresAt!))
    }

    @Test func tokenClaimIsReliable() throws {
        let exp = seen.addingTimeInterval(900)
        let jwt = try token(claims: ["sub": "user", "exp": exp.timeIntervalSince1970])
        let hint = try #require(ExpiryDetector.hint(for: jwt, in: []))
        #expect(hint.source == .tokenClaim)
        #expect(hint.state(at: exp.addingTimeInterval(1)) == .expired(exp))
        #expect(ExpiryDetector.hint(for: try token(claims: ["sub": "user"]), in: []) == nil)
    }

    @Test func signedLinksNameTheirEnd() throws {
        let aws = "https://bucket.s3.amazonaws.com/file.zip?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=placeholder&X-Amz-Date=20261103T095724Z&X-Amz-Expires=300&X-Amz-SignedHeaders=host&X-Amz-Signature=\(value)"
        let hint = try #require(ExpiryDetector.hint(for: value, in: [appearance("Download: \(aws) done")]))
        #expect(hint.source == .signedLink)
        #expect(hint.expiresAt == Date(timeIntervalSince1970: 1_793_699_844 + 300))
        let azure = "https://account.blob.core.windows.net/c/file?sv=2024-01-01&se=2026-11-03T10%3A00%3A00Z&sp=r&sig=\(value)"
        #expect(ExpiryDetector.hint(for: value, in: [appearance(azure)])?.expiresAt == Date(timeIntervalSince1970: 1_793_700_000))
        // Without a signature, a date in a link is just a parameter.
        let unsigned = "https://example.com/report?X-Amz-Date=20261103T095724Z&X-Amz-Expires=300&id=\(value)"
        #expect(ExpiryDetector.hint(for: value, in: [appearance(unsigned)]) == nil)
    }

    @Test func githubDownloadLinksExpireOnTheirOwn() throws {
        let text = #"[{"name":"README.md","download_url":"https://raw.githubusercontent.com/org/repo/master/README.md?token=\#(value)","type":"file"}]"#
        let hint = try #require(ExpiryDetector.hint(for: value, in: [appearance(text)]))
        #expect(hint.source == .shortLivedLink(service: "GitHub"))
        #expect(hint.state(at: seen.addingTimeInterval(3600)) == .expiresOnItsOwn)
        #expect(hint.state(at: seen.addingTimeInterval(ExpiryHint.shortLivedAge)) == .probablyExpired(nil))
        // The same token outside a GitHub download link says nothing.
        #expect(ExpiryDetector.hint(for: value, in: [appearance("https://example.com/?token=\(value)")]) == nil)
    }

    @Test func onlyTheSignatureInheritsASignedLinksEnd() {
        let base = "https://bucket.s3.amazonaws.com/file.zip?X-Amz-Date=20261103T095724Z&X-Amz-Expires=300"
        // A session token, a key id or any other parameter keeps its own lifetime.
        for link in ["\(base)&X-Amz-Signature=other&X-Amz-Security-Token=\(value)",
                     "\(base)&X-Amz-Credential=\(value)&X-Amz-Signature=other",
                     "\(base)&X-Amz-Signature=other&token=\(value)",
                     "https://bucket.s3.amazonaws.com/\(value)/file.zip?X-Amz-Date=20261103T095724Z&X-Amz-Expires=300&X-Amz-Signature=other"] {
            #expect(ExpiryDetector.hint(for: value, in: [appearance(link)]) == nil)
        }
        // An end date outside this century is no hint at all, not a link without a date.
        let farAzure = "https://account.blob.core.windows.net/c/file?se=9999-12-31T00%3A00%3A00Z&sig=\(value)"
        let farCloudFront = "https://d1.cloudfront.net/file?Expires=99999999999&Signature=\(value)&Key-Pair-Id=placeholder"
        #expect(ExpiryDetector.hint(for: value, in: [appearance(farAzure)]) == nil)
        #expect(ExpiryDetector.hint(for: value, in: [appearance(farCloudFront)]) == nil)
    }

    @Test func unnamedExpiryIsOnlyForSessionsAndTokens() {
        let past = iso(seen.addingTimeInterval(-3600))
        for key in ["client_secret", "api_key", "password", "id", "private_key"] {
            let text = #"{"token":"other","\#(key)":"\#(value)","expiry":"\#(past)"}"#
            #expect(ExpiryDetector.hint(for: value, in: [appearance(text)]) == nil, "\(key)")
        }
        // A key named for the field still pairs, whatever the credential.
        let named = #"{"client_secret":"\#(value)","client_secret_expires_at":"\#(past)"}"#
        #expect(ExpiryDetector.hint(for: value, in: [appearance(named)])?.source == .field("client_secret_expires_at"))
    }

    @Test func oddNumbersAndNamesAreNotExpiries() {
        // A negative lifetime is not one second.
        let negative = #"{"access_token":"\#(value)","expires_in": -1}"#
        #expect(ExpiryDetector.hint(for: value, in: [appearance(negative)]) == nil)
        // A field name that isn't plain text is never shown.
        let odd = #"{"token":"\#(value)","expires at ✓":"\#(iso(seen))"}"#
        #expect(ExpiryDetector.hint(for: value, in: [appearance(odd)]) == nil)
    }

    @Test func githubTokensWithTheirOwnLifetimeAreNotDownloadLinks() {
        let pat = "ghp_" + value
        let text = "https://raw.githubusercontent.com/org/repo/main/README.md?token=\(pat)"
        #expect(ExpiryDetector.hint(for: pat, in: [appearance(text)]) == nil)
    }

    @Test func plainOutputHasNoHint() {
        #expect(ExpiryDetector.hint(for: value, in: [appearance("API_TOKEN=\(value)\nLOG_LEVEL=debug")]) == nil)
    }
}
