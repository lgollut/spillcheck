import Darwin
import Foundation

/// Stable, content-free startup diagnostics. A pending journal is evidence to preserve,
/// never authority to delete keys or to replace a committed vault's keys. With an empty
/// store it is resumed with its exact identities rather than replaced.
public enum ProtectionBootstrapError: Error, Equatable, Sendable {
    case busy, unsafeJournal, journalUnavailable
    case manifestMismatch, commitUnconfirmed, rollbackIncomplete
}

struct ProtectionBootstrapRecord: Codable, Equatable {
    enum Phase: String, Codable { case prepared, creating, rollbackIncomplete }
    typealias Failure = KeyFailureDiagnostic
    let version: Int
    let attemptID: UUID
    let manifest: ProtectionManifest
    let accessGroup: String
    let identifierPrefix: String
    var phase: Phase = .prepared
    var attempted: [KeyComponent] = []
    var created: [KeyComponent] = []
    var unresolved: [KeyComponent] = []
    var failure: Failure?

    init(manifest: ProtectionManifest, configuration: ProtectionConfiguration) {
        version = 1
        attemptID = UUID()
        self.manifest = manifest
        accessGroup = configuration.accessGroup
        identifierPrefix = configuration.identifierPrefix
    }

    func validate(configuration: ProtectionConfiguration) throws {
        guard version == 1, accessGroup == configuration.accessGroup,
              identifierPrefix == configuration.identifierPrefix,
              accessGroup.utf8.count <= 256, identifierPrefix.utf8.count <= 256,
              manifest.inventoryRightID.utf8.count <= 512,
              Set(attempted).count == attempted.count, Set(created).count == created.count,
              Set(unresolved).count == unresolved.count,
              Set(created).isSubset(of: Set(attempted)), Set(unresolved).isSubset(of: Set(attempted)),
              failure?.isValid != false,
              phase != .prepared || attempted.isEmpty,
              phase != .rollbackIncomplete || !unresolved.isEmpty else {
            throw ProtectionBootstrapError.unsafeJournal
        }
        do { try manifest.validate(identifierPrefix: identifierPrefix) }
        catch { throw ProtectionBootstrapError.unsafeJournal }
    }
}

enum ProtectionBootstrapIOFailurePoint { case fileSync, directorySync }

/// The directory and file descriptors pin the owned entries throughout one attempt.
/// The persistent lock inode is never unlinked, including on successful completion.
private final class ProtectionBootstrapJournal {
    static let recordName = ".protection-bootstrap.json"
    static let lockName = ".protection-bootstrap.lock"
    static let maximumBytes = 16 * 1024
    private let directoryURL: URL
    private let failureInjector: ((ProtectionBootstrapIOFailurePoint) throws -> Void)?
    private var directoryDescriptor: Int32
    private var lockDescriptor: Int32

