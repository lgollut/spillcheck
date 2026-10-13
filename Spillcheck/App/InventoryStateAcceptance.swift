#if DEBUG
import Darwin
import Foundation
import CryptoKit
import CoreFoundation
@_spi(Testing) import SpillcheckCore

/// The runner chooses an action, never a value, occurrence, native identity or state fixture.
/// This helper only recognizes the fixed fake token used by signed collection acceptance.
@MainActor
enum InventoryStateAcceptance {
    static let fixtureValue = "ghp_8nR4vY2qL7sD9mF3xK6cP1aB5hJ0uE4wT9zS"
    static let maximumRows = 128

    enum Fixture: Equatable {
        case codex
        case claude(SessionIdentity)
        var provider: AgentProvider { if case .claude = self { return .claudeCode }; return .codex }
        func accepts(_ session: SessionIdentity) -> Bool {
            switch self { case .codex: return session.provider == .codex
            case .claude(let expected): return session == expected }
        }
    }

    /// Fixed constructed transcript contract; never caller-selected counts or content.
    @MainActor
    struct ClaudeFixture {
        static let profile = "owned-claude-inventory"
        static let version = "2.1.296"
        let root: URL
        let session: SessionIdentity
        let source: URL
        let digest: String
        var fixture: Fixture { .claude(session) }
        var scope: CollectionScope { .init(provider: .claudeCode, profileID: Self.profile,
            interface: .standaloneCLI, path: .versionedTranscript) }

        static func fromArguments(_ arguments: [String], recovery: DisposableRecoveryConfiguration?) throws -> Self? {
            let flags = arguments.filter { $0 == "--acceptance-claude-inventory" }.count
            guard flags > 0 else { return nil }
            guard flags == 1, let recovery, recovery.inventoryStateEnabled, !recovery.upgradeStateEnabled,
                  arguments.contains("--acceptance-no-profile-catchup"),
                  !arguments.contains("--acceptance-recovery-install-profile"),
                  !arguments.contains("--acceptance-claude-role-evidence"),
                  !arguments.contains("--acceptance-recovery-claude-role-evidence"),
                  try CodexCollectionConfiguration.fromArguments(arguments) == nil,
                  let configuration = try CollectionConfiguration.fromArguments(arguments),
                  configuration.profileID == profile, configuration.agentVersion == version,
                  configuration.activeSources.isEmpty, configuration.authorizedHosts == [.standaloneCLI],
                  configuration.historicalInterface == .standaloneCLI,
                  configuration.roots.map(\.path) == [recovery.root.appendingPathComponent("claude/projects").path] else {
                throw Failure.unsafeState
            }
            let data = try read(root: recovery.root, components: ["claude-inventory.json"], maximum: 4096)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["schemaVersion", "sessionID", "sourcePath", "sourceSHA256"],
                  let schema = object["schemaVersion"] as? NSNumber, schema.intValue == 1,
                  CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
                  let id = object["sessionID"] as? String, let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id,
                  let path = object["sourcePath"] as? String,
                  path == recovery.root.appendingPathComponent("claude/projects/inventory/" + id + ".jsonl").path,
                  let digest = object["sourceSHA256"] as? String,
                  digest.utf8.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw Failure.unsafeState
            }
            let result = Self(root: recovery.root,
                session: try SessionIdentity(provider: .claudeCode, profileID: profile, sessionID: id),
                source: URL(fileURLWithPath: path), digest: digest)
            try result.requireOriginalSource()
            return result
        }

        func requireOriginalSource() throws {
            let data = try Self.read(root: root, components: ["claude", "projects", "inventory", session.sessionID + ".jsonl"],
                                     maximum: 64 * 1024)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else {
                throw Failure.unsafeState
            }
        }

        func retryDescriptor() throws -> CoverageSourceRetryDescriptor {
            try requireOriginalSource()
            return .init(scope: scope, session: session, sourceURL: source)
        }

        func validBatch(_ batch: CollectionBatch, metadata: CaptureMetadata, path: CollectionPath) -> Bool {
            metadata.agent == .claudeCode && metadata.profileID == Self.profile && metadata.interface == .standaloneCLI
                && path == .versionedTranscript && InventoryStateAcceptance.hasReadEvidence(batch)
                && batch.sources.allSatisfy { item in
                    item.record.metadata.identity.session == session && item.context?.transcriptPath == source.path
                        && item.record.metadata.origin.adapterID == "claude-code"
                        && item.record.metadata.origin.adapterVersion == ClaudeAdapter.adapterVersion
                        && item.record.metadata.origin.agentVersion == Self.version
                }
        }

