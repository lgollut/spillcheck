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

Check signed Codex/T3 restart with one encrypted capture pending:

```sh
python3 Tests/AppAcceptance/run-app-codex-recovery.py \
  --source-directory /absolute/private/owned-t3-proof-directory \
  --app /absolute/path/to/Spillcheck.app \
  --expected-bundle-sha256 FROZEN_BUNDLE_SHA256 \
  --executable /absolute/path/to/codex \
  --expected-reader-version 0.162.1 \
  --expected-producer-version 0.162.1 \
  --host-version 0.0.46-nightly.20261011.2980 \
  --output .build/acceptance/codex-recovery.json \
  --private-control .build/acceptance/codex-recovery-private.json
```

The input directory must contain the exact fresh T3 source's private runtime identity,
completed task and lineage proofs, successful live observer and signed collection
reports, verified task/observer overlap, and frozen candidate manifest. The caller's
`CODEX_THREAD_ID` must differ from the selected source. The runner reads only that
original source with profile discovery disabled and requires the five content-type
counts from its prior observer report. It creates no provider session or registration.

The first signed worker collects into a fresh disposable vault, then shuts down
normally and drains any in-flight polls. A separate signed worker starts with no
active source or profile discovery and a stop-processing control already present.
Once it reports processing stopped and an empty queue, the runner sends one synthetic
`SpillcheckHistoryPoll` through the bundled helper and requires exactly one new,
encrypted, unclaimed capture. That capture's private digest must survive normal
worker shutdown. A third signed worker loads the same vault and must both consume
and successfully process that exact capture. Inventory, analyzed-source receipt,
and alert identities must remain unchanged, with an empty queue and no gaps.

This measures synthetic queue admission and restart replay of an already scanned
source. It does not establish provider hook dispatch, automatic enrollment, a fresh
detector scan, saved-profile or checkpoint restoration, crash recovery, upgrades,
reader degradation, native child coverage, source opening, or full T3 acceptance.

Only the original fresh-vault owner can remove its keys, after all three workers complete
normal shutdown and all owned groups stop. Failed runs retain the exact private
cleanup handoff, run token, manifest, and diagnostic reports. `cleanupPending` includes
retained failure artifacts; `ownedProtectionCleanupPending` separately records whether
vault key cleanup remains unconfirmed. Loaded workers never receive key deletion
authority. Check the proof, queue, replay, and cleanup boundaries without launching
an app or touching Keychain:

```sh
python3 -m unittest discover -s Tests/AppAcceptance -p 'test_codex_recovery_boundary.py'
```

`run-app-codex-reader-recovery.py` uses the same options with fresh output and
private-control paths to test a temporarily unavailable reader. It starts with an
absent executable path inside its disposable directory, with no active source or
profile catch-up. One synthetic poll must remain encrypted and unclaimed after an
actual failed attempt. A bounded, read-only SQLite query reads only the disposable
queue's identifier, retry count and state; an authorizer denies payload access.

After observing retry 1 or 2, the runner creates an owned symlink to the pinned
reader. The same capture must be consumed and successfully processed, producing
the fixture's seven appearances across five types and one session. Later successful
processing must preserve occurrence, receipt and alert identities. This later
processing can come from the normal monitor; it does not prove delivery of a
particular repeated helper invocation. The test checks final queue drain,
ciphertext, unchanged candidate and source proofs, and creator-owned cleanup.
It does not establish recovery of a durable omission after retry exhaustion.

```sh
python3 -m unittest discover -s Tests/AppAcceptance -p 'test_codex_reader_recovery_boundary.py'
```

When the signed candidate changes, preserve the original source proof directory
and create an independent current-candidate baseline before reusing that source:

```sh
python3 Tests/AppAcceptance/run-app-codex-baseline.py \
  --source-directory /absolute/private/original-t3-proof-directory \
  --candidate-manifest /absolute/private/current-candidate-build.json \
  --directory /absolute/private/new-current-baseline-directory \
  --app /absolute/path/to/Spillcheck.app \
  --expected-bundle-sha256 CURRENT_BUNDLE_SHA256 \
  --executable /absolute/path/to/codex \
  --expected-reader-version 0.162.1 \
  --expected-producer-version 0.162.1 \
  --host-version 0.0.46-nightly.20261011.2980
```

This checks the immutable historical ownership, observer and signed reports under
their original manifest. It then runs the existing signed ingestion test for that
one exact original source using the new candidate. Exact content-type counts,
an empty queue, no gaps, ciphertext protection, normal exit and fresh-vault cleanup
must pass independently. No provider session is created. The recorded host version
belongs to the original source; this is post-run ingestion, not new live T3 evidence.

