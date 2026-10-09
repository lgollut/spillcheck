import Foundation

/// The three measured supplements. They provide reduced coverage when Betterleaks is unavailable.
enum NativeSecretRules {
    /// A scanner's loose PEM expression does not establish a complete private-key block.
    /// The value must use the same header/footer label and measured minimum body size.
    static func isCompletePEM(_ bytes: Data) -> Bool {
        let lower = Data(bytes.map { (65...90).contains($0) ? $0 + 32 : $0 })
        let prefix = Data("-----begin ".utf8)
        guard lower.starts(with: prefix),
              let newline = lower.range(of: Data([10]), in: prefix.count..<min(lower.count, prefix.count + 128)),
              let label = String(data: lower.subdata(in: prefix.count..<newline.lowerBound), encoding: .utf8),
              let expression = try? NSRegularExpression(pattern: #"^((?:[a-z0-9_-]{1,64} )?)private key( block)?-----\r?$"#),
              let match = expression.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
              let tagRange = Range(match.range(at: 1), in: label) else { return false }
        let block = match.range(at: 2).location == NSNotFound ? "" : " block"
        let footer = Data("-----end \(label[tagRange])private key\(block)-----".utf8)
        return lower.count - footer.count - newline.lowerBound >= 64 && lower.suffix(footer.count) == footer
    }

    static func scan(_ segment: SourceSegment, source: SourceRecord, deadline: TimeInterval) throws -> DetectorOutput {
        guard let text = String(data: segment.utf8, encoding: .utf8) else { throw DetectorFailure.invalidSource }
        var findings: [DetectorFinding] = []
        var gaps: [CoverageGap] = []
        let rules: [(String, String, SecretCategory, DetectionReason)] = [
            ("leakret-opaque-bearer", #"(?im)\bAuthorization[\t ]*:[\t ]*Bearer[\t ]+([A-Za-z0-9._~+/-]{24,250})(?=[\t \r\n]|$)"#, .token, .entropy),
            ("leakret-prose-password", #"(?i)\b(?:database|account|login|service|smtp|redis|postgres(?:ql)?)?[\t ]*password[\t ]+is[\t ]+[`"']([^`"'\r\n]{5,250})[`"']"#, .password, .credentialField),
        ]
        for (id, pattern, category, reason) in rules {
            if ProcessInfo.processInfo.systemUptime >= deadline { gaps.append(CoverageGap(reason: .budgetExhausted)); break }
            let expression = try NSRegularExpression(pattern: pattern)
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard !Task.isCancelled else { throw DetectorFailure.cancelled }
                guard ProcessInfo.processInfo.systemUptime < deadline,
                      findings.count < ScannerMapper.maximumFindings else {
                    gaps.append(CoverageGap(reason: .budgetExhausted)); break
                }
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let value = String(text[range])
                guard !placeholder(value), id != "leakret-opaque-bearer" || entropy(value) >= 3.3 else { continue }
                let start = text[..<range.lowerBound].utf8.count
                let end = start + text[range].utf8.count
                let location = try CanonicalLocation(segmentID: segment.id, range: UTF8Range(start, end))
                let extraction = try ExactExtraction(valueUTF8: Data(value.utf8), location: location, in: source)
                let evidence = DetectionEvidence(rule: try RuleIdentity(id: id, version: "1"), signal: .ambiguous,
                                                 reason: reason, category: category)
                findings.append(try DetectorFinding(extraction: extraction, evidence: [evidence]))
            }
        }
        let pem = try completePEM(segment, source: source, deadline: deadline)
        findings.append(contentsOf: pem.findings)
        gaps.append(contentsOf: pem.coverageGaps)
        return DetectorOutput(detectorVersion: BetterleaksSecretDetector.version, findings: findings,
                              unlocated: [], coverageGaps: gaps)
    }

    private static func entropy(_ value: String) -> Double {
        let counts = Dictionary(grouping: value.utf8, by: { $0 }).mapValues(\.count)
        let count = Double(value.utf8.count)
        return counts.values.reduce(0) { value, frequency in
            let probability = Double(frequency) / count
            return value - probability * log2(probability)
        }
    }

    private static func placeholder(_ value: String) -> Bool {
        ["redacted", "masked", "filtered", "replace-me", "placeholder", "your-password"].contains(value.lowercased())
            || ["<", "${", "$(", "{{"].contains(where: { value.hasPrefix($0) })
            || Set(value).isSubset(of: Set("*xX.•"))
    }

    private static func completePEM(_ segment: SourceSegment, source: SourceRecord, deadline: TimeInterval) throws -> DetectorOutput {
        // A bounded byte parser avoids an unbounded backtracking regex for incomplete blocks.
        let lower = Data(segment.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 })
        let prefix = Data("-----begin ".utf8)
        var findings: [DetectorFinding] = []
        var gaps: [CoverageGap] = []
        var cursor = 0, candidates = 0
        var absentFooters: Set<Data> = []
        while cursor < lower.count, let beginning = lower.range(of: prefix, in: cursor..<lower.count) {
            guard !Task.isCancelled else { throw DetectorFailure.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline, candidates < 128,
                  findings.count < ScannerMapper.maximumFindings else {
                gaps.append(CoverageGap(reason: .budgetExhausted)); break
            }
            candidates += 1
            cursor = beginning.upperBound
            let lineEnd = lower.range(of: Data([10]), in: cursor..<min(lower.count, cursor + 128))?.lowerBound
                ?? min(lower.count, cursor + 128)
            let line = lower.subdata(in: cursor..<lineEnd)
            guard let label = String(data: line, encoding: .utf8) else { continue }
            let expression = try NSRegularExpression(pattern: #"^((?:[a-z0-9_-]{1,64} )?)private key( block)?-----\r?$"#)
            guard let match = expression.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
                  let tagRange = Range(match.range(at: 1), in: label) else { continue }
            let tag = String(label[tagRange])
            let block = match.range(at: 2).location == NSNotFound ? "" : " block"
            let footer = Data("-----end \(tag)private key\(block)-----".utf8)
            if absentFooters.contains(footer) { continue }
            guard let ending = lower.range(of: footer, in: lineEnd..<lower.count) else {
                absentFooters.insert(footer); continue
            }
            guard ending.lowerBound - lineEnd >= 64 else { cursor = ending.upperBound; continue }
            let location = try CanonicalLocation(segmentID: segment.id,
                                                 range: UTF8Range(beginning.lowerBound, ending.upperBound))
            let bytes = segment.utf8.subdata(in: beginning.lowerBound..<ending.upperBound)
            let evidence = DetectionEvidence(rule: try RuleIdentity(id: "leakret-complete-pem", version: "1"),
                                             signal: .strong, reason: .privateKeyBlock, category: .privateKey)
            findings.append(try DetectorFinding(extraction: ExactExtraction(valueUTF8: bytes, location: location, in: source),
                                                evidence: [evidence]))
            cursor = ending.upperBound
        }
        return DetectorOutput(detectorVersion: BetterleaksSecretDetector.version, findings: findings,
                              unlocated: [], coverageGaps: gaps)
    }
}