        private static func read(root: URL, components: [String], maximum: Int) throws -> Data {
            var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw Failure.unsafeState }
            defer { close(directory) }
            for name in components.dropLast() {
                var info = stat()
                guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                    throw Failure.unsafeState
                }
                let next = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Failure.unsafeState }
                close(directory); directory = next
            }
            guard let name = components.last else { throw Failure.unsafeState }
            var parent = stat()
            guard fstat(directory, &parent) == 0, parent.st_uid == getuid(), parent.st_mode & 0o077 == 0 else {
                throw Failure.unsafeState
            }
            let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw Failure.unsafeState }
            defer { close(descriptor) }
            var before = stat(), after = stat(), named = stat()
            guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_uid == getuid(), before.st_mode & 0o077 == 0, before.st_nlink == 1,
                  before.st_size > 0, before.st_size <= maximum else { throw Failure.unsafeState }
            var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            guard count == bytes.count, fstat(descriptor, &after) == 0,
                  fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  after.st_dev == named.st_dev, after.st_ino == named.st_ino,
                  after.st_mode == named.st_mode, named.st_nlink == 1 else { throw Failure.unsafeState }
            return Data(bytes)
        }
    }

    enum Failure: String, Error { case unsafeState, unexpectedInventory, missingPendingReceipt, postconditionFailed, reportUnavailable }
    struct ReviewPlan {
        let confirmed: UUID
        let falsePositive: UUID
        let notificationIdentifier: String
        let receiptKind: String
    }
    struct Report: Encodable {
        let measured: Bool
        let truncated: Bool
        let phase: String
        let counts: [String: Int]
        let digests: [String: [String]]
        let reviewCounts: [String: Int]
        let deliveryCounts: [String: Int]
        let payloadRowCount: Int
        let referencedPayloadCount: Int
        let availableReferencedPayloadCount: Int
        let nextValueLabel: Int
        let schemaVersion: Int
        let removedLocationReceiptCount: Int
        let revokedMarkerCount: Int
        let upgrade: UpgradeReport?
        let removedUpgrade: RemovedUpgradeReport?
        let systemNotificationDeliveryEstablished = false
        let actualNotificationDeliverySuppressed = true
    }
    struct UpgradeReport: Encodable {
        let enabled = true
        let recordStableDigests: [String]
        let recordTimesMatchOccurrences: Bool
        let classificationCounts: [String: Int]
        let producerClassificationCounts: [String: [String: Int]]
        let producerReviewCounts: [String: [String: Int]]
        let producerOccurrenceDigests: [String: [String]]
    }
    struct RemovedUpgradeReport: Encodable {
        let enabled = true
        let protectedRecordCount: Int
        let metadataOnlyRecordCount: Int
        let recordTimesMatchObsoleteAppearances: Bool
        let removedLocationDigests: [String]
        let obsoleteAppearanceContentTypeCounts: [String: Int]
    }
    private struct Pair<K: Encodable, V: Encodable>: Encodable { let key: K; let value: V }
    /// New source content can advance only the final timestamp of this fixture's
    /// value record. The full original record is still reported in `digests`.
    private struct StableRecord: Encodable {
        let id: UUID
        let fingerprint: ValueFingerprint
        let protectedValue: ProtectedPayloadReference?
        let categories: Set<SecretCategory>
        let firstOccurrenceAt: Date
        init(_ record: InventoryRecord) {
            id = record.id; fingerprint = record.fingerprint; protectedValue = record.protectedValue
            categories = record.categories; firstOccurrenceAt = record.firstOccurrenceAt
        }
    }

    /// Match DetectionPipeline's read-evidence contract. `observedRead` supplies evidence
    /// for valid empty polls; a returned historical source is evidence independently.
    static func hasReadEvidence(_ batch: CollectionBatch) -> Bool {
        batch.readEvidenceEligible && (batch.observedRead || !batch.sources.isEmpty || !batch.checkpoints.isEmpty
            || batch.historicalProgress.map { $0.bytesRead > 0 || !$0.hasUnreadContent } == true)
    }

    static func requireIdle(processingStopped: Bool, actionBusy: Bool,
                            queueCount: Int, claimedCount: Int, pendingCount: Int) throws {
        guard processingStopped, !actionBusy, queueCount == 0, claimedCount == 0, pendingCount == 0 else {
            throw Failure.unsafeState
        }
    }

    static func hasExactRetainedInventory(_ snapshot: InventorySnapshot, fingerprint: ValueFingerprint, fixture: Fixture = .codex) -> Bool {
        guard snapshot.records.count == 1, let record = snapshot.records[fingerprint], record.protectedValue != nil,
              snapshot.occurrences.count == 7, snapshot.obsoleteMarkers.isEmpty,
              snapshot.obsoleteAppearances.isEmpty, snapshot.unlocatedResults.isEmpty,
              snapshot.unlocatedReceipts.isEmpty, snapshot.unlocatedLabels.isEmpty,
              snapshot.valueLabels.count == 1, snapshot.valueLabels[fingerprint] != nil,
              snapshot.conversationLabels.count == 1, snapshot.locationReceipts.count == 7,
              !snapshot.sourceKinds.isEmpty, snapshot.sourceKinds.count <= maximumRows,
              snapshot.sourceTimes.count <= maximumRows, snapshot.analysisReceipts.count <= maximumRows else { return false }
        let occurrences = Array(snapshot.occurrences.values)
        if case .claude = fixture {
            guard Dictionary(grouping: occurrences, by: { $0.source.contentType }).mapValues(\.count)
                    == [.userPrompt: 3, .intermediateResponse: 1, .finalResponse: 1, .toolOutput: 1, .toolError: 1],
                  occurrences.allSatisfy({ occurrence in
                      guard case .transcriptByteOffset = occurrence.source.locator else { return false }
                      return occurrence.source.origin.interface == .standaloneCLI
                          && occurrence.source.origin.adapterID == "claude-code"
                          && occurrence.source.origin.adapterVersion == ClaudeAdapter.adapterVersion
                          && occurrence.source.origin.agentVersion == ClaudeFixture.version
                  }) else { return false }
        }
        return occurrences.allSatisfy { $0.valueID == record.id && $0.source.identity.session.provider == fixture.provider && fixture.accepts($0.source.identity.session) }
            && Set(occurrences.map { $0.source.identity.session }).count == 1
            && Set(occurrences.map { $0.source.contentType }) == Set(ContentType.allCases)
            && snapshot.sourceKinds.keys.allSatisfy { $0.session == occurrences.first?.source.identity.session }
            && snapshot.analysisReceipts.allSatisfy { $0.source.session == occurrences.first?.source.identity.session }
            && snapshot.locationReceipts.values.allSatisfy { receipt in
                guard case .occurrence(let id) = receipt else { return false }
                return snapshot.occurrences[id] != nil
            }
    }

    static func reviewPlan(_ snapshot: InventorySnapshot, fingerprint: ValueFingerprint, fixture: Fixture = .codex) throws -> ReviewPlan {
        guard hasExactRetainedInventory(snapshot, fingerprint: fingerprint, fixture: fixture),
              snapshot.occurrences.values.allSatisfy({ $0.review == .unreviewed }),
              snapshot.alertDecisions.count + snapshot.historicalNotificationDecisions.count == 1 else {
            throw Failure.unexpectedInventory
        }
        let occurrences = snapshot.occurrences.keys.sorted { $0.uuidString < $1.uuidString }
        if let alert = snapshot.alertDecisions.values.first, alert.delivery == .pending {
            return .init(confirmed: occurrences[0], falsePositive: occurrences[1],
                         notificationIdentifier: alert.notificationIdentifier, receiptKind: "live")
        }
        if let decision = snapshot.historicalNotificationDecisions.values.first, decision.delivery == .pending {
            return .init(confirmed: occurrences[0], falsePositive: occurrences[1],
                         notificationIdentifier: decision.notificationIdentifier, receiptKind: "historical")
        }
        throw Failure.missingPendingReceipt
    }

    static func phase(_ snapshot: InventorySnapshot, fingerprint: ValueFingerprint, upgradeState: Bool = false,
                      upgradeRemovedState: Bool = false, fixture: Fixture = .codex) -> String {
        if upgradeRemovedState, let phase = removedUpgradePhase(snapshot, fingerprint: fingerprint) { return phase }
        if upgradeState, let phase = revokedUpgradePhase(snapshot, fingerprint: fingerprint) { return phase }
        if hasExactRetainedInventory(snapshot, fingerprint: fingerprint, fixture: fixture) {
            let counts = Dictionary(grouping: snapshot.occurrences.values, by: { $0.review }).mapValues(\.count)
            let delivery = snapshot.alertDecisions.values.map(\.delivery)
                + snapshot.historicalNotificationDecisions.values.map(\.delivery)
            if counts == [.unreviewed: 7], delivery == [.pending] { return "baseline" }
            if counts == [.confirmedSecret: 1, .falsePositive: 1, .unreviewed: 5], delivery == [.delivered] {
                return "reviewed"
            }
        }
        if snapshot.records.isEmpty, snapshot.occurrences.isEmpty, snapshot.obsoleteAppearances.isEmpty,
           snapshot.obsoleteMarkers.count == 1, snapshot.obsoleteMarkers[fingerprint]?.acknowledgement == .revoked,
           snapshot.alertDecisions.isEmpty, snapshot.unlocatedResults.isEmpty,
           snapshot.unlocatedReceipts.isEmpty, snapshot.unlocatedLabels.isEmpty,
           snapshot.valueLabels.count == 1, snapshot.valueLabels[fingerprint] != nil,
           snapshot.conversationLabels.count == 1, snapshot.locationReceipts.count == 7,
           snapshot.locationReceipts.values.allSatisfy({ $0 == .removed }),
           snapshot.strongSignalReceipts.isEmpty,
           !snapshot.sourceKinds.isEmpty, snapshot.sourceKinds.count <= maximumRows,
           snapshot.sourceTimes.count <= maximumRows, snapshot.analysisReceipts.count <= maximumRows,
           Set(snapshot.sourceKinds.keys.map(\.session)).count == 1,
           snapshot.sourceKinds.keys.allSatisfy({ fixture.accepts($0.session) }),
           snapshot.historicalNotificationDecisions.count <= 1,
           snapshot.historicalNotificationDecisions.values.allSatisfy({ $0.delivery == .delivered }) {
            return "removed"
        }
        return "unexpected"
    }

    static func recordTimesMatchObsoleteAppearances(_ snapshot: InventorySnapshot) -> Bool {
        if snapshot.records.isEmpty { return snapshot.obsoleteAppearances.isEmpty }
        return snapshot.records.values.allSatisfy { record in
            let times = snapshot.obsoleteAppearances.values.filter { $0.valueID == record.id }.map(\.occurredAt)
            return times.min() == record.firstOccurrenceAt && times.max() == record.lastOccurrenceAt
        }
    }

    private static func removedUpgradePhase(_ snapshot: InventorySnapshot, fingerprint: ValueFingerprint) -> String? {
        if phase(snapshot, fingerprint: fingerprint) == "removed" { return "removed-upgrade7" }
        guard snapshot.records.count == 1, let record = snapshot.records[fingerprint], record.protectedValue == nil,
              record.categories.isEmpty, snapshot.occurrences.isEmpty, snapshot.obsoleteAppearances.count == 7,
              snapshot.obsoleteMarkers.count == 1, snapshot.obsoleteMarkers[fingerprint]?.acknowledgement == .revoked,
              snapshot.alertDecisions.isEmpty, snapshot.strongSignalReceipts.isEmpty,
              snapshot.unlocatedResults.isEmpty, snapshot.unlocatedReceipts.isEmpty, snapshot.unlocatedLabels.isEmpty,
              snapshot.valueLabels.count == 1, snapshot.valueLabels[fingerprint] != nil,
              snapshot.conversationLabels.count == 2, snapshot.locationReceipts.count == 14,
              snapshot.locationReceipts.values.filter({ $0 == .removed }).count == 7,
              !snapshot.sourceKinds.isEmpty, snapshot.sourceKinds.count <= maximumRows,
              snapshot.sourceTimes.count <= maximumRows, snapshot.analysisReceipts.count <= maximumRows,
              snapshot.historicalNotificationDecisions.count <= 1,
              snapshot.historicalNotificationDecisions.values.allSatisfy({ $0.delivery == .delivered }),
              recordTimesMatchObsoleteAppearances(snapshot) else { return nil }
        let appearances = Array(snapshot.obsoleteAppearances.values)
        let newSessions = Set(appearances.map { $0.source.session })
        let removedIdentities = snapshot.locationReceipts.filter { $0.value == .removed }.map(\.key)
        let oldSessions = Set(removedIdentities.map { $0.source.session })
        guard newSessions.count == 1, oldSessions.count == 1, oldSessions.isDisjoint(with: newSessions),
              Set(snapshot.conversationLabels.keys) == oldSessions.union(newSessions),
              snapshot.sourceKinds.keys.allSatisfy({ oldSessions.union(newSessions).contains($0.session) }),
              snapshot.sourceTimes.keys.allSatisfy({ oldSessions.union(newSessions).contains($0.session) }),
              snapshot.analysisReceipts.allSatisfy({ oldSessions.union(newSessions).contains($0.source.session) }),
              appearances.allSatisfy({ $0.valueID == record.id && $0.source.session.provider == .codex && $0.locator == .upstreamItem }),
              Set(appearances.compactMap { snapshot.sourceKinds[$0.source] }) == Set(ContentType.allCases),
              snapshot.locationReceipts.allSatisfy({ identity, receipt in
                  if receipt == .removed { return true }
                  guard case .obsoleteAppearance(let id) = receipt else { return false }
                  return snapshot.obsoleteAppearances[id]?.source == identity.source
              }), Set(snapshot.locationReceipts.values.compactMap { receipt -> UUID? in
                  if case .obsoleteAppearance(let id) = receipt { return id }; return nil
              }) == Set(snapshot.obsoleteAppearances.keys) else { return nil }
        return "removed-upgrade14"
    }

    static func recordTimesMatchOccurrences(_ snapshot: InventorySnapshot) -> Bool {
        guard !snapshot.records.isEmpty else { return false }
        return snapshot.records.values.allSatisfy { record in
            let times = snapshot.occurrences.values.filter { $0.valueID == record.id }.map { $0.source.contentTime }
            return times.min() == record.firstOccurrenceAt && times.max() == record.lastOccurrenceAt
        }
    }

    static func requireRetainedRevocation(_ snapshot: InventorySnapshot, fingerprint: ValueFingerprint) throws {
        guard phase(snapshot, fingerprint: fingerprint) == "reviewed", recordTimesMatchOccurrences(snapshot),
              Set(snapshot.occurrences.values.map { $0.source.origin.agentVersion }).count == 1,
              snapshot.occurrences.values.allSatisfy(isNativeCLIOccurrence) else { throw Failure.unexpectedInventory }
    }

    private static func isNativeCLIOccurrence(_ occurrence: Occurrence) -> Bool {
        occurrence.source.identity.session.provider == .codex && occurrence.source.origin.interface == .standaloneCLI
            && occurrence.source.origin.adapterID == "codex" && occurrence.source.origin.adapterVersion == CodexAdapter.adapterVersion
            && occurrence.source.origin.canonicalization == .exclusiveAuthority && occurrence.source.locator == .upstreamItem
            && !occurrence.source.origin.agentVersion.isEmpty && occurrence.source.origin.agentVersion.utf8.count <= 256
    }

    private static func revokedUpgradePhase(_ snapshot: InventorySnapshot, fingerprint: ValueFingerprint) -> String? {
        guard snapshot.records.count == 1, let record = snapshot.records[fingerprint], record.protectedValue != nil,
              [7, 14].contains(snapshot.occurrences.count), snapshot.obsoleteMarkers.count == 1,
              snapshot.obsoleteMarkers[fingerprint]?.acknowledgement == .revoked,
              snapshot.obsoleteAppearances.isEmpty, snapshot.unlocatedResults.isEmpty,
              snapshot.unlocatedReceipts.isEmpty, snapshot.unlocatedLabels.isEmpty,
              snapshot.valueLabels.count == 1, snapshot.valueLabels[fingerprint] != nil,
              snapshot.locationReceipts.count == snapshot.occurrences.count,
              !snapshot.sourceKinds.isEmpty, snapshot.sourceKinds.count <= maximumRows,
              snapshot.sourceTimes.count <= maximumRows, snapshot.analysisReceipts.count <= maximumRows,
              snapshot.alertDecisions.count + snapshot.historicalNotificationDecisions.count == 1,
              (snapshot.alertDecisions.values.map(\.delivery) + snapshot.historicalNotificationDecisions.values.map(\.delivery)) == [.delivered],
              recordTimesMatchOccurrences(snapshot) else { return nil }
        let occurrences = Array(snapshot.occurrences.values)
        let sessions = Set(occurrences.map { $0.source.identity.session })
        guard sessions.count == snapshot.occurrences.count / 7,
              Set(snapshot.conversationLabels.keys) == sessions,
              occurrences.allSatisfy({ $0.valueID == record.id && isNativeCLIOccurrence($0) }),
              snapshot.sourceKinds.keys.allSatisfy({ sessions.contains($0.session) }),
              snapshot.sourceTimes.keys.allSatisfy({ sessions.contains($0.session) }),
              snapshot.analysisReceipts.allSatisfy({ sessions.contains($0.source.session) }),
              snapshot.locationReceipts.allSatisfy({ identity, receipt in
                  guard case .occurrence(let id) = receipt else { return false }
                  return snapshot.occurrences[id]?.identity == identity
              }) else { return nil }
        let ordinary = occurrences.filter { $0.classification == .ordinary }
        let obsolete = occurrences.filter { $0.classification == .obsolete }
        guard ordinary.count == 7, Set(ordinary.map { $0.source.contentType }) == Set(ContentType.allCases),
              Dictionary(grouping: ordinary, by: \.review).mapValues(\.count)
                == [.confirmedSecret: 1, .falsePositive: 1, .unreviewed: 5],
              Set(ordinary.map { $0.source.identity.session }).count == 1,
              Set(ordinary.map { $0.source.origin.agentVersion }).count == 1 else { return nil }
        if obsolete.isEmpty { return "reviewed-revoked7" }
        guard obsolete.count == 7, obsolete.allSatisfy({ $0.review == .unreviewed }),
              Set(obsolete.map { $0.source.contentType }) == Set(ContentType.allCases),
              Set(obsolete.map { $0.source.identity.session }).count == 1,
              Set(obsolete.map { $0.source.origin.agentVersion }).count == 1,
              ordinary[0].source.identity.session != obsolete[0].source.identity.session,
              ordinary[0].source.origin.agentVersion != obsolete[0].source.origin.agentVersion else { return nil }
        return "reviewed-revoked14"
    }

    /// Codable Sets are not order-stable. Only fields declared as Sets in the inventory
    /// contract are sorted; ordered arrays elsewhere retain their order and associations.
    static func canonicalBytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        guard bytes.count <= 256 * 1024 else { throw Failure.reportUnavailable }
        let json = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
        func normalize(_ value: Any, key: String? = nil) throws -> Any {
            if let object = value as? [String: Any] {
                return try object.mapValuesWithKeys { try normalize($1, key: $0) }
            }
            if let array = value as? [Any] {
                let normalized = try array.map { try normalize($0) }
                if ["categories", "origins", "evidence"].contains(key ?? "") {
                    return try normalized.map { item in
                        (try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys, .fragmentsAllowed]), item)
                    }.sorted { $0.0.lexicographicallyPrecedes($1.0) }.map(\.1)
                }
                return normalized
            }
            return value
        }
        return try JSONSerialization.data(withJSONObject: normalize(json), options: [.sortedKeys, .fragmentsAllowed])
    }

    static func report(snapshot: InventorySnapshot, fingerprint: ValueFingerprint,
                       store: ProtectedStore, cryptography: BackgroundCryptography,
                       upgradeState: Bool = false, upgradeRemovedState: Bool = false, fixture: Fixture = .codex) async throws -> Report {
        var counts: [String: Int] = [:], digests: [String: [String]] = [:]
        func keyedRows<T: Encodable>(_ name: String, _ rows: [T]) async throws -> [String] {
            guard rows.count <= maximumRows else { throw Failure.reportUnavailable }
            var result: [String] = []
            for row in rows {
                // Domain separation prevents equal encodings in different record categories
                // from serving as interchangeable evidence.
                var bytes = Data(("inventory-state-v1/" + name + "\n").utf8)
                bytes.append(try canonicalBytes(row))
                result.append(try await cryptography.revision(canonicalBytes: bytes).keyedDigest.base64EncodedString())
            }
            return result.sorted()
        }
        func values<T: Encodable>(_ name: String, _ rows: [T]) async throws {
            counts[name] = rows.count
            digests[name] = try await keyedRows(name, rows)
        }
        func pairs<K: Encodable, V: Encodable>(_ name: String, _ rows: [K: V]) async throws {
            try await values(name, rows.map { Pair(key: $0.key, value: $0.value) })
        }
        try await pairs("records", snapshot.records)
        try await pairs("occurrences", snapshot.occurrences)
        try await pairs("obsoleteMarkers", snapshot.obsoleteMarkers)
        try await pairs("obsoleteAppearances", snapshot.obsoleteAppearances)
        try await pairs("alerts", snapshot.alertDecisions)
        try await pairs("historicalNotifications", snapshot.historicalNotificationDecisions)
        try await pairs("unlocatedResults", snapshot.unlocatedResults)
        try await values("analysisReceipts", Array(snapshot.analysisReceipts))
        try await pairs("locationReceipts", snapshot.locationReceipts)
        try await pairs("strongSignalReceipts", snapshot.strongSignalReceipts)
        try await values("unlocatedReceipts", Array(snapshot.unlocatedReceipts))
        try await pairs("sourceKinds", snapshot.sourceKinds)
        try await pairs("sourceTimes", snapshot.sourceTimes)
        try await pairs("conversationLabels", snapshot.conversationLabels)
        try await pairs("valueLabels", snapshot.valueLabels)
        try await pairs("unlocatedLabels", snapshot.unlocatedLabels)
        let references = Set(snapshot.records.values.compactMap(\.protectedValue))
            .union(snapshot.occurrences.values.compactMap(\.protectedExcerpt))
            .union(snapshot.occurrences.values.compactMap { $0.source.protectedMetadata })
        guard references.count <= maximumRows else { throw Failure.reportUnavailable }
        var available = 0
        for reference in references { if try await store.payload(reference) != nil { available += 1 } }
        let payloadCount = try await store.protectedPayloadCountForTesting()
        let deliveries = snapshot.alertDecisions.values.map(\.delivery) + snapshot.historicalNotificationDecisions.values.map(\.delivery)
        var upgrade: UpgradeReport?
        if upgradeState && !upgradeRemovedState {
            let groups = Dictionary(grouping: snapshot.occurrences.values, by: { $0.source.origin.agentVersion })
            guard groups.count <= 2, groups.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
                throw Failure.reportUnavailable
            }
            var producerDigests: [String: [String]] = [:]
            for (version, rows) in groups {
                producerDigests[version] = try await keyedRows("occurrences", rows.map { Pair(key: $0.id, value: $0) })
            }
            upgrade = try await UpgradeReport(recordStableDigests: keyedRows("stable-records",
                snapshot.records.map { Pair(key: $0.key, value: StableRecord($0.value)) }),
                recordTimesMatchOccurrences: recordTimesMatchOccurrences(snapshot),
                classificationCounts: Dictionary(grouping: snapshot.occurrences.values, by: { $0.classification.rawValue }).mapValues(\.count),
                producerClassificationCounts: groups.mapValues { Dictionary(grouping: $0, by: { $0.classification.rawValue }).mapValues(\.count) },
                producerReviewCounts: groups.mapValues { Dictionary(grouping: $0, by: { $0.review.rawValue }).mapValues(\.count) },
                producerOccurrenceDigests: producerDigests)
        }
        var removedUpgrade: RemovedUpgradeReport?
        if upgradeRemovedState {
            removedUpgrade = try await RemovedUpgradeReport(
                protectedRecordCount: snapshot.records.values.filter { $0.protectedValue != nil }.count,
                metadataOnlyRecordCount: snapshot.records.values.filter { $0.protectedValue == nil && $0.categories.isEmpty }.count,
                recordTimesMatchObsoleteAppearances: recordTimesMatchObsoleteAppearances(snapshot),
                removedLocationDigests: keyedRows("locationReceipts", snapshot.locationReceipts.filter { $0.value == .removed }
                    .map { Pair(key: $0.key, value: $0.value) }),
                obsoleteAppearanceContentTypeCounts: Dictionary(grouping: snapshot.obsoleteAppearances.values,
                    by: { snapshot.sourceKinds[$0.source]?.rawValue ?? "unavailable" }).mapValues(\.count))
        }
        return Report(measured: true, truncated: false, phase: phase(snapshot, fingerprint: fingerprint,
            upgradeState: upgradeState && !upgradeRemovedState, upgradeRemovedState: upgradeRemovedState, fixture: fixture),
            counts: counts, digests: digests,
            reviewCounts: Dictionary(grouping: snapshot.occurrences.values, by: { $0.review.rawValue }).mapValues(\.count),
            deliveryCounts: Dictionary(grouping: deliveries, by: { $0.rawValue }).mapValues(\.count),
            payloadRowCount: payloadCount, referencedPayloadCount: references.count,
            availableReferencedPayloadCount: available, nextValueLabel: snapshot.nextValueLabel, schemaVersion: snapshot.schemaVersion,
            removedLocationReceiptCount: snapshot.locationReceipts.values.filter { $0 == .removed }.count,
            revokedMarkerCount: snapshot.obsoleteMarkers.values.filter { $0.acknowledgement == .revoked }.count,
            upgrade: upgrade, removedUpgrade: removedUpgrade)
    }
}

