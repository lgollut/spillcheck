import CryptoKit
import Foundation
import Security
import Testing
@_spi(Testing) @testable import SpillcheckCore

private enum FixtureFailure: Error { case key, decrypt }

@MainActor
private final class FixturePrivateKey: InventoryPrivateKeyAccess {
    let key: SecKey
    let exportedPublicKey: Data
    var isAuthorized = false
    var authorizations = 0
    var deauthorizations = 0
    var authorizationError: ViewingAuthorizationError?
    var decryptionError: ViewingAuthorizationError?
    var authorizeBeforeThrow = false
    var holdAuthorization = false
    var holdDecryption = false
    var authorizationGate: CheckedContinuation<Void, Never>?
    var decryptionGate: CheckedContinuation<Void, Never>?

    init() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                                          kSecAttrKeySizeInBits: 256]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              let publicKey = SecKeyCopyPublicKey(key),
              let bytes = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw FixtureFailure.key
        }
        self.key = key
        self.exportedPublicKey = bytes
    }

    func authorize(localizedReason: String) async throws {
        authorizations += 1
        let error = authorizationError
        if holdAuthorization {
            await withCheckedContinuation { authorizationGate = $0 }
        }
        if let error {
            if authorizeBeforeThrow { isAuthorized = true }
            throw error
        }
        // Intentionally ignore cancellation to exercise stale framework completion guards.
        isAuthorized = true
    }

    func decrypt(_ wrappedKey: Data) async throws -> Data {
        let error = decryptionError
        if holdDecryption { await withCheckedContinuation { decryptionGate = $0 } }
        if let error {
            if authorizeBeforeThrow { isAuthorized = true }
            throw error
        }
        guard isAuthorized else { throw ViewingAuthorizationError.denied(code: -1004) }
        guard let bytes = SecKeyCreateDecryptedData(
            key, .eciesEncryptionStandardVariableIVX963SHA256AESGCM, wrappedKey as CFData, nil
        ) as Data? else { throw FixtureFailure.decrypt }
        return bytes
    }

    func deauthorize() async {
        isAuthorized = false
        deauthorizations += 1
    }
}

@MainActor
private final class FixtureClock {
    var uptime: TimeInterval = 1_000
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { uptime += seconds; date = date.addingTimeInterval(seconds) }
}

private func binding(_ kind: ProtectedPayloadKind, ownerID: UUID = UUID()) -> PayloadBinding {
    PayloadBinding(reference: ProtectedPayloadReference(), ownerID: ownerID, kind: kind)
}

@MainActor
private func fixture() throws -> (BackgroundCryptography, InventoryViewingSession, FixturePrivateKey, FixtureClock) {
    let manifest = ProtectionManifest.fresh(identifierPrefix: "com.spillcheck.test")
    let key = try FixturePrivateKey()
    let crypto = try BackgroundCryptography(
        manifest: manifest, queueKey: Data(repeating: 0x17, count: 32),
        identityKey: Data(repeating: 0x29, count: 32), inventoryPublicKey: key.exportedPublicKey
    )
    let clock = FixtureClock()
    let viewing = InventoryViewingSession(manifest: manifest, privateKey: key,
                                          uptime: { clock.uptime }, wallTime: { clock.date })
    return (crypto, viewing, key, clock)
}

private func modified(
    _ payload: ProtectedPayload, schemaVersion: Int? = nil, binding: PayloadBinding? = nil,
    keyID: String? = nil, algorithm: ProtectedPayloadAlgorithm? = nil,
    wrappedDataKey: Data? = nil, sealedPayload: Data? = nil
) -> ProtectedPayload {
    ProtectedPayload(schemaVersion: schemaVersion ?? payload.schemaVersion,
                     binding: binding ?? payload.binding, keyID: keyID ?? payload.keyID,
                     algorithm: algorithm ?? payload.algorithm,
                     wrappedDataKey: wrappedDataKey ?? payload.wrappedDataKey,
                     sealedPayload: sealedPayload ?? payload.sealedPayload)
}

