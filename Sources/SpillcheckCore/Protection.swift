import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Includes HMAC-only receipts and obsolete markers, not just retained ciphertext.
public enum StoreProtectionState: String, Codable, Sendable {
    case empty, protectedDataPresent
}

public enum ProtectedPayloadKind: String, Codable, CaseIterable, Sendable {
    case value, excerpt, sessionMetadata, sourceMetadata
    case queueEvent, ledgerSnapshot, sourceCheckpoint

    public var isBackgroundAccessible: Bool {
        switch self {
        case .queueEvent, .ledgerSnapshot, .sourceCheckpoint: true
        default: false
        }
    }
}

public struct PayloadBinding: Hashable, Codable, Sendable {
    public let reference: ProtectedPayloadReference
    public let ownerID: UUID
    public let kind: ProtectedPayloadKind

    public init(reference: ProtectedPayloadReference, ownerID: UUID, kind: ProtectedPayloadKind) {
        self.reference = reference
        self.ownerID = ownerID
        self.kind = kind
    }
}

public enum ProtectedPayloadAlgorithm: String, Codable, Sendable {
    case backgroundAESGCM = "aes-256-gcm"
    case inventoryECIESAESGCM = "ecies-standard-variable-iv-x963-sha256-aes-gcm+aes-256-gcm"
}

/// A portable ciphertext envelope. Raw value, path and title bytes never belong in its headers.
public struct ProtectedPayload: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let binding: PayloadBinding
    public let keyID: String
    public let algorithm: ProtectedPayloadAlgorithm
    public let wrappedDataKey: Data?
    public let sealedPayload: Data

    public init(
        schemaVersion: Int = Self.currentSchemaVersion, binding: PayloadBinding,
        keyID: String, algorithm: ProtectedPayloadAlgorithm,
        wrappedDataKey: Data? = nil, sealedPayload: Data
    ) {
        self.schemaVersion = schemaVersion
        self.binding = binding
        self.keyID = keyID
        self.algorithm = algorithm
        self.wrappedDataKey = wrappedDataKey
        self.sealedPayload = sealedPayload
    }

    public var authenticatedData: Data {
        // Version-1 ciphertext authenticates this exact domain, including the original name.
        framedFields([
            "leakret-payload", String(schemaVersion), binding.reference.id.uuidString,
            binding.ownerID.uuidString, binding.kind.rawValue, keyID, algorithm.rawValue,
        ])
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    public static func decode(_ data: Data, maximumBytes: Int = 16 * 1024 * 1024) throws -> Self {
        guard maximumBytes > 0, data.count <= maximumBytes else { throw ProtectionError.invalidEnvelope }
        do {
            let payload = try JSONDecoder().decode(Self.self, from: data)
            try payload.validate()
            return payload
        } catch let error as ProtectionError { throw error }
        catch { throw ProtectionError.invalidEnvelope }
    }

    func validate(expectedBinding: PayloadBinding? = nil) throws {
        guard schemaVersion == Self.currentSchemaVersion, !keyID.isEmpty, sealedPayload.count >= 28,
              expectedBinding.map({ $0 == binding }) ?? true else { throw ProtectionError.invalidEnvelope }
        switch algorithm {
        case .backgroundAESGCM:
            guard binding.kind.isBackgroundAccessible, wrappedDataKey == nil else {
                throw ProtectionError.invalidEnvelope
            }
        case .inventoryECIESAESGCM:
            guard !binding.kind.isBackgroundAccessible, wrappedDataKey?.isEmpty == false else {
                throw ProtectionError.invalidEnvelope
            }
        }
    }
}