/// Process-local native source evidence. Durable obsolete appearances intentionally
/// contain no producer version or analysis revision, so neither is inferred from
/// the current profile. Source receipts prove observed revisions, not which one
/// originally inserted a particular appearance.
@MainActor
final class InventoryRemovedUpgradeAcceptance {
    enum Failure: String, Error { case unsafeScope, invalidSource, changedSource, budgetExceeded, incompleteRead, reportUnavailable }
    struct Report: Encodable {
        let measured = true
        let truncated = false
        let failure: String?
        let observedSourceCount: Int
        let observedBatchCount: Int
        let matchedAppearanceCount: Int
        let allAppearancesHaveCommittedNativeSource: Bool
        let readerVersions: [String]
        let producerAppearanceCounts: [String: Int]
        let producerContentTypeCounts: [String: [String: Int]]
        let producerSessionCounts: [String: Int]
        let producerSourceDigests: [String: [String]]
        let producerReceiptDigests: [String: [String]]
        let producerAppearanceDigests: [String: [String]]
    }
    private struct Observation {
        let metadata: SourceRecordMetadata
        var revisions: Set<ContentRevision>
        var provenances: Set<SourceProvenance>
    }
    private struct Pair<K: Encodable, V: Encodable>: Encodable { let key: K; let value: V }
    let profileID: String
    private var observations: [SourceIdentity: Observation] = [:]
    private var readerVersions: Set<String> = []
    private var batches = 0
    private(set) var failure: Failure?