The new `baseline-receipt.json` binds every fixed historical proof file, the new
candidate manifest and the actual signed report by hash. Both old and new reports
remain unchanged. Pass `--candidate-baseline-directory` with this new directory to
either recovery runner while keeping `--source-directory` pointed at the original
proofs. Recovery checks both proof sets, uses the new manifest for app preflight,
and rejects changed evidence or an incomplete baseline. Omitting the option keeps
the original strict same-candidate requirement. These files never promote the
historical live or exact-marker evidence to the new candidate.

The baseline keeps its small evidence directory after success. The existing signed
runner owns its separate disposable vault and cleanup control. A failed launch or
acceptance keeps that exact cleanup handoff and a failed baseline receipt; later
success cannot overwrite it. Boundary checks launch no app and access no Keychain:

```sh
python3 -m unittest discover -s Tests/AppAcceptance -p 'test_codex_baseline_boundary.py'
```

Check retained review state, a stored delivery receipt, and obsolete-content removal
across signed restarts and full reads of the exact retained fake T3 source:

```sh
python3 Tests/AppAcceptance/run-app-codex-inventory-state.py \
  --source-directory /absolute/private/original-t3-proof-directory \
  --candidate-baseline-directory /absolute/private/passed-current-baseline-directory \
  --app /absolute/path/to/Spillcheck.app \
  --expected-bundle-sha256 CURRENT_BUNDLE_SHA256 \
  --executable /absolute/path/to/codex \
  --expected-reader-version 0.162.1 \
  --expected-producer-version 0.162.1 \
  --host-version 0.0.46-nightly.20261011.2980 \
  --output .build/acceptance/codex-inventory-state.json \
  --private-control .build/acceptance/codex-inventory-state-private.json
```

The separate passed current-candidate baseline is mandatory. All three workers use
the same original source authority and vault, authorize only the T3 route, disable
profile discovery, and keep normal Codex polling stopped. The runner creates no
provider session, copies no authentication, and changes no provider configuration.

The first worker admits one exact-source historical audit through the bundled
helper and the explicit disposable history-request flag. Its fresh audit identity
uses a seven-day window, one known native source, no discovery, and no child traversal.
It requires the original seven appearances across all five content types and a
normally settled pending notification decision. After processing stops with an
empty queue, the token-authenticated `inventory-review-and-receipt` control marks
two distinct appearances confirmed and false positive through the app's normal
mutation path. It also marks one existing notification decision delivered in the
store. This receipt is test data; OS notification delivery is suppressed and is
never claimed.

The second worker restores the state, then `inventory-replay-source` queues a
selected-source historical audit. Actual clean batches must read every previously
recorded source item, cover all five types, report nonzero bytes and complete
progress, and successfully process the exact capture. Full keyed digests of stored
record values must remain unchanged, including reviews, receipt delivery, source
receipts and labels. Identity sets alone cannot pass this check.

With processing stopped again, `inventory-obsolete-and-remove` acknowledges the
fake value as revoked and removes retained content through the normal app actions.
The third worker restores that state and repeats the full-source audit. The revoked
marker and removed-location receipts must survive, while values, appearances,
protected payload rows and live alerts stay absent. The original analysis receipts
remain. The queue must be empty and every capture fully processed before removal,
so this test loses no pending work. It requires no coverage gaps after deletion
and replay; even `captureRejected` fails this completed-source case.

The runner drives these fixed controls automatically. Workers must exit normally
before the original creator receives its cleanup token. If cleanup is uncertain,
the runner preserves the live creator and a private PID/control handoff rather than
terminating its deletion authority. Failed reports distinguish retained artifacts
from unconfirmed key cleanup. The original creator has a bounded 900-second lifetime.
No loaded worker may delete the keys.

This establishes only the measured retained-state behavior. It does not establish
OS notification delivery, live provider hook dispatch, a schema or provider upgrade,
crash recovery, source opening, or full host support. Boundary tests launch no app,
provider session or Keychain operation:

```sh
python3 -m unittest discover -s Tests/AppAcceptance -p 'test_codex_inventory_state_boundary.py'
```

Check native web-result scanning, durable receipts, cold restart and exact reread:

```sh
python3 Tests/AppAcceptance/run-app-codex-web-results.py \
  --app /absolute/path/to/Spillcheck.app \
  --candidate-manifest /absolute/private/current-candidate-build.json \
  --expected-bundle-sha256 RECORDED_BUNDLE_SHA256 \
  --executable /absolute/path/to/codex \
  --expected-version 0.162.1 \
  --model gpt-6.1-sol \
  --auth-file "$HOME/.codex/auth.json" \
  --output .build/acceptance/codex-web-results.json \
  --private-control .build/acceptance/codex-web-results-private.json
```

The runner makes one public-documentation search in a fresh private home and
workspace. It copies only authentication, removes that copy after the producer
stops, and keeps the exact returned native session for signed verification. It
does not send a fake secret to the search service or change personal settings.