    init(at directory: URL, failureInjector: ((ProtectionBootstrapIOFailurePoint) throws -> Void)? = nil) throws {
        guard directory.isFileURL else { throw ProtectionBootstrapError.unsafeJournal }
        var newlyCreated: [URL] = []
        var candidate = directory
        while true {
            var info = stat()
            if lstat(candidate.path, &info) == 0 { break }
            guard errno == ENOENT, candidate.path != "/" else {
                throw ProtectionBootstrapError.journalUnavailable
            }
            newlyCreated.append(candidate)
            candidate.deleteLastPathComponent()
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw ProtectionBootstrapError.journalUnavailable }
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw ProtectionBootstrapError.unsafeJournal }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0, directoryInfo.st_uid == geteuid(),
              directoryInfo.st_mode & S_IFMT == S_IFDIR, directoryInfo.st_mode & 0o077 == 0 else {
            Darwin.close(directoryFD)
            throw ProtectionBootstrapError.unsafeJournal
        }
        // A newly created directory's own entry belongs to its parent. Flush each
        // parent involved in recursive creation before any key effects. Existing
        // ancestors (including the read-only system root) require no new-entry sync.
        do { try Self.syncParents(of: newlyCreated) }
        catch { Darwin.close(directoryFD); throw error }
        let lockFD = openat(directoryFD, Self.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else {
            Darwin.close(directoryFD)
            throw ProtectionBootstrapError.unsafeJournal
        }
        do { try Self.validateFile(lockFD) }
        catch { Darwin.close(lockFD); Darwin.close(directoryFD); throw error }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD)
            Darwin.close(directoryFD)
            throw ProtectionBootstrapError.busy
        }
        // Fail closed if a replacement lock inode appeared while opening this one.
        var lockInfo = stat()
        var namedLockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0,
              fstatat(directoryFD, Self.lockName, &namedLockInfo, AT_SYMLINK_NOFOLLOW) == 0,
              lockInfo.st_dev == namedLockInfo.st_dev, lockInfo.st_ino == namedLockInfo.st_ino else {
            Darwin.close(lockFD)
            Darwin.close(directoryFD)
            throw ProtectionBootstrapError.unsafeJournal
        }
        directoryDescriptor = directoryFD
        lockDescriptor = lockFD
        directoryURL = directory
        self.failureInjector = failureInjector
    }

    deinit { release() }

    func release() {
        if lockDescriptor >= 0 { Darwin.close(lockDescriptor); lockDescriptor = -1 }
        if directoryDescriptor >= 0 { Darwin.close(directoryDescriptor); directoryDescriptor = -1 }
    }

    func read() throws -> ProtectionBootstrapRecord? {
        try verifyLocation()
        let descriptor = openat(directoryDescriptor, Self.recordName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw ProtectionBootstrapError.unsafeJournal
        }
        defer { Darwin.close(descriptor) }
        try Self.validateFile(descriptor)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0, info.st_size <= Self.maximumBytes else {
            throw ProtectionBootstrapError.unsafeJournal
        }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { buffer in
            Darwin.read(descriptor, buffer.baseAddress!, buffer.count)
        }
        var excess: UInt8 = 0
        guard count == data.count, Darwin.read(descriptor, &excess, 1) == 0 else {
            throw ProtectionBootstrapError.unsafeJournal
        }
        do { return try JSONDecoder().decode(ProtectionBootstrapRecord.self, from: data) }
        catch { throw ProtectionBootstrapError.unsafeJournal }
    }

    func write(_ record: ProtectionBootstrapRecord, replacing previous: ProtectionBootstrapRecord?) throws {
        guard try read() == previous else { throw ProtectionBootstrapError.unsafeJournal }
        let bytes: Data
        do { bytes = try JSONEncoder().encode(record) }
        catch { throw ProtectionBootstrapError.journalUnavailable }
        guard bytes.count <= Self.maximumBytes else { throw ProtectionBootstrapError.unsafeJournal }
        if previous == nil {
            // Exclusive creation means a crash during this write leaves a rejected partial
            // record, never an absent record that could authorize another set of keys.
            let descriptor = openat(directoryDescriptor, Self.recordName,
                                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw ProtectionBootstrapError.unsafeJournal }
            defer { Darwin.close(descriptor) }
            try writeAndSync(bytes, to: descriptor)
            try failureInjector?(.directorySync)
            guard Self.fullSync(directoryDescriptor) else { throw ProtectionBootstrapError.journalUnavailable }
            return
        }
        let temporaryName = ".protection-bootstrap.\(UUID().uuidString).tmp"
        let descriptor = openat(directoryDescriptor, temporaryName,
                                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ProtectionBootstrapError.journalUnavailable }
        defer { Darwin.close(descriptor); _ = unlinkat(directoryDescriptor, temporaryName, 0) }
        try writeAndSync(bytes, to: descriptor)
        guard try read() == previous else { throw ProtectionBootstrapError.unsafeJournal }
        guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, Self.recordName) == 0 else {
            throw ProtectionBootstrapError.journalUnavailable
        }
        try failureInjector?(.directorySync)
        guard Self.fullSync(directoryDescriptor) else { throw ProtectionBootstrapError.journalUnavailable }
    }

    func remove(matching record: ProtectionBootstrapRecord) throws {
        guard try read() == record else { throw ProtectionBootstrapError.unsafeJournal }
        guard unlinkat(directoryDescriptor, Self.recordName, 0) == 0,
              Self.fullSync(directoryDescriptor) else { throw ProtectionBootstrapError.journalUnavailable }
    }

    private static func validateFile(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else {
            throw ProtectionBootstrapError.unsafeJournal
        }
    }

    func verifyLocation() throws {
        guard directoryDescriptor >= 0, lockDescriptor >= 0 else {
            throw ProtectionBootstrapError.journalUnavailable
        }
        var directoryInfo = stat()
        var namedDirectory = stat()
        var lockInfo = stat()
        var namedLock = stat()
        guard fstat(directoryDescriptor, &directoryInfo) == 0,
              lstat(directoryURL.path, &namedDirectory) == 0,
              namedDirectory.st_mode & S_IFMT == S_IFDIR, namedDirectory.st_uid == geteuid(),
              namedDirectory.st_mode & 0o077 == 0,
              namedDirectory.st_dev == directoryInfo.st_dev, namedDirectory.st_ino == directoryInfo.st_ino,
              fstat(lockDescriptor, &lockInfo) == 0,
              fstatat(directoryDescriptor, Self.lockName, &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
              namedLock.st_dev == lockInfo.st_dev, namedLock.st_ino == lockInfo.st_ino else {
            throw ProtectionBootstrapError.unsafeJournal
        }
        try Self.validateFile(lockDescriptor)
    }

    private static func syncParents(of directories: [URL]) throws {
        for directory in directories {
            let parent = directory.deletingLastPathComponent().resolvingSymlinksInPath()
            let descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw ProtectionBootstrapError.journalUnavailable }
            let synced = fullSync(descriptor)
            Darwin.close(descriptor)
            guard synced else { throw ProtectionBootstrapError.journalUnavailable }
        }
    }

    private func writeAndSync(_ bytes: Data, to descriptor: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw ProtectionBootstrapError.journalUnavailable }
                offset += written
            }
        }
        try failureInjector?(.fileSync)
        guard Self.fullSync(descriptor) else { throw ProtectionBootstrapError.journalUnavailable }
    }

    /// Plain `fsync` can leave writes in the drive cache on macOS. Fall back to it only
    /// where the file system does not support a full flush.
    private static func fullSync(_ descriptor: Int32) -> Bool {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return true }
        guard errno == ENOTSUP || errno == EINVAL || errno == ENOTTY else { return false }
        return fsync(descriptor) == 0
    }
}