public struct ProtectionManifest: Equatable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let vaultID: UUID
    public let queueKeyID: UUID
    public let identityKeyID: UUID
    public let inventoryRightID: String

    public init(
        schemaVersion: Int = Self.currentSchemaVersion, vaultID: UUID,
        queueKeyID: UUID, identityKeyID: UUID, inventoryRightID: String
    ) {
        self.schemaVersion = schemaVersion
        self.vaultID = vaultID
        self.queueKeyID = queueKeyID
        self.identityKeyID = identityKeyID
        self.inventoryRightID = inventoryRightID
    }

    public static func fresh(identifierPrefix: String = "com.leakret.app") -> Self {
        let vaultID = UUID()
        return Self(vaultID: vaultID, queueKeyID: UUID(), identityKeyID: UUID(),
                    inventoryRightID: "\(identifierPrefix).inventory.v1.\(vaultID.uuidString)")
    }

    public func validate(identifierPrefix: String? = nil) throws {
        guard schemaVersion == Self.currentSchemaVersion, queueKeyID != identityKeyID,
              !inventoryRightID.isEmpty else { throw KeyUnavailable.invalidManifest }
        if let identifierPrefix {
            guard inventoryRightID == "\(identifierPrefix).inventory.v1.\(vaultID.uuidString)" else {
                throw KeyUnavailable.invalidManifest
            }
        }
    }
}

public enum KeyComponent: String, Codable, Sendable { case queue, identity, inventory }

/// Controlled diagnostic values only; framework userInfo and content are never retained.
public enum KeyUnavailable: Error, Equatable, Sendable {
    case missingManifest, invalidManifest
    case missingKey(KeyComponent)
    case unusableKey(KeyComponent, code: Int)
    case accessGroupUnavailable
    case unsupportedInventoryAlgorithm
}

public enum ProtectionError: Error, Equatable, Sendable {
    case invalidEnvelope, incorrectKey, invalidPurpose, authenticationFailed
    case cryptographyFailure(code: Int)
}

public enum ViewingAuthorizationError: Error, Equatable, Sendable {
    case cancelled, unavailable(code: Int), denied(code: Int), invalidated, busy
}

private func framedFields(_ fields: [String]) -> Data {
    fields.reduce(into: Data()) { output, field in
        let bytes = Data(field.utf8)
        var count = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &count) { output.append(contentsOf: $0) }
        output.append(bytes)
    }
}

private let inventoryWrappingAlgorithm = SecKeyAlgorithm.eciesEncryptionStandardVariableIVX963SHA256AESGCM

private func importedPublicKey(_ data: Data) throws -> SecKey {
    var error: Unmanaged<CFError>?
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                                      kSecAttrKeyClass: kSecAttrKeyClassPublic,
                                      kSecAttrKeySizeInBits: 256]
    guard let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &error),
          SecKeyIsAlgorithmSupported(key, .encrypt, inventoryWrappingAlgorithm) else {
        let code = error.map { Int(CFErrorGetCode($0.takeRetainedValue())) } ?? 0
        throw KeyUnavailable.unusableKey(.inventory, code: code)
    }
    return key
}

