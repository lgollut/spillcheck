import Foundation
@_spi(Testing) import SpillcheckCore

// Compile the app's actual configuration/evidence implementation, with only the unrelated setup default stubbed.
struct AgentProfileDraft {
    static let defaultHosts: Set<AgentInterface> = [.standaloneCLI, .t3]
    static func supportedHosts(for provider: AgentProvider) -> Set<AgentInterface> {
        defaultHosts.union([.desktopCode])
    }
}
private enum Failure: Error { case failed(String) }
private func check(_ condition: Bool, _ stage: String) throws { if !condition { throw Failure.failed(stage) } }

@main struct ClaudeRoleEvidenceProbe {
    static let parent = "11111111-1111-4111-8111-111111111111"
    static let other = "22222222-2222-4222-8222-222222222222"
    static let sourceRoot = URL(fileURLWithPath: "/fake-spillcheck-claude-acceptance")
    static let parentPath = sourceRoot.appendingPathComponent(parent + ".jsonl").path
    static let childPath = sourceRoot.appendingPathComponent(parent + "/subagents/agent-native.jsonl").path
    static let now = Date(timeIntervalSince1970: 1_792_000_000)
    static let roles = ClaudeAcceptanceRoles(profileID: "owned-fixture", roots: [sourceRoot], interfaces: [.standaloneCLI, .t3])

    static func source(marker: String, path: String? = nil, session: String = parent,
                       kind: ContentType? = nil, profile: String = "owned-fixture",
                       revision: UInt8 = 1, time: Date = now, suffix: String = "",
                       text: String? = nil, producer: String = "2.1.296",
                       interface: AgentInterface = .standaloneCLI) throws -> CollectedSource {
        let session = try SessionIdentity(provider: .claudeCode, profileID: profile, sessionID: session)
        let origin = try SourceOrigin(adapterID: "claude-code", adapterVersion: "fixture", agentVersion: producer,
            interface: interface, provenance: .live, canonicalization: .sharedUpstreamIdentity)
        let metadata = try SourceRecordMetadata(identity: SourceIdentity(session: session, itemID: marker + suffix),
            contentType: kind ?? ClaudeAcceptanceRoleEvidence.expected[marker]!, contentTime: time, observedAt: now,
            origin: origin)
        let bytes = Data((text ?? "LEAKRET_M3_\(marker) \(ClaudeAcceptanceRoleEvidence.token)").utf8)
        return CollectedSource(record: try SourceRecord(metadata: metadata,
            revision: ContentRevision(keyedDigest: Data(repeating: revision, count: 32)),
            segments: [SourceSegment(id: "text", utf8: bytes)]),
            context: .init(sessionIdentifier: session.sessionID,
                transcriptPath: path ?? (marker.hasPrefix("CHILD_") ? childPath : parentPath)))
    }