The first worker must start with an empty analysis ledger. Normal collection must
commit full current-detector receipts matching original native result identities,
revisions and bounded result-only segment commitments. A second worker must
restore those receipts before reading, then force a complete selected-source
audit that preserves both the original result commitments and stored state.
Query text, assistant echoes, partial receipts and an unchanged checkpoint alone
cannot pass. The current fixture requires a clean result with no findings; this
measures actual scanning and receipt persistence, not secret-detection recall.

The original creator retains sole vault-cleanup authority across both workers.
Failed runs keep controlled diagnostics and the owned source, with authentication
removal and any pending key cleanup reported separately. The check does not
establish side-chat hosted results, native child input or full host support.
Boundary tests require no provider, app or Keychain operation:

```sh
python3 -m unittest discover -s Tests/AppAcceptance -p 'test_codex_web_results_boundary.py'
```

Check a genuine native Plan through the shared native-content acceptance runner:

```sh
python3 Tests/AppAcceptance/run-app-codex-native-content.py --fixture plan \
  --app /absolute/path/to/Spillcheck.app \
  --candidate-manifest /absolute/private/current-candidate-build.json \
  --expected-bundle-sha256 RECORDED_BUNDLE_SHA256 \
  --executable /absolute/path/to/codex \
  --expected-version 0.162.1 \
  --model gpt-6-astra \
  --auth-file "$HOME/.codex/auth.json" \
  --output .build/acceptance/codex-plan.json \
  --private-control .build/acceptance/codex-plan-private.json
```

The existing `run-app-codex-plan.py` command forwards to this fixture. A real
Codex Plan-mode turn in an owned temporary home supplies the exact native item
identity, text hash and byte count. Authentication is removed after the producer
stops and before signed reads. There is no synthetic-output fallback.

Plan, MCP and hook-prompt fixtures use the same signed workers, report schema,
receipt checks, `native-content-replay` control and creator-owned cleanup. The
first worker must scan the actual native item and commit a full detector receipt.
The second must restore the stored state before reading, then audit that exact
source with a new successful capture and unchanged content commitments. Plan's
`/text` must match the independent producer observation; an assistant echo cannot
substitute for a native `plan` item.

Detailed parsing, malformed content, persistence and omission recovery remain in
`CodexPlanContentTests.swift`. Shared runner boundary tests cover report and
cleanup gates:

```sh
python3 -m unittest discover -s Tests/AppAcceptance -p 'test_codex_native_content_boundary.py'
```

This harmless fixture measures signed scanning, receipt persistence and rereading.
It does not measure detector recall or establish Desktop/T3 support. Historical
Plan reports retain their original schema and candidate hashes; the shared runner
requires a fresh signed run before claiming acceptance for a new candidate.

Check durable Codex CLI omission recovery through the signed app's production
**Retry this source** path:

```sh
python3 Tests/AppAcceptance/run-app-codex-omission-recovery.py run \
  --app /absolute/path/to/Spillcheck.app \
  --candidate-manifest /absolute/private/current-candidate-build.json \
  --expected-bundle-sha256 CURRENT_BUNDLE_SHA256 \
  --executable /absolute/path/to/codex \
  --expected-version 0.162.1 \
  --auth-file /absolute/private/existing-codex-auth.json \
  --model AUTHORIZED_TEST_MODEL \
  --output .build/acceptance/codex-omission-recovery.json \
  --private-control .build/acceptance/codex-omission-recovery-private.json
```

Use fresh output paths. This creates one real provider session in a new private
`CODEX_HOME` and fake workspace. The signed app installs its owned hooks there and
verifies its saved profile through the genuine CLI's encrypted delivery. Existing
authentication is copied into that temporary home; personal settings, trust files
and histories are not modified or enumerated. `codex_omission_fixture.py` is copied
into the workspace: it records only its own runtime session identity privately,
prints the fixed fake token, and deliberately returns exit 7 for its error command.
The baseline requires seven appearances across all five content types.

Drive the normal terminal UI from another terminal or tool call while `run` remains
active; no desktop clicking is needed. The control endpoint accepts only fixed
actions and returns controlled UI labels, never raw terminal text:

```sh
python3 Tests/AppAcceptance/run-app-codex-omission-recovery.py control \
  --private-control .build/acceptance/codex-omission-recovery-private.json \
  --action state
```

Choose each action from the observed current state. Confirm the displayed fake
folder with `enter`; use `review` when `startupHooksReviewMenu` is observed, then
`trust` when the eight owned hooks and `trustAllControl` are observed. This uses the
CLI's normal review controls; it never writes a trust decision directly. Once
`postTrustDetailsObserved` is true, use `escape` to close the review, then `verify`
and a separate `enter` to send the one-use setup challenge. Wait for
`setupConnected`, send `fixture` and `enter`, then wait for `fixtureCollected`
before `quit` and `enter`. `hooks` opens `/hooks` when followed by `enter`. An
unrecognized screen or rejected action is a failed setup, not evidence of trust;
do not send blind confirmation keys. The provider phase and all process groups
have bounded lifetimes.

