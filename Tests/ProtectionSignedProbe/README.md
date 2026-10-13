# Production protection probe

This isolated native probe links the production Core package, including its durable bootstrap record and actual protected-store manifest transaction. It uses a signing configuration authorized for the selected Keychain access group, with separate `com.leakret.app.protection-probe` services and UUIDs. It writes only synthetic fixture data in the selected disposable directory. It does not inspect agent histories or application settings.

Build the probe from the repository root:

```sh
swift build --product SpillcheckCore
python3 Tests/ProtectionSignedProbe/build.py --products-path .build/out/Products/Debug
```

Package the binary in a native app bundle with entitlements that authorize the selected Keychain access group. Include a provisioning profile when the signing configuration requires one. The app's Info.plist must provide these keys for the no-argument GUI run:

| Key | Value |
| --- | --- |
| `SpillcheckKeychainAccessGroup` | Fully qualified owned group, such as `TEAM_ID.com.leakret.app` |
| `SpillcheckProbeDirectory` | Absolute path to an isolated disposable directory |
| `SpillcheckProbeReportPath` | Absolute path for the safe JSON report |

Building does not launch the probe or request authentication. Use the products directory reported by your Swift build if it differs from the example. New fixtures commit their manifest in `protected-store` before retiring the bootstrap record. Older JSON-only fixtures fail with `legacy-fixture-requires-fresh-directory`; preserve those artifacts and choose a fresh disposable directory. The probe never converts a pending record into permission to create replacement keys.

An interrupted setup keeps its private bootstrap record. While the protected store is still empty, the next start resumes with the recorded key identities: it reuses keys that exist and creates only missing ones under the same identities. It never deletes keys left by an earlier attempt or generates a replacement set. Preserve the record and exact failed fixture; deleting the record to force a fresh attempt would orphan keys created under it. A record matching an already committed store manifest is reconciled only after its original keys load successfully.

Open that exact app bundle through LaunchServices and click **Verify production vault**. Complete the actual macOS authentication prompt. The native window reports the result without displaying synthetic plaintext. The JSON report goes to the configured private file and stdout. **Close probe** exits the process.

For noninteractive checks, invoke the signed executable with explicit arguments:

```sh
SIGNED_PROBE_APP/Contents/MacOS/ProtectionSignedProbe \
  --access-group TEAM_ID.com.leakret.app \
  --directory /absolute/path/to/disposable/probe-data
```

Replace `SIGNED_PROBE_APP`, `TEAM_ID`, and the disposable-directory path with the configured bundle, team identifier, and test directory. Repeat with the same directory to exercise existing keys and ciphertext. Use the LaunchServices window and explicit button for interactive system authentication.

The probe checks that an exported `LAPublicKey` can be imported into an actor-owned `SecKey`, wrap a fresh AES key while locked, and have the same persisted LA private key unwrap it after system authorization. It also checks exact bytes after deleting the disposable source file, immediate masking, private-operation denial through that same production viewing session after masking, stable background/identity keys, explicit missing-key failure, and ciphertext inspection. The authentication method is not inferred from a successful authorization result.

The source-deletion check creates a private disposable synthetic upstream file, seals from its exact bytes when creating a new fixture, deletes the source before reveal, and verifies its absence. A reopened fixture reuses its earlier retained ciphertext. The source file is removed on failure as well. Offline crypto/viewing tests separately exercise key-role isolation, HMAC byte identity, envelope tampering, monotonic inactivity expiry, cancellation, and stale successful or throwing callback handling.

Run the probe with the signing configuration and macOS version being validated. Release signing, notarization, and hardware without Touch ID require their own checks.
