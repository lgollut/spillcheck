import Foundation
import SpillcheckCore

/// Records only allowlisted startup facts. Constructing this snapshot never reads a vault,
/// a bootstrap journal, or device keys, including when an unknown framework error is supplied.
struct StorageStartupFailure: Encodable, Equatable {
    enum Phase: String, Encodable {
        case preparingStorage, probingStorage, loadingDeviceKeys, openingStore
        case committingBootstrap, configuringCollection, startingCapture
    }
    enum Reason: String, Encodable {
        case bootstrapBusy, bootstrapUnsafeJournal, bootstrapJournalUnavailable
        case bootstrapManifestMismatch, bootstrapCommitUnconfirmed
        case bootstrapRollbackIncomplete
        case keyMissingManifest, keyInvalidManifest, keyMissing, keyUnusable
        case keyAccessGroupUnavailable, keyUnsupportedInventoryAlgorithm
        case storageUnsafeLocation, storageDatabaseUnavailable, storageManifestMissing
        case storageManifestMismatch, storageCorruptProtectedState, storageProtectionUnavailable
        case storageUnavailable, unknown
    }
    let phase: Phase
    let occurredAt: Date
    let reason: Reason
    let component: KeyComponent?
    let nativeStatusCode: Int?

    init(error: any Error, phase: Phase, at time: Date = Date()) {
        self.phase = phase
        occurredAt = time
        var component: KeyComponent?
        var nativeStatusCode: Int?
        if let failure = error as? ProtectionBootstrapError {
            reason = switch failure {
            case .busy: .bootstrapBusy
            case .unsafeJournal: .bootstrapUnsafeJournal
            case .journalUnavailable: .bootstrapJournalUnavailable
            case .manifestMismatch: .bootstrapManifestMismatch
            case .commitUnconfirmed: .bootstrapCommitUnconfirmed
            case .rollbackIncomplete: .bootstrapRollbackIncomplete
            }
        } else if let failure = error as? KeyUnavailable {
            let diagnostic = KeyFailureDiagnostic(failure)
            component = diagnostic.component; nativeStatusCode = diagnostic.code
            reason = switch diagnostic.reason {
            case .missingManifest: .keyMissingManifest
            case .invalidManifest: .keyInvalidManifest
            case .missingKey: .keyMissing
            case .unusableKey: .keyUnusable
            case .accessGroupUnavailable: .keyAccessGroupUnavailable
            case .unsupportedInventoryAlgorithm: .keyUnsupportedInventoryAlgorithm
            }
        } else if let failure = error as? StorageError {
            reason = switch failure {
            case .unsafeStorageLocation: .storageUnsafeLocation
            case .databaseUnavailable: .storageDatabaseUnavailable
            case .manifestMissing: .storageManifestMissing
            case .manifestMismatch: .storageManifestMismatch
            case .corruptProtectedState: .storageCorruptProtectedState
            case .protectionUnavailable: .storageProtectionUnavailable
            default: .storageUnavailable
            }
        } else { reason = .unknown }
        self.component = component
        self.nativeStatusCode = nativeStatusCode
    }
}

/// Startup evidence is separate from coverage: an unavailable vault supplies no counts.
struct StartupDiagnostics: Encodable {
    enum ExportType: String, Encodable { case startupFailure }
    let schemaVersion = 1
    let exportType = ExportType.startupFailure
    let coverageAvailable = false
    let generatedAt: Date
    let appVersion: String?
    let appBuild: String?
    let startupFailure: StorageStartupFailure

    init(failure: StorageStartupFailure, at now: Date = Date(), bundle: Bundle = .main) {
        generatedAt = now
        let versions = DiagnosticsExport.versions(in: bundle)
        appVersion = versions.appVersion; appBuild = versions.appBuild
        startupFailure = failure
    }
}

enum DiagnosticsExport {
    enum Unavailable: Error { case noReport }
    static let help = "Exports versions, coverage states, queue counts, storage capacity and controlled startup details. No values, conversation text, paths or native identifiers."