    init(profileID: String) { self.profileID = profileID }

    static func configuredProfile(_ configuration: CodexCollectionConfiguration,
                                  recovery: DisposableRecoveryConfiguration) throws -> String {
        guard recovery.upgradeRemovedStateEnabled, configuration.interface == .standaloneCLI,
              configuration.authority == .publicNativeItems, configuration.activeSources.isEmpty,
              configuration.home.deletingLastPathComponent().path == recovery.root.path,
              let canonical = realpath(configuration.home.path, nil) else { throw Failure.unsafeScope }
        defer { free(canonical) }
        var info = stat()
        guard String(cString: canonical) == configuration.home.path,
              lstat(configuration.home.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.unsafeScope }
        return configuration.profileID
    }

    func observe(_ batch: CollectionBatch, metadata: CaptureMetadata, path: CollectionPath,
                 cryptography: BackgroundCryptography) async {
        guard failure == nil else { return }
        // Lifecycle callbacks and empty polls cannot establish appearance provenance.
        // Leave them to normal collection health; only source-bearing reads enter
        // this bounded witness or count toward its callback budget.
        guard !batch.sources.isEmpty else { return }
        do {
            guard metadata.agent == .codex, metadata.profileID == profileID,
                  metadata.interface == .standaloneCLI, path == .publicHistory else { throw Failure.unsafeScope }
            guard batches < 128, batch.sources.count <= 128 else { throw Failure.budgetExceeded }
            guard InventoryStateAcceptance.hasReadEvidence(batch), let reader = batch.observedReaderVersion,
                  !reader.isEmpty, reader.utf8.count <= 256,
                  !batch.coverageGaps.contains(where: { $0.requiresAnalysis && ($0.reason != .budgetExhausted || batch.continuation == nil) }) else {
                throw Failure.incompleteRead
            }
            batches += 1; readerVersions.insert(reader)
            guard readerVersions.count <= 2 else { throw Failure.budgetExceeded }
            for collected in batch.sources {
                let source = collected.record, item = source.metadata
                guard item.identity.session.provider == .codex, item.identity.session.profileID == profileID,
                      UUID(uuidString: item.identity.session.sessionID)?.uuidString.lowercased() == item.identity.session.sessionID,
                      item.origin.adapterID == "codex", item.origin.adapterVersion == CodexAdapter.adapterVersion,
                      item.origin.interface == .standaloneCLI, item.origin.canonicalization == .exclusiveAuthority,
                      item.locator == .upstreamItem, !item.origin.agentVersion.isEmpty,
                      item.origin.agentVersion.utf8.count <= 256,
                      source.segments.count <= 1024,
                      source.segments.reduce(0, { $0 + $1.utf8.count + $1.id.utf8.count }) <= 2 * 1024 * 1024,
                      try await cryptography.revision(canonicalBytes: WebResultAcceptance.canonicalSegments(source.segments)) == source.revision else {
                    throw Failure.invalidSource
                }
                if var previous = observations[item.identity] {
                    let old = previous.metadata
                    guard old.contentType == item.contentType, old.contentTime == item.contentTime,
                          old.locator == item.locator, old.timeBasis == item.timeBasis,
                          old.origin.agentVersion == item.origin.agentVersion else { throw Failure.changedSource }
                    previous.revisions.insert(source.revision); previous.provenances.insert(item.origin.provenance)
                    guard previous.revisions.count <= 4, previous.provenances.count <= 8 else { throw Failure.budgetExceeded }
                    observations[item.identity] = previous
                } else {
                    guard observations.count < 128 else { throw Failure.budgetExceeded }
                    observations[item.identity] = .init(metadata: item, revisions: [source.revision], provenances: [item.origin.provenance])
                }
            }
            guard Set(observations.keys.map(\.session)).count <= 2 else { throw Failure.unsafeScope }
        } catch { failure = (error as? Failure) ?? .reportUnavailable }
    }