/// Holds only the exported inventory public key. No private inventory operation exists here.
public actor BackgroundCryptography: BackgroundStoreCryptography {
    public nonisolated let manifest: ProtectionManifest
    private let queueKey: SymmetricKey
    private let identityKey: SymmetricKey
    private let inventoryPublicKey: SecKey

    init(manifest: ProtectionManifest, queueKey: Data, identityKey: Data, inventoryPublicKey: Data) throws {
        try manifest.validate()
        guard queueKey.count == 32, identityKey.count == 32, queueKey != identityKey else {
            throw KeyUnavailable.invalidManifest
        }
        self.manifest = manifest
        self.queueKey = SymmetricKey(data: queueKey)
        self.identityKey = SymmetricKey(data: identityKey)
        self.inventoryPublicKey = try importedPublicKey(inventoryPublicKey)
    }

    public func sealBackground(_ plaintext: Data, binding: PayloadBinding) throws -> ProtectedPayload {
        guard binding.kind.isBackgroundAccessible else { throw ProtectionError.invalidPurpose }
        let header = ProtectedPayload(binding: binding, keyID: manifest.queueKeyID.uuidString,
                                      algorithm: .backgroundAESGCM, sealedPayload: Data())
        guard let combined = try AES.GCM.seal(plaintext, using: queueKey,
                                              authenticating: header.authenticatedData).combined else {
            throw ProtectionError.invalidEnvelope
        }
        return ProtectedPayload(binding: binding, keyID: header.keyID, algorithm: header.algorithm,
                                sealedPayload: combined)
    }

    public func openBackground(_ payload: ProtectedPayload, binding: PayloadBinding) throws -> Data {
        try payload.validate(expectedBinding: binding)
        guard binding.kind.isBackgroundAccessible, payload.algorithm == .backgroundAESGCM else {
            throw ProtectionError.invalidPurpose
        }
        guard payload.keyID == manifest.queueKeyID.uuidString else { throw ProtectionError.incorrectKey }
        return try openAES(payload, key: queueKey)
    }

    public func sealInventory(_ plaintext: Data, binding: PayloadBinding) throws -> ProtectedPayload {
        guard !binding.kind.isBackgroundAccessible else { throw ProtectionError.invalidPurpose }
        let dataKey = SymmetricKey(size: .bits256)
        let keyBytes = dataKey.withUnsafeBytes { Data($0) }
        var error: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(inventoryPublicKey, inventoryWrappingAlgorithm,
                                                      keyBytes as CFData, &error) as Data? else {
            throw ProtectionError.cryptographyFailure(code: error.map {
                Int(CFErrorGetCode($0.takeRetainedValue()))
            } ?? 0)
        }
        let header = ProtectedPayload(binding: binding, keyID: manifest.inventoryRightID,
                                      algorithm: .inventoryECIESAESGCM, wrappedDataKey: wrapped,
                                      sealedPayload: Data())
        guard let combined = try AES.GCM.seal(plaintext, using: dataKey,
                                              authenticating: header.authenticatedData).combined else {
            throw ProtectionError.invalidEnvelope
        }
        return ProtectedPayload(binding: binding, keyID: header.keyID, algorithm: header.algorithm,
                                wrappedDataKey: wrapped, sealedPayload: combined)
    }

    public func fingerprint(exactBytes: Data) throws -> ValueFingerprint {
        // Stable domains preserve fingerprints and revision receipts in existing vaults.
        var input = framedFields(["leakret-identity", "1", "exact-value"])
        input.append(exactBytes)
        return try ValueFingerprint(keyedDigest: Data(HMAC<SHA256>.authenticationCode(for: input, using: identityKey)))
    }

    public func revision(canonicalBytes: Data) throws -> ContentRevision {
        var input = framedFields(["leakret-identity", "1", "canonical-revision"])
        input.append(canonicalBytes)
        return try ContentRevision(keyedDigest: Data(HMAC<SHA256>.authenticationCode(for: input, using: identityKey)))
    }

    /// Synthetic fixtures only. Nothing is placed in the user's Keychain, and no private key is returned.
    @_spi(Testing) public static func ephemeralForTesting(
        manifest: ProtectionManifest = .fresh(identifierPrefix: "com.spillcheck.test")
    ) throws -> BackgroundCryptography {
        let privateKey = P256.KeyAgreement.PrivateKey()
        return try BackgroundCryptography(
            manifest: manifest,
            queueKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
            identityKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
            inventoryPublicKey: privateKey.publicKey.x963Representation
        )
    }

    /// Disposable acceptance stores only. The application bootstrap never calls this factory.
    /// A synthetic seed lets a separate crash-test process reopen the same encrypted fixture.
    @_spi(Testing) public static func deterministicForTesting(
        seed: Data, manifest: ProtectionManifest
    ) throws -> BackgroundCryptography {
        guard !seed.isEmpty else { throw KeyUnavailable.invalidManifest }
        func derive(_ purpose: String) -> Data {
            var input = framedFields(["spillcheck-test-only", "1", purpose])
            input.append(seed)
            return Data(SHA256.hash(data: input))
        }
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: derive("inventory-private-key"))
        return try BackgroundCryptography(manifest: manifest, queueKey: derive("queue-key"),
                                           identityKey: derive("identity-key"),
                                           inventoryPublicKey: privateKey.publicKey.x963Representation)
    }
}

