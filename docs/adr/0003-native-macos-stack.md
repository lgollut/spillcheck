# Use Swift and native macOS frameworks

Status: adopted in the current implementation. macOS 14 on Apple Silicon and
direct signed/notarized distribution are the release baseline. Passing build or
core tests does not establish release readiness; see [current gates](../BETA_READINESS.md).

## Decision

The [specification](../SPEC.md) requires local background analysis, encrypted
retention and authenticated viewing. Keep these operations in a native app with
one long-running process. Closing a window preserves monitoring; quitting stops
the app's workers. Hook invocations do not launch the app or retain outputs while
it is stopped. Login launch is an explicit user preference.

| Concern | Choice |
| --- | --- |
| UI and lifecycle | SwiftUI with AppKit integration; Swift 6 strict concurrency. |
| Persistence | SQLite through GRDB, explicit migrations and transactional source progress. |
| Payload protection | CryptoKit AES-GCM, Keychain background keys and LocalAuthentication persisted rights for inventory decryption. |
| Value identity | HMAC-SHA256 with a dedicated key, separate from encryption keys. |
| Capture | Bundled compiled Swift helper and bounded, versioned Unix-socket delivery. |
| Detection | Pinned bundled Betterleaks with reviewed rules and native Swift rules for demonstrated gaps. |
| macOS integration | UserNotifications and `SMAppService.mainApp`. |
| Build | Xcode app/helper targets, Swift Package Manager for Core and test executables. |
| Distribution | Developer ID signing, hardened runtime and notarization. |

Do not add a web frontend, application server, cloud database, LLM detector or
auto-update client to this version. The [architecture guide](../ARCHITECTURE.md)
maps these responsibilities to code. [Test guidance](../../Tests/README.md)
separates Core, app-controller, signed-app and genuine-provider checks.

## Storage and authentication

Use distinct keys for background queue encryption, keyed value identity and
inventory revelation. An inventory public key lets the processor protect new
values and excerpts without unlocking old entries. Its private key requires
system authorization through `LAPersistedRight`. Retained payloads use fresh
AES-GCM data keys wrapped with Apple's supported P-256 ECIES VariableIV algorithm.
Do not implement custom elliptic-curve cryptography.

Bind record identity, payload kind and schema version into authenticated data,
and persist key identifiers with ciphertext. Background keys must not decrypt
retained inventory payloads. The viewing session owns its authorization deadline
and clears revealed data on masking, window closure, sleep, session lock or five
minutes of inactivity, even if macOS would permit authentication reuse.

Encrypt raw values, excerpts, titles, paths and untrusted source metadata before
writing them to SQLite. Searchable fields and diagnostics contain only approved
masked labels and structural data. Use owner-only storage and socket permissions,
and preserve the installed signing and Keychain identity across app updates.
Missing keys with protected data present must never cause silent replacement.

The user accepts no device-loss recovery or cross-Mac migration for this version.
Local restarts and app upgrades must preserve usable keys and inventory state.
Deletion removes protected content from active storage, with obsolete recognition
and independent source receipts preserved as specified in
[ADR 0004](0004-remember-obsolete-values.md). It does not promise forensic erasure
from SQLite pages, filesystem snapshots or backups.

Field encryption keeps the inventory index queryable. SQLCipher would also hide
structural database metadata, but is not part of this design. The app necessarily
sees newly captured plaintext in memory and does not promise protection against
a compromised running Mac or an attacker executing as the user.

## Scanner choice and maintenance

The current Betterleaks version and artifact hashes are recorded in
[`Dependencies/Scanner/dependencies.json`](../../Dependencies/Scanner/dependencies.json).
Review scanner and rule upgrades together with their CLI flags and report parser;
do not apply documentation for another release to the pinned binary.

Run the scanner through anonymous pipes with explicit app-controlled rules, a
private working directory and a controlled environment. Disable service
verification, inline suppression signatures, archive expansion and decoding.
Enforce network isolation and bounded process/output lifetimes. Keep source text
and reports out of files, arguments, environment variables and diagnostic logs.

Validate exact extracted values and every occurrence range against the original
source, including repeated text, Unicode and multiline blocks. Keep ambiguous
results available for review; scanner confidence is not credential validity.
Unlocated evidence cannot invent a revealable value. `SecretDetector` separates
scanner implementation from inventory and alert behavior.

Native rules may cover demonstrated gaps. Scanner failure must remain visible
as incomplete coverage and eligible retry work; native rules must not silently
claim equivalent coverage. No second external scanner is required by this decision.