    func report(snapshot: InventorySnapshot, cryptography: BackgroundCryptography) async throws -> Report {
        guard snapshot.obsoleteAppearances.count <= 128, snapshot.locationReceipts.count <= 128,
              snapshot.analysisReceipts.count <= 128, snapshot.sourceKinds.count <= 128 else { throw Failure.reportUnavailable }
        var counts: [String: Int] = [:], types: [String: [String: Int]] = [:], sessions: [String: Set<SessionIdentity>] = [:]
        var sources: [String: Set<String>] = [:], receipts: [String: Set<String>] = [:], appearances: [String: Set<String>] = [:]
        var matched = 0
        func digest<T: Encodable>(_ domain: String, _ value: T) async throws -> String {
            var bytes = Data(("inventory-state-v1/" + domain + "\n").utf8)
            bytes.append(try InventoryStateAcceptance.canonicalBytes(value))
            return try await cryptography.revision(canonicalBytes: bytes).keyedDigest.base64EncodedString()
        }
        for appearance in snapshot.obsoleteAppearances.values {
            guard let observed = observations[appearance.source], observed.metadata.contentTime == appearance.occurredAt,
                  observed.metadata.timeBasis == appearance.timeBasis, observed.metadata.locator == appearance.locator,
                  observed.provenances.contains(appearance.provenance), snapshot.sourceKinds[appearance.source] == observed.metadata.contentType,
                  snapshot.locationReceipts.filter({ identity, receipt in
                      receipt == .obsoleteAppearance(appearance.id) && identity.source == appearance.source
                  }).count == 1 else { continue }
            let committed = snapshot.analysisReceipts.filter { receipt in
                receipt.source == appearance.source && observed.revisions.contains(receipt.revision)
                    && receipt.detectorVersion == BetterleaksSecretDetector.version
            }
            guard !committed.isEmpty else { continue }
            let version = observed.metadata.origin.agentVersion
            matched += 1; counts[version, default: 0] += 1
            types[version, default: [:]][observed.metadata.contentType.rawValue, default: 0] += 1
            sessions[version, default: []].insert(appearance.source.session)
            sources[version, default: []].insert(try await digest("sourceKinds", Pair(key: appearance.source, value: observed.metadata.contentType)))
            for receipt in committed { receipts[version, default: []].insert(try await digest("analysisReceipts", receipt)) }
            appearances[version, default: []].insert(try await digest("obsoleteAppearances", Pair(key: appearance.id, value: appearance)))
        }
        return Report(failure: failure?.rawValue, observedSourceCount: observations.count, observedBatchCount: batches,
            matchedAppearanceCount: matched, allAppearancesHaveCommittedNativeSource: failure == nil
                && !snapshot.obsoleteAppearances.isEmpty && matched == snapshot.obsoleteAppearances.count,
            readerVersions: readerVersions.sorted(), producerAppearanceCounts: counts, producerContentTypeCounts: types,
            producerSessionCounts: sessions.mapValues(\.count), producerSourceDigests: sources.mapValues { $0.sorted() },
            producerReceiptDigests: receipts.mapValues { $0.sorted() }, producerAppearanceDigests: appearances.mapValues { $0.sorted() })
    }
}

private extension Dictionary where Key == String, Value == Any {
    func mapValuesWithKeys(_ transform: (String, Any) throws -> Any) rethrows -> [String: Any] {
        try Dictionary(uniqueKeysWithValues: map { (key, value) in (key, try transform(key, value)) })
    }
}
#endif
