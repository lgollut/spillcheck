# Spillcheck

Spillcheck is a native macOS app that inventories secrets observed in Codex and
Claude Code sessions. It collects locally, scans with a bundled detector, stores
values and context encrypted, and requires authentication to reveal them.
Review, rotation/revocation acknowledgements and masked notifications help track
what needs attention.

The app is in development. [Codex](docs/CODEX_BETA.md) and
[Claude](docs/CLAUDE_BETA.md) have explicit beta scopes and exclusions.
[Beta readiness](docs/BETA_READINESS.md) tracks open verification and trial work;
[release requirements](docs/RELEASING.md) cover distribution and platform checks.

## Build

Use macOS on Apple Silicon, Xcode 27, XcodeGen and Python 3.9 or later. The
installed app does not require Python. A signed development build needs a
matching signing identity, provisioning profile and Keychain entitlements.
Configure signing in Xcode, then run from the repository root:

```sh
make scanner-dependencies
make test
make app
open .build/app/Build/Products/Debug/Spillcheck.app
```

Scanner setup downloads the pinned Betterleaks executable, rules and license,
and verifies their checksums against
[dependency metadata](Dependencies/Scanner/dependencies.json). Downloads are
cached under `.build/dependencies/scanner`; prepared resources are in
`.build/scanner`.

The build script accepts explicit signing overrides:

```sh
scripts/build-app.sh --signing-identity "<SIGNING_IDENTITY>" --team-id "<TEAM_ID>"
```

Existing vaults require their original application and Keychain access identity.
The [architecture guide](docs/ARCHITECTURE.md) explains the persisted identity
and storage contracts that must survive app updates.

## Set up collection

The first-launch assistant discovers agent executables, adds owned hooks and
guides a delivery check from a fresh session. Select the executable and profile
whose content you want analyzed. Review provider hook and folder-trust prompts
normally. Finding an executable or verifying delivery does not prove complete
content coverage.

Settings → General → Run setup again reopens the assistant. Settings → Agents
also offers manual profile selection and hook repair/removal. Enable Claude
Desktop support explicitly to include saved local Code conversations. Launch at
login is off by default; notifications require macOS permission.

CLI and T3 may share a native profile and registration. Collection status names
the provider/profile and configured transport; shared hooks do not identify the
producing host. An unfamiliar version alone does not block collection. Required
provider operations and source formats determine compatibility.

Debug builds can preview setup with sample data using
`--demo-setup welcome|how-it-works|choose-agents|connect|preferences|ready`.

## Test and contribute

```sh
swift test --no-parallel
python3 Tests/Tooling/run-python-tests.py
```

The [test guide](Tests/README.md) separates core and tooling checks from signed
app, genuine-provider and interactive authentication checks. To include an
already-built signed scanner bundle:

```sh
SPILLCHECK_SIGNED_SCANNER_APP="$PWD/.build/app/Build/Products/Debug/Spillcheck.app" swift test --no-parallel
```

See [Contributing](CONTRIBUTING.md) for changesets and PR checks. Generated test
reports belong in ignored build/output directories, alongside the run artifacts.

## Repository

- `Spillcheck/`: macOS app, UI and bundled helper target.
- `Sources/`: Swift core, hook executable and acceptance executables.
- `Dependencies/Scanner/`: pinned production scanner metadata.
- `scripts/`: build, scanner preparation and release tooling.
- `Tests/`: regression tests, fixtures and acceptance runbooks.
- [`docs/`](docs/README.md): current product, architecture, scope and release guides.