After the CLI exits normally, the runner stops native polling, removes only its
owned reader symlink, and admits two synthetic exact-session polls. Both must
exhaust their retries and retain distinct durable omissions. Restoring the pinned
reader and successfully reading that source again must leave both omissions open.
A private authenticated control then invokes production source retry for the
latest failed work. One or two certified, linked seven-day audits must cover its
frozen original interval, recover exactly its omission, and preserve the older
failure's warning. Occurrence, receipt, alert and saved setup identities must stay
unchanged. A remaining `sourceUnavailable` warning is therefore required for this
test to pass.

The runner stops owned processes, removes the temporary provider home (including
copied authentication and registration), and only then permits the original fresh
vault creator to delete its keys. Failures retain the private cleanup handoff;
`ownedProtectionCleanupPending` distinguishes unconfirmed key cleanup from retained
diagnostic artifacts. Reports never export native session IDs or raw provider
content. A pass establishes this selected CLI omission recovery path. The failed
polls are synthetic admissions: it does not establish failure-hook dispatch,
desktop or T3 acceptance, automatic enrollment, native child coverage, source
opening, crash or upgrade recovery, or full Codex support.

```sh
python3 -m unittest discover -s Tests/AppAcceptance -p 'test_codex_omission_recovery_boundary.py'
```

Check a genuine Codex executable upgrade and orderly restart with a fresh signed
vault and saved CLI profile:

```sh
python3 Tests/AppAcceptance/run-app-codex-upgrade.py run \
  --app /absolute/path/to/Spillcheck.app \
  --candidate-manifest /absolute/private/current-candidate-build.json \
  --expected-bundle-sha256 CURRENT_BUNDLE_SHA256 \
  --starting-executable /absolute/path/to/older/codex \
  --upgraded-executable /absolute/path/to/current/codex \
  --expected-starting-version 0.160.1 \
  --expected-upgraded-version 0.162.1 \
  --auth-file /absolute/private/existing-codex-auth.json \
  --model AUTHORIZED_TEST_MODEL \
  --output .build/acceptance/codex-upgrade.json \
  --private-control .build/acceptance/codex-upgrade-private.json
```

Use fresh output paths and two actual, different executables. Versions are probed;
the runner never simulates them or rewrites encrypted preferences. It copies
authentication into a new private `CODEX_HOME`, installs production hooks there,
and uses only fake fixture content. Personal configuration and trust files remain
untouched. Each CLI records its own runtime identity privately; each actual
producer version must contribute seven appearances across all five content types.

Add `--preserve-user-state` to exercise retained user decisions through the same
genuine executable upgrade. Before changing readers, the signed app reviews two
distinct original appearances as confirmed and false positive, marks its one
existing notification decision delivered in storage, and acknowledges the fake
value as revoked while retaining its content. Delivery is explicitly seeded;
system notification presentation is suppressed in this mode.

All complete inventory record commitments must remain equal during the upgrade,
queued-work restart and second worker startup. The newer genuine producer must
then add seven obsolete, unreviewed appearances without another alert. Original
reviews, revocation, receipt delivery, source records and labels remain unchanged.
The value record may advance its last-occurrence timestamp only; a separate
commitment protects every other field, and both timestamps must match the actual
occurrences. Normal no-turn resume and both selected-source poll replays must
preserve the complete resulting state. These are incremental poll replays, not a
claim of another full source reread or detector scan.

Run a separate fresh fixture with both `--preserve-user-state` and
`--remove-content-before-upgrade` to check deleted content. After the same review
and stored delivery preparation, normal revocation and removal must leave zero
values, occurrences and protected payload rows, with seven removed-location
receipts. That exact state must survive the genuine reader upgrade and saved
profile restart. The new producer must then add one metadata-only value record
and seven obsolete appearances, with no protected values, excerpts or new alerts.
The original seven removed-location receipts and all original analysis/source
receipts must remain unchanged. Removal intentionally deletes occurrence reviews
and live alerts; a settled historical delivery receipt remains if that was the
seeded kind.

The deleted-content variant measures new producer identity and all five content
types from actual public native batches joined to committed current-detector
receipts. It never assigns producer versions from the command-line expectation
or treats zero ordinary occurrences as evidence of new-source collection. Its
transient source witness is separate from durable inventory commitments, so a
cold restart cannot pass by rewriting stored evidence. These flags do not
establish legacy app-schema migration, desktop/T3 upgrade support or macOS
notification presentation. Both variants require their own signed passing run.

Vault readiness is checked before copying authentication or starting either
provider. The runner pins its helper libraries and manifest as well as the app,
fixture and provider binaries, and verifies the original authentication file
remains unchanged. Boundary checks run without an app or provider:

