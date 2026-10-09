# Signed vault owner for GUI restart checks

This test executable creates a fresh production vault in a private temporary directory. It commits the manifest, closes the store, and retains the original `ProtectionServices` that created the keys. It uses the selected signed Spillcheck app bundle's signing identity, entitlements, and Keychain access group. UUID-based production key identifiers remain separate from existing vaults. The selected app bundle, agent hooks and histories are unchanged.

The owner has no windows and performs no private-value decryption or authentication. Build and signing do not create keys. Only `start` creates the disposable vault; only a later `launch` command starts the selected app. The app loads the same committed manifest on every run. Its launch arguments omit `--acceptance-cleanup-new-vault`.

Build from the repository root after the core package has been built:

```sh
python3 Tests/ProtectionSignedProbe/vault-owner-session.py build \
  --app .build/app/Build/Products/Debug/Spillcheck.app \
  --products-path .build/out/Products/Debug
```

`--app` selects the signed bundle to test. The builder requires its signing identity to be available and validates its bundle identifier and Keychain access group against the application configuration in the runner. A different signing configuration requires matching app and runner configuration before this check can run.

The builder reuses existing core products, compiles with Swift 6 strict concurrency, copies the selected bundle, replaces the copy's executable, and signs it with the selected bundle's exact signing identity and entitlements. It verifies both bundles. It refuses to overwrite a previous owner bundle; use a fresh `--output-directory` for a later build. Before each launch, the owner verifies the selected executable's recorded SHA-256, the bundle's sealed deep signature and its original code-directory hash.

Start when the Mac is available for manual app checks:

```sh
python3 Tests/ProtectionSignedProbe/vault-owner-session.py start \
  --ready .build/implementation/vault-owner-ready.json \
  --report .build/implementation/vault-owner-report.json \
  --lease-seconds 3600
python3 Tests/ProtectionSignedProbe/vault-owner-session.py command \
  --ready .build/implementation/vault-owner-ready.json --action launch
```

The private ready file contains the nonce and disposable paths. The owner seeds one synthetic Claude 2.1.293 user prompt, then accepts fixed commands through private files. A launch response identifies the owned app PID and report. The launched app holds until its normal Quit action. The owner tracks each `Process`, reaps it, and requires exit status zero, a `shutdown-complete` report, empty raw caches and empty stdout/stderr before opening the store or launching another app.

The commands below use the same `--ready` argument:

| Action | Effect |
| --- | --- |
| `launch` | Start one fixed selected-app command with this store and selected synthetic source. |
| `inspect` | After all app runs have quit normally, read masked aggregate inventory and payload-reference existence. Close the store before returning. |
| `append-original` | While the app is ready, monitoring and queue zero, append a new synthetic prompt containing the original fixed fixture value. |
| `append-replacement` | Append a new prompt containing a different fixed fixture value under the same readiness checks. |
| `cleanup` | After normal app exit and queue zero, verify the same manifest, use the original creator's cleanup SPI, then remove only this owned directory. |
| `preserve` | End the owner without deleting keys or files. This reports cleanup pending. |

First let the baseline app ingest the seed, quit normally, and run `inspect`. This records the encrypted value, excerpt and source-metadata references before deletion. Then relaunch, delete the retained content through the GUI, quit and inspect. The original record and content should be absent, the remembered references inaccessible, and receipts retained. Relaunch the same store to check that the old source does not restore content. A live `append-original` checks that a genuinely new source appearance can be detected.

For the obsolete-value sequence, acknowledge the current value through the GUI, remove its retained content, quit and inspect. Relaunch and append the original value. Its new appearance should be metadata-only and silent. Append the replacement to verify ordinary detection and a normal alert. Forget the obsolete marker through the GUI, then append the original again to check later ordinary detection. Quit before the final `inspect` and `cleanup` commands. The owner reports aggregate state and app-owned opaque entry IDs; it never returns values, excerpts, source titles, fingerprints or native session IDs. Bounded ciphertext inspection checks the known synthetic values, fixture marker and source path. Final app acceptance reports and snapshots survive owned-file removal in the external report.

Optional network isolation uses a fixed test policy:

```sh
python3 Tests/ProtectionSignedProbe/vault-owner-session.py command \
  --ready .build/implementation/vault-owner-ready.json --action launch \
  --sandbox-mode network-denied-trusted-scanner-bootstrap
```

That policy denies parent networking, permits only the exact owned `protected-store/capture.sock` for the local capture listener, and lets `/usr/bin/sandbox-exec` bootstrap the unchanged production scanner sandbox. The literal executable exception does not constrain its arguments. This is a trusted fixture policy with a generic bootstrap escape; it does not establish secure denial for every descendant. Default restart tests use `unsandboxed`.

Cleanup requires the live original creator. A changed manifest, running or abnormal child, missing shutdown report, nonzero queue or failed ciphertext-marker inspection rejects cleanup. Lease expiry preserves files and keys and does not terminate a child. A failed cleanup preserves the manifest for diagnosis. Do not delete the temporary directory or kill the owner before successful cleanup. Once the original owner exits, a service loaded from the saved manifest cannot use this cleanup SPI; the preserved manifest is evidence, not cleanup authorization. No recovery path silently weakens that production guard.

Capture masked launch receipts before cleanup removes the private response files:

```sh
python3 Tests/ProtectionSignedProbe/finalize-vault-owner-evidence.py capture-launches \
  --responses OWNED_PRIVATE_DIRECTORY/responses \
  --output .build/implementation/vault-owner-launch-receipts.json
```

The test operator records native observations in a separate JSON file with an `observations` array. Each item has a controlled `step`, `runIndex`, `observedNativeUI` booleans/counts, and an optional copy of the safe `appAcceptanceReport`. The same file records masked `launches` and the fixture scope. Update a pending observation when it is completed; duplicate step names are rejected. The finalizer's source defines the accepted steps and fields. It ignores raw values, excerpts, nonces, source paths, titles and native IDs.

After all app runs quit and owner cleanup completes, finalize the saved evidence:

```sh
python3 Tests/ProtectionSignedProbe/finalize-vault-owner-evidence.py finalize \
  --owner-report .build/implementation/vault-owner-report.json \
  --observations .build/implementation/vault-owner-native-observations.json \
  --launch-receipts .build/implementation/vault-owner-launch-receipts.json \
  --output docs/implementation/m6-signed-restart-offline.json
python3 Tests/ProtectionSignedProbe/test_vault_owner_evidence.py
```

Missing or pending observations leave their checks false and produce exit status 1. Omit `--owner-report` and choose a `.build` output path for an explicitly incomplete preview. OS notification request acceptance, visible display and clicking to masked inventory have separate assertions. Recorded lock/sleep events from an already-masked workflow remain scoped observations and establish no authenticated-reveal lifecycle result.

The completed recorded run uses these saved r2 inputs:

```sh
python3 Tests/ProtectionSignedProbe/finalize-vault-owner-evidence.py finalize \
  --owner-report .build/implementation/vault-owner-report-r2.json \
  --observations .build/implementation/vault-owner-native-observations-r2.json \
  --launch-receipts .build/implementation/vault-owner-launch-receipts-r2.json \
  --output docs/implementation/m6-signed-restart-offline.json
```

Its notification click was confirmed by the user, then matched to native accessibility state and actual app navigation events. Banner text was not independently read through accessibility. The report records controlled notification construction plus the user's response as its masking evidence, and records the notification preference restored to disabled and launch at login left off. The finalizer copies only recognized preference booleans and validates expected provenance values before adding those summaries.