private func openAES(_ payload: ProtectedPayload, key: SymmetricKey) throws -> Data {
    do {
        return try AES.GCM.open(AES.GCM.SealedBox(combined: payload.sealedPayload), using: key,
                                authenticating: payload.authenticatedData)
    } catch { throw ProtectionError.authenticationFailed }
}

public struct ProtectionConfiguration: Sendable {
    /// The original namespace is part of the installed app's provisioned Keychain identity.
    public let accessGroup: String
    public let identifierPrefix: String

    public init(accessGroup: String, identifierPrefix: String = "com.leakret.app") {
        self.accessGroup = accessGroup
        self.identifierPrefix = identifierPrefix
    }
}

private struct BackgroundKeychainItem {
    let component: KeyComponent
    let account: UUID
    let configuration: ProtectionConfiguration

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: "\(configuration.identifierPrefix).\(component.rawValue).v1",
         kSecAttrAccount: account.uuidString, kSecAttrAccessGroup: configuration.accessGroup,
         kSecUseDataProtectionKeychain: true]
    }

    func load() throws -> Data {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw failure(status) }
        guard let data = result as? Data, data.count == 32 else {
            throw KeyUnavailable.unusableKey(component, code: Int(errSecDecode))
        }
        return data
    }

    func create() throws -> Data {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var query = query
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData] = bytes
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status) }
        return bytes
    }

    func removeCreatedItem() { _ = SecItemDelete(query as CFDictionary) }

    func removeCreatedItemVerifyingAbsence() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
        var probe = query
        probe[kSecMatchLimit] = kSecMatchLimitOne
        probe[kSecReturnAttributes] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        probe[kSecUseAuthenticationContext] = context
        let verification = SecItemCopyMatching(probe as CFDictionary, nil)
        guard verification == errSecItemNotFound else {
            throw failure(verification == errSecSuccess ? errSecDuplicateItem : verification)
        }
    }

    private func failure(_ status: OSStatus) -> KeyUnavailable {
        switch status {
        case errSecItemNotFound: .missingKey(component)
        case errSecMissingEntitlement: .accessGroupUnavailable
        default: .unusableKey(component, code: Int(status))
        }
    }
}

@MainActor
protocol InventoryPrivateKeyAccess: AnyObject {
    var isAuthorized: Bool { get }
    func authorize(localizedReason: String) async throws
    func decrypt(_ wrappedKey: Data) async throws -> Data
    func deauthorize() async
}

@MainActor
private final class PersistedInventoryKey: InventoryPrivateKeyAccess {
    let right: LAPersistedRight
    init(_ right: LAPersistedRight) { self.right = right }
    var isAuthorized: Bool { right.state == .authorized }
    func authorize(localizedReason: String) async throws {
        do { try await right.authorize(localizedReason: localizedReason) }
        catch { throw safeAuthorizationError(error) }
    }
    func decrypt(_ wrappedKey: Data) async throws -> Data {
        do { return try await right.key.decrypt(wrappedKey, algorithm: inventoryWrappingAlgorithm) }
        catch { throw safeAuthorizationError(error) }
    }
    func deauthorize() async { await right.deauthorize() }
}

private func safeAuthorizationError(_ error: any Error) -> ViewingAuthorizationError {
    let code = (error as NSError).code
    if let error = error as? LAError {
        switch error.code {
        case .userCancel, .appCancel, .systemCancel: return .cancelled
        case .notInteractive, .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet, .biometryLockout:
            return .unavailable(code: code)
        default: break
        }
    }
    return .denied(code: code)
}