```sh
python3 -m unittest discover -s Tests/AppAcceptance -p 'test_codex_upgrade*boundary.py'
```

While `run` is active, inspect or operate its fixed controls with:

```sh
python3 Tests/AppAcceptance/run-app-codex-upgrade.py control \
  --private-control .build/acceptance/codex-upgrade-private.json \
  --action state
```

For `producerStage=starting`, follow the observed normal folder/hook review:
`review`, `trust`, then wait for `postTrustDetailsObserved`. Close the menu with
`escape`, send `verify` and a separate `enter`, and wait for `setupConnected`.
Send `fixture`, `enter`; after `fixtureCollected`, send `quit`, `enter`. Only
confirm a folder prompt when it is actually observed. For `producerStage=upgraded`,
open `hooks`, `enter`; wait for `upgradedTrustedHookMenuObserved`, close with
`escape`, then use `fixture`, `enter`, and eventually `quit`, `enter`. If normal
hook review is required again, complete the observed review controls first.
The upgraded stage rejects another `verify`, preserving the original connection
proof. Never substitute blind keys or direct trust-file writes for an observed UI.

The three signed workers have separate gates:

1. The first installs and verifies the profile, collects the older fixture, then
   pauses processing with exactly one encrypted, unclaimed synthetic poll pending.
   Retargeting its owned executable symlink must update production setup while
   preserving that capture, registration, proof, inventory, receipts and alerts.
2. The second restores the saved profile without reinstalling or applying
   collection overrides. It must consume **and successfully process** the exact
   pending capture. Its original admission reader version remains `0.160.1`;
   independent successful-read evidence must attest the actual `0.162.1` reader.
3. The third collects the genuine upgraded fixture and checks new admissions use
   the upgraded version. Replaying both owned sources must add no occurrences,
   receipts or alerts, and the original producer metadata must remain intact.

An automatic bounded CLI check resumes the exact older owned session with no
prompt argument or model turn, requires its controlled history markers and exact
resume identity, then quits normally. This establishes CLI history resume only;
it does not establish Spillcheck's source-opening UI. The queued poll is synthetic
admission, not evidence of provider pending-hook dispatch. A pass makes no full
Codex, desktop, T3, native-child, schema/checkpoint migration, or crash-recovery
claim.

Cleanup stops owned processes and removes temporary authentication and registration
before authorizing only the original vault creator to delete its keys. Failures
retain the exact private cleanup handoff; `ownedProtectionCleanupPending` remains
distinct from retained diagnostics. Reports contain no raw terminal content or
native session IDs. Boundary tests launch no provider, app, or Keychain operation:

```sh
python3 -m unittest discover -s Tests/AppAcceptance -p 'test_codex_upgrade_boundary.py'
```

Keep a synthetic inventory open for manual native review and viewing checks:

```sh
python3 Tests/AppAcceptance/run-app-workflow.py \
  --ready .build/acceptance/workflow-ready.json \
  --output .build/acceptance/workflow.json \
  --duration 3600
```

`--app` selects the signed bundle, and `--duration` bounds the run to 30 through 7200 seconds. The private ready file identifies the disposable source, app report, and process. Viewing uses real macOS authentication. Complete authentication in the system prompt and quit the app normally to finish cleanup. The report checks termination and cleanup; manual workflow outcomes require separate review.

`workflowStateObservations` retains at most 512 changed states for the exact
test process: authorized/visible booleans, revealed-content counts, fixed viewing
and masking event counters, and elapsed time. It records no revealed values or
source metadata. App-report reads are bounded to 256 KiB regular owned files;
unknown fields/events are never copied. Captured observations survive a later
finalization failure. Sampling and cumulative counters do not automatically
establish manual acceptance: verify a revealed state before each action, then
zero revealed counts and the corresponding mask-event increment afterward.
An exhausted sample budget remains explicit. Keep the normal 300-second
inactivity timeout; use another app without interacting with Spillcheck while
waiting. Authenticate only in macOS and quit the disposable app normally.

The drivers create separate production Keychain items for their disposable vaults. `Tests/Support/acceptance_artifacts.py` removes each owned directory after the test passes and the app confirms vault cleanup. Failed runs retain their exact vault and manifest for diagnosis. Use `--help` to inspect options without launching an app.

Run genuine disposable Claude CLI sessions through owned hooks into the signed app:

```sh
python3 Tests/AppAcceptance/run-app-claude-live.py \
  --app /absolute/current/Spillcheck.app \
  --candidate-manifest /absolute/current/candidate-build.json \
  --expected-bundle-sha256 CURRENT_BUNDLE_SHA256 \
  --executable /absolute/path/to/claude --expected-version 2.1.295 \
  --configuration-executable /absolute/current/spillcheck-storage-acceptance \
  --output .build/acceptance/app-claude-live.json
```

