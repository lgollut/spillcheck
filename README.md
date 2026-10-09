# Spillcheck

Spillcheck inventories secrets observed in Codex and Claude Code sessions on the
Mac. The product specification is in [docs/SPEC.md](docs/SPEC.md).

The app, Xcode project, Swift modules, helpers, and repository directory use
Spillcheck. Existing installations retain their provisioned `com.leakret.app`
bundle and Keychain identity so the renamed app can reopen the same encrypted
vault. On first launch, the app moves `Application Support/Leakret` to
`Application Support/Spillcheck`. It preserves the database filename, encryption
domains, stored rule and queue identifiers, and notification identifiers.
Two existing store directories require reconciliation before the app opens either.
Owned hooks from the previous name can be repaired or removed using their exact
registration UUID. Repair updates the helper path and requires verification again.

Published acceptance reports preserve measured results and historical product
names, with personal metadata sanitized as described in the
[evidence notes](docs/implementation/README.md). Legacy synthetic markers remain
supported for replaying fixtures. See [rename details](docs/RENAME.md).

The local development MVP is implemented. Milestones 1–5 passed. Milestone 6
records passing local acceptance, measurements, signed restart/cooperative
offline checks and release tooling; its full release gate remains open.
Distribution, macOS 14 execution, and hardware without Touch ID remain deferred
checks. [Acceptance evidence](docs/implementation/milestone-6.md)
distinguishes tested behavior from remaining checks.

The app includes encrypted ingestion and inventory, a bundled local scanner,
Codex and Claude collection, bounded catch-up, authenticated viewing, review,
obsolete-value recognition, masked alerts, and owned hook setup/removal.

See [Contributing](CONTRIBUTING.md) for PR checks and required changesets, and the
[release guide](docs/RELEASING.md) for versioning and changelog publication.

## Use the development app

After building, open the signed development app from the repository root:

```sh
open .build/app/Build/Products/Debug/Spillcheck.app
```

Open Settings to detect agents and explicitly select profiles. Finding an
executable does not establish a verified connection. Setup installs owned hooks
and requires a synthetic verification event. Launch at login is off by default.
Enable notifications in macOS to receive masked alerts.

The tested standalone versions are Codex 0.161.0 and Claude Code 2.1.293. Claude
2.1.294 was unvalidated and shown as unsupported in the recorded discovery check.
Select a supported executable and profile explicitly. The
[matrix](docs/implementation/supported-matrix.md) records the exact tested T3
tuples and limitations. Notarized distribution and upgrade acceptance are
deferred.

## Build the application

Use macOS on Apple Silicon, Xcode 27, XcodeGen, and Python 3.9 or later. App
signing requires a matching development identity, provisioning profile, and
Keychain entitlements. Configure signing in Xcode before building. From the
repository root:

```sh
make scanner-dependencies
make test
make app
```

The build script also accepts explicit signing overrides:

```sh
scripts/build-app.sh --signing-identity "<SIGNING_IDENTITY>" --team-id "<TEAM_ID>"
```

Replace the placeholders with your configured identity and team. Existing vault
installations require their original application and Keychain access identity.
Signing configuration, entitlements, and release policy must agree.

`scanner-dependencies` downloads the pinned Betterleaks executable, configuration,
and license and verifies their checksums against
[Dependencies/Scanner/dependencies.json](Dependencies/Scanner/dependencies.json).
Downloads live in `.build/dependencies/scanner/betterleaks`; scanner preparation
copies verified resources into `.build/scanner` for tests and app bundling.
Subsequent builds use the cached dependencies.

The app target is `Spillcheck.xcodeproj`. `make app` builds
`.build/app/Build/Products/Debug/Spillcheck.app`, including the signed scanner and
delivery helper. The core package is independently testable with Swift Package
Manager. Python runs build and acceptance tooling; the installed app does not
require it.
[Implementation status](docs/implementation/milestones.json) tracks completed
gates and required release checks.

