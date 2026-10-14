# Architecture

Spillcheck is a native macOS app with one long-running app process, a short-lived
capture helper, and a bundled local scanner. Collection, detection and storage
run on the Mac. The [specification](SPEC.md) defines product behavior;
[Codex](CODEX_BETA.md) and [Claude](CLAUDE_BETA.md) define the advertised collection
scope. Implemented parsing alone does not establish live-provider coverage.

## Code ownership

| Path | Responsibility |
| --- | --- |
| `Spillcheck/App/` | SwiftUI/AppKit UI, lifecycle, setup, notifications, login preference and composition of Core services. |
| `Spillcheck/App/AppRuntime.swift` | Opens the vault, selects configured collection routes, starts workers and coordinates pause, resume and shutdown. |
| `Sources/SpillcheckCore/` | Collection contracts and adapters, detection, protected storage, inventory rules and authenticated viewing. |
| `Sources/SpillcheckHook/` | Reads a provider hook from stdin and attempts bounded local delivery. It does not import Core or launch the app. |
| `Dependencies/Scanner/` | Pinned Betterleaks binary, configuration and license metadata. `scripts/bundle-scanner.py` verifies and bundles the prepared artifacts. |
| `Sources/SpillcheckAcceptance/` and `Sources/SpillcheckResourceAcceptance/` | Test executables for storage, provider and resource checks. They are not bundled in the app. |
| `Tests/` | Core regressions, app controller checks and explicit provider/signed-app acceptance runners. |

`Package.swift` defines the independently testable Core library and executables.
`project.yml` defines the Xcode app and bundled helper; regenerate the Xcode
project with XcodeGen after changing its inputs. Swift 6 strict concurrency and
macOS 14 are the baseline. The shipping build targets Apple Silicon.

## Collection to inventory

1. `AgentSetupController` saves explicit provider profiles and authorized hosts.
   Hook installation, provider trust, a verified delivery challenge and recent
   collection activity remain separate facts.
2. The helper sends a versioned, length-framed packet to the app's private Unix
   socket. `CaptureTransport.swift` checks local delivery and bounds its work.
   The app acknowledges a capture only after its encrypted queue commit.
3. Active monitors and bounded historical readers also enqueue work.
   `CollectionRouter.swift` selects a normalizer by provider, profile and host.
   Claude uses its versioned transcript reader; Codex uses its app-server history
   client and the selected source authority for each native session.
4. Adapters produce canonical source identities and text segments with exact
   UTF-8 mappings. `CodexEnrolledSessionRouter.swift` preserves the chosen native
   or hook authority. Matching text, timestamps or project paths cannot establish
   that two routes represent the same source.
5. `DetectionPipeline.swift` passes supported content to `SecretDetector.swift`.
   The pinned Betterleaks process uses anonymous pipes, a controlled environment
   and configuration, disabled service verification and a network-denied sandbox.
   `NativeSecretRules.swift` supplies additional local rules.
6. `ScannerMapping.swift` binds findings to exact original ranges. Unlocated
   evidence remains unlocated; it cannot create an invented revealable value.
7. `ProtectedStore.swift` commits findings, source receipts, checkpoints and
   notification decisions together. Multi-source captures complete only after
   their source work commits. Failed work cannot advance analyzed coverage.
8. `Inventory.swift` groups exact values independently of occurrence identity.
   `AppModel` and presentation modules expose masked summaries; viewing protected
   values and context requires a separate authenticated workflow.

History catch-up is limited to seven days of eligible content, with bounded
discovery and persisted continuations. It does not expire retained inventory.
See [session reader guidance](SESSION_READER_REUSE.md) for framing, replay and
checkpoint rules. Missing content, capacity limits and scanner failures remain
visible through coverage reporting.

## Storage and viewing

`ProtectedStore` is an actor backed by SQLite through GRDB. `Protection.swift`
separates background AES-GCM encryption, a dedicated HMAC identity key and an
inventory public key. Background processing can encrypt new retained payloads
without authorizing access to existing ones. Each retained payload has a fresh
data key wrapped for the inventory key; private-key use requires authorization
through `LAPersistedRight`.

`ProtectionBootstrapJournal.swift` coordinates key creation and store startup.
Missing keys with existing protected state are an error, not permission to
create a replacement vault. Raw values, excerpts, titles and paths stay encrypted
at rest; diagnostics and searchable summaries use controlled metadata.

`InventoryViewingWorkflow.swift` and the app's `ViewingController.swift` manage
reveals. One authentication unlocks a viewing session, and revealing needs no
further prompt while it lasts. While unlocked, the selected appearance's excerpt
and source are decrypted together with the value, which stays hidden in place
until revealed; `RetainedExcerpt.pieces(around:)` finds it, and an excerpt
without the whole value stays hidden. A revealed value stays revealed across its
appearances. Hiding the value keeps its context, and selecting another entry
clears what was shown without ending the session. The session expires after five
minutes of inactivity and ends on locking, window closure, sleep or macOS
session lock. Closing a window keeps
monitoring active; pause suspends collection, processing and alerts; quit stops
owned workers. Monitoring necessarily handles newly captured plaintext in memory.

Deletion and obsolete-value recognition are separate operations. Removing
retained content preserves independent source receipts against historical
resurrection. An acknowledged obsolete value may keep only its keyed recognition
marker until explicit forgetting. See [ADR 0004](adr/0004-remember-obsolete-values.md).

## Installed-data compatibility

The product name is Spillcheck, but `com.leakret.app` remains the provisioned
bundle identity and production key-service prefix. Preserve its Keychain access
group and macOS registrations when changing display names or signing settings.

`AppStorageLocation.swift` moves the whole owned `Application Support/Leakret`
directory to `Application Support/Spillcheck` before opening it, including SQLite
sidecars. It rejects symlinks, unowned directories and two simultaneous stores.
The DEBUG `--store-directory` override bypasses this production migration.

`leakret.sqlite`, version-1 ciphertext authentication and HMAC domains, persisted
native rule IDs, historical queue discriminators and notification IDs are storage
contracts. Do not rename them as cosmetic cleanup. Claude and Codex hook repair
recognize either product name only with the saved registration UUID; unrelated
handlers remain untouched. Current migration regressions stay required even
though [ADR 0007](adr/0007-codex-beta-scope.md) excludes unpublished-development
migration acceptance from the first beta gate.

## Testing responsibilities

Core Swift tests exercise parsing, identity, detection, transactions and replay.
App controller tests exercise setup and viewing with injected dependencies.
Python tests check runner orchestration, evidence validation, cleanup and build
tools. They do not substitute for tests of application behavior.

Signed-app acceptance uses DEBUG instrumentation with disposable stores to check
the actual bundle, helper, scanner, protected persistence and restart behavior.
Genuine-provider checks establish specific collection claims; synthetic fixtures
cannot grant those claims. See [test commands](../Tests/README.md),
[current readiness](BETA_READINESS.md) and [release procedure](RELEASING.md).
