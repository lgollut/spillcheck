# Durable scoped recovery checks

Measured October 9, 2026. The first checks use synthetic native-source fixtures
and ephemeral test cryptography to establish storage and pipeline behavior. The
signed trial below separately establishes genuine Claude CLI upgrade and process
restart. GUI recovery and system health notification delivery remain unestablished.

The final focused command was:

```sh
swift test --filter CoverageRecoveryTests
```

All nine tests passed in one suite. An earlier recovery, pipeline, and capture
run passed 21 tests in three suites, including the seven recovery cases present
at that point. A prior focused storage, workflow, capture, and recovery run
passed 31 tests.

The first complete 275-test run found two exact timestamp comparisons in the
re-failure fixture that differed by about 0.12 microseconds after SQLite's Unix
epoch conversion. The fixture now permits less than one microsecond while still
rejecting renewal to the failure observed 24 hours later. No product code changed.
The nine focused recovery tests passed again after this correction; the complete
suite rerun is tracked in the measured matrix.

## What the fixtures establish

- Older encrypted gap records decode without invented scope, recovery state, or
  confirmed format failure.
- A failed completion transaction leaves its queue entry, source checkpoint,
  omission records, and health incidents unchanged.
- Omission references remain separate from processed-source receipts. Replaying
  one omitted native item does not create another omission or another active
  health incident.
- An unrelated readable sibling cannot resolve an omission. Resolving one item
  leaves another omitted item in the same scope visible. A partially readable
  record cannot resolve its unread block.
- A complete successful reparse of a transcript position can recover a malformed
  record whose native session identity was initially unavailable. Native public
  history items still require their canonical session and item identity.
- Delivery receipts and incident identities survive a separate store lifetime.
  Resolving an incident sends no recovery notification. A subsequent confirmed
  incident receives a new identity.
- A demonstrated failure at a previously recovered native position reopens that
  omission with its original identity and source age. The old delivered incident
  remains resolved, and the new incident receives one notification. Parser
  generation changes and elapsed time alone do not reopen omissions.
- Required operation failures have separate live, history, and hook identities.
  Notifications name the controlled provider, host, and operation labels. A fresh
  successful assessment resolves only the exact route's operation incident when
  it requires assessment and has no unresolved native omissions. Content failures,
  other hosts, and other operations remain visible. An incident with both route
  and native failures requires both an exact successful reparse and a working
  operation assessment.
- Older encrypted content-only incidents retain their original keyed identity
  and delivered receipt when decoded with the new optional operation field.
  Reobserving the same failure after restart produces no duplicate notification.
- An unfamiliar version and intentionally unsupported content create no health
  notification. A confirmed required-content failure produces masked text without
  profile, session, item, or source-content strings.
- A two-day-old unresolved omission remains visible after the short activity-gap
  query stops returning it. Passing the seven-day recovery boundary marks it
  unrecoverable; elapsed time never marks it recovered.
- Expired captures and exhausted retries retain encrypted loss metadata. Validated
  transport metadata supplies provider, profile, and host attribution. Event
  content is discarded, and a native source mapping is not invented. Synthetic
  profile and content markers were absent from the database and WAL bytes.

The existing pipeline checks also passed replay suppression, all five content
types, historical versus live attribution, partial scanner retry, pause and
deletion races, retained-excerpt masking, and obsolete-value behavior.

## Signed disposable vault lifetime

The separate [startup artifact followup](app-claude-harness-compatibility-startup-artifact-followup-2026-10-09.json)
clarifies two earlier queue-key startup failures with code `-25308`. The exact retry
root retains private diagnostics but contains no configured protected-store
directory or database. The first root is unavailable, so its artifact and ownership
gate remains unverified. The historical `cleanupPending` field does not establish
a retained vault, manifest, or remaining Keychain item. No Keychain query, mutation,
or broad filesystem search occurred. The fresh queue-add failure precedes successful
key creation flags and store initialization in the code; actual Keychain item
absence and the cause of those historical failures remain unverified.

The [signed owner trial](app-claude-harness-compatibility-recovery-owner-2026-10-09.json)
passed seven lifetime checks on October 9. A separate signed process created a
fresh vault, closed its store, and retained the original key-cleanup authority.
A signed collector loaded that existing manifest and exited normally before the
original creator removed its own keys. No provider session, authentication copy,
or hook installation occurred. Inventory, queue, alerts, and gaps remained empty.

The first [genuine recovery attempt](app-claude-harness-compatibility-recovery-startup-2026-10-09.json)
stopped before any provider call: the private DEBUG installer omitted the version
required by the production draft guard. Exact creator cleanup, registration
cleanup, authentication removal, and owned process teardown passed. Its retained
diagnostics do not represent pending protection cleanup. The private installer
now receives the runner's observed version; production setup independently probes
the executable again. Four guard and queue tests pass, including private home ownership,
symlink rejection, observed-version input, and refusal to create an owner over an
existing encrypted manifest. No product eligibility or loaded-key cleanup guard
was weakened.

The queue fixture keeps one exact capture identity through separate store
lifetimes, rejects a failed atomic completion, and observes successful completion
only after its retry commits. Expiry can create a consumed-capture receipt, so
the signed runner requires both the durable receipt and the new worker's successful
processing callback for every pre-restart pending identity. A fresh historical
audit cannot satisfy this check. Private reports use keyed identity digests;
published reports contain only comparison results and controlled counts. The
checkpoint check proves persisted checkpoint identities were loaded. It does not
assert unchanged byte offsets or adapter-state values.

`Tests/AppAcceptance/run-app-claude-recovery.py --owner-smoke` repeats the short
lifetime trial. Its full mode passed all 22 explicit gates in the
[genuine signed recovery report](app-claude-harness-compatibility-recovery-2026-10-09.json).

