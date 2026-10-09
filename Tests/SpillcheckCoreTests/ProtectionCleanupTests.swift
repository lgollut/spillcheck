import Foundation
import LocalAuthentication
import Security
import Testing
@_spi(Testing) @testable import SpillcheckCore

@MainActor
private final class CleanupGuardPrivateKey: InventoryPrivateKeyAccess {
    var isAuthorized = true
    var deauthorizations = 0
    func authorize(localizedReason: String) async throws {}
    func decrypt(_ wrappedKey: Data) async throws -> Data { throw ViewingAuthorizationError.invalidated }
    func deauthorize() async { isAuthorized = false; deauthorizations += 1 }
}

@Suite("Disposable protection cleanup ownership")
struct ProtectionCleanupTests {
    @Test func absenceSignatureRequiresTheSameDomainCodeAndUnderlyingCause() {
        let missing = NSError(domain: NSOSStatusErrorDomain, code: Int(errSecItemNotFound))
        let reference = NSError(domain: LAErrorDomain, code: -1019,
            userInfo: [NSUnderlyingErrorKey: missing, NSLocalizedDescriptionKey: "private diagnostic excluded"])
        let signature = protectionCleanupErrorSignature(reference)
        #expect(signature?.count == 2)
        #expect(signature?.first?.domain == LAErrorDomain && signature?.first?.code == -1019)
        #expect(signature?.last?.domain == NSOSStatusErrorDomain && signature?.last?.code == Int(errSecItemNotFound))
        let sameStatusDifferentMessage = NSError(domain: LAErrorDomain, code: -1019,
            userInfo: [NSUnderlyingErrorKey: missing, NSLocalizedDescriptionKey: "another excluded message"])
        #expect(protectionCleanupSignaturesMatch(signature, protectionCleanupErrorSignature(sameStatusDifferentMessage)))
        for different in [
            NSError(domain: NSCocoaErrorDomain, code: -1019, userInfo: [NSUnderlyingErrorKey: missing]),
            NSError(domain: LAErrorDomain, code: LAError.Code.notInteractive.rawValue, userInfo: [NSUnderlyingErrorKey: missing]),
            NSError(domain: LAErrorDomain, code: -1019,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed))])
        ] {
            #expect(!protectionCleanupSignaturesMatch(signature, protectionCleanupErrorSignature(different)))
        }
        #expect(!protectionCleanupSignaturesMatch(signature, nil))
        #expect(!protectionCleanupSignaturesMatch(nil, nil))
    }

    @Test @MainActor func loadedOrMismatchedProtectionCannotAuthorizeKeychainCleanup() async throws {
        let manifest = ProtectionManifest.fresh(identifierPrefix: "com.spillcheck.test.cleanup-guard")
        let background = try BackgroundCryptography.ephemeralForTesting(manifest: manifest)
        let key = CleanupGuardPrivateKey()
        let viewing = InventoryViewingSession(manifest: manifest, privateKey: key)
        // A deliberately unprovisioned group makes accidental framework access fail.
        // The guard must return before touching either Keychain or the viewing session.
        let configuration = ProtectionConfiguration(accessGroup: "invalid-cleanup-fixture-group",
            identifierPrefix: "com.spillcheck.test.cleanup-guard")
        let loaded = ProtectionServices(manifest: manifest, background: background,
            viewingSession: viewing, createdNewManifest: false, configuration: configuration)
        #expect(try await loaded.removeNewlyCreatedProtectionForTesting() == false)
        #expect(key.deauthorizations == 0 && key.isAuthorized)

        let wrongPrefix = ProtectionServices(manifest: manifest, background: background,
            viewingSession: viewing, createdNewManifest: true,
            configuration: ProtectionConfiguration(accessGroup: configuration.accessGroup,
                identifierPrefix: "com.spillcheck.test.another-owner"))
        await #expect(throws: KeyUnavailable.invalidManifest) {
            try await wrongPrefix.removeNewlyCreatedProtectionForTesting()
        }
        #expect(key.deauthorizations == 0 && key.isAuthorized)

        let wrongManifest = ProtectionServices(manifest: manifest,
            background: try BackgroundCryptography.ephemeralForTesting(),
            viewingSession: viewing, createdNewManifest: true, configuration: configuration)
        await #expect(throws: KeyUnavailable.invalidManifest) {
            try await wrongManifest.removeNewlyCreatedProtectionForTesting()
        }
        #expect(key.deauthorizations == 0 && key.isAuthorized)
    }
}