    static func commit(_ record: SourceRecord, store: ProtectedStore, crypto: BackgroundCryptography) async throws {
        let bytes = Data(ClaudeAcceptanceRoleEvidence.token.utf8)
        let range = record.segments[0].utf8.range(of: bytes)!
        let location = try CanonicalLocation(components: [.init(segmentID: "text", range: .init(range.lowerBound, range.upperBound))])
        let extraction = try ExactExtraction(valueUTF8: bytes, location: location, in: record)
        let reference = ProtectedPayloadReference()
        let payload = try await crypto.sealInventory(bytes, binding: .init(reference: reference, ownerID: reference.id, kind: .value))
        let detection = try LocatedDetection(extraction: extraction, in: record,
            fingerprint: await crypto.fingerprint(exactBytes: bytes),
            evidence: [.init(rule: .init(id: "fixture", version: "1"), signal: .strong, reason: .recognizedFormat, category: .token)],
            protectedValue: reference)
        guard let permit = await store.processingPermit() else { throw Failure.failed("no-permit") }
        _ = try await store.commit(SourceAnalysis(source: record, detectorVersion: BetterleaksSecretDetector.version,
            detections: [detection]), payloads: [payload], permit: permit, at: now)
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spillcheck-claude-role-probe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let crypto = try BackgroundCryptography.ephemeralForTesting()
        let store = try await ProtectedStore.open(at: root, cryptography: crypto)
        let sources = try ClaudeAcceptanceRoleEvidence.expected.keys.sorted().map { try source(marker: $0) }
        let batch = CollectionBatch(sources: sources)
        let evidence = ClaudeAcceptanceRoleEvidence(roles: roles)
        await evidence.collect(batch)
        let empty = await evidence.summary(snapshot: store.snapshot(), syntheticValueID: nil)
        try check(!empty.complete && empty.markers.values.allSatisfy(\.isEmpty), "uncommitted-not-counted")
        for source in sources { try await commit(source.record, store: store, crypto: crypto) }
        let snapshot = await store.snapshot()
        let value = snapshot.records.values.first!.id
        try check(await evidence.summary(snapshot: snapshot, syntheticValueID: value).complete, "twelve-markers-shared-native-session")
        try check(await evidence.summary(snapshot: snapshot, syntheticValueID: value).completePairsByProducer == ["2.1.296": 1], "complete-pair-producer-isolation")
        try check(!(await evidence.summary(snapshot: snapshot, syntheticValueID: UUID())).complete, "wrong-value-not-counted")
        await evidence.collect(batch)
        try check(await evidence.summary(snapshot: snapshot, syntheticValueID: value).complete, "canonical-replay-stable")
        try check(!(await evidence.summary(snapshot: .init(records: snapshot.records, occurrences: snapshot.occurrences),
            syntheticValueID: value)).complete, "receipt-required")
        try check(!(await evidence.summary(snapshot: .init(records: snapshot.records, analysisReceipts: snapshot.analysisReceipts),
            syntheticValueID: value)).complete, "occurrence-required")
        try await store.close()
        let reopened = try await ProtectedStore.open(at: root, cryptography: crypto)
        try check(await evidence.summary(snapshot: reopened.snapshot(), syntheticValueID: value).complete, "durable-after-reopen")
        try await reopened.close()

        let childFirst = ClaudeAcceptanceRoleEvidence(roles: roles)
        await childFirst.collect(.init(sources: sources.filter { $0.record.metadata.identity.itemID.hasPrefix("CHILD_") }))
        try check(!(await childFirst.summary(snapshot: snapshot, syntheticValueID: value)).nativeLinkVerified, "parent-must-be-observed")
        await childFirst.collect(.init(sources: sources.filter { !$0.record.metadata.identity.itemID.hasPrefix("CHILD_") }))
        try check(await childFirst.summary(snapshot: snapshot, syntheticValueID: value).complete, "child-before-parent-is-supported")

        for mutation in ["stale-revision", "wrong-content-time", "parent-mirror", "wrong-profile", "outside-root", "wrong-type", "wrong-parent-native-session", "bare-marker"] {
            let altered = ClaudeAcceptanceRoleEvidence(roles: roles)
            await altered.collect(.init(sources: try ClaudeAcceptanceRoleEvidence.expected.keys.sorted().map { marker in
                try source(marker: marker, path: mutation == "parent-mirror" ? parentPath
                    : mutation == "outside-root" ? "/elsewhere/\(parent).jsonl" : nil,
                    session: mutation == "wrong-parent-native-session" ? other : parent,
                    kind: mutation == "wrong-type" ? .toolOutput : nil,
                    profile: mutation == "wrong-profile" ? "foreign" : "owned-fixture",
                    revision: mutation == "stale-revision" ? 2 : 1,
                    time: mutation == "wrong-content-time" ? now.addingTimeInterval(1) : now,
                    text: mutation == "bare-marker" ? "LEAKRET_M3_\(marker)" : nil)
            }))
            try check(!(await altered.summary(snapshot: snapshot, syntheticValueID: value)).complete, mutation)
        }
        let split = ClaudeAcceptanceRoleEvidence(roles: roles)
        await split.collect(.init(sources: try ClaudeAcceptanceRoleEvidence.expected.keys.sorted().map { marker in
            try source(marker: marker, path: marker == "CHILD_FINAL"
                ? sourceRoot.appendingPathComponent(parent + "/subagents/agent-other.jsonl").path : nil)
        }))
        try check(!(await split.summary(snapshot: snapshot, syntheticValueID: value)).complete, "cannot-union-sibling-child-types")
        let conflicting = ClaudeAcceptanceRoleEvidence(roles: roles)
        await conflicting.collect(batch)
        await conflicting.collect(.init(sources: [try source(marker: "CHILD_FINAL", path: parentPath)]))
        try check(!(await conflicting.summary(snapshot: snapshot, syntheticValueID: value)).nativeLinkVerified, "identity-role-path-conflict-invalidates")
        let changedSession = ClaudeAcceptanceRoleEvidence(roles: roles)
        await changedSession.collect(batch)
        await changedSession.collect(.init(sources: [try source(marker: "CHILD_FINAL", session: other)]))
        try check(!(await changedSession.summary(snapshot: snapshot, syntheticValueID: value)).nativeLinkVerified, "source-session-conflict-invalidates")
        let changedProducer = ClaudeAcceptanceRoleEvidence(roles: roles)
        await changedProducer.collect(batch)
        await changedProducer.collect(.init(sources: [try source(marker: "CHILD_FINAL", producer: "2.1.295")]))
        try check(!(await changedProducer.summary(snapshot: snapshot, syntheticValueID: value)).nativeLinkVerified, "source-producer-conflict-invalidates")
        let splitProducer = ClaudeAcceptanceRoleEvidence(roles: roles)
        await splitProducer.collect(.init(sources: try ClaudeAcceptanceRoleEvidence.expected.keys.sorted().map { marker in
            try source(marker: marker, producer: marker.hasPrefix("CHILD_") ? "2.1.295" : "2.1.296")
        }))
        try check((await splitProducer.summary(snapshot: snapshot, syntheticValueID: value)).completePairsByProducer.isEmpty, "cannot-pool-producers-in-one-pair")
        let overflow = ClaudeAcceptanceRoleEvidence(roles: roles)
        await overflow.collect(.init(sources: try (0...128).map { try source(marker: "CHILD_FINAL", suffix: String($0)) }))
        try check(!(await overflow.summary(snapshot: snapshot, syntheticValueID: value)).bounded, "marker-observation-bound")

        let args = ["--claude-profile", "owned-fixture", "--claude-version", "2.1.296",
            "--claude-source-root", sourceRoot.path, "--claude-interface", "standalone-cli",
            "--acceptance-claude-role-evidence", "--acceptance-no-profile-catchup", "--acceptance-cleanup-new-vault"]
        let configuration = try CollectionConfiguration.fromArguments(args)
        try check(try ClaudeAcceptanceRoles.fromArguments(args, configuration: configuration,
            explicitStore: true, reportRequested: true) != nil, "valid-fresh-vault-config")
        for (label, changedArgs, explicit, report) in [
            ("store-required", args, false, true), ("report-required", args, true, false),
            ("duplicate-flag", args + ["--acceptance-claude-role-evidence"], true, true),
            ("cleanup-required", args.filter { $0 != "--acceptance-cleanup-new-vault" }, true, true),
            ("no-profile-discovery", args.filter { $0 != "--acceptance-no-profile-catchup" }, true, true),
            ("no-recovery-vault", args + ["--acceptance-recovery-worker"], true, true)] {
            do {
                _ = try ClaudeAcceptanceRoles.fromArguments(changedArgs, configuration: configuration,
                    explicitStore: explicit, reportRequested: report)
                throw Failure.failed(label)
            } catch is ClaudeCollectionError {}
        }
        try check(try ClaudeAcceptanceRoles.fromArguments([], configuration: nil,
            explicitStore: false, reportRequested: false) == nil, "ordinary-app-has-no-marker-inspection")
        let desktopArgs = ["--claude-profile", "owned-fixture", "--claude-version", "2.1.296",
            "--claude-source-root", sourceRoot.path, "--claude-interface", "desktop-code",
            "--claude-active-source", parentPath, "--claude-session", parent,
            "--claude-authorized-host", "desktop-code", "--claude-authorized-host", "standalone-cli",
            "--acceptance-claude-role-evidence", "--acceptance-no-profile-catchup", "--acceptance-cleanup-new-vault"]
        let desktopConfiguration = try CollectionConfiguration.fromArguments(desktopArgs)
        let desktopRoles = try ClaudeAcceptanceRoles.fromArguments(desktopArgs, configuration: desktopConfiguration,
            explicitStore: true, reportRequested: true)
        try check(desktopRoles?.interfaces == [.standaloneCLI, .desktopCode]
            && desktopConfiguration?.historicalInterface == .standaloneCLI, "explicit-owned-desktop-role-admission")
        let desktopEvidence = ClaudeAcceptanceRoleEvidence(roles: desktopRoles!)
        let desktopSources = try ClaudeAcceptanceRoleEvidence.expected.keys.sorted().map {
            try source(marker: $0, interface: .desktopCode)
        }
        await desktopEvidence.collect(.init(sources: desktopSources))
        // Canonical receipt identity is shared across transports, but an observation cannot
        // borrow an occurrence committed with a different interface for role evidence.
        try check(!(await desktopEvidence.summary(snapshot: snapshot, syntheticValueID: value)).complete,
            "desktop-observation-cannot-borrow-cli-occurrence")
        let desktopRoot = root.appendingPathComponent("desktop-store", isDirectory: true)
        let desktopCrypto = try BackgroundCryptography.ephemeralForTesting()
        let desktopStore = try await ProtectedStore.open(at: desktopRoot, cryptography: desktopCrypto)
        for source in desktopSources { try await commit(source.record, store: desktopStore, crypto: desktopCrypto) }
        let desktopSnapshot = await desktopStore.snapshot()
        let desktopValue = desktopSnapshot.records.values.first!.id
        let desktopSummary = await desktopEvidence.summary(snapshot: desktopSnapshot, syntheticValueID: desktopValue)
        try check(desktopSummary.complete && desktopSummary.completePairsByProducer == ["2.1.296": 1],
            "owned-desktop-native-pair-role-evidence")
        try await desktopStore.close()
        let desktopReopened = try await ProtectedStore.open(at: desktopRoot, cryptography: desktopCrypto)
        try check(await desktopEvidence.summary(snapshot: desktopReopened.snapshot(), syntheticValueID: desktopValue).complete,
            "owned-desktop-role-evidence-durable-after-reopen")
        try await desktopReopened.close()
        do {
            _ = try ClaudeAcceptanceRoles.fromArguments(desktopArgs.filter { $0 != "--acceptance-cleanup-new-vault" },
                configuration: desktopConfiguration, explicitStore: true, reportRequested: true)
            throw Failure.failed("desktop-role-still-requires-owned-cleanup")
        } catch is ClaudeCollectionError {}
        let recoveryRoot = URL(fileURLWithPath: "/private/tmp/spillcheck-claude-role-admission-" + UUID().uuidString, isDirectory: true)
        let home = recoveryRoot.appendingPathComponent("claude", isDirectory: true)
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: recoveryRoot) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let token = recoveryRoot.appendingPathComponent("run-token")
        try Data(repeating: 7, count: 32).write(to: token)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        let executable = recoveryRoot.appendingPathComponent("selected-claude")
        try Data("fake provider, never executed".utf8).write(to: executable)
        let recoveryArgs = ["--acceptance-recovery-claude-role-evidence", "--acceptance-recovery-worker",
            "--acceptance-recovery-root", recoveryRoot.path, "--acceptance-recovery-token", token.path,
            "--store-directory", recoveryRoot.appendingPathComponent("protected-store").path,
            "--acceptance-report", recoveryRoot.appendingPathComponent("report.json").path,
            "--acceptance-finish-file", recoveryRoot.appendingPathComponent("finish").path,
            "--acceptance-recovery-home", home.path, "--acceptance-recovery-executable", executable.path,
            "--acceptance-recovery-version", "2.1.296"]
        let recovery = try DisposableRecoveryConfiguration(arguments: recoveryArgs)
        let recoveryRoles = try ClaudeAcceptanceRoles.fromRecoveryArguments(recoveryArgs, recovery: recovery,
            explicitStore: true, reportRequested: true)
        try check(recoveryRoles != nil, "owned-recovery-admission")
        let saved = CollectionConfiguration(profileID: "owned-signed-claude-recovery", agentVersion: "2.1.296",
            roots: [projects], activeSources: [])
        try recoveryRoles?.requireMatchingRecoveryProfile(saved)
        // Recovery admission keeps the exact owned profile paths. On macOS, Foundation
        // canonicalizes /private/tmp source URLs to /tmp; evidence must compare like paths.
        try check(recoveryRoles?.roots.map(\.path) == [projects.path], "recovery-admission-retains-owned-profile-root")
        let recoveryParentPath = projects.appendingPathComponent(parent + ".jsonl").path
        let recoveryChildPath = projects.appendingPathComponent(parent + "/subagents/agent-native.jsonl").path
        let recoveryParentURL = URL(fileURLWithPath: recoveryParentPath)
        let recoveryChildURL = URL(fileURLWithPath: recoveryChildPath)
        try FileManager.default.createDirectory(at: recoveryChildURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // These owned files establish real filesystem paths. This probe supplies the
        // constructed normalized records directly; it does not parse these placeholder rows.
        for url in [recoveryParentURL, recoveryChildURL] {
            try Data("{}\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let canonicalRecoveryRoot = projects.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalRecoveryParent = recoveryParentURL.standardizedFileURL.resolvingSymlinksInPath().path
        try check(projects.path != canonicalRecoveryRoot
            && canonicalRecoveryParent.hasPrefix(canonicalRecoveryRoot + "/")
            && !canonicalRecoveryParent.hasPrefix(projects.path + "/"),
            "recovery-fixture-measures-swift-foundation-path-alias")
        let recoverySources = try ClaudeAcceptanceRoleEvidence.expected.keys.sorted().map { marker in
            try source(marker: marker, path: marker.hasPrefix("CHILD_") ? recoveryChildPath : recoveryParentPath,
                profile: saved.profileID)
        }
        let recoveryEvidence = ClaudeAcceptanceRoleEvidence(roles: recoveryRoles!)
        await recoveryEvidence.collect(.init(sources: recoverySources))
        let recoveryStoreRoot = root.appendingPathComponent("recovery-store", isDirectory: true)
        let recoveryCrypto = try BackgroundCryptography.ephemeralForTesting()
        let recoveryStore = try await ProtectedStore.open(at: recoveryStoreRoot, cryptography: recoveryCrypto)
        for source in recoverySources { try await commit(source.record, store: recoveryStore, crypto: recoveryCrypto) }
        let recoverySnapshot = await recoveryStore.snapshot()
        let recoveryValue = recoverySnapshot.records.values.first!.id
        let recoverySummary = await recoveryEvidence.summary(snapshot: recoverySnapshot, syntheticValueID: recoveryValue)
        try check(recoverySummary.complete && recoverySummary.completePairsByProducer == ["2.1.296": 1],
            "owned-recovery-canonical-root-committed-pair")
        for mutation in ["outside-recovery-root", "wrong-recovery-profile", "wrong-recovery-parent"] {
            let invalidEvidence = ClaudeAcceptanceRoleEvidence(roles: recoveryRoles!)
            await invalidEvidence.collect(.init(sources: try ClaudeAcceptanceRoleEvidence.expected.keys.sorted().map { marker in
                try source(marker: marker,
                    path: mutation == "outside-recovery-root"
                        ? home.appendingPathComponent("other/" + (marker.hasPrefix("CHILD_")
                            ? parent + "/subagents/agent-native.jsonl" : parent + ".jsonl")).path
                        : marker.hasPrefix("CHILD_") ? recoveryChildPath : recoveryParentPath,
                    session: mutation == "wrong-recovery-parent" ? other : parent,
                    profile: mutation == "wrong-recovery-profile" ? "foreign" : saved.profileID)
            }))
            try check(!(await invalidEvidence.summary(snapshot: recoverySnapshot,
                syntheticValueID: recoveryValue)).nativeLinkVerified, mutation)
        }
        try await recoveryStore.close()
        let recoveryReopened = try await ProtectedStore.open(at: recoveryStoreRoot, cryptography: recoveryCrypto)
        try check(await recoveryEvidence.summary(snapshot: recoveryReopened.snapshot(), syntheticValueID: recoveryValue).complete,
            "owned-recovery-canonical-root-durable-after-reopen")
        try await recoveryReopened.close()
        let invalidRecoveryArguments: [(String, [String], DisposableRecoveryConfiguration?, Bool, Bool)] = [
            ("recovery-token-required", recoveryArgs, nil, true, true),
            ("recovery-store-required", recoveryArgs, recovery, false, true),
            ("recovery-report-required", recoveryArgs, recovery, true, false),
            ("recovery-duplicate-flag", recoveryArgs + ["--acceptance-recovery-claude-role-evidence"], recovery, true, true),
            ("recovery-worker-required", recoveryArgs.filter { $0 != "--acceptance-recovery-worker" }, recovery, true, true),
            ("recovery-no-key-cleanup", recoveryArgs + ["--acceptance-cleanup-new-vault"], recovery, true, true),
            ("recovery-no-source-override", recoveryArgs + ["--claude-profile", "unowned"], recovery, true, true),
            ("recovery-no-codex-override", recoveryArgs + ["--codex-profile", "unowned"], recovery, true, true),
            ("recovery-no-fresh-role-mode", recoveryArgs + ["--acceptance-claude-role-evidence"], recovery, true, true)]
        for (label, changedArgs, selectedRecovery, explicit, report) in invalidRecoveryArguments {
            do {
                _ = try ClaudeAcceptanceRoles.fromRecoveryArguments(changedArgs, recovery: selectedRecovery,
                    explicitStore: explicit, reportRequested: report)
                throw Failure.failed(label)
            } catch is ClaudeCollectionError {}
        }
        for bad in [CollectionConfiguration(profileID: "unowned", agentVersion: "2.1.296", roots: [projects], activeSources: []),
                    CollectionConfiguration(profileID: saved.profileID, agentVersion: "2.1.296", roots: [sourceRoot], activeSources: []),
                    CollectionConfiguration(profileID: saved.profileID, agentVersion: "2.1.296", roots: [projects], activeSources: [], authorizedHosts: [.desktopCode])] {
            do { try recoveryRoles?.requireMatchingRecoveryProfile(bad); throw Failure.failed("recovery-saved-scope-match") }
            catch is ClaudeCollectionError {}
        }
        try FileManager.default.removeItem(at: projects)
        try FileManager.default.createSymbolicLink(at: projects, withDestinationURL: recoveryRoot)
        do {
            _ = try ClaudeAcceptanceRoles.fromRecoveryArguments(recoveryArgs, recovery: recovery, explicitStore: true, reportRequested: true)
            throw Failure.failed("recovery-project-symlink-rejected")
        } catch is ClaudeCollectionError {}
        print("{\"passed\":true,\"providerLaunched\":false,\"appLaunched\":false}")
    }
}