@MainActor
public struct ProtectionServices {
    public let manifest: ProtectionManifest
    public let background: BackgroundCryptography
    public let viewingSession: InventoryViewingSession
    /// The caller must commit this manifest durably before accepting any work.
    public let createdNewManifest: Bool
    private let bootstrapConfiguration: ProtectionConfiguration

    init(manifest: ProtectionManifest, background: BackgroundCryptography,
         viewingSession: InventoryViewingSession, createdNewManifest: Bool,
         configuration: ProtectionConfiguration) {
        self.manifest = manifest
        self.background = background
        self.viewingSession = viewingSession
        self.createdNewManifest = createdNewManifest
        bootstrapConfiguration = configuration
    }

    /// Call only after closing a disposable acceptance store. Loaded production manifests
    /// never authorize cleanup, and callers cannot substitute a different Keychain query.
    @_spi(Testing) public func removeNewlyCreatedProtectionForTesting() async throws -> Bool {
        guard createdNewManifest else { return false }
        let configuration = bootstrapConfiguration
        guard !configuration.accessGroup.isEmpty, !configuration.identifierPrefix.isEmpty,
              background.manifest == manifest, viewingSession.manifest == manifest else {
            throw KeyUnavailable.invalidManifest
        }
        try manifest.validate(identifierPrefix: configuration.identifierPrefix)
        await viewingSession.deauthorize()
        var firstFailure: (any Error)?
        for item in [
            BackgroundKeychainItem(component: .queue, account: manifest.queueKeyID, configuration: configuration),
            BackgroundKeychainItem(component: .identity, account: manifest.identityKeyID, configuration: configuration)
        ] {
            do { try item.removeCreatedItemVerifyingAbsence() }
            catch let error as KeyUnavailable { firstFailure = firstFailure ?? error }
            catch { firstFailure = firstFailure ?? KeyUnavailable.unusableKey(item.component, code: (error as NSError).code) }
        }
        do { try await removeCreatedInventoryRightVerifyingAbsence(manifest.inventoryRightID) }
        catch { firstFailure = firstFailure ?? error }
        if let firstFailure { throw firstFailure }
        return true
    }
}

@_spi(Testing)
public struct ProtectionCleanupErrorStatus: Codable, Equatable, Sendable {
    public let domain: String
    public let code: Int
}

@_spi(Testing)
public struct ProtectionCleanupProbeFailure: Error, Codable, Sendable {
    public let stage: String
    public let observed: [ProtectionCleanupErrorStatus]?
    public let expected: [ProtectionCleanupErrorStatus]?
}

// Error messages and arbitrary userInfo never enter cleanup evidence. Refuse a chain
// longer than this bound rather than matching only its visible prefix.
func protectionCleanupErrorSignature(_ error: any Error) -> [ProtectionCleanupErrorStatus]? {
    var current = error as NSError
    var signature: [ProtectionCleanupErrorStatus] = []
    for _ in 0..<8 {
        signature.append(.init(domain: current.domain, code: current.code))
        guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return signature }
        current = underlying
    }
    return nil
}

func protectionCleanupSignaturesMatch(_ expected: [ProtectionCleanupErrorStatus]?,
                                      _ observed: [ProtectionCleanupErrorStatus]?) -> Bool {
    guard let expected, !expected.isEmpty, let observed else { return false }
    return expected == observed
}

