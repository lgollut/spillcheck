import Foundation

/// What a value's own text, or the output around it, says about when it stops working. It is read
/// from revealed content only, so it is never stored and never decides anything by itself.
public struct ExpiryHint: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// The value is a token whose own `exp` claim says when it expires.
        case tokenClaim
        /// The value sits in a signed link whose signature covers its expiry.
        case signedLink
        /// A field next to the value in the same object, such as `expiresAt`. It is what the output
        /// said when it was printed: a session can be extended each time it is used.
        case field(String)
        /// A link its service documents as expiring on its own, with no date to read.
        case shortLivedLink(service: String)
    }

    public enum State: Hashable, Sendable {
        /// The token or its link says it expired.
        case expired(Date)
        /// The output's date has passed, or a link meant to expire on its own is old. Not proof.
        case probablyExpired(Date?)
        /// It says when it expires, and that is still ahead.
        case expires(Date)
        /// A link that expires on its own, seen too recently to call it expired.
        case expiresOnItsOwn
    }

    public let source: Source
    public let expiresAt: Date?
    /// The latest appearance the hint was read from.
    public let seenAt: Date

    /// A link that expires on its own counts as probably expired once its latest appearance is this
    /// old. GitHub documents no lifetime for these links, only that they expire.
    public static let shortLivedAge: TimeInterval = 24 * 3600

    public init(source: Source, expiresAt: Date?, seenAt: Date) {
        self.source = source
        self.expiresAt = expiresAt
        self.seenAt = seenAt
    }

    public func state(at now: Date) -> State {
        switch source {
        case .tokenClaim, .signedLink:
            guard let expiresAt else { return .expiresOnItsOwn }
            return expiresAt <= now ? .expired(expiresAt) : .expires(expiresAt)
        case .field:
            guard let expiresAt else { return .expiresOnItsOwn }
            return expiresAt <= now ? .probablyExpired(expiresAt) : .expires(expiresAt)
        case .shortLivedLink:
            return now.timeIntervalSince(seenAt) >= Self.shortLivedAge ? .probablyExpired(nil) : .expiresOnItsOwn
        }
    }
}

/// Reads expiry evidence for one exact value from the text of its appearances.
public enum ExpiryDetector {
    public struct Appearance: Sendable {
        public let text: String
        public let observedAt: Date
        public init(text: String, observedAt: Date) {
            self.text = text
            self.observedAt = observedAt
        }
    }

    /// The strongest evidence wins: the token's own claim, then a signed link, then a field next to
    /// the value, then a link format that expires on its own. Among appearances, the latest date
    /// wins, because a later output can show a session that was extended.
    public static func hint(for value: String, in appearances: [Appearance]) -> ExpiryHint? {
        guard value.utf8.count >= 8 else { return nil }
        let latest = appearances.map(\.observedAt).max() ?? .distantPast
        if let expiry = tokenExpiry(value) { return ExpiryHint(source: .tokenClaim, expiresAt: expiry, seenAt: latest) }
        var signed: ExpiryHint?, field: ExpiryHint?, shortLived: ExpiryHint?
        for appearance in appearances {
            for hint in linkHints(for: value, in: appearance) {
                switch hint.source {
                case .shortLivedLink:
                    if shortLived.map({ hint.seenAt > $0.seenAt }) ?? true { shortLived = hint }
                default:
                    if later(hint, than: signed) { signed = hint }
                }
            }
            if let hint = fieldHint(for: value, in: appearance), later(hint, than: field) { field = hint }
        }
        return signed ?? field ?? shortLived
    }

    private static func later(_ hint: ExpiryHint, than current: ExpiryHint?) -> Bool {
        guard let current else { return true }
        return (hint.expiresAt ?? .distantPast) > (current.expiresAt ?? .distantPast)
    }

    // MARK: Token claims