/// Coordinates effect ordering without knowing how keys are made. Tests inject effects;
/// production supplies Keychain and LARight creation, possession checks, and owned removal.
@MainActor
final class ProtectionBootstrapAttempt {
    let manifest: ProtectionManifest
    let createsNewManifest: Bool
    private let journal: ProtectionBootstrapJournal
    private var record: ProtectionBootstrapRecord?
    /// Components an interrupted earlier attempt may have created under these identities.
    private let inherited: Set<KeyComponent>
    private var handled: Set<KeyComponent> = []
    private var created: Set<KeyComponent> = []
    private var reused: Set<KeyComponent> = []
    private var finished = false

    init(at directory: URL, manifest existing: ProtectionManifest?, storeState: StoreProtectionState,
         configuration: ProtectionConfiguration,
         failureInjector: ((ProtectionBootstrapIOFailurePoint) throws -> Void)? = nil,
         probe: () throws -> StoreProtectionProbe) throws {
        guard !configuration.accessGroup.isEmpty, !configuration.identifierPrefix.isEmpty else {
            throw KeyUnavailable.accessGroupUnavailable
        }
        guard existing != nil || storeState == .empty else { throw KeyUnavailable.missingManifest }
        if let existing { try existing.validate(identifierPrefix: configuration.identifierPrefix) }
        journal = try ProtectionBootstrapJournal(at: directory, failureInjector: failureInjector)
        let current = try probe()
        guard current.manifest == existing, current.state == storeState else {
            throw ProtectionBootstrapError.manifestMismatch
        }
        let pending = try journal.read()
        if let pending {
            try pending.validate(configuration: configuration)
            if let existing, pending.manifest != existing { throw ProtectionBootstrapError.manifestMismatch }
        }
        createsNewManifest = existing == nil
        // No data was ever stored under a pending setup's keys while the store is empty. Resume
        // with exactly those identities, so nothing an earlier attempt created is orphaned by a
        // replacement set and nothing it left behind needs to be deleted.
        manifest = existing ?? pending?.manifest ?? .fresh(identifierPrefix: configuration.identifierPrefix)
        inherited = createsNewManifest ? Set(pending?.attempted ?? []) : []
        if createsNewManifest, pending == nil {
            let fresh = ProtectionBootstrapRecord(manifest: manifest, configuration: configuration)
            try fresh.validate(configuration: configuration)
            try journal.write(fresh, replacing: nil)
            record = fresh
        } else { record = pending }
    }