@MainActor
private func removeCreatedInventoryRightVerifyingAbsence(_ identifier: String) async throws {
    // Establish storage availability and this owned right's presence first. A fresh,
    // never-created identifier measures absence in this same client/framework context.
    // No global LocalAuthentication numeric status is treated as "not found".
    do { _ = try await LARightStore.shared.right(forIdentifier: identifier) }
    catch { throw ProtectionCleanupProbeFailure(stage: "owned-right-positive-control",
        observed: protectionCleanupErrorSignature(error), expected: nil) }

    let negativeIdentifier = identifier + ".never-created." + UUID().uuidString
    var negative: [ProtectionCleanupErrorStatus]?
    do { _ = try await LARightStore.shared.right(forIdentifier: negativeIdentifier) }
    catch { negative = protectionCleanupErrorSignature(error) }
    guard let negative else {
        throw ProtectionCleanupProbeFailure(stage: "never-created-negative-control", observed: nil, expected: nil)
    }

    do { try await LARightStore.shared.removeRight(forIdentifier: identifier) }
    catch { throw ProtectionCleanupProbeFailure(stage: "owned-right-removal",
        observed: protectionCleanupErrorSignature(error), expected: negative) }

    var removed: [ProtectionCleanupErrorStatus]?
    do { _ = try await LARightStore.shared.right(forIdentifier: identifier) }
    catch { removed = protectionCleanupErrorSignature(error) }
    guard protectionCleanupSignaturesMatch(negative, removed) else {
        throw ProtectionCleanupProbeFailure(stage: "removed-right-absence-verification",
            observed: removed, expected: negative)
    }
}

@MainActor
public enum ProtectionBootstrap {
    public static func prepare(
        manifest existing: ProtectionManifest?, storeState: StoreProtectionState,
        configuration: ProtectionConfiguration
    ) async throws -> ProtectionServices {
        guard !configuration.accessGroup.isEmpty, !configuration.identifierPrefix.isEmpty else {
            throw KeyUnavailable.accessGroupUnavailable
        }
        guard existing != nil || storeState == .empty else { throw KeyUnavailable.missingManifest }
        let manifest = existing ?? .fresh(identifierPrefix: configuration.identifierPrefix)
        try manifest.validate(identifierPrefix: configuration.identifierPrefix)
        let queue = BackgroundKeychainItem(component: .queue, account: manifest.queueKeyID, configuration: configuration)
        let identity = BackgroundKeychainItem(component: .identity, account: manifest.identityKeyID, configuration: configuration)
        var createdQueue = false
        var createdIdentity = false
        var createdRight = false
        do {
            let queueBytes: Data
            let identityBytes: Data
            let right: LAPersistedRight
            if existing != nil {
                queueBytes = try queue.load()
                identityBytes = try identity.load()
                do { right = try await LARightStore.shared.right(forIdentifier: manifest.inventoryRightID) }
                catch {
                    let code = (error as NSError).code
                    if code == Int(errSecMissingEntitlement) { throw KeyUnavailable.accessGroupUnavailable }
                    if code == Int(errSecItemNotFound) { throw KeyUnavailable.missingKey(.inventory) }
                    throw KeyUnavailable.unusableKey(.inventory, code: code)
                }
            } else {
                queueBytes = try queue.create()
                createdQueue = true
                identityBytes = try identity.create()
                createdIdentity = true
                do {
                    right = try await LARightStore.shared.saveRight(
                        LARight(requirement: .biometry(fallback: .devicePasscode)), identifier: manifest.inventoryRightID)
                    createdRight = true
                } catch {
                    let code = (error as NSError).code
                    if code == Int(errSecMissingEntitlement) { throw KeyUnavailable.accessGroupUnavailable }
                    throw KeyUnavailable.unusableKey(.inventory, code: code)
                }
            }
            await right.deauthorize()
            guard right.key.publicKey.canEncrypt(using: inventoryWrappingAlgorithm),
                  right.key.canDecrypt(using: inventoryWrappingAlgorithm) else {
                throw KeyUnavailable.unsupportedInventoryAlgorithm
            }
            let publicBytes: Data
            do { publicBytes = try await right.key.publicKey.bytes }
            catch { throw KeyUnavailable.unusableKey(.inventory, code: (error as NSError).code) }
            let background = try BackgroundCryptography(manifest: manifest, queueKey: queueBytes,
                                                        identityKey: identityBytes, inventoryPublicKey: publicBytes)
            let viewing = InventoryViewingSession(manifest: manifest, privateKey: PersistedInventoryKey(right))
            return ProtectionServices(manifest: manifest, background: background,
                                      viewingSession: viewing, createdNewManifest: existing == nil,
                                      configuration: configuration)
        } catch {
            // Only this attempt's newly-created UUIDs are eligible for rollback.
            if createdQueue { queue.removeCreatedItem() }
            if createdIdentity { identity.removeCreatedItem() }
            if createdRight { try? await LARightStore.shared.removeRight(forIdentifier: manifest.inventoryRightID) }
            throw error
        }
    }
}