    /// The `exp` claim of a JWT, when the value is one.
    static func tokenExpiry(_ value: String) -> Date? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, value.hasPrefix("eyJ"),
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }),
              let payload = base64URLDecode(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let exp = claims["exp"] as? NSNumber else { return nil }
        return plausible(Date(timeIntervalSince1970: exp.doubleValue))
    }

    private static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    // MARK: Links

    private static let linkCharacters = CharacterSet(charactersIn: " \t\r\n\"'<>`\\")
    /// Bounds the work on one excerpt: a value printed more often than this says nothing new.
    private static let maxOccurrences = 32

    /// Hints from every link in the appearance that contains the value.
    static func linkHints(for value: String, in appearance: Appearance) -> [ExpiryHint] {
        let text = appearance.text
        var hints: [ExpiryHint] = []
        var searchStart = text.startIndex
        var seen = 0
        while seen < maxOccurrences, let found = text.range(of: value, range: searchStart..<text.endIndex) {
            searchStart = found.upperBound
            seen += 1
            guard let link = link(around: found, in: text) else { continue }
            if let hint = linkHint(link, value: value, seenAt: appearance.observedAt) { hints.append(hint) }
        }
        return hints
    }

    /// The URL that contains `range`, if the value sits inside one.
    private static func link(around range: Range<String.Index>, in text: String) -> String? {
        let windowStart = text.index(range.lowerBound, offsetBy: -2048, limitedBy: text.startIndex) ?? text.startIndex
        guard let scheme = text.range(of: "http", options: .backwards, range: windowStart..<range.lowerBound),
              text[scheme.lowerBound...].hasPrefix("https://") || text[scheme.lowerBound...].hasPrefix("http://") else { return nil }
        var end = scheme.lowerBound
        let limit = text.index(range.upperBound, offsetBy: 2048, limitedBy: text.endIndex) ?? text.endIndex
        while end < limit, !text[end].unicodeScalars.contains(where: linkCharacters.contains) {
            end = text.index(after: end)
        }
        guard end >= range.upperBound else { return nil }
        return String(text[scheme.lowerBound..<end])
    }

    private static func linkHint(_ link: String, value: String, seenAt: Date) -> ExpiryHint? {
        guard let question = link.firstIndex(of: "?") else { return nil }
        let host = link[..<question].split(separator: "/").dropFirst().first.map { $0.lowercased() } ?? ""
        var query: [String: String] = [:], raw: [String: String] = [:]
        for item in link[link.index(after: question)...].split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1)
            guard let name = pair.first?.lowercased() else { continue }
            let text = pair.count > 1 ? String(pair[1]) : ""
            raw[name] = text
            query[name] = text.removingPercentEncoding ?? text
        }
        // A link's end is the end of its signature only. A key id, a session token or any other
        // credential carried in the same link has a lifetime of its own.
        func isSignature(_ name: String) -> Bool { query[name] == value || raw[name] == value }
        func signedV4(_ prefix: String) -> Date? {
            guard isSignature("\(prefix)-signature"), let date = query["\(prefix)-date"].flatMap(compactTimestamp),
                  let seconds = query["\(prefix)-expires"].flatMap(TimeInterval.init) else { return nil }
            return plausible(date.addingTimeInterval(seconds))
        }
        if let expiry = signedV4("x-amz") ?? signedV4("x-goog") {
            return ExpiryHint(source: .signedLink, expiresAt: expiry, seenAt: seenAt)
        }
        // An Azure shared access signature names its end time.
        if isSignature("sig"), let end = query["se"].flatMap(isoDate).flatMap(plausible) {
            return ExpiryHint(source: .signedLink, expiresAt: end, seenAt: seenAt)
        }
        // A CloudFront signed link names its end as an epoch time.
        if isSignature("signature"), query["key-pair-id"] != nil,
           let end = query["expires"].flatMap(TimeInterval.init).flatMap({ plausible(Date(timeIntervalSince1970: $0)) }) {
            return ExpiryHint(source: .signedLink, expiresAt: end, seenAt: seenAt)
        }
        // GitHub documents download links as expiring and meant to be used once, without a lifetime.
        // A personal access or app token put in such a link keeps its own lifetime.
        let ownLifetime = ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"].contains { value.hasPrefix($0) }
        if ["raw.githubusercontent.com", "codeload.github.com"].contains(host), !ownLifetime, query["token"] == value {
            return ExpiryHint(source: .shortLivedLink(service: "GitHub"), expiresAt: nil, seenAt: seenAt)
        }
        return nil
    }

    /// The compact UTC timestamp of AWS and Google V4 signatures, such as 20261103T095724Z.
    private static func compactTimestamp(_ text: String) -> Date? {
        let digits = Array(text.utf8)
        guard digits.count == 16, digits[8] == UInt8(ascii: "T"), digits[15] == UInt8(ascii: "Z") else { return nil }
        func number(_ range: Range<Int>) -> Int? { Int(String(decoding: digits[range], as: UTF8.self)) }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
              let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }

    // MARK: Fields

    /// Key endings that name an expiry, longest first so `expiresat` wins over `expires`.
    private static let expiryEndings = ["expirationtime", "expirationdate", "expiration", "expiresat", "expiresin",
                                        "expirytime", "expirydate", "expiretime", "expireat", "validuntil",
                                        "notafter", "expires", "expiry"]

    /// An expiry field next to the value, when the value is a whole string field of a JSON object.
    static func fieldHint(for value: String, in appearance: Appearance) -> ExpiryHint? {
        if let hint = fieldHint(for: value, text: appearance.text, observedAt: appearance.observedAt) { return hint }
        // JSON printed inside a string arrives with its quotes escaped.
        guard appearance.text.contains("\\\"") else { return nil }
        let unescaped = appearance.text.replacingOccurrences(of: "\\\"", with: "\"")
        return fieldHint(for: value, text: unescaped, observedAt: appearance.observedAt)
    }

    private static func fieldHint(for value: String, text: String, observedAt: Date) -> ExpiryHint? {
        let bytes = Array(text.utf8)
        let needle = Array(value.utf8)
        var best: ExpiryHint?
        var from = 0, seen = 0
        while seen < maxOccurrences, let at = firstIndex(of: needle, in: bytes, from: from) {
            from = at + 1
            seen += 1
            guard let (object, key) = enclosingObject(of: at..<(at + needle.count), in: bytes, value: value),
                  let expiry = expiry(in: object, forKey: key, observedAt: observedAt) else { continue }
            let hint = ExpiryHint(source: .field(expiry.field), expiresAt: expiry.date, seenAt: observedAt)
            if later(hint, than: best) { best = hint }
        }
        return best
    }

    private struct Pair {
        let key: String
        let value: String
        let range: Range<Int>
    }

    /// The innermost JSON object in which the value is a whole string field, with that field's key.
    /// Parsing starts at each `{` before the value, nearest first, so text clipped mid-string before
    /// the object doesn't throw the parser off.
    private static func enclosingObject(of range: Range<Int>, in bytes: [UInt8], value: String) -> ([Pair], String)? {
        var candidate = range.lowerBound - 1
        var tried = 0
        while candidate >= 0, tried < 64 {
            defer { candidate -= 1 }
            guard bytes[candidate] == UInt8(ascii: "{") else { continue }
            tried += 1
            for object in parseObjects(from: candidate, in: bytes) {
                if let pair = object.first(where: { $0.range == range && $0.value == value }) { return (object, pair.key) }
            }
        }
        return nil
    }

    /// The fields of every object opened at or after `start`, until the object at `start` closes.
    /// Lenient: only double-quoted strings, and nested values other than scalars are skipped.
    private static func parseObjects(from start: Int, in bytes: [UInt8]) -> [[Pair]] {
        var objects: [[Pair]] = []
        var stack: [Int?] = []  // an index into `objects` for `{`, nil for `[`
        var pendingKey: String?
        var i = start
        let n = min(bytes.count, start + 16_384)
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        while i < n {
            let byte = bytes[i]
            switch byte {
            case UInt8(ascii: "\""):
                var j = i + 1, escaped = false
                while j < n {
                    if escaped { escaped = false } else if bytes[j] == UInt8(ascii: "\\") { escaped = true }
                    else if bytes[j] == UInt8(ascii: "\"") { break }
                    j += 1
                }
                guard j < n else { return objects }
                let content = (i + 1)..<j
                let string = String(decoding: bytes[content], as: UTF8.self)
                var k = j + 1
                while k < n, isSpace(bytes[k]) { k += 1 }
                if let top = stack.last, let object = top {
                    if pendingKey == nil, k < n, bytes[k] == UInt8(ascii: ":") {
                        pendingKey = string
                        i = k + 1
                        continue
                    }
                    if let key = pendingKey {
                        objects[object].append(Pair(key: key, value: string, range: content))
                        pendingKey = nil
                    }
                }
                i = j + 1
                continue
            case UInt8(ascii: "{"):
                pendingKey = nil
                objects.append([])
                stack.append(objects.count - 1)
            case UInt8(ascii: "["):
                pendingKey = nil
                stack.append(nil)
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                pendingKey = nil
                guard !stack.isEmpty else { return objects }
                stack.removeLast()
                if stack.isEmpty { return objects }
            case UInt8(ascii: ","):
                pendingKey = nil
            default:
                // A bare number is a field's value too, as in "expires_in": 3600, sign included so
                // that -1 isn't read as one second. true, null and the like end the field.
                if let key = pendingKey, let top = stack.last, let object = top, !isSpace(byte) {
                    pendingKey = nil
                    let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
                    guard digits.contains(byte) || byte == UInt8(ascii: "-") else { break }
                    var j = i + 1
                    while j < n, digits.contains(bytes[j]) || ".eE+-".utf8.contains(bytes[j]) { j += 1 }
                    objects[object].append(Pair(key: key, value: String(decoding: bytes[i..<j], as: UTF8.self), range: i..<j))
                    i = j
                    continue
                }
            }
            i += 1
        }
        return objects
    }

    /// The expiry field that belongs to the value's field. A field named for another credential,
    /// such as `refreshTokenExpiresAt` next to an access token, doesn't count. A plain `expiresAt`
    /// doesn't count for a refresh token, which usually outlives it.
    private static func expiry(in object: [Pair], forKey key: String, observedAt: Date) -> (field: String, date: Date)? {
        let own = normalized(key)
        var paired: [(String, Date)] = [], plain: [(String, Date)] = []
        for pair in object where pair.key != key && isPlainFieldName(pair.key) {
            let name = normalized(pair.key)
            let ending: String?
            if name == "exp" { ending = "exp" } else { ending = expiryEndings.first { name.hasSuffix($0) } }
            guard let ending, let date = date(pair.value, relative: ending == "expiresin", observedAt: observedAt) else { continue }
            let prefix = String(name.dropLast(ending.count))
            if prefix.isEmpty {
                if isShortLived(own) { plain.append((pair.key, date)) }
            } else if prefix == own || own.hasPrefix(prefix) || prefix.hasPrefix(own) {
                paired.append((pair.key, date))
            }
        }
        return (paired.isEmpty ? plain : paired).max { $0.1 < $1.1 }
    }

    /// An unnamed expiry, such as a bare `expiresAt`, describes the session or token in its object.
    /// It isn't taken for a client secret, a password or an API key printed in the same object,
    /// which keep working after it, nor for a refresh token, which usually outlives it.
    private static func isShortLived(_ own: String) -> Bool {
        let longLived = ["refresh", "secret", "password", "passwd", "private", "client", "apikey", "key"]
        guard !longLived.contains(where: own.contains), own != "id", own != "userid" else { return false }
        return ["token", "session", "jwt", "bearer", "cookie", "ticket", "otp"].contains(where: own.contains)
    }

    /// Field names are shown to the user, so only plain ones count.
    private static func isPlainFieldName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 40 && name.unicodeScalars.allSatisfy {
            $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "_-.".unicodeScalars.contains($0))
        }
    }

    private static func normalized(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func date(_ raw: String, relative: Bool, observedAt: Date) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if relative {
            guard let seconds = TimeInterval(text), seconds > 0, seconds < 100_000_000 else { return nil }
            return observedAt.addingTimeInterval(seconds)
        }
        if text.allSatisfy(\.isNumber), let number = TimeInterval(text) {
            switch text.count {
            case 9...10: return plausible(Date(timeIntervalSince1970: number))
            case 12...13: return plausible(Date(timeIntervalSince1970: number / 1000))
            default: return nil
            }
        }
        return isoDate(text).flatMap(plausible)
    }

    private static func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Dates outside this century are more likely ids or counters than expiries.
    private static func plausible(_ date: Date) -> Date? {
        (946_684_800...4_102_444_800).contains(date.timeIntervalSince1970) ? date : nil
    }

    private static func firstIndex(of needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count, start <= bytes.count - needle.count else { return nil }
        var i = start
        while i <= bytes.count - needle.count {
            if bytes[i] == needle[0], bytes[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }
}