The runner installed and verified a production owned profile in a fresh private
Claude home. Genuine sessions used independently observed producers 2.1.293 and
2.1.295. Retargeting only the run's selected executable symlink triggered the
production upgrade assessment and a fresh historical audit. Saved registration
and encrypted connection proof remained unchanged. Both producers committed all
five required content types plus native-child prompts and final responses. Native
inspection found all nine typed markers for each producer, with complete framing
and valid native fields.

A DEBUG control then stopped only processing and polling, leaving encrypted
admission operating in the owned vault. Another genuine session created unclaimed
pending work. The first collector exited normally with those entries retained;
a new signed process loaded the same manifest, profile, registration, and proof.
Every pre-exit pending identity appeared in both its durable consumed receipts
and the fresh worker's successful completion callbacks. The automatic restart
audit also settled. The original native source identities and bytes remained
unchanged. Keyed comparisons retained prior occurrences, source-analysis receipts,
and alert identities. Persisted live and history checkpoint identities were loaded;
unchanged offsets or adapter-state values were not asserted.

Final inventory contained one synthetic value, 37 occurrences across three native
sessions containing that value, and all five types for each producer. Three historical
audits were settled, with zero unread progress, queued captures, or coverage gaps.
Replaying the exact parents and their own child files through overlapping CLI/T3
metadata added no occurrences, source receipts, or alerts. This replay establishes
duplicate suppression; it is not a genuine concurrent T3 host run. Marker bytes
were absent from the encrypted store files. Owned processes stopped, the exact
owned hook registration and temporary authentication were removed, and the original
fresh creator removed its keys. Diagnostics were not retained and protection
cleanup is complete.

Notifications were Off: all three ordinary alerts recorded `permissionDenied`.
No actual health notification delivery was established. Signed review and obsolete
state recovery, recovery after a demonstrated required-format failure, and upgrade
or restart in other hosts still need separate acceptance. The full compatibility
plan remains incomplete. The definitive build used for this run passed strict
signature verification and all 283 tests in 34 suites. Production Swift source
hashes matched before and after that build; no Swift files changed during the run.

The later [signed schema-migration preflight](app-claude-harness-compatibility-schema-migration-preflight-2026-10-09.json)
stopped at the existing-app admission guard. A separate Spillcheck instance was
already running in another checkout. No creator, collector, provider, or build
launched, and no protection creation was attempted. Private diagnostics remain
retained. Its operator then closed that app; no forced termination or product fix
resolved the guard.

The resumed [genuine signed schema-migration trial](app-claude-harness-compatibility-schema-migration-2026-10-09.json)
passed all 28 gates. It repeated the original 22 genuine Claude recovery checks and
added six app-build and migration checks. The first collector installed and verified
one Claude profile in the old signed app, upgraded its owned executable from 2.1.293
to 2.1.295, and exited with encrypted captures pending. Its fresh vault creator
remained alive in a separately copied, verified old signed bundle. The runner then
built the fixed repository Debug bundle in 14.774 seconds and launched the new
collector at the original app and helper paths. App/helper designated requirements,
entitlements, and the Keychain access group matched. All 63 frozen source/build
inputs remained unchanged, including 57 production Swift files and `Package.swift`.

The new collector measured decrypted loaded profile schema 2 and read-back persisted
schema 3. The saved setup proof, registration, manifest, inventory, receipts, alert
identities, and native identities survived. Every pre-exit pending capture was
successfully processed by the new worker with its matching durable receipt. All
five types and native-child prompt/final content were committed for both genuine
producers. Final inventory again held one value and 37 occurrences across three
value-bearing native sessions. Three audits settled with zero unread progress,
queued captures, or gaps. Replay, native source byte comparisons, encrypted marker
inspection, exact creator key cleanup, registration removal, authentication removal,
process teardown, and private artifact removal passed.

This time the app recorded notification permission Allowed and three ordinary
alerts as delivered. The trial created no required-operation or format incident,
so actual scoped health notification acceptance remains open. Checkpoint comparisons
still establish identity loading only. This run migrates one saved Claude CLI
profile; other hosts/providers, review and obsolete-state recovery, and restoration
after a demonstrated required-format failure remain unestablished.

Three constructed checks passed for its fixed target, strict measured schema
predicate, and source-freeze detection before the genuine run. The isolated app
migration fixtures separately covered both legacy schemas, both providers, both
transports, preserved proof/registration fields, and the decrypted pending capture
body. They remain synthetic checks.

## Remaining acceptance gates

The following still require genuine provider runs and signed-app acceptance:

- Extend the measured Claude CLI upgrade and restart to Codex and the required
  T3/GUI hosts. Establish signed review and obsolete-state preservation alongside
  inventory, registrations, native identities, checkpoint recovery, and alert suppression.
- Extend the measured signed schema-2-to-3 migration beyond one saved Claude CLI
  profile. Other provider/host and signed review/obsolete-state preservation remain
  unestablished.
- Restore a compatible executable after a demonstrated operation or format
  failure and recover eligible omissions from available original history.
- Keep another host of the same provider collecting while one host upgrades or
  fails. Verify all six required local host/provider combinations concurrently.
- Confirm complete required-content coverage in GUI-created sessions, including
  native children and any required live-only content.
- Deliver one actual masked macOS health notification for a scoped required-format
  or operation failure, retain suppression across restart, and leave unaffected
  routes working.

The [compatibility plan](../HARNESS_COMPATIBILITY_PLAN.md) and
[measured matrix](supported-matrix.md) retain the authoritative gate status.