    /// A component inherited from an interrupted attempt is first looked up with `existing` and
    /// reused when present. Otherwise `effect` creates it under the same journaled identity,
    /// which fails closed if an item that could not be read is still there.
    func create<Value>(_ component: KeyComponent, existing: (() async -> Value?)? = nil,
                       effect: () async throws -> Value) async throws -> Value {
        guard createsNewManifest, !finished, var updated = record, !handled.contains(component),
              inherited.contains(component) || !updated.attempted.contains(component) else {
            throw ProtectionBootstrapError.unsafeJournal
        }
        try Task.checkCancellation()
        handled.insert(component)
        if inherited.contains(component) {
            if let existing, let value = await existing() {
                reused.insert(component)
                try Task.checkCancellation()
                return value
            }
            try Task.checkCancellation()
        } else {
            updated.phase = .creating
            updated.unresolved = []
            updated.attempted.append(component)
            try journal.write(updated, replacing: record)
            record = updated
        }
        let value = try await effect()
        // In-memory success alone grants this process authority to roll this item back.
        // A restarted process deliberately never reconstructs this set from the journal.
        created.insert(component)
        updated.phase = .creating
        updated.unresolved = []
        if !updated.created.contains(component) { updated.created.append(component) }
        try journal.write(updated, replacing: record)
        record = updated
        try Task.checkCancellation()
        return value
    }

    func commit(probe: () throws -> StoreProtectionProbe) throws {
        if finished { return }
        try journal.verifyLocation()
        guard try probe().manifest == manifest else { throw ProtectionBootstrapError.commitUnconfirmed }
        if let record { try journal.remove(matching: record) }
        finished = true
        journal.release()
    }

    /// No inferred cleanup of an interrupted attempt. Only this live attempt's completed
    /// create calls authorize removal; a failed create may only be checked for absence, and a
    /// reused item stays for the next resumed attempt.
    func rollback(cause: KeyUnavailable? = nil, remove: (KeyComponent) async throws -> Void,
                  verifyAbsent: (KeyComponent) async throws -> Void) async throws {
        guard createsNewManifest, !finished, var updated = record else { return }
        var unresolved: [KeyComponent] = []
        for component in updated.attempted.reversed() {
            if reused.contains(component) { unresolved.append(component); continue }
            do {
                if created.contains(component) { try await remove(component) }
                else { try await verifyAbsent(component) }
            } catch { unresolved.append(component) }
        }
        if unresolved.isEmpty {
            try journal.remove(matching: updated)
            record = nil
            finished = true
            journal.release()
        } else {
            updated.phase = .rollbackIncomplete
            updated.unresolved = unresolved
            updated.failure = cause.map(ProtectionBootstrapRecord.Failure.init)
            // Even an I/O failure preserves the earlier record and exact identities.
            do { try journal.write(updated, replacing: record); record = updated }
            catch { throw ProtectionBootstrapError.rollbackIncomplete }
            throw ProtectionBootstrapError.rollbackIncomplete
        }
    }

    /// Used only after original-process disposable cleanup verified every created key absent.
    func retireAfterVerifiedCleanup() throws {
        guard createsNewManifest else { return }
        if finished { return }
        if let record { try journal.remove(matching: record) }
        record = nil
        finished = true
        journal.release()
    }
}