Build the current `spillcheck-storage-acceptance` SwiftPM product first. Its `--claude-configure-hook` mode uses production owned-hook editing to configure only the disposable provider settings. The signed app receives genuine prompts, responses, successful shell/MCP output, errors, and native child content through its bundled helper. The driver checks original provider markers, committed required content types, canonical replay through overlapping CLI/T3 routes, encrypted storage, and controlled shutdown. It records actual executable and producer versions. `--expected-version` is an optional acceptance assertion, not product eligibility.

The paired candidate options bind the manifest bytes, recorded source inputs,
signed bundle and executable before and after the run. Both options must be given
together. Unpinned legacy invocations remain available but explicitly cannot claim
current-candidate acceptance. These checks do not establish complete compiler-input
provenance or the expected signing identity. Every output path must be fresh.

The app's explicit `--acceptance-finish-file` sentinel ends the held run through normal queue drain and termination. Provider authentication and the owned registration are removed on failure as well as success. An unavailable production vault leaves its exact manifest and private diagnostic report for guarded cleanup. A successful ingestion report does not establish saved setup verification, restart or upgrade recovery, simultaneous GUI sessions, or source opening. The genuine core Claude runner measures the durable setup challenge separately.

Failed signed Claude runs retain their original fake provider sources under the private disposable `claude/projects` directory, even when owned vault key cleanup succeeded. Cleanup removes all sibling Claude configuration and authentication material, including refreshed credentials. It never follows a substituted configuration or `projects` symlink. Failure to remove authentication fails acceptance. The private retained-directory handoff and report remain alongside the owned vault artifacts; use a fresh output for each retry. A passing run with confirmed vault cleanup still removes the entire disposable root. Check these boundaries without launching a provider or using Keychain with `python3 Tests/AppAcceptance/test_claude_live_boundary.py`.

The live runner also accepts `--historical-producer-executable` and `--expected-historical-version`. It creates one genuine older full-content session before the signed app starts, using the same disposable provider home. All live runs use the current executable. This mode alone adds the explicit acceptance history-request flag and delivers the existing frozen seven-day request through the signed helper. It requires all five committed content types for each actual producer version, unchanged older native identities and bytes, stable executable versions, and the ordinary child, replay, encryption, and cleanup checks. An older GUI-bundled executable invoked as CLI does not prove the GUI host route.

Run the constructed signed regression for a selected parent and its own child with
a distinct native session UUID, without launching Claude or copying authentication:

```sh
python3 Tests/AppAcceptance/run-app-claude-child-fixture.py \
  --app /absolute/current/Spillcheck.app \
  --candidate-manifest /absolute/current/candidate-build.json \
  --expected-bundle-sha256 CURRENT_BUNDLE_SHA256 \
  --output .build/acceptance/app-claude-child-fixture.json
```

The fresh fixture contains twelve typed markers, two native sessions and five
child occurrences. The runner selects only the parent, requires strict committed
parent/own-child evidence, then replays the unchanged original files across
CLI/T3 metadata. Exact counts, an empty queue, no gaps, encrypted storage and normal
creator cleanup must pass. Candidate binding is mandatory. Reports explicitly mark
the fixture as constructed and never claim genuine provider or host acceptance.
Failed runs retain their exact private source/vault handoff. Check its pure
boundaries with `python3 -m unittest discover -s Tests/AppAcceptance -p 'test_claude_child_fixture_boundary.py'`.

For a fresh attended Claude Desktop Local Code conversation, follow
[Desktop ordinary-hook acceptance](CLAUDE_DESKTOP_HOOKS.md). Its collector starts
without a preselected source or profile catch-up, so an ordinary Desktop hook
must discover the session before main/native-child collection can pass.

For simultaneous genuine CLI, Desktop and T3 sessions sharing one unprimed
collector, follow [Concurrent Claude hosts](CLAUDE_CONCURRENT_HOOKS.md). The
coordinator requires three runtime bindings, overlapping native publication,
staged receipt-backed parent/child completion, and owned configuration cleanup.

Observe an original native source created by a genuine owned T3 Claude child:

```sh
python3 Tests/AppAcceptance/run-app-claude-selected.py \
  --manifest /absolute/private/owned-native-manifest.json \
  --ready /absolute/private/collector-ready.json \
  --producer-done /absolute/private/producer-finished \
  --output .build/acceptance/app-claude-selected.json
```

The producer writes its own runtime native session and original transcript mapping to the private manifest, then waits for the collector-ready sentinel before creating the remaining content. The observer launches no provider and edits no hooks. It requires a complete owned prompt under the exact native identity before selection. After producer completion, it requires all five types separately in one exact parent and one own native child, with seven parent markers (including shell/MCP success and errors) and five child markers. The strict Debug app evidence requires the exact analyzed revision receipt and matching fake-value occurrence, type, and time. Neither missing types pooled across children nor an older prompt/final-only fixture can pass. The selected producer must provide one complete committed pair and one independently verified original-native pair. The observer replays only the exact parent and own child files across CLI/T3 metadata. Two positive occurrence-count samples before producer completion establish live growth. A child may share its parent's native session field; the observer preserves that identity. The app receives explicit `t3` and `standalone-cli` host authorization for this overlap check, with its active source still tagged `t3` and profile catch-up disabled. Native child discovery needs no extra host authorization beyond that selected route.

