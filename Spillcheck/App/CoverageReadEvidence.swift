import Foundation
import SpillcheckCore

extension AppModel {
    /// Durable read times survive relaunch. They never establish that a reader is running now.
    func restoreSuccessfulReads(from report: CoverageReport) {
        let reads = report.successfulReads.items.filter { read in
            guard let profile = agentProfiles[read.scope.provider] else { return false }
            return profile.profileID == read.scope.profileID && profile.collectionInterfaces.contains(read.scope.interface)
        }
        var readDates: [CollectionScope: Date] = [:]
        var operationReads: [CollectionScope: [CollectionOperation: Date]] = [:]
        for read in reads {
            readDates[read.scope] = max(readDates[read.scope] ?? .distantPast, read.succeededAt)
            operationReads[read.scope, default: [:]][read.operation] = max(
                operationReads[read.scope]?[read.operation] ?? .distantPast, read.succeededAt)
        }
        // This runs on every refresh. An assignment invalidates every view that reads the
        // value, even when it is unchanged, so only changes are published.
        if lastReadDates != readDates { lastReadDates = readDates }
        if lastOperationReads != operationReads { lastOperationReads = operationReads }
        var assessments = collectionAssessments
        for scope in Set(reads.map(\.scope)).union(assessments.keys) {
            guard let profile = agentProfiles[scope.provider], profile.profileID == scope.profileID else { continue }
            let evidence = reads.filter { $0.scope == scope }
            // Published acceptance describes an exact producer/reader/host tuple and route.
            // A runtime read, or evidence for an older executable, cannot confer acceptance.
            // Codex's configured interface is a shared transport binding. Even
            // a matching published version tuple cannot identify the actual host.
            let accepted = scope.provider != .codex && !evidence.isEmpty && evidence.allSatisfy { read in
                guard read.readerVersion == profile.version,
                      !read.producerVersions.isEmpty,
                      scope.path == (scope.provider == .codex ? .publicHistory : .versionedTranscript),
                      scope.interface != .t3 || read.hostVersion == profile.t3Version else { return false }
                return read.producerVersions.allSatisfy {
                    CollectionCompatibility.recordedEvidence(provider: scope.provider, interface: scope.interface,
                        producerVersion: $0, readerVersion: read.readerVersion, hostVersion: read.hostVersion) == .validated
                }
            }
            let current = assessments[scope]
            assessments[scope] = CollectionAssessment(scope: scope,
                observedExecutableVersion: current?.observedExecutableVersion ?? profile.version,
                format: current?.format, usableOperations: current?.usableOperations ?? [],
                unavailableContent: current?.unavailableContent ?? [], failures: current?.failures ?? [],
                acceptanceEvidence: accepted ? .validated : .unverified)
        }
        if collectionAssessments != assessments { collectionAssessments = assessments }
    }
}