public enum ViewingActivityKind: String, Codable, Sendable {
    case successfulReveal, keyDown, mouseDown, scroll
}

public enum ViewingInvalidationReason: String, Codable, Sendable {
    case userMask, windowClose, sleep, sessionLock, inactivity, authorizationFailure
}

public struct ViewingSessionSnapshot: Equatable, Codable, Sendable {
    public let generation: UInt64
    public let timeoutSeconds: TimeInterval
    public let expiresAt: Date?
    public let lastAcceptedActivityAt: Date?
    public let lastAcceptedActivityKind: ViewingActivityKind?
    public let acceptedActivityCount: UInt64
    public let isAuthorized: Bool
}

/// UI plaintext and all private-key operations are confined to the main actor.
@MainActor
public final class InventoryViewingSession {
    public let manifest: ProtectionManifest
    public let timeoutSeconds: TimeInterval
    public private(set) var revealed: [ProtectedPayloadReference: Data] = [:]
    public var onInvalidate: (@MainActor (ViewingInvalidationReason) -> Void)?
    private let privateKey: any InventoryPrivateKeyAccess
    private let uptime: @MainActor () -> TimeInterval
    private let wallTime: @MainActor () -> Date
    private var generation: UInt64 = 0
    private var deadline: TimeInterval?
    private var expiresAt: Date?
    private var lastActivityAt: Date?
    private var lastActivityKind: ViewingActivityKind?
    private var activityCount: UInt64 = 0
    private var pending: Task<Data, any Error>?
    private var retiringOperation: Task<Data, any Error>?
    private var deauthorization: Task<Void, Never>?

    init(
        manifest: ProtectionManifest, privateKey: any InventoryPrivateKeyAccess,
        timeoutSeconds: TimeInterval = 300,
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wallTime: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.manifest = manifest
        self.privateKey = privateKey
        self.timeoutSeconds = timeoutSeconds.isFinite && timeoutSeconds > 0 ? timeoutSeconds : 300
        self.uptime = uptime
        self.wallTime = wallTime
    }

    public var isAuthorized: Bool {
        privateKey.isAuthorized && deadline.map { $0 > uptime() } == true
    }

    public var snapshot: ViewingSessionSnapshot {
        ViewingSessionSnapshot(generation: generation, timeoutSeconds: timeoutSeconds,
                               expiresAt: expiresAt, lastAcceptedActivityAt: lastActivityAt,
                               lastAcceptedActivityKind: lastActivityKind,
                               acceptedActivityCount: activityCount, isAuthorized: isAuthorized)
    }