    static func versions(in bundle: Bundle) -> (appVersion: String?, appBuild: String?) {
        (CoverageDiagnostics.version(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
         CoverageDiagnostics.version(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String))
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    /// A startup failure takes precedence even if startup opened part of the store.
    @MainActor static func encoded(model: AppModel, report: CoverageReport? = nil,
                                   at now: Date = Date(), bundle: Bundle = .main) throws -> Data {
        if model.canExportStartupDiagnostics, let failure = model.startupFailure {
            return try encode(StartupDiagnostics(failure: failure, at: now, bundle: bundle))
        }
        guard !model.storageUnavailable, let report else { throw Unavailable.noReport }
        return try CoverageDiagnostics(model: model, report: report, at: now, bundle: bundle).encoded()
    }
}

/// Only allowlisted fields enter this schema. Native identities get aliases valid in this export.
struct CoverageDiagnostics: Encodable {
    enum HostAttribution: String, Encodable {
        case unverified
    }

    private static func attributedHost(_ provider: AgentProvider?, _ interface: AgentInterface?) -> AgentInterface? {
        nil
    }

    private static func hostAttribution(_ provider: AgentProvider?) -> HostAttribution {
        .unverified
    }

    struct Query: Encodable {
        let returned: Int
        let total: Int
        let truncated: Bool
        init<Item>(_ page: CoverageQueryPage<Item>) {
            returned = page.items.count; total = page.totalCount; truncated = page.isTruncated
        }
    }
    struct Queue: Encodable {
        let pending: Int
        let historical: Int
        let processing: Int
        let encryptedBytes: Int
        let oldestPendingAt: Date?
    }
    struct Capacity: Encodable {
        struct Usage: Encodable {
            let count: Int
            let countLimit: Int
            let remainingCount: Int
            let encryptedBytes: Int
            let encryptedBytesLimit: Int
            let remainingEncryptedBytes: Int
            let countState: StoreCapacityState
            let bytesState: StoreCapacityState
            let state: StoreCapacityState

            init(_ usage: StoreCapacityUsage) {
                count = usage.count; countLimit = usage.countLimit; remainingCount = usage.remainingCount
                encryptedBytes = usage.encryptedBytes; encryptedBytesLimit = usage.encryptedBytesLimit
                remainingEncryptedBytes = usage.remainingEncryptedBytes
                countState = usage.countState; bytesState = usage.bytesState; state = usage.state
            }
        }
        let sourceAuthorities: Usage
        let codexHookContentSlots: Usage

        init(_ snapshot: StoreCapacitySnapshot) {
            sourceAuthorities = Usage(snapshot.sourceAuthorities)
            codexHookContentSlots = Usage(snapshot.codexHookContentSlots)
        }
    }
    struct Route: Encodable {
        let profileAlias: String
        let provider: AgentProvider
        let configuredInterface: AgentInterface
        let host: AgentInterface?
        let hostAttribution: HostAttribution
        let path: CollectionPath
        let observedExecutableVersion: String?
        let hostVersion: String?
        let configuredHostVersion: String?
        let lastReadAt: Date?
        let usableOperations: [CollectionOperation]
        let unavailableContent: [ContentType]
        let failures: [CompatibilityFailure]
        let acceptanceEvidence: CapabilityValidation
    }
    struct Gap: Encodable {
        let profileAlias: String?
        let auditAlias: String?
        let captureAlias: String?
        let provider: AgentProvider?
        let configuredInterface: AgentInterface?
        let host: AgentInterface?
        let hostAttribution: HostAttribution
        let path: CollectionPath?
        let reason: CoverageGapReason
        let contentType: ContentType?
        let operation: CollectionOperation?
        let sourceKind: CoverageSourceKind?
        let diagnosticCode: CoverageDiagnosticCode?
        let requiredContentFailure: Bool?
        let excludedContent: Bool?
        let state: CoverageIssueState
        let firstObservedAt: Date?
        let lastObservedAt: Date?
        let resolvedAt: Date?
        let affectedStart: Date?
        let affectedEnd: Date?
        let exactSourceRetryAvailable: Bool

        @MainActor init(_ observation: AppModel.CoverageObservation, aliases: inout Aliases) {
            let gap = observation.gap
            profileAlias = observation.profile.map { aliases.profile($0) }
            auditAlias = observation.audit.map { aliases.audit($0) }
            captureAlias = observation.workID.map { aliases.capture($0) }
            provider = gap.scope?.provider ?? observation.profile?.provider
            configuredInterface = gap.scope?.interface
            host = CoverageDiagnostics.attributedHost(provider, configuredInterface)
            hostAttribution = CoverageDiagnostics.hostAttribution(provider)
            path = gap.scope?.path
            reason = gap.reason; contentType = gap.contentType; operation = gap.operation
            sourceKind = gap.sourceKind; diagnosticCode = gap.diagnosticCode
            requiredContentFailure = gap.isRequiredFormatFailure; excludedContent = gap.excludedContent
            state = observation.state; firstObservedAt = observation.first; lastObservedAt = observation.last
            resolvedAt = observation.resolvedAt
            affectedStart = observation.affectedStart; affectedEnd = observation.affectedEnd
            exactSourceRetryAvailable = observation.retry != nil
        }
    }
    struct Audit: Encodable {
        let profileAlias: String
        let auditAlias: String
        let provider: AgentProvider
        let reason: AuditReason
        let windowStart: Date
        let windowEnd: Date
        let lastAttemptedAt: Date?
        let completedAt: Date?
        let continuationQueued: Bool?
        let hasUnreadContent: Bool
        let bytesRead: Int
    }
    struct Work: Encodable {
        let captureAlias: String
        let profileAlias: String
        let auditAlias: String?
        let provider: AgentProvider
        let configuredInterface: AgentInterface
        let host: AgentInterface?
        let hostAttribution: HostAttribution
        let path: CollectionPath
        let operation: CollectionOperation
        let trigger: CollectionWorkTrigger?
        let state: CollectionWorkState
        let admittedAt: Date
        let lastAttemptedAt: Date?
        let completedAt: Date?
        let exactSourceRetryAvailable: Bool
    }
    struct Read: Encodable {
        let profileAlias: String
        let provider: AgentProvider
        let configuredInterface: AgentInterface
        let host: AgentInterface?
        let hostAttribution: HostAttribution
        let path: CollectionPath
        let operation: CollectionOperation
        let succeededAt: Date
        let producerVersions: [String]
        let readerVersion: String?
        let hostVersion: String?
        let configuredHostVersion: String?
    }
    /// No mapping leaves this encoder, and aliases never contain protected input bytes.
    struct Aliases {
        private var profiles: [CoverageProfileKey: String] = [:]
        private var audits: [CoverageAuditIdentity: String] = [:]
        private var captures: [UUID: String] = [:]
        mutating func profile(_ key: CoverageProfileKey) -> String {
            if let existing = profiles[key] { return existing }
            let alias = "profile-\(profiles.count + 1)"; profiles[key] = alias; return alias
        }
        mutating func audit(_ key: CoverageAuditIdentity) -> String {
            if let existing = audits[key] { return existing }
            let alias = "audit-\(audits.count + 1)"; audits[key] = alias; return alias
        }
        mutating func capture(_ key: UUID) -> String {
            if let existing = captures[key] { return existing }
            let alias = "capture-\(captures.count + 1)"; captures[key] = alias; return alias
        }
    }

    let schemaVersion = 4
    let generatedAt: Date
    let appVersion: String?
    let appBuild: String?
    let claudeParserContract = ClaudeAdapter.parserContractVersion
    let codexParserContract = CodexAdapter.parserContract
    let window: DateInterval
    let monitoringEnabled: Bool
    let queue: Queue
    let capacity: Capacity?
    let eventQuery: Query
    let omissionQuery: Query
    let historyQuery: Query
    let workQuery: Query
    let successfulReadQuery: Query
    let omissionStateCounts: [String: Int]
    let omissionStateCountsComplete: Bool
    let routes: [Route]
    let gaps: [Gap]
    let audits: [Audit]
    let work: [Work]
    let successfulReads: [Read]

    /// Version probes must return version syntax, never arbitrary executable output.
    static func version(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 100,
              let range = value.range(of: #"^[0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z][0-9A-Za-z.+-]*)?$"#,
                          options: .regularExpression), range == value.startIndex..<value.endIndex else { return nil }
        return value
    }

    @MainActor init(model: AppModel, report: CoverageReport, at now: Date = Date(), bundle: Bundle = .main) {
        generatedAt = now
        let versions = DiagnosticsExport.versions(in: bundle)
        appVersion = versions.appVersion; appBuild = versions.appBuild
        window = report.window; monitoringEnabled = model.monitoringEnabled
        queue = .init(pending: report.queue.count, historical: report.queue.historicalCount,
            processing: report.queue.claimedCount, encryptedBytes: report.queue.encryptedBytes,
            oldestPendingAt: report.oldestPendingCaptureAt)
        capacity = report.capacity.map(Capacity.init)
        eventQuery = Query(report.gapEvents); omissionQuery = Query(report.omissions); historyQuery = Query(report.history)
        workQuery = Query(report.work); successfulReadQuery = Query(report.successfulReads)
        omissionStateCounts = Dictionary(uniqueKeysWithValues: report.omissionStateCounts.map { ($0.key.rawValue, $0.value) })
        omissionStateCountsComplete = report.omissionStateCounts.values.reduce(0, +) == report.omissions.totalCount
        var aliases = Aliases()
        routes = model.routes.flatMap(\.assessments).map { assessment in
            let lastRead = report.successfulReads.items.filter { $0.scope == assessment.scope }.map(\.succeededAt).max()
            let configuredHostVersion = assessment.scope.interface == .t3
                ? Self.version(model.agentProfiles[assessment.scope.provider]?.t3Version) : nil
            return Route(profileAlias: aliases.profile(.init(provider: assessment.scope.provider, profileID: assessment.scope.profileID)),
                provider: assessment.scope.provider, configuredInterface: assessment.scope.interface,
                host: Self.attributedHost(assessment.scope.provider, assessment.scope.interface),
                hostAttribution: Self.hostAttribution(assessment.scope.provider), path: assessment.scope.path,
                observedExecutableVersion: Self.version(assessment.observedExecutableVersion),
                hostVersion: nil,
                configuredHostVersion: configuredHostVersion,
                lastReadAt: [model.lastReadDates[assessment.scope], lastRead].compactMap { $0 }.max(),
                usableOperations: assessment.usableOperations.sorted { $0.rawValue < $1.rawValue },
                unavailableContent: assessment.unavailableContent.sorted { $0.rawValue < $1.rawValue },
                failures: assessment.failures, acceptanceEvidence: assessment.acceptanceEvidence)
        }
        gaps = model.coverageObservations(report: report).map { Gap($0, aliases: &aliases) }
        audits = report.history.items.map {
            Audit(profileAlias: aliases.profile(.init(provider: $0.provider, profileID: $0.profileID)),
                auditAlias: aliases.audit(.init(auditID: $0.progress.audit.id, provider: $0.provider, profileID: $0.profileID)),
                provider: $0.provider, reason: $0.progress.audit.reason,
                windowStart: $0.progress.audit.start, windowEnd: $0.progress.audit.end,
                lastAttemptedAt: $0.lastAttemptedAt, completedAt: $0.completedAt,
                continuationQueued: $0.continuationQueued, hasUnreadContent: $0.progress.hasUnreadContent,
                bytesRead: $0.progress.bytesRead)
        }
        work = report.work.items.map {
            let scope = $0.context.scope
            return Work(captureAlias: aliases.capture($0.id),
                profileAlias: aliases.profile(.init(provider: scope.provider, profileID: scope.profileID)),
                auditAlias: $0.context.audit.map { aliases.audit($0) }, provider: scope.provider,
                configuredInterface: scope.interface, host: Self.attributedHost(scope.provider, scope.interface),
                hostAttribution: Self.hostAttribution(scope.provider), path: scope.path, operation: $0.context.operation,
                trigger: $0.context.trigger, state: $0.state,
                admittedAt: $0.admittedAt, lastAttemptedAt: $0.lastAttemptedAt, completedAt: $0.completedAt,
                exactSourceRetryAvailable: $0.context.retry?.hasExactSelection == true)
        }
        successfulReads = report.successfulReads.items.map {
            Read(profileAlias: aliases.profile(.init(provider: $0.scope.provider, profileID: $0.scope.profileID)),
                provider: $0.scope.provider, configuredInterface: $0.scope.interface,
                host: Self.attributedHost($0.scope.provider, $0.scope.interface),
                hostAttribution: Self.hostAttribution($0.scope.provider), path: $0.scope.path,
                operation: $0.operation, succeededAt: $0.succeededAt,
                producerVersions: $0.producerVersions.compactMap(Self.version).sorted(),
                readerVersion: Self.version($0.readerVersion),
                hostVersion: nil,
                configuredHostVersion: Self.version($0.hostVersion))
        }
    }

    func encoded() throws -> Data { try DiagnosticsExport.encode(self) }
}