These stricter selected-source gates have synthetic boundary coverage only until a fresh genuine T3 fixture produces all twelve markers. Earlier T3 reports remain historical evidence for their narrower scope. Run `python3 Tests/AppAcceptance/test_claude_selected_boundary.py` to check the gate without launching an app, provider, or authentication prompt.

The reusable evidence reader in `Tests/Support/claude_native_evidence.py` checks source ownership, type, required fields, and complete framing. It reads only explicit parents and each parent's own `subagents` directory, with at most 32 children per parent, 64 files total, two MiB per file, and sixteen MiB total. The selected observer does not discover sibling conversations. Fresh disposable homes in the live runner use bounded native parent discovery. Reports contain counts, marker labels, versions, and controlled limitations; private replay inputs retain actual paths and native IDs. Constructed boundary checks run with `python3 Tests/Support/test_claude_native_evidence.py` and do not establish provider acceptance.

Run a genuine signed Claude CLI upgrade and restart against one fresh owned vault:

```sh
python3 Tests/AppAcceptance/run-app-claude-recovery.py \
  --app /absolute/current/Spillcheck.app \
  --candidate-manifest /absolute/current/candidate-build.json \
  --expected-bundle-sha256 CURRENT_BUNDLE_SHA256 \
  --starting-executable /absolute/older/claude \
  --expected-starting-version OLDER_ACTUAL_VERSION \
  --upgraded-executable /absolute/current/claude \
  --expected-upgraded-version CURRENT_ACTUAL_VERSION \
  --configuration-executable /absolute/current/spillcheck-storage-acceptance \
  --output .build/acceptance/app-claude-recovery.json
```

The default expected producers are 2.1.293 and 2.1.295; the two `--expected-*-version` options change these acceptance assertions. The runner independently probes both executables. It installs and verifies a saved production profile in its private home, retargets only its own executable symlink, and restarts the signed collector with unclaimed encrypted work pending. Each exact pending capture must appear in the new worker's successful completion callbacks and durable consumed receipts. A fresh history audit or an expired capture receipt cannot satisfy that gate. Private keyed comparisons check inventory, source receipts, alert identities, registration, proof, manifest, and loaded checkpoint identities. They do not assert unchanged checkpoint offsets or adapter state.

A separate signed vault owner retains the original fresh-key cleanup authority while collector processes restart. Only that original creator removes its keys after collectors exit and the exact owned registration is removed. Loaded manifests cannot acquire cleanup authority. Add `--owner-smoke` for the short lifetime check without provider calls, copied authentication, or hook installation. Reports distinguish retained diagnostic artifacts from pending protection cleanup.

Current recovery also requires all twelve committed markers in one exact native
parent/own-child pair for each producer. A separate DEBUG flag admits this
measurement only inside the token-bound disposable recovery home, with the exact
saved Claude profile and existing creator-owned vault. After ordinary pending-work
recovery, the runner sends one bounded production retry request per original native
file, with no directory discovery and unchanged session identities. The new
worker must observe the complete pairs against their original full detector
receipts and typed occurrences. This forced reread must preserve occurrence,
receipt and alert identities; a counts-only prompt/final child report cannot pass.

Creator cleanup also requires confirmed provider/collector group cleanup and
removal of temporary authentication before its finish token is written. Failures
retain original fake sources under `claude/projects`, plus the exact private vault
handoff. Only sibling authentication/configuration material is removed.
Candidate pinning applies to fixed-bundle runs and is
rejected with rebuild mode, which changes the selected bundle.

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
stop their owned process group and retain private diagnostics. This mode tests
one Claude CLI profile. Other host/provider migrations and review/obsolete-state
recovery remain separate gates.

For the deferred schema 1→3 gate, add `--expected-starting-schema 1` together with
`--rebuild-app-between-workers`. This requires an actual verified schema-1 signed
baseline at the same fixed bundle path before starting. The runner never rewrites
or downgrades an encrypted preference to manufacture that baseline. Its restarted
worker must measure loaded schema **1** and saved schema **3**; observing 2→3
cannot satisfy the selected gate. The default remains schema 2, and explicitly
supplying either starting schema without rebuild mode is rejected before launching
anything. The original creator, signing bindings, fixed rebuild target, source
freeze, queue recovery, content, and cleanup requirements remain unchanged.

