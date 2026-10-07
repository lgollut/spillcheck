# Build the MVP with Swift and native macOS frameworks

Status: proposed implementation stack. The macOS 14/Apple Silicon baseline and direct signed/notarized distribution are confirmed by the user. Integration, scanner, and vault choices must pass the prototype gates in the [implementation plan](../IMPLEMENTATION_PLAN.md).

Reviewed: October 7, 2026.

## Context

[The specification](../SPEC.md) requires a native Mac application with local analysis, background monitoring, encrypted retained values, authenticated revelation, and agent-specific collection. [ADR 0001](0001-local-analysis.md) fixes the local processing boundary. [ADR 0002](0002-retain-encrypted-values.md) fixes retention independently of source history.

The repository currently contains documentation only. There is no existing application stack to preserve.

## Recommended stack

| Concern | Choice | Reason |
| --- | --- | --- |
| Language | Swift 6 language mode, strict concurrency | One language for the UI, collectors, storage, and native system integration. |
| Platform | macOS 14 minimum, Apple Silicon first | Confirmed release baseline. Intel support needs a separate tested build before being advertised. |
| Application UI | SwiftUI, with AppKit lifecycle integration | Inventory, details, settings, menu bar, window handling, and source opening fit native frameworks. |
| Application lifecycle | One long-running app process | Closing its window preserves monitoring. Quitting terminates monitoring and owned workers. |
| Concurrency | Swift actors and structured concurrency | Separate ingestion, processing, persistence, and viewing state without scanning on the main actor. |
| Persistence | SQLite through GRDB, explicit migrations | Transactions and unique constraints support occurrence identity, checkpoints, and notification decisions. GRDB supports Swift Package Manager and is MIT licensed. [GRDB documentation](https://github.com/groue/GRDB.swift/blob/master/README.md). |
| Payload encryption | CryptoKit AES-GCM | Authenticated encryption for queued content and retained payloads. Encrypt before writing to SQLite. |
| Key protection and revelation | Keychain plus LocalAuthentication persisted rights | Separate keys available for monitoring from the key that permits inventory decryption. Prototype `LARightStore`/`LAPersistedRight` first; Security.framework access-controlled keys are the fallback. [Apple authorization APIs](https://developer.apple.com/videos/play/wwdc2022/10108/). |
| Value identity | CryptoKit HMAC-SHA256 with a dedicated Keychain key | Groups identical extracted values without putting plaintext or an unkeyed password hash into indexes. |
| Hook executable | Bundled compiled Swift command-line target | Reads agent JSON from stdin and makes a short local delivery attempt. Users do not need Python, Node, Homebrew, or a shell script dependency. |
| Hook transport | Unix-domain socket, length-framed versioned messages | Private local IPC with bounded payloads, a short deadline, and same-user peer checks. The app owns the receiver. |
| Initial scanner | Pinned bundled Betterleaks with reviewed local rules | Preferred prototype candidate with MIT licensing, current rule development, contextual credential rules, and stdin support. Add Swift rules only for demonstrated coverage gaps. Scanner output must be mapped back to exact source ranges. |
| Notifications | UserNotifications | Masked system alerts that navigate to an inventory detail. |
| Login preference | ServiceManagement `SMAppService.mainApp` | Registers the app itself for login only when the user enables the preference. [Apple login item API](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp). |
| Build and dependencies | Xcode app and helper targets, Swift Package Manager for core modules | Native signing and bundling, with independently testable Swift packages. Pin dependency and scanner versions. |
| Tests | Swift Testing for core behavior, XCTest for app integration and UI | Domain, scanner, persistence, and replay fixtures run without UI; authentication and lifecycle need macOS integration checks. |
| Distribution | Developer ID signed and notarized application, direct distribution | Confirmed distribution route. Use hardened runtime and validate entitlements during the prototype. |

Do not add a web frontend, application server, cloud database, LLM detector, or auto-update client to this MVP. The confirmed product does not require them.

## Storage and authentication design

Use distinct keys for distinct duties:

1. A background queue key encrypts incoming content and allows the processor to read pending events while the inventory is locked.
2. A dedicated identity key creates HMAC fingerprints for value grouping and content identities where needed.
3. An inventory public key lets the processor protect new values and excerpts without unlocking old entries. Its private key requires system authorization before decrypting inventory payloads.

First prototype `LAPersistedRight`. Apple allows its public-key operations while unauthorized and private-key operations only after authorization. Its `deauthorize()` operation fits the viewing-session lifecycle. Validate password fallback, restart behavior, signing, and hardware support on the proposed supported Macs. [Apple persisted-right lifecycle](https://developer.apple.com/videos/play/wwdc2022/10108/).

Retained payloads use fresh symmetric data keys, AES-GCM, and Apple public-key wrapping. Prototype a supported P-256 ECIES `VariableIV` algorithm and its authenticated private-key use. Check algorithm support on macOS 14. If persisted rights cannot meet the support matrix, test Security.framework keys with `userPresence` and `privateKeyUsage` in the macOS Data Protection Keychain. Select and version the exact wrapping format only after these tests; do not implement custom elliptic-curve cryptography. [Apple encryption API](https://developer.apple.com/documentation/security/seckeycreateencrypteddata(_:_:_:_:)), [Mac Keychain implementations](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

Bind record identity, payload type, and schema version as authenticated associated data. Persist key identifiers with ciphertext so migrations and eventual key rotation are possible. Queue keys must never decrypt retained inventory payloads.

The viewing session owns its authorization state, expires after the proposed five minutes of inactivity, and clears revealed data when locked. Window closure, sleep, session lock, and immediate masking end it. Deauthorize the persisted right or invalidate the fallback authentication context, release key references, and cancel pending reveals. The app must enforce its own deadline even if macOS would permit authentication reuse.

SQLite contains ciphertext for values, raw excerpts, raw titles, paths, and untrusted source metadata. Store only approved masked labels and structural fields in searchable columns. Treat titles as potentially secret-bearing too. No plaintext full-text index, SQL tracing, raw scanner reports, or content in diagnostic logs.

Use an application-owned private directory under Application Support, owner-only file/socket permissions, and a stable signing identity across updates. Missing keys produce a key-unavailable state. Do not replace them silently when ciphertext exists. Device-bound vault keys also mean a copied database alone cannot restore revelation on another Mac.

The user accepts no device-loss recovery or cross-Mac migration for the MVP. Local restarts and app upgrades must still preserve usable keys and inventory state.

Content deletion removes payloads, occurrences, payload-specific keys, cached plaintext, and associated retry/notification work from active app storage. For values acknowledged as rotated or revoked, keep a minimal keyed recognition marker until explicit forgetting or reset, as confirmed in [ADR 0004](0004-remember-obsolete-values.md). Keep independent source receipts to prevent historical resurrection. Deletion does not promise forensic erasure from SQLite pages, filesystem snapshots, or backups.

Field encryption satisfies the specified protection for values and excerpts while keeping the inventory index queryable. SQLCipher would additionally hide structural database metadata, but adds packaging and migration work. Add it if that broader protection becomes a requirement; it does not replace the separate revelation key.

This design protects retained data on disk and controls normal app revelation. Monitoring necessarily sees newly captured plaintext in memory. It does not promise protection against a compromised running Mac or an attacker executing as the user.

## Scanner choice and maintenance

Betterleaks is the recommended initial engine, subject to fixture results. It is MIT licensed and maintained by contributors who made Gitleaks, including the original author. Its current rule development makes it a stronger prototype candidate than Gitleaks, whose upstream limits releases to security fixes. Bundle a reviewed version and explicit app-controlled configuration. Leakret still owns adoption of rule updates and measured category coverage. [Betterleaks project](https://github.com/betterleaks/betterleaks), [license](https://github.com/betterleaks/betterleaks/blob/v1.9.0/LICENSE), [Gitleaks maintenance](https://github.com/gitleaks/gitleaks).

As of October 7, 2026, the latest stable release is v1.9.0; v2.0.0-rc.1 is a prerelease with breaking CLI, configuration, and report changes. Start the prototype on a pinned stable release. Evaluate v2 separately before upgrading the integration. Do not combine stable flags with documentation from the development branch. Both releases provide macOS arm64 and x64 archives. [Stable release](https://github.com/betterleaks/betterleaks/releases/tag/v1.9.0), [v2 release candidate](https://github.com/betterleaks/betterleaks/releases/tag/v2.0.0-rc.1).

Run `stdin` through `Process` and anonymous stdin/stdout pipes. For v1.9.0, explicitly set `--validation=false`, `--ignore-gitleaks-allow`, `--max-decode-depth=0`, and `--max-archive-depth=0`. The allow flag disables both Betterleaks and Gitleaks inline suppression signatures. Sanitize inherited `BETTERLEAKS_*` and `GITLEAKS_*` configuration variables, pass the app's reviewed configuration explicitly, and use a private working directory without auto-discovered configuration or ignore files. Never select a remote-source command. Verify the pinned build with networking blocked. Keep inputs and reports out of files, arguments, environment variables, and diagnostic logs. [Stable CLI implementation](https://github.com/betterleaks/betterleaks/blob/v1.9.0/cmd/root.go).

These flags are version-specific. V2 renames suppression control to `--no-allow-signatures` and changes credential-stage controls and environment overrides. Review that integration separately instead of forwarding v1 arguments into v2.

Betterleaks already has generic password and credential-URI rules with context-dependent confidence. Its language-oriented filtering is relevant to session text, but accuracy on our corpus remains unmeasured. Preserve low-confidence candidates for Leakret's needs-review workflow. Do not equate scanner confidence or validation status with proof that a secret is usable. Add native rules only when fixtures demonstrate a gap. [Contextual rules and confidence](https://github.com/betterleaks/betterleaks/releases/tag/v1.8.0).

Validate exact extracted values and all occurrence ranges against the original event before retaining them. Test repeated appearances, Unicode, multiline blocks, decoding, and scanner chunk boundaries. Keep the scanner behind a `SecretDetector` interface and version its report parser. Retain unlocated evidence without inventing a revealable value. [Stable finding representation](https://github.com/betterleaks/betterleaks/blob/v1.9.0/report/finding.go).

Use Gitleaks as a comparison baseline, not the preferred runtime. It has a simpler established integration but receives security fixes only. Both engines need measured source mapping and reviewed rules.

Compare TruffleHog during the prototype. Its maintained detector set is useful, but it has AGPL licensing, update and verification behavior to disable, and detector results that need additional source mapping. It is a benchmark candidate, not a required runtime dependency. Validate `--no-verification`, `--no-update`, and `--no-ignore-tag` with network access blocked. [TruffleHog repository](https://github.com/trufflesecurity/trufflehog), [CLI flags](https://github.com/trufflesecurity/trufflehog/blob/main/docs/man/trufflehog.1).

If fixtures justify a small Swift ruleset, it can also provide an explicit reduced-coverage fallback when the scanner fails. Otherwise show partial coverage and retry the scanner within the stated limits. Do not build a parallel detector preemptively or silently claim equivalent coverage.

## Consequences

- Native system integration stays in Swift. The only proposed shipping dependencies are GRDB and a bundled scanner with its rules.
- No persistent daemon is needed. Hook invocations cannot launch the app, retain outputs while it is stopped, or keep monitoring alive after quit.
- Direct distribution avoids committing to App Store sandbox constraints before collection has been proven. It still needs signing, notarization, careful path handling, and an explicit supported OS matrix.
- The public-key inventory vault adds complexity, but separates background ingestion from the ability to reveal retained data. An always-accessible vault key with a UI authentication prompt would provide a weaker boundary and must be documented as a changed design if selected.
- Agent adapters and scanner engines remain replaceable. The inventory and alert logic depend on normalized events and detection evidence, not upstream JSON structures.