@Suite("Independent background and authenticated inventory protection")
struct ProtectionTests {
    @Test func backgroundKindsRoundTripAndCodecExcludeRawBytes() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let plaintext = Data("SYNTHETIC-SPILLCHECK-queue-title-path-Ä-🔐\n".utf8)
        for kind in [ProtectedPayloadKind.queueEvent, .ledgerSnapshot, .sourceCheckpoint] {
            let context = binding(kind)
            let envelope = try await crypto.sealBackground(plaintext, binding: context)
            let encoded = try envelope.encoded()
            #expect(encoded.range(of: plaintext) == nil)
            let decoded = try ProtectedPayload.decode(encoded)
            #expect(decoded == envelope)
            #expect(try await crypto.openBackground(decoded, binding: context) == plaintext)
        }
    }

    @Test func backgroundCannotSealOrDecryptInventoryFields() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        for kind in [ProtectedPayloadKind.value, .excerpt, .sessionMetadata, .sourceMetadata] {
            let context = binding(kind)
            await #expect(throws: ProtectionError.invalidPurpose) {
                try await crypto.sealBackground(Data("synthetic".utf8), binding: context)
            }
            let inventory = try await crypto.sealInventory(Data("synthetic".utf8), binding: context)
            await #expect(throws: ProtectionError.invalidPurpose) {
                try await crypto.openBackground(inventory, binding: context)
            }
        }
    }

    @Test func fingerprintUsesExactBytesAndSeparateRevisionDomain() async throws {
        let first = try BackgroundCryptography.ephemeralForTesting()
        let second = try BackgroundCryptography.ephemeralForTesting(manifest: first.manifest)
        let bytes = Data("SYNTHETIC-Ä-🔐\n".utf8)
        let digest = try await first.fingerprint(exactBytes: bytes)
        #expect(digest == (try await first.fingerprint(exactBytes: bytes)))
        #expect(digest != (try await first.fingerprint(exactBytes: Data(bytes.dropLast()))))
        #expect(digest != (try await first.fingerprint(exactBytes: Data("SYNTHETIC-Ä-🔐\n".utf8))))
        #expect(digest != (try await second.fingerprint(exactBytes: bytes)))
        #expect(digest.keyedDigest != (try await first.revision(canonicalBytes: bytes)).keyedDigest)
        #expect(digest.keyedDigest != Data(SHA256.hash(data: bytes)))
    }

    @Test func changingOnlyIdentityKeyCannotChangeQueueEncryptionAccess() async throws {
        let manifest = ProtectionManifest.fresh(identifierPrefix: "com.spillcheck.test.roles")
        let publicKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        let queueKey = Data(repeating: 0x31, count: 32)
        let identityKey = Data(repeating: 0x42, count: 32)
        let first = try BackgroundCryptography(manifest: manifest, queueKey: queueKey,
                                               identityKey: identityKey, inventoryPublicKey: publicKey)
        let changedIdentity = try BackgroundCryptography(manifest: manifest, queueKey: queueKey,
                                                         identityKey: Data(repeating: 0x53, count: 32), inventoryPublicKey: publicKey)
        let changedQueue = try BackgroundCryptography(manifest: manifest, queueKey: Data(repeating: 0x64, count: 32),
                                                      identityKey: identityKey, inventoryPublicKey: publicKey)
        let exact = Data("SYNTHETIC-distinct-key-roles".utf8)
        let context = binding(.queueEvent)
        let queue = try await first.sealBackground(exact, binding: context)
        #expect(try await changedIdentity.openBackground(queue, binding: context) == exact)
        let originalDigest = try await first.fingerprint(exactBytes: exact)
        let changedIdentityDigest = try await changedIdentity.fingerprint(exactBytes: exact)
        let changedQueueDigest = try await changedQueue.fingerprint(exactBytes: exact)
        #expect(originalDigest != changedIdentityDigest)
        #expect(originalDigest == changedQueueDigest)
        await #expect(throws: ProtectionError.authenticationFailed) {
            try await changedQueue.openBackground(queue, binding: context)
        }
    }

    @Test func backgroundFreshNoncesAndWrongKeysReject() async throws {
        let first = try BackgroundCryptography.ephemeralForTesting()
        let second = try BackgroundCryptography.ephemeralForTesting(manifest: first.manifest)
        let context = binding(.queueEvent)
        let plaintext = Data("synthetic-pending-event".utf8)
        let one = try await first.sealBackground(plaintext, binding: context)
        let two = try await first.sealBackground(plaintext, binding: context)
        #expect(one.sealedPayload != two.sealedPayload)
        await #expect(throws: ProtectionError.authenticationFailed) {
            try await second.openBackground(one, binding: context)
        }
    }

    @Test func deterministicAcceptanceFactoryReopensOnlyMatchingSyntheticSeed() async throws {
        let manifest = ProtectionManifest.fresh(identifierPrefix: "com.spillcheck.test.crash")
        let seed = Data("SYNTHETIC-spillcheck-acceptance-process-seed".utf8)
        let first = try BackgroundCryptography.deterministicForTesting(seed: seed, manifest: manifest)
        let reopened = try BackgroundCryptography.deterministicForTesting(seed: seed, manifest: manifest)
        let wrong = try BackgroundCryptography.deterministicForTesting(seed: Data("SYNTHETIC-different-seed".utf8), manifest: manifest)
        let context = binding(.ledgerSnapshot)
        let exact = Data("SYNTHETIC-disposable-ledger".utf8)
        let payload = try await first.sealBackground(exact, binding: context)
        #expect(try await reopened.openBackground(payload, binding: context) == exact)
        let originalFingerprint = try await first.fingerprint(exactBytes: exact)
        let reopenedFingerprint = try await reopened.fingerprint(exactBytes: exact)
        #expect(originalFingerprint == reopenedFingerprint)
        await #expect(throws: ProtectionError.authenticationFailed) {
            try await wrong.openBackground(payload, binding: context)
        }
    }

    @Test func everyBackgroundBindingFieldAndCiphertextAreValidated() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let context = binding(.ledgerSnapshot)
        let payload = try await crypto.sealBackground(Data("synthetic-ledger".utf8), binding: context)
        let otherReference = PayloadBinding(reference: ProtectedPayloadReference(), ownerID: context.ownerID, kind: context.kind)
        let otherOwner = PayloadBinding(reference: context.reference, ownerID: UUID(), kind: context.kind)
        let otherKind = PayloadBinding(reference: context.reference, ownerID: context.ownerID, kind: .sourceCheckpoint)
        var corrupted = payload.sealedPayload
        corrupted[corrupted.count - 1] ^= 1
        for candidate in [modified(payload, schemaVersion: 2), modified(payload, binding: otherReference),
                          modified(payload, binding: otherOwner), modified(payload, binding: otherKind),
                          modified(payload, keyID: UUID().uuidString),
                          modified(payload, algorithm: .inventoryECIESAESGCM),
                          modified(payload, wrappedDataKey: Data([1])), modified(payload, sealedPayload: corrupted)] {
            await #expect(throws: (any Error).self) {
                try await crypto.openBackground(candidate, binding: context)
            }
        }
        // Even if a caller accepts an attacker's replaced binding, GCM authenticates the original fields.
        for context in [otherReference, otherOwner, otherKind] {
            await #expect(throws: ProtectionError.authenticationFailed) {
                try await crypto.openBackground(modified(payload, binding: context), binding: context)
            }
        }
    }

    @Test func codecRejectsUnknownVersionOversizeAndMalformedHeaders() async throws {
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let payload = try await crypto.sealBackground(Data([1]), binding: binding(.queueEvent))
        #expect(throws: ProtectionError.invalidEnvelope) { try ProtectedPayload.decode(Data("{}".utf8)) }
        #expect(throws: ProtectionError.invalidEnvelope) { try ProtectedPayload.decode(payload.encoded(), maximumBytes: 1) }
        #expect(throws: ProtectionError.invalidEnvelope) { try ProtectedPayload.decode(modified(payload, schemaVersion: 2).encoded()) }
        #expect(throws: ProtectionError.invalidEnvelope) { try ProtectedPayload.decode(modified(payload, keyID: "").encoded()) }
    }

    @Test @MainActor func inventoryWrappingRoundTripsExactBytesAndFreshDataKeys() async throws {
        let (crypto, viewing, key, _) = try fixture()
        let exactBytes = Data("SYNTHETIC-value-Ä-🔐\n".utf8)
        for kind in [ProtectedPayloadKind.value, .excerpt, .sessionMetadata, .sourceMetadata] {
            let context = binding(kind)
            let one = try await crypto.sealInventory(exactBytes, binding: context)
            let two = try await crypto.sealInventory(exactBytes, binding: context)
            #expect(!key.isAuthorized)
            #expect(one.wrappedDataKey != two.wrappedDataKey)
            #expect(one.sealedPayload != two.sealedPayload)
            #expect(try await viewing.reveal(one, binding: context, localizedReason: "Synthetic test") == exactBytes)
            #expect(viewing.revealed[context.reference] == exactBytes)
            await viewing.deauthorize()
        }
    }

    @Test @MainActor func inventoryAADRejectsAcceptedChangedOwner() async throws {
        let (crypto, viewing, _, _) = try fixture()
        let context = binding(.value)
        let payload = try await crypto.sealInventory(Data("synthetic".utf8), binding: context)
        let replaced = PayloadBinding(reference: context.reference, ownerID: UUID(), kind: context.kind)
        await #expect(throws: ProtectionError.authenticationFailed) {
            try await viewing.reveal(modified(payload, binding: replaced), binding: replaced, localizedReason: "Synthetic test")
        }
        #expect(viewing.revealed.isEmpty)
        #expect(!viewing.isAuthorized)
        await viewing.deauthorize()
    }

    @Test @MainActor func swappingValidWrappedDataKeysAndCiphertextFails() async throws {
        let (crypto, viewing, _, _) = try fixture()
        let context = binding(.sourceMetadata)
        let first = try await crypto.sealInventory(Data("SYNTHETIC-first-title-path".utf8), binding: context)
        let second = try await crypto.sealInventory(Data("SYNTHETIC-second-title-path".utf8), binding: context)
        for replaced in [modified(first, wrappedDataKey: second.wrappedDataKey),
                         modified(first, sealedPayload: second.sealedPayload)] {
            await #expect(throws: ProtectionError.authenticationFailed) {
                try await viewing.reveal(replaced, binding: context, localizedReason: "Synthetic test")
            }
            #expect(viewing.revealed.isEmpty)
            #expect(!viewing.isAuthorized)
        }
        await viewing.deauthorize()
    }

    @Test @MainActor func cancellationNeverCachesPlaintext() async throws {
        let (crypto, viewing, key, _) = try fixture()
        let context = binding(.value)
        let payload = try await crypto.sealInventory(Data("synthetic".utf8), binding: context)
        key.authorizationError = .cancelled
        await #expect(throws: ViewingAuthorizationError.cancelled) {
            try await viewing.reveal(payload, binding: context, localizedReason: "Synthetic test")
        }
        #expect(viewing.revealed.isEmpty)
        #expect(!viewing.isAuthorized)
        await viewing.deauthorize()
        #expect(!key.isAuthorized)
    }

    @Test @MainActor func maskIsSynchronousForEveryLifecycleReason() async throws {
        let (crypto, viewing, key, _) = try fixture()
        let context = binding(.excerpt)
        let payload = try await crypto.sealInventory(Data("synthetic".utf8), binding: context)
        for reason in [ViewingInvalidationReason.userMask, .windowClose, .sleep, .sessionLock, .inactivity] {
            _ = try await viewing.reveal(payload, binding: context, localizedReason: "Synthetic test")
            let generation = viewing.snapshot.generation
            viewing.invalidate(reason: reason)
            #expect(viewing.revealed.isEmpty)
            #expect(viewing.snapshot.expiresAt == nil)
            #expect(!viewing.isAuthorized)
            #expect(viewing.snapshot.generation > generation)
            await viewing.deauthorize()
            #expect(!key.isAuthorized)
        }
    }

    @Test @MainActor func timeoutUsesMonotonicTimeAndAcceptedActivityExtendsIt() async throws {
        let (crypto, viewing, _, clock) = try fixture()
        let context = binding(.value)
        let payload = try await crypto.sealInventory(Data("synthetic".utf8), binding: context)
        _ = try await viewing.reveal(payload, binding: context, localizedReason: "Synthetic test")
        #expect(viewing.timeoutSeconds == 300)
        #expect(viewing.snapshot.acceptedActivityCount == 1)
        clock.advance(299)
        viewing.expireIfNeeded()
        #expect(viewing.isAuthorized)
        viewing.acceptActivity(.scroll)
        #expect(viewing.snapshot.acceptedActivityCount == 2)
        clock.advance(299)
        clock.date = Date(timeIntervalSince1970: 0) // Wall-clock changes cannot extend viewing authorization.
        viewing.expireIfNeeded()
        #expect(viewing.isAuthorized)
        clock.advance(1)
        viewing.expireIfNeeded()
        #expect(!viewing.isAuthorized)
        #expect(viewing.revealed.isEmpty)
        viewing.acceptActivity(.keyDown)
        #expect(viewing.snapshot.acceptedActivityCount == 2)
        await viewing.deauthorize()
    }

    @Test @MainActor func staleAuthorizationAfterWindowCloseCannotReveal() async throws {
        let (crypto, viewing, key, _) = try fixture()
        let context = binding(.value)
        let payload = try await crypto.sealInventory(Data("synthetic".utf8), binding: context)
        key.holdAuthorization = true
        let task = Task { try await viewing.reveal(payload, binding: context, localizedReason: "Synthetic test") }
        while key.authorizationGate == nil { await Task.yield() }
        viewing.invalidate(reason: .windowClose)
        key.authorizationGate?.resume()
        key.authorizationGate = nil
        await #expect(throws: ViewingAuthorizationError.invalidated) { try await task.value }
        #expect(viewing.revealed.isEmpty)
        #expect(!viewing.isAuthorized)
        #expect(!key.isAuthorized)
        await viewing.deauthorize()
        #expect(!key.isAuthorized)
    }

    @Test @MainActor func stalePrivateDecryptAfterSessionLockCannotReveal() async throws {
        let (crypto, viewing, key, _) = try fixture()
        let context = binding(.value)
        let payload = try await crypto.sealInventory(Data("synthetic".utf8), binding: context)
        key.holdDecryption = true
        let task = Task { try await viewing.reveal(payload, binding: context, localizedReason: "Synthetic test") }
        while key.decryptionGate == nil { await Task.yield() }
        viewing.invalidate(reason: .sessionLock)
        key.decryptionGate?.resume()
        key.decryptionGate = nil
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(viewing.revealed.isEmpty)
        #expect(!viewing.isAuthorized)
        await viewing.deauthorize()
    }

    @Test @MainActor func unexpectedFrameworkDeauthorizationClearsCachedPlaintext() async throws {
        let (crypto, viewing, key, _) = try fixture()
        let context = binding(.value)
        let payload = try await crypto.sealInventory(Data("synthetic".utf8), binding: context)
        _ = try await viewing.reveal(payload, binding: context, localizedReason: "Synthetic test")
        key.isAuthorized = false
        viewing.expireIfNeeded()
        #expect(viewing.revealed.isEmpty)
        #expect(viewing.snapshot.expiresAt == nil)
        await viewing.deauthorize()
    }

    @Test @MainActor func nextAuthorizationWaitsForStaleAuthorizationToBeRetired() async throws {
        let (crypto, viewing, key, _) = try fixture()
        let context = binding(.value)
        let payload = try await crypto.sealInventory(Data("synthetic".utf8), binding: context)
        key.holdAuthorization = true
        let first = Task { try await viewing.reveal(payload, binding: context, localizedReason: "Synthetic test") }
        while key.authorizationGate == nil { await Task.yield() }
        viewing.invalidate(reason: .sleep)
        key.holdAuthorization = false
        let second = Task { try await viewing.reveal(payload, binding: context, localizedReason: "Synthetic test") }
        for _ in 0..<10 { await Task.yield() }
        #expect(key.authorizations == 1)
        key.authorizationGate?.resume()
        key.authorizationGate = nil
        await #expect(throws: ViewingAuthorizationError.invalidated) { try await first.value }
        #expect(try await second.value == Data("synthetic".utf8))
        #expect(key.authorizations == 2)
        #expect(viewing.isAuthorized)
        await viewing.deauthorize()
    }

    @Test @MainActor func staleThrowingFrameworkCompletionsAreDeauthorizedBeforeNextReveal() async throws {
        for duringAuthorization in [true, false] {
            let (crypto, viewing, key, _) = try fixture()
            let context = binding(.value)
            let payload = try await crypto.sealInventory(Data("synthetic".utf8), binding: context)
            key.authorizeBeforeThrow = true
            if duringAuthorization {
                key.holdAuthorization = true
                key.authorizationError = .denied(code: -1)
            } else {
                key.holdDecryption = true
                key.decryptionError = .denied(code: -1)
            }
            let first = Task { try await viewing.reveal(payload, binding: context, localizedReason: "Synthetic test") }
            while duringAuthorization ? key.authorizationGate == nil : key.decryptionGate == nil { await Task.yield() }
            viewing.invalidate(reason: .sessionLock)
            while key.deauthorizations == 0 { await Task.yield() }
            key.authorizationError = nil
            key.decryptionError = nil
            key.holdAuthorization = false
            key.holdDecryption = false
            let second = Task { try await viewing.reveal(payload, binding: context, localizedReason: "Synthetic test") }
            for _ in 0..<10 { await Task.yield() }
            #expect(key.authorizations == 1)
            if duringAuthorization {
                key.authorizationGate?.resume()
                key.authorizationGate = nil
            } else {
                key.decryptionGate?.resume()
                key.decryptionGate = nil
            }
            await #expect(throws: ViewingAuthorizationError.invalidated) { try await first.value }
            #expect(try await second.value == Data("synthetic".utf8))
            #expect(key.deauthorizations >= 2)
            #expect(viewing.isAuthorized)
            await viewing.deauthorize()
            #expect(!key.isAuthorized)
        }
    }

    @Test @MainActor func missingManifestWithEvenHMACOnlyProtectedStateNeverProvisions() async throws {
        // Deliberately invalid access group: missing-manifest rejection must precede any Keychain/LA call.
        await #expect(throws: KeyUnavailable.missingManifest) {
            try await ProtectionBootstrap.prepare(manifest: nil, storeState: .protectedDataPresent,
                                                  configuration: ProtectionConfiguration(accessGroup: "invalid-fixture-group"))
        }
    }

    @Test @MainActor func malformedManifestAndMissingKeysDoNotGenerateReplacementKeys() async throws {
        let sharedID = UUID()
        let bad = ProtectionManifest(vaultID: UUID(), queueKeyID: sharedID, identityKeyID: sharedID,
                                     inventoryRightID: "invalid")
        #expect(throws: KeyUnavailable.invalidManifest) { try bad.validate() }
        await #expect(throws: KeyUnavailable.invalidManifest) {
            try await ProtectionBootstrap.prepare(manifest: bad, storeState: .empty,
                                                  configuration: ProtectionConfiguration(accessGroup: "invalid-fixture-group"))
        }
        let manifest = ProtectionManifest.fresh(identifierPrefix: "com.spillcheck.test.missing")
        // An unsigned test process cannot access this deliberately unprovisioned group.
        // Failure must be explicit, including when the store currently contains no blobs.
        await #expect(throws: (any Error).self) {
            try await ProtectionBootstrap.prepare(manifest: manifest, storeState: .empty,
                                                  configuration: ProtectionConfiguration(accessGroup: "invalid-fixture-group", identifierPrefix: "com.spillcheck.test.missing"))
        }
    }
}