Reports distinguish `signedAppSchema1To3MigrationEstablished` from the existing
`signedAppSchema2To3MigrationEstablished`; at most the selected claim can be true,
and only after the complete signed run passes with the matching measured schemas.
Preparing this option and passing its boundary tests does **not** establish a
signed 1→3 migration. Device-key access and a verified schema-1 baseline are still
required. Review/obsolete-state preservation and failure/restoration remain
separate unestablished gates.

`python3 Tests/AppAcceptance/test_claude_recovery_boundary.py` checks the fixed build
target, strict measured schema predicates, option admission, schema-specific report
claims, and source-freeze detection without
launching providers, apps, builds, or vaults.

Migration from unpublished Codex development builds is outside the first-beta
gate under [ADR 0007](../../docs/adr/0007-codex-beta-scope.md). Direct
schema/profile/storage regressions still cover the production migration code.

## Signed native content

The native-content runner verifies full scanner receipts, cold restoration and
a forced exact-source reread for a Plan, MCP result, Stop-hook continuation or
local-image input with accompanying text.
Build the current signed app and Swift tests first. Each fixture requires fresh
output paths and a separate disposable vault:

```sh
python3 Tests/AppAcceptance/run-app-codex-native-content.py \
  --fixture mcp \
  --app /absolute/current/Spillcheck.app \
  --candidate-manifest /absolute/current/candidate-build.json \
  --expected-bundle-sha256 CURRENT_BUNDLE_SHA256 \
  --executable /absolute/codex --expected-version 0.162.1 \
  --model gpt-6-astra --auth-file /absolute/authorized/auth.json \
  --output .build/acceptance/native-mcp-report.json \
  --private-control .build/acceptance/native-mcp-control.json
```

Use `--fixture plan` for the Plan example above. Use `--fixture hook-prompt`
with distinct fresh report/control paths and
`--scratch-path /absolute/compiled/SwiftPM/scratch` for the hook run. It uses the
CLI's normal review of one owned Stop hook; trust files are not prewritten. Its
private native descriptor is exported only after two exact-owned passive reads
and confirmed shutdown. Callback metadata cannot supply native item identity.

Use `--fixture local-image` for the fake local-image case, with the same compiled
Swift scratch path. The old `run-app-codex-local-media.py` command forwards here.
The real producer supplies one user item containing text and an image reference.
After producer shutdown, the runner removes authentication and verifies and removes
the owned image. Passive reads bind the original native item before signed reads.
The shared witness requires the exact text receipt and the specific excluded-image
record to survive cold restart and replay. Missing images never become a general
permission to ignore other warnings. Image bytes are not scanned.

The original vault creator must report ready before authentication is copied or
a provider starts. Independent MCP/Stop-callback processes and descriptor readers
must stop before credential or vault cleanup. A blocked owner prevents provider
work. This runner creates no personal profile, reads no personal history and
does not establish desktop/T3 support or a second detector scan.

Pure boundaries, with no app, provider or Keychain access:

```sh
python3 -m unittest discover -s Tests/AppAcceptance -p test_codex_native_content_boundary.py -v
```

## Constructed Claude inventory persistence

`run-app-claude-inventory-state.py` uses one fixed fake Claude 2.1.296 transcript:
seven appearances across all five content types. The signed app admits its exact
private path, session, profile and SHA-256 before collection. No provider runs,
authentication or settings are copied, personal sources are read, or system
notifications are delivered.

The original fresh-vault owner remains responsible for cleanup. Three loaded
workers collect and review two appearances, seed a **stored** delivery receipt,
restart and replay the exact source, revoke and remove content, then restart and
replay once more. Full keyed domain values, source identities, completed work and
positive read bytes must agree; counters alone cannot pass. The fixed source
binding remains available after content removal. Claude polling is inhibited for
these workers so the admitted audit and replay must supply their own receipts.

Run against a newly built immutable Debug candidate containing the Claude
inventory controls. Both report parents must already exist; the output parent
must be outside system temporary directories for the private diagnostic journal.

```sh
python3 Tests/AppAcceptance/run-app-claude-inventory-state.py \
  --app /absolute/current/Spillcheck.app \
  --candidate-manifest /absolute/current/candidate-build.json \
  --expected-bundle-sha256 CURRENT_BUNDLE_SHA256 \
  --output /absolute/private-results/claude-inventory-report.json \
  --private-control /absolute/private-results/claude-inventory-control.json
```

A passing result establishes constructed signed inventory behavior. Genuine
CLI/Desktop/T3 collection, source opening, subagents, side questions, notification
banners, provider upgrades and crash recovery require their separate evidence.
Failure diagnostics survive reboot and identify exact owned material; they do
not authorize loaded workers or future processes to delete protection keys.

Offline boundaries (no app, provider or Keychain access):

```sh
python3 -m unittest discover -s Tests/AppAcceptance -p test_claude_inventory_state_boundary.py -v
```
