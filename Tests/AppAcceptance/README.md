# Signed app acceptance

These drivers run the signed development app with its bundled scanner and production vault in a disposable directory. Run commands from the repository root after `make app`.

Check Claude ingestion, all five content types, encrypted storage, process memory, and shutdown cleanup:

```sh
python3 Tests/AppAcceptance/run-app-pipeline.py \
  --output .build/acceptance/app-pipeline.json
```

`--app` selects another signed app bundle. The default is `.build/app/Build/Products/Debug/Spillcheck.app`. The driver creates a synthetic transcript and exits after the app's timed acceptance run.

Check Codex collection against one to four exact, newly owned synthetic T3 threads:

```sh
python3 Tests/AppAcceptance/run-app-codex-pipeline.py \
  --thread OWNED_SYNTHETIC_THREAD_ID \
  --output .build/acceptance/codex-app-pipeline.json
```

Repeat `--thread` for each selected thread. `--home` and `--executable` select the original provider store and Codex reader. This driver uses the default built app and the measured tuple of Codex reader 0.161.0, producer 0.160.1, and T3 0.0.46-nightly.20261007.2761. It reads the selected threads with profile discovery disabled. It does not create provider sessions.

Keep a synthetic inventory open for manual native review and viewing checks:

```sh
python3 Tests/AppAcceptance/run-app-workflow.py \
  --ready .build/acceptance/workflow-ready.json \
  --output .build/acceptance/workflow.json \
  --duration 3600
```

`--app` selects the signed bundle, and `--duration` bounds the run to 30 through 7200 seconds. The private ready file identifies the disposable source, app report, and process. Viewing uses real macOS authentication. Complete authentication in the system prompt and quit the app normally to finish cleanup. The report checks termination and cleanup; manual workflow outcomes require separate review.

The drivers create separate production Keychain items for their disposable vaults. `Tests/Support/acceptance_artifacts.py` removes each owned directory after the test passes and the app confirms vault cleanup. Failed runs retain their exact vault and manifest for diagnosis. Use `--help` to inspect options without launching an app.

Run genuine disposable Claude CLI sessions through owned hooks into the signed app:

```sh
python3 Tests/AppAcceptance/run-app-claude-live.py \
  --executable /absolute/path/to/claude --expected-version 2.1.295 \
  --output .build/acceptance/app-claude-live.json
```

Build the current `spillcheck-storage-acceptance` SwiftPM product first. Its `--claude-configure-hook` mode uses production owned-hook editing to configure only the disposable provider settings. The signed app receives genuine prompts, responses, successful shell/MCP output, errors, and native child content through its bundled helper. The driver checks original provider markers, committed required content types, canonical replay through overlapping CLI/T3 routes, encrypted storage, and controlled shutdown. It records actual executable and producer versions. `--expected-version` is an optional acceptance assertion, not product eligibility.

The app's explicit `--acceptance-finish-file` sentinel ends the held run through normal queue drain and termination. Provider authentication and the owned registration are removed on failure as well as success. An unavailable production vault leaves its exact manifest and private diagnostic report for guarded cleanup. A successful ingestion report does not establish saved setup verification, restart or upgrade recovery, simultaneous GUI sessions, or source opening. The genuine core Claude runner measures the durable setup challenge separately.

The live runner also accepts `--historical-producer-executable` and `--expected-historical-version`. It creates one genuine older full-content session before the signed app starts, using the same disposable provider home. All live runs use the current executable. This mode alone adds the explicit acceptance history-request flag and delivers the existing frozen seven-day request through the signed helper. It requires all five committed content types for each actual producer version, unchanged older native identities and bytes, stable executable versions, and the ordinary child, replay, encryption, and cleanup checks. An older GUI-bundled executable invoked as CLI does not prove the GUI host route.

Observe an original native source created by a genuine owned T3 Claude child:

```sh
python3 Tests/AppAcceptance/run-app-claude-selected.py \
  --manifest /absolute/private/owned-native-manifest.json \
  --ready /absolute/private/collector-ready.json \
  --producer-done /absolute/private/producer-finished \
  --output .build/acceptance/app-claude-selected.json
```