    public func reveal(
        _ payload: ProtectedPayload, binding: PayloadBinding, localizedReason: String
    ) async throws -> Data {
        expireIfNeeded()
        try payload.validate(expectedBinding: binding)
        guard !binding.kind.isBackgroundAccessible, payload.algorithm == .inventoryECIESAESGCM,
              payload.keyID == manifest.inventoryRightID else { throw ProtectionError.incorrectKey }
        guard pending == nil else { throw ViewingAuthorizationError.busy }
        generation &+= 1
        let requestGeneration = generation
        let previousOperation = retiringOperation
        let task = Task { @MainActor [self] () throws -> Data in
            // A canceled framework operation may still finish. Its final deauthorization
            // completes before a subsequent authorization can begin on the same right.
            _ = await previousOperation?.result
            await deauthorization?.value
            try checkGeneration(requestGeneration)
            retiringOperation = nil
            if !isAuthorized {
                do { try await privateKey.authorize(localizedReason: localizedReason) }
                catch {
                    try await checkPrivateCompletion(requestGeneration)
                    throw error
                }
                try await checkPrivateCompletion(requestGeneration)
                guard privateKey.isAuthorized else { throw ViewingAuthorizationError.invalidated }
                lastActivityAt = nil
                lastActivityKind = nil
                activityCount = 0
                deadline = uptime() + timeoutSeconds
                expiresAt = wallTime().addingTimeInterval(timeoutSeconds)
            }
            try checkGeneration(requestGeneration)
            guard isAuthorized, let wrappedKey = payload.wrappedDataKey else {
                throw ViewingAuthorizationError.invalidated
            }
            let bytes: Data
            do { bytes = try await privateKey.decrypt(wrappedKey) }
            catch {
                try await checkPrivateCompletion(requestGeneration)
                throw error
            }
            try await checkPrivateCompletion(requestGeneration)
            guard isAuthorized, bytes.count == 32 else { throw ViewingAuthorizationError.invalidated }
            return try openAES(payload, key: SymmetricKey(data: bytes))
        }
        pending = task
        do {
            let output = try await task.value
            try checkGeneration(requestGeneration)
            guard isAuthorized else { throw ViewingAuthorizationError.invalidated }
            pending = nil
            revealed[binding.reference] = output
            acceptActivity(.successfulReveal)
            return output
        } catch {
            // An obsolete completion must not mask a newer authorized request.
            if generation == requestGeneration {
                invalidate(reason: .authorizationFailure)
                await deauthorization?.value
            }
            throw error
        }
    }

    private func checkGeneration(_ expected: UInt64) throws {
        guard generation == expected, !Task.isCancelled else { throw ViewingAuthorizationError.invalidated }
    }

    private func checkPrivateCompletion(_ expected: UInt64) async throws {
        do { try checkGeneration(expected) }
        catch {
            await privateKey.deauthorize()
            throw error
        }
    }

    public func acceptActivity(_ kind: ViewingActivityKind) {
        expireIfNeeded()
        guard isAuthorized else { return }
        lastActivityAt = wallTime()
        lastActivityKind = kind
        activityCount &+= 1
        deadline = uptime() + timeoutSeconds
        expiresAt = lastActivityAt?.addingTimeInterval(timeoutSeconds)
    }

    public func expireIfNeeded() {
        if deadline.map({ $0 <= uptime() }) == true {
            invalidate(reason: .inactivity)
        } else if deadline != nil, !privateKey.isAuthorized {
            invalidate(reason: .authorizationFailure)
        }
    }

    public func invalidate(reason: ViewingInvalidationReason) {
        generation &+= 1
        if let pending { retiringOperation = pending }
        pending?.cancel()
        pending = nil
        deadline = nil
        expiresAt = nil
        revealed.removeAll(keepingCapacity: false)
        onInvalidate?(reason)
        let previous = deauthorization
        let key = privateKey
        deauthorization = Task { @MainActor in
            await previous?.value
            await key.deauthorize()
        }
    }

    public func deauthorize() async {
        invalidate(reason: .userMask)
        await deauthorization?.value
    }

    /// Exercises the framework boundary on this session's actual key without UI authorization.
    /// Only a known-valid envelope (successfully revealed in the interactive probe) proves denial.
    @_spi(Testing) public func privateOperationDeniedForTesting(_ payload: ProtectedPayload) async -> Bool {
        guard !isAuthorized, payload.keyID == manifest.inventoryRightID,
              let bytes = payload.wrappedDataKey, !bytes.isEmpty else { return false }
        do {
            _ = try await privateKey.decrypt(bytes)
            return false
        } catch { return true }
    }
}