To include the signed bundle in the test run after building the app:

```sh
SPILLCHECK_SIGNED_SCANNER_APP="$PWD/.build/app/Build/Products/Debug/Spillcheck.app" swift test
```

The [rename acceptance report](docs/implementation/spillcheck-rename.json)
records 235 core tests across 31 suites and passing signed-scanner integration.
The tested Spillcheck app reopened the existing vault after moving its
directory, with the original protection manifest unchanged. Earlier consecutive
app builds retained valid signatures and unchanged scanner resources.

## Repository layout

- `Spillcheck/`: macOS application, UI, and bundled helper target.
- `Sources/`: core Swift package, hook executable, and acceptance executables.
- `Dependencies/Scanner/`: pinned production scanner dependency metadata.
- `scripts/`: application build, scanner preparation, and release packaging.
- `Tests/`: core tests, signed probes, live-provider runners, synthetic fixtures,
  and shared test support. App acceptance tools live in `Tests/AppAcceptance/`;
  build and release tooling tests live in `Tests/Tooling/`.
- `docs/`: product decisions, implementation reports, and outstanding release checks.

Exploratory collection, scanner-comparison, vault, and T3 projects have been
removed. Production fixtures and acceptance tooling remain with the app's tests.

## Evidence and remaining checks

Genuine standalone CLI fixtures measured source read-start to commit-observation
p95 of 340.2 ms for [Claude 2.1.293](docs/implementation/m6-claude-observation-latency.json)
across 12 live revisions and 785.1 ms for [Codex 0.161.0](docs/implementation/m6-codex-observation-latency.json)
across eight live revisions. These small fixtures exclude replay and catch-up;
provider timestamps do not prove first-byte publication. T3 and historical
latency remain unmeasured, and Codex child-prompt coverage remains unverified.

The real Claude CLI
pipeline passed all required content cases, encrypted-storage checks, and stable
replay. The actual signed app also passed production-Keychain acceptance, with
one encrypted value and one occurrence for each required content type.
[Milestone 3 evidence and commands](docs/implementation/milestone-3.md)
describe these scopes and the preserved earlier failures. To repeat the native
check on an unlocked Mac:

```sh
python3 Tests/AppAcceptance/run-app-pipeline.py --output .build/implementation/app-pipeline.json
```

- [Production scanner fixtures and checks](Tests/Fixtures/Scanner/README.md)
- [Claude implementation gate](docs/implementation/milestone-3.json)
- [Native workflow](docs/implementation/milestone-5.md)
- [Acceptance and packaging](docs/implementation/milestone-6.md)
- [Tested interface/version matrix](docs/implementation/supported-matrix.md)
- [Implementation sequence](docs/IMPLEMENTATION_PLAN.md)
- [Release requirements and recorded deferrals](docs/implementation/release-checks.json)

Local implementation is complete under the recorded deferrals. The app has
passed real authentication, cancellation and window-close masking; its sleep,
screen-lock and inactivity handlers have no automated test, and its recorded
sleep/lock events happened while content was already masked. macOS 14 runtime and
hardware without Touch ID remain required before release. Direct source opening
is disabled until a route is validated; authenticated retained-context viewing
has been exercised. The [signed restart/offline workflow](docs/implementation/m6-signed-restart-offline.json)
passed 27 checks across four normal app runs, including deletion, obsolete-value
rediscovery, replacement, forgetting, review and masked OS notification
navigation. Its network policy is a cooperative fixture with a trusted bootstrap
escape; it establishes no all-descendant or system-wide boundary. Broader latency
and GUI-memory workloads remain documented limits. Actual login launch and
Developer ID install/update/key persistence remain unverified. Release tooling
has passing synthetic policy tests; no notarization upload was performed. The confirmed release baseline and authentication
requirements remain in force; both deferred environment tests must pass before
release.
