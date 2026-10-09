import Foundation

struct ScannerReportFinding: Decodable {
    let RuleID: String?
    let Match: String?
    let Secret: String?
    let StartLine: Int?
    let EndLine: Int?
    let StartColumn: Int?
    let EndColumn: Int?
    let Attributes: [String: String]?
    let ComponentSets: [ScannerComponentSet]?
}

struct ScannerComponentSet: Decodable { let components: [ScannerReportFinding]? }

enum ScannerMapper {
    static let maximumFindings = 4_096

    static func map(
        _ report: Data, source: SourceRecord, segment: SourceSegment, allowedRuleIDs: Set<String>,
        deadline: TimeInterval = .infinity
    ) throws -> DetectorOutput {
        let reports: [ScannerReportFinding]
        do { reports = try JSONDecoder().decode([ScannerReportFinding]?.self, from: report) ?? [] }
        catch { throw DetectorFailure.invalidReport }
        guard reports.count <= maximumFindings else { throw DetectorFailure.outputLimitExceeded }
        var located: [DetectorFinding] = []
        var unlocated: [UnlocatedDetection] = []
        var gaps: Set<CoverageGap> = []
        var expanded: [(ScannerReportFinding, String?)] = []
        for finding in reports {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DetectorFailure.timedOut }
            guard let id = finding.RuleID, allowedRuleIDs.contains(id) else {
                let evidence = try unknownEvidence()
                unlocated.append(try UnlocatedDetection(evidence: [evidence], reason: .scannerReportMismatch))
                gaps.insert(CoverageGap(reason: .unsupportedContent))
                continue
            }
            if id == "aws-access-token" {
                // The public access-key identifier supplies context only. The measured
                // confidential component is the only composite field whose capture is supported.
                let before = expanded.count
                for set in finding.ComponentSets ?? [] {
                    for component in set.components ?? [] where component.RuleID == "aws-secret-access-key" {
                        expanded.append((component, finding.Attributes?["confidence"]))
                    }
                }
                if expanded.count == before {
                    unlocated.append(try UnlocatedDetection(evidence: [evidence(finding)], reason: .scannerReportMismatch))
                    gaps.insert(CoverageGap(reason: .unsupportedContent))
                }
            } else if finding.ComponentSets?.isEmpty == false,
                      !["generic-password", "generic-credential-uri"].contains(id) {
                unlocated.append(try UnlocatedDetection(evidence: [evidence(finding)], reason: .ambiguousRange))
                gaps.insert(CoverageGap(reason: .unsupportedContent))
            } else { expanded.append((finding, nil)) }
            guard expanded.count <= maximumFindings else { throw DetectorFailure.outputLimitExceeded }
        }
        let lineStarts = segment.utf8.enumerated().reduce(into: [0]) { offsets, item in
            if item.element == 10 { offsets.append(item.offset + 1) }
        }
        for (finding, parentConfidence) in expanded {
            guard !Task.isCancelled else { throw DetectorFailure.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DetectorFailure.timedOut }
            guard let id = finding.RuleID, allowedRuleIDs.contains(id) else {
                unlocated.append(try UnlocatedDetection(evidence: [unknownEvidence()], reason: .scannerReportMismatch))
                gaps.insert(CoverageGap(reason: .unsupportedContent))
                continue
            }
            let itemEvidence = evidence(finding, inheritedConfidence: parentConfidence)
            if id == "private-key", itemEvidence.reason == .localRule {
                gaps.insert(CoverageGap(reason: .unsupportedContent))
            }
            do {
                let extractions = try extractions(finding, source: source, segment: segment, lineStarts: lineStarts)
                for extraction in extractions {
                    located.append(try DetectorFinding(extraction: extraction, evidence: [itemEvidence]))
                    guard located.count <= maximumFindings else { throw DetectorFailure.outputLimitExceeded }
                }
            } catch let error as LocationMappingFailure {
                unlocated.append(try UnlocatedDetection(evidence: [itemEvidence], reason: error.reason))
                gaps.insert(CoverageGap(reason: .unsupportedContent))
            }
        }
        return DetectorOutput(detectorVersion: BetterleaksSecretDetector.version,
                              findings: try merge(located), unlocated: Array(Set(unlocated)), coverageGaps: Array(gaps))
    }

    static func evidence(_ finding: ScannerReportFinding, inheritedConfidence: String? = nil) -> DetectionEvidence {
        let id = finding.RuleID!
        let category: SecretCategory
        let reason: DetectionReason
        let incompletePEM = id == "private-key" && !NativeSecretRules.isCompletePEM(Data((finding.Secret ?? "").utf8))
        if id.contains("private-key") {
            category = .privateKey; reason = incompletePEM ? .localRule : .privateKeyBlock
        } else if id.contains("credential-uri") || id.contains("connection-string") {
            category = .connectionCredential; reason = .connectionString
        } else if id.contains("password") {
            category = .password; reason = .credentialField
        } else if ["token", "jwt", "pat", "bearer"].contains(where: { id.contains($0) }) {
            category = .token; reason = .recognizedFormat
        } else { category = .apiKey; reason = id == "generic-api-key" ? .credentialField : .recognizedFormat }
        // Scanner confidence is evidence, never provider validation or user review.
        let confidence = finding.Attributes?["confidence"] ?? inheritedConfidence
        return DetectionEvidence(rule: try! RuleIdentity(id: id, version: "betterleaks-1.9.0"),
                                 signal: confidence == "high" && !incompletePEM ? .strong : .ambiguous, reason: reason, category: category)
    }

    private static func unknownEvidence() throws -> DetectionEvidence {
        DetectionEvidence(rule: try RuleIdentity(id: "leakret-unrecognized-report-rule", version: "1"),
                          signal: .ambiguous, reason: .localRule, category: .apiKey)
    }

    private struct LocationMappingFailure: Error {
        let reason: LocationFailure
        init(_ reason: LocationFailure) { self.reason = reason }
    }

    private static func extractions(
        _ finding: ScannerReportFinding, source: SourceRecord, segment: SourceSegment, lineStarts: [Int]
    ) throws -> [ExactExtraction] {
        guard let match = finding.Match, let secret = finding.Secret, !match.isEmpty, !secret.isEmpty,
              let sl = finding.StartLine, let el = finding.EndLine, let sc = finding.StartColumn, let ec = finding.EndColumn,
              sl >= 1, sl <= el, el <= lineStarts.count, sc >= 1, ec >= 1 else {
            throw LocationMappingFailure(.scannerReportMismatch)
        }
        let matchBytes = Data(match.utf8), secretBytes = Data(secret.utf8)
        let (start, startOverflow) = lineStarts[sl - 1].addingReportingOverflow(sc - 1)
        let (end, endOverflow) = lineStarts[el - 1].addingReportingOverflow(ec)
        guard !startOverflow, !endOverflow else { throw LocationMappingFailure(.scannerReportMismatch) }
        let coordinateValid = start >= 0 && start < end && end <= segment.utf8.count
            && segment.utf8.subdata(in: start..<end) == matchBytes
        let contexts = try allRanges(of: matchBytes, in: segment.utf8)
        guard coordinateValid || !contexts.isEmpty else { throw LocationMappingFailure(.scannerReportMismatch) }
        let captures = try captureRanges(match: match, secret: secretBytes, ruleID: finding.RuleID!)
        guard !captures.isEmpty else { throw LocationMappingFailure(.ambiguousRange) }
        var result: [ExactExtraction] = []
        for context in contexts {
            for capture in captures {
                let range = try UTF8Range(context.lowerBound + capture.lowerBound, context.lowerBound + capture.upperBound)
                let location = try CanonicalLocation(segmentID: segment.id, range: range)
                do {
                    if finding.RuleID == "generic-credential-uri", secretBytes.contains(37) {
                        let whole = try CanonicalLocation(segmentID: segment.id,
                                                         range: UTF8Range(context.lowerBound, context.upperBound))
                        result.append(try ExactExtraction.declaredURIPassword(location: location, context: whole, in: source))
                    } else {
                        result.append(try ExactExtraction(valueUTF8: secretBytes, location: location, in: source))
                    }
                } catch { throw LocationMappingFailure(.invalidEncoding) }
                guard result.count <= maximumFindings else { throw DetectorFailure.outputLimitExceeded }
            }
        }
        return result
    }

    private static func captureRanges(match: String, secret: Data, ruleID: String) throws -> [Range<Int>] {
        let bytes = Data(match.utf8)
        if ruleID == "generic-password" {
            let assignment = try NSRegularExpression(pattern: #"(?i)^(?:passw(?:or)?d|psw|[_.-]pw)\b[ \t'"\\]{0,3}(?:=>|:=|=|:)[ \t]{0,5}"#)
            if let prefix = assignment.firstMatch(in: match, range: NSRange(match.startIndex..., in: match)),
               let range = Range(prefix.range, in: match) {
                var start = match[..<range.upperBound].utf8.count
                if start < bytes.count, [34, 39, 96].contains(bytes[start]) { start += 1 }
                guard start + secret.count <= bytes.count, bytes.subdata(in: start..<(start + secret.count)) == secret else { return [] }
                return [start..<(start + secret.count)]
            }
        }
        let pattern: String?
        switch ruleID {
        case "generic-credential-uri":
            pattern = #"(?i)^(?:https?|postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|rediss?|amqps?|ldaps?|smtps?|ftps?|ssh)://[^:/@\s'"`]{0,128}:([^/@\s'"`]{1,256})@"#
        case "generic-password":
            pattern = #"(?i)^(?:login|log_in|authenticate)\b[ \t]*\([ \t]*[^,()\r\n]{1,250}[ \t]*,[ \t]*["'`]((?:\\.|[^"'`\\\r\n]){4,250})["'`]"#
        default: pattern = nil
        }
        if let pattern {
            let expression = try NSRegularExpression(pattern: pattern)
            guard let capture = expression.firstMatch(in: match, range: NSRange(match.startIndex..., in: match)),
                  let range = Range(capture.range(at: 1), in: match) else { return [] }
            let start = match[..<range.lowerBound].utf8.count
            let end = start + match[range].utf8.count
            return bytes.subdata(in: start..<end) == secret ? [start..<end] : []
        }
        let candidates = try allRanges(of: secret, in: bytes)
        return candidates.count == 1 ? candidates : []
    }

    private static func allRanges(of needle: Data, in haystack: Data) throws -> [Range<Int>] {
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        while start < haystack.count, let range = haystack.range(of: needle, in: start..<haystack.count) {
            ranges.append(range)
            guard ranges.count <= maximumFindings else { throw DetectorFailure.outputLimitExceeded }
            start = range.upperBound
        }
        return ranges
    }

    static func merge(_ findings: [DetectorFinding]) throws -> [DetectorFinding] {
        var merged: [CanonicalLocation: DetectorFinding] = [:]
        for finding in findings {
            if let previous = merged[finding.extraction.location] {
                let extraction: ExactExtraction
                if previous.extraction.valueUTF8 == finding.extraction.valueUTF8 { extraction = previous.extraction }
                else {
                    switch (previous.extraction.transform, finding.extraction.transform) {
                    case (.identity, .declaredURIPasswordPercentEncoding): extraction = finding.extraction
                    case (.declaredURIPasswordPercentEncoding, .identity): extraction = previous.extraction
                    default: throw ContractError.conflictingValueAtLocation
                    }
                }
                merged[finding.extraction.location] = try DetectorFinding(
                    extraction: extraction, evidence: previous.evidence.union(finding.evidence))
            } else { merged[finding.extraction.location] = finding }
        }
        return merged.values.sorted {
            let a = $0.extraction.location.components[0], b = $1.extraction.location.components[0]
            return a.segmentID == b.segmentID ? a.range.lowerBound < b.range.lowerBound : a.segmentID < b.segmentID
        }
    }
}
