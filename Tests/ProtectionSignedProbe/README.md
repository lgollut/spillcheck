# Production protection probe

This isolated native probe compiles the production protection implementation. It uses a signing configuration authorized for the selected Keychain access group, with separate `com.leakret.app.protection-probe` services and UUIDs. It writes only synthetic fixture data in the selected disposable directory. It does not inspect agent histories or application settings.

Build the probe from the repository root:

```sh
xcrun swiftc -swift-version 6 -strict-concurrency=complete -O -parse-as-library \
  -target arm64-apple-macos14.0 \
  Sources/SpillcheckCore/SourceContracts.swift \
  Sources/SpillcheckCore/StorageContracts.swift \
  Sources/SpillcheckCore/Protection.swift \
  Tests/ProtectionSignedProbe/main.swift \
  -o .build/ProtectionSignedProbe
```

Package the binary in a native app bundle with entitlements that authorize the selected Keychain access group. Include a provisioning profile when the signing configuration requires one. The app's Info.plist must provide these keys for the no-argument GUI run:

| Key | Value |
| --- | --- |
| `SpillcheckKeychainAccessGroup` | Fully qualified owned group, such as `TEAM_ID.com.leakret.app` |
| `SpillcheckProbeDirectory` | Absolute path to an isolated disposable directory |
| `SpillcheckProbeReportPath` | Absolute path for the safe JSON report |

Open that exact app bundle through LaunchServices and click **Verify production vault**. Complete the actual macOS authentication prompt. The native window reports the result without displaying synthetic plaintext. The JSON report goes to the configured private file and stdout. **Close probe** exits the process.

For noninteractive checks, invoke the signed executable with explicit arguments:

```sh
SIGNED_PROBE_APP/Contents/MacOS/ProtectionSignedProbe \
  --access-group TEAM_ID.com.leakret.app \
  --directory /absolute/path/to/disposable/probe-data
```

Replace `SIGNED_PROBE_APP`, `TEAM_ID`, and the disposable-directory path with the configured bundle, team identifier, and test directory. Repeat with the same directory to exercise existing keys and ciphertext. Recorded direct CLI authorization attempts returned LocalAuthentication `-1004`; the LaunchServices window and explicit button successfully requested system authentication.

The recorded [interactive report](../../docs/implementation/production-vault-interactive.json) has 16 passing checks: 13 noninteractive checks and three interactive checks. It establishes that the exported `LAPublicKey` can be imported into an actor-owned `SecKey`, wrap a fresh AES key while locked, and have the same persisted LA private key unwrap it after system authorization. It also verifies exact bytes after deleting the disposable source file, immediate masking, private-operation denial through that same production viewing session after masking, stable background/identity keys, explicit missing-key failure, and ciphertext inspection. The authentication method is not inferred from a successful authorization result.

The source-deletion check creates a private disposable synthetic upstream file, seals from its exact bytes when creating a new fixture, deletes the source before reveal, and verifies its absence. A reopened fixture reuses its earlier retained ciphertext. The source file is removed on failure as well. All 21 offline crypto/viewing tests pass, separately exercising key-role isolation, HMAC byte identity, envelope tampering, monotonic inactivity expiry, cancellation, and stale successful or throwing callback handling.

These recorded development checks apply to the tested signing configuration and validation environment. Release signing/notarization and the deferred macOS 14 and hardware-without-Touch-ID runs remain separate release checks.