The producer writes its own runtime native session and original transcript mapping to the private manifest, then waits for the collector-ready sentinel before creating the remaining content. The observer launches no provider and edits no hooks. It requires a complete owned prompt under the exact native identity before selection. After producer completion, it verifies all five types and the native child's own prompt and final markers, and replays the exact parent and own child files across CLI/T3 metadata. Two positive occurrence-count samples before producer completion establish live growth. A child may share its parent's native session field; the observer preserves that identity.

The reusable evidence reader in `Tests/Support/claude_native_evidence.py` checks source ownership, type, required fields, and complete framing. It reads only explicit parents and each parent's own `subagents` directory, with at most 32 children per parent, 64 files total, two MiB per file, and sixteen MiB total. The selected observer does not discover sibling conversations. Fresh disposable homes in the live runner use bounded native parent discovery. Reports contain counts, marker labels, versions, and controlled limitations; private replay inputs retain actual paths and native IDs. Constructed boundary checks run with `python3 Tests/Support/test_claude_native_evidence.py` and do not establish provider acceptance.

Run a genuine signed Claude CLI upgrade and restart against one fresh owned vault:

```sh
python3 Tests/AppAcceptance/run-app-claude-recovery.py \
  --starting-executable /absolute/older/claude \
  --upgraded-executable /absolute/current/claude \
  --output .build/acceptance/app-claude-recovery.json
```

The default expected producers are 2.1.293 and 2.1.295; the two `--expected-*-version` options change these acceptance assertions. The runner independently probes both executables. It installs and verifies a saved production profile in its private home, retargets only its own executable symlink, and restarts the signed collector with unclaimed encrypted work pending. Each exact pending capture must appear in the new worker's successful completion callbacks and durable consumed receipts. A fresh history audit or an expired capture receipt cannot satisfy that gate. Private keyed comparisons check inventory, source receipts, alert identities, registration, proof, manifest, and loaded checkpoint identities. They do not assert unchanged checkpoint offsets or adapter state.

A separate signed vault owner retains the original fresh-key cleanup authority while collector processes restart. Only that original creator removes its keys after collectors exit and the exact owned registration is removed. Loaded manifests cannot acquire cleanup authority. Add `--owner-smoke` for the short lifetime check without provider calls, copied authentication, or hook installation. Reports distinguish retained diagnostic artifacts from pending protection cleanup. The [October 9 recovery evidence](../../docs/implementation/harness-compatibility-recovery.md) records the passing genuine CLI trial and remaining host, failure-restoration, review/obsolete-state, and actual health notification gates.

The optional `--rebuild-app-between-workers` mode tests an actual app and encrypted
profile upgrade from schema 2 to 3. Start with the previously verified schema-2
signed Debug bundle still at the default path and freeze the new schema-3 sources.
This mode requires that exact repository bundle path and a full genuine run. After
the first collector exits with pending encrypted work, it invokes only
`scripts/build-app.sh --configuration Debug --derived-data` for the repository's
`.build/app`. The fresh creator stays in a separately copied, verified old signed
bundle while the collector and helper keep their original paths. The build must
finish with the creator alive, unchanged app/helper signing bindings, changed
signed artifacts, and unchanged source hashes. The restarted collector must report
the actual decrypted loaded schema 2 and persisted schema 3, alongside all existing
queue, proof, registration, identity, content, and cleanup assertions. Failed builds
stop their owned process group and retain private diagnostics. This mode is an
acceptance mechanism with a [passing 28-gate genuine signed trial](../../docs/implementation/app-claude-harness-compatibility-schema-migration-2026-10-09.json)
for one Claude CLI profile. Other host/provider migrations and review/obsolete-state
recovery remain separate gates.

`python3 Tests/AppAcceptance/test_claude_recovery_boundary.py` checks the fixed build
target, strict measured schema predicate, and source-freeze detection without
launching providers, apps, builds, or vaults.
