# Harness compatibility implementation and open gates

Implementation started with the user's explicit authorization on October 9, 2026.
The [plan](../HARNESS_COMPATIBILITY_PLAN.md) remains incomplete. Phase 0 now has
genuine manually operated sessions in both official local GUIs. Claude's main
source passed encrypted live collection and settled original-source catch-up;
its side-chat authority remains open. Codex's repaired live reader passes parent
content and four child content types, but the exact child prompt fixture remains
unexecuted. Independent CLI/T3 compatibility, recovery and evidence
work continued. No production GUI setup authorization or enabled Desktop collector
is claimed before that gate passes.

## Measured results

- Genuine Claude CLI executable/producer 2.1.295 passed all nine typed markers,
  all five required types, native child content, durable owned-hook verification,
  stable replay, empty queue, encrypted marker inspection and owned cleanup.
  It committed 20 occurrences across two canonical sessions. Unknown native
  envelope records still produced `unsupportedContent`.
  [Claude evidence](harness-compatibility-claude.md)
- Genuine mixed original history from 2.1.293 and live CLI content from 2.1.295
  passed all required markers from both producers: 38 occurrences, three canonical
  sessions, stable original native IDs/content, replay, queue, encryption and
  cleanup. The old bundled producer was invoked as CLI, which does not establish
  a GUI collection route. This earlier run had `captureRejected` and
  `unsupportedContent`; neither source commitment nor its empty queue proved
  frozen-audit settlement. [Earlier mixed history](claude-harness-compatibility-mixed-history-2026-10-09.json)
- Genuine Codex CLI producer/reader 0.161.0 passed separate catch-up and active
  selected-thread observation through the production passive client. All five
  required types and the child's own final passed; 14 occurrences across two
  sessions, zero gaps, unique native locations, stable replay, empty queue and
  encrypted inspection. These runs do not prove an owned native hook challenge,
  current T3, GUI collection or signed concurrent operation.
  [Codex evidence](harness-compatibility-codex.md)
- Claude GUI 2.31226.0 used embedded producer 2.1.293 in a directly created local
  session. The manual main fixture delivered owned hooks, committed all five
  types and seven typed markers including native child prompt/final, and passed
  encrypted inspection and replay: 15 occurrences, seven live source revisions,
  queue empty. The original cold probe committed content but failed frozen-audit
  completion before the admission fix. A separate fresh encrypted catch-up store
  using parser contract 4 now passes all five types, child prompt/final, one
  settled audit, zero gaps, empty queue and replay. Original sources are unchanged.
  This does not measure omission recovery in a prior store. Side-chat markers were absent from the
  native transcript and the display/prompt hook fields inspected then; a focused
  `SubagentStop` measurement also found no side-chat events or markers in these
  inspected routes. Registration removal passed; the earlier settings-preservation
  comparison is false, with no retained snapshot establishing its cause.
  Native control still times out; manual operation supplied this evidence.
  [Main live report](claude-gui-harness-compatibility-main-2026-10-09.json),
  [focused side report](claude-gui-harness-compatibility-side-2026-10-09.json),
  [settled catch-up](claude-gui-harness-compatibility-catchup-2026-10-09.json).
  The focused run preserved current settings. Nine `agent-name`/`custom-title`
  envelopes were narrowly recognized as non-message metadata; content-bearing
  or unknown records continue to gap.
- A documented passive Claude Mod candidate passed static validation in the
  actual embedded 2.1.293 executable. In the genuine GUI trial, visible main
  prompt/final markers were present in the native transcript, but the observer
  received only one startup callback. Its main-content positive control failed,
  so no side API absence or canonical side authority is established. Exact owned
  plugin, marketplace, private directory and matching cache removal passed;
  the user confirmed `/reload-plugins` after removal. Runtime unloading was
  operator-confirmed. [Mod trial and cleanup](claude-gui-mod-harness-compatibility-2026-10-09.json)
- Codex GUI `com.openai.codex` has bundle version 26.930.61225 and genuine local
  producer 0.160.1. The authorized original store and exact parent/child native
  relationship were verified with reader 0.161.0. The observer crashed after
  parent admission because its compiled Core module and linked library differed.
  A matched rebuild imported all five parent types through exact-source catch-up.
  Bounded reader shutdown now passes. The original child stopped after the
  collector failure and has no required child markers in either its exact public
  source or bounded original rollout inspection. A new matched live R3 run
  committed all five parent types and child intermediate/final/tool output/tool
  error: 14 occurrences across two native sessions. Queue, replay, bounded
  exact-source replay, encryption and both reader shutdowns passed with zero gaps.
  Catch-up passes only for the observed partial content, not the full required-content gate. The
  parent's actual spawn omitted the requested child prompt marker; this is
  fixture noncompliance, not evidence that the provider cannot expose it.
  The corrected two-turn R4 fixture stopped after parent steps and child
  bootstrap because native `send_input` was unavailable. Its child content test
  was never submitted. No further manual retry or provider turn was started.
  Native control is explicitly denied; the user operated the disposable session
  manually, with no alternate automation bypass.
  [Native partial report](harness-compatibility-codex-gui-native-partial-2026-10-09.json),
  [exact child diagnostic](harness-compatibility-codex-gui-native-child-source-2026-10-09.json),
  [R3 live result](harness-compatibility-codex-gui-live-r3-2026-10-09.json),
  [R4 unavailable-step result](harness-compatibility-codex-gui-live-r4-2026-10-09.json),
  [R4 original/public comparison](harness-compatibility-codex-gui-spawn-prompt-contract-r4-2026-10-09.json),
  [child prompt research](codex-gui-child-prompt-source-research-2026-10-09.md).
- The first signed genuine Claude attempts failed before provider launch with
  `key-unavailable-queue--25308`. The scoped vault remains guarded for later
  cleanup; provider authentication and owned hook registration were removed.
  [Preserved failure](app-claude-harness-compatibility-startup-2026-10-09.json)
- A subsequent unchanged direct-binary launch passed fresh device-key startup
  and five-content synthetic ingestion. The unchanged signed genuine Claude
  2.1.295 run then passed all nine typed markers, all five types, native child
  prompt/final commitment, stable CLI/T3 replay, empty queue, encrypted marker
  inspection and scoped key/registration/authentication cleanup: 20 occurrences
  across two sessions. The earlier intermittent `-25308` cause remains unknown.
  `unsupportedContent` remains disclosed. Notifications were Off; two decisions
  were `permissionDenied`, so no OS banner is established.
  [Current startup](app-harness-compatibility-startup-current-2026-10-09.json),
  [signed genuine collection](app-claude-harness-compatibility-live-2026-10-09.json)
- The corrected signed mixed run passes positive committed counts for all five
  types of each producer, 2.1.293 and 2.1.295, and all nine native markers each:
  38 occurrences across three canonical sessions and six child occurrences.
  One frozen historical audit settled with no unread progress, an empty queue
  and zero gaps. Older native identities/source bytes, replay, encryption and
  owned cleanup passed. The earlier signed mixed report is retained separately.
  [Settled signed mixed report](app-claude-harness-compatibility-mixed-history-settled-2026-10-09.json)
  The regression reproduces the prior rejection: the test receiver had omitted
  the audit binding required by the encrypted queue. Correcting admission leaves
  the production store check intact. Seven native non-message metadata envelopes
  are skipped only when message/content are absent; unknown content still gaps.
  [Diagnosis and regression](claude-harness-compatibility-gap-localization.md)

The final regression summary and signed retry are recorded in
[verification](harness-compatibility-verification-2026-10-09.json). Historical
October 7–8 reports remain unchanged. New reports use the existing
[redaction conventions](README.md).

The latest completed signed development build passed. The full suite passed 283 tests in 34
suites with signed-scanner integration; helper tests passed 13, setup checks 19,
and native workflow probe checks 21. The probes used synthetic private-key access
and an injected notification backend. An earlier full run found two sub-microsecond
timestamp assertions, corrected without changing product code. Final production
Swift hashes match before and after the passing build (57 files). Stronger
recovery predicates require exact pending capture identities in both durable
receipts and the restarted worker's successful completion callbacks; catch-up
or expiry alone cannot satisfy them. Signed child prompt/final commits are also
required for each producer. No GUI, authentication or OS health-banner gate is inferred
from regression checks.

Current T3 Codex core observation also passed through one app-owned delegated
fixture using the live composer catalog, Codex producer/reader 0.161.0 and T3
0.0.46-nightly.20261008.2833. The child's own runtime supplied its exact native
thread identity. After production completed, the passive reader committed all
five types, nine occurrences in one native session, stable replay, empty queue
and encrypted inspection. No new top-level thread or unrelated history search
was used. This did not test live overlap, grandchildren, hooks or signed
concurrency. [Current T3 report](harness-compatibility-codex-t3-delegated-2026-10-09.json)

Supported generic T3 task/thread metadata still has no exact Claude native
mapper. A new app-owned Claude child exposed its own `CLAUDE_CODE_SESSION_ID`.
The standard source path derived from it was verified against that child's
native rows and own prompt, without searching unrelated history. Runtime-field
stability is unverified. A second genuine child then passed signed live
selected-source collection: all five types, native child prompt/final, 16
occurrences, six changing live count samples, exact-source CLI/T3 replay,
empty queue, encryption and new-vault cleanup. The native source records one
canonical session; no extra session identity was invented for child content.
Hooks, MCP subtypes, concurrent independent CLI/GUI production and recovery
remain separate gates.
[Current mapping](harness-compatibility-claude-t3-mapping-current-2026-10-09.json),
[signed T3 collection](app-claude-t3-harness-compatibility-live-2026-10-09.json).

## Implemented independent work

Shared contract eligibility now admits recognized CLI/T3 routes without exact
version allowlists. Connection proof, operation/content compatibility and genuine
acceptance evidence are separate. Versions remain provenance, outside native
identity, revision and replay keys. Actual executable probes are bounded and
provider-framed; failed probes retry with a 30-second backoff. Codex method
assessment distinguishes missing methods, rejected parameters, malformed replies
and transient failures, without resuming sessions or creating turns.

Both providers admit CLI and T3 together within the authorized native home.
Codex public-history monitoring suppresses overlapping host selection for the
same canonical native thread. The optional native-rollout alternative keeps the
persisted `codex-t3-transcript-v1` authority identifier. There is no silent
authority switch when public history fails. GUI routes remain excluded pending
their source contracts.

Parser changes tolerate additive fields, scan supported extra tool-payload
strings, and retain exact component coordinates. Required-field failures produce
scoped gaps while readable siblings continue. Per-row producer metadata can
differ from the selected executable. Empty initial Claude reads remain retryable.
Parser-contract checkpoints invalidate stale completion shortcuts without
changing source identity or previously analyzed occurrence receipts.

Saved profiles decode schemas 1 and 2 and write schema 3 while retaining profile,
native home, registration and proof identities. Every committed release wrote
schema 1; schema 2 was written only by an intermediate build of this work. Real
installs therefore migrate 1→3, which the setup probe covers with synthetic
profiles but no genuine signed trial has measured. `authorizedHosts` is independent
of the unchanged legacy `interface`, which remains the owned registration's
transport binding. Legacy CLI/T3 profiles authorize both hosts in their existing
home; legacy Desktop profiles remain disabled. Schema-3 missing/invalid host
authorization fails closed. Installed transport changes and removal of that
shared transport are rejected, and encrypted write failure restores prior state.
Host authorization changes edit neither provider hooks nor the saved proof.
A newly verified event must be encrypted in the queue
before its configuration-bound proof is persisted. A compatible executable
replacement leaves that proof and owned provider trust intact. Re-verification
uses a new one-use challenge without a remembered proof hiding pending delivery.
Proof bindings cover provider, profile, registration, interface, configuration,
helper and socket; changed owned configuration invalidates the proof.

Executable fingerprints include symlink targets. The selected executable path
is retained so an updater can retarget it. A changed reader is reaped and its
operation evidence cleared. A fresh seven-day catch-up audit is queued only for
the changed provider, with a new audit identifier and current end time. The
other provider's collector remains running. Actual GUI app/embedded producer
update detection is still pending phase 0.

Encrypted omission references and incident receipts survive store lifetimes.
Only a successful reparse of the affected row/item resolves its omission.
Session-level recovery requires a complete gap-free pass; a readable final page
or warm cursor suffix cannot resolve an earlier omission. Discovery failures
without a native session retain scoped gaps without invented source identities.
Unresolved omissions remain visible within the seven-day recovery period;
elapsed time marks loss, never recovery. Confirmed required-format incidents
produce masked durable health notifications; unfamiliar metadata and optional
unsupported content do not. [Recovery fixtures](harness-compatibility-recovery.md)

Confirmed required-operation failures also have masked incidents. A fresh method
failure revokes its cached usability; optional timestamp fallback failure leaves
dated content readable while live/history assessments remain partial. Only an
assessment without that operation's failures can settle a route-level incident.
Linked native omissions still require their exact successful reparse. A new
failure at a recovered native position reopens the same omission without renewing
its original source age, while retaining the prior incident's delivery receipt.

Settings no longer presents an exclusive CLI/T3 choice. It exposes each
authorized host's observations and acceptance evidence separately from shared
owned-registration verification. A shared hook cannot establish the actual
producer host, and no per-host suppression control promises otherwise.
The isolated app probe passes 19 checks for legacy migration, encryption,
rollback, stable native replay, scoped status and sole-host historical routing.
Genuine signed schema-2 to schema-3 migration also passes for one Claude profile.
That source schema came from an intermediate build; the shipped 1→3 path is measured
only by the synthetic setup probe.
Coverage displays scoped limitations and the menu distinguishes verified setup
from observed live reading. DEBUG acceptance can stop through an owned finish
sentinel and exports child commit counts/types without paths, IDs or content.
Key cleanup requires an explicit disposable store and newly created keys.

A DEBUG signed recovery owner provisions a fresh private vault and retains
its original guarded key-cleanup capability while ordinary signed workers reload
the same encrypted store. Its owner/worker restart smoke test passed. An initial
genuine recovery attempt stopped before provider launch because its disposable
profile omitted the observed version required by the existing setup guard;
owned registration, authentication and new-key cleanup passed. The corrected
runner independently probes both executables and passes that metadata through
the unchanged production installer. The genuine signed 2.1.293 to 2.1.295 upgrade
and actual process restart then passed all 22 predicates: saved connection proof
and registration, exact encrypted pending capture processing, original native
source stability, per-producer all-five commitment and child prompt/final,
inventory/receipt/alert preservation, checkpoint identity loading, automatic
upgrade/restart audits, duplicate suppression, encryption and original-creator
cleanup. Final inventory has 37 occurrences in three value-bearing canonical
sessions, three settled audits, no unread progress, zero gaps and an empty queue.
Checkpoint offsets/parser state are not claimed unchanged. Notifications were
Off with three `permissionDenied` alert decisions; no system delivery is proved.
[Signed upgrade/restart](app-claude-harness-compatibility-recovery-2026-10-09.json),
[owner test](app-claude-harness-compatibility-recovery-owner-2026-10-09.json),
[preserved startup failure](app-claude-harness-compatibility-recovery-startup-2026-10-09.json)

A separate genuine trial rebuilt the signed app between collector lifetimes at
the same app/helper paths. Its original fresh key owner stayed alive in a
verified private copy of the old signed bundle. The new worker measured actual
decrypted schema 2 and persisted schema 3. All 28 predicates pass, including the
22 recovery predicates above, stable signing/access bindings and source inputs.
It finished with 37 occurrences, three value-bearing native sessions, three
settled audits, zero gaps and an empty queue; exact new-key, registration,
authentication, process and artifact cleanup passed. The 57 production Swift
files match before/after, the main app binary changed, and helper/scanner bytes
are unchanged. Notifications were Allowed and three ordinary alerts have
app-reported `delivered` receipts; visible banners and scoped health delivery
were not measured. This trial migrates one Claude schema-2 profile, not every
legacy/provider/host combination. No committed release wrote schema 2, so the
trial does not cover the 1→3 migration that existing installs will take.
[Signed application/configuration migration](app-claude-harness-compatibility-schema-migration-2026-10-09.json)

## Review corrections

A review of this work found and fixed the defects below after the signed and
genuine runs above. Those runs measured earlier builds and do not cover these
changes; signed genuine acceptance must be rerun on the corrected build.

- Claude parser contract `claude-transcript-5`. Contract 4 treated every
  `attachment` row without a top-level `message` or `content` as metadata. Their
  payloads sit under `attachment`, so a prompt typed while a turn was running,
  persisted only as a `queued_command` with `commandMode` `prompt`, was dropped
  without a gap. Contract 5 collects it as a user prompt and recognizes listed
  harness-context subtypes without content. Queued task notifications, mentioned
  files, edited-file snippets, diagnostics, hook output and unknown subtypes
  remain unsupported-content gaps. Earlier Claude "zero gap" results did not
  cover queued prompts.
  [Fixture](../../Tests/Fixtures/Claude/claude-attachment-envelopes.jsonl)
- Health incidents. An omission that expired unrecovered held its incident open
  forever; the active-incident key then absorbed every later failure with the
  same identity without a new notification. Unrecoverable omissions no longer
  hold incidents open. Expiry settles content incidents that can no longer
  recover, and a recurrence opens a new incident. A required failure also links
  an open omission first recorded without one.
- Codex audits. One thread's omission no longer blocks session-wide recovery for
  every later thread in the same audit; the audit still reports unread content.
- A transient-only read failure is assessed as unverified rather than
  incompatible. Runtime operation observations reset when the observed
  executable version changes.

Verification: `swift test` passed 287 tests in 34 suites, and an unsigned Debug
app build succeeded. Neither replaces signed or genuine-provider acceptance.

## Every remaining plan gate

All phase exit gates below remain open, including phases with passing independent
implementation and fixture checks.

| Phase | Exact unmet work or acceptance |
| --- | --- |
| 0, Claude GUI | Establish actual GUI side-chat prompt/final passive dispatch, stable native identity/affiliation and canonical authority, then signed encrypted ingestion and restart/dedup behavior. The Mod candidate failed its main-content positive control; API absence is unproved. Main all-five live content, child prompt/final and settled original-source catch-up pass. Side-chat history absent from the original store must remain explicit. Current settings preservation and exact owned cleanup pass; earlier comparison remains unattributed. Native control times out; manual operation works. |
| 0, Codex GUI | Execute and collect the exact native child's own prompt, together with all required child content, through an evidenced available GUI tool or route. R3 live parent all-five and child four-type content, native identity and exact-source replay pass; full required-content catch-up remains incomplete. R3's actual spawn omitted the requested prompt. R4's native `send_input` was unavailable, and its recorded bootstrap spawn did not match the literal; READY output does not prove child user-input storage. Original child user/developer IDs are absent from all three passive public methods, while assistant IDs match. This is an unmet fixture/source gate, not a general prompt-source impossibility claim. Matched artifacts and bounded shutdown pass. Native control is denied; manual operation works. |
| 1 | Finish GUI-dependent simultaneous route configuration and ownership only after phase 0. Prove installed legacy/provider/host migrations beyond the one genuine Claude schema-2 profile, independent connection/compatibility/evidence status for all required hosts, and persistent scoped failure while another host remains operational in the signed app. CLI/T3 host authorization, 19 isolated app checks and genuine encrypted schema-2→3 migration preserve the shared owned registration, proof, native identities and pending work. Shared hook verification alone cannot attribute the producer host. |
| 2 | Validate current T3 hook setup and runtime mapping stability, then measure T3 plus CLI plus directly created GUI sessions concurrently; GUI live-only content and signed child coverage; a required tool-format failure leaving prompts/responses and other hosts active with one actual masked health notification. Signed genuine CLI 2.1.295, corrected mixed 2.1.293/2.1.295 commitment and settled history, saved signed CLI setup proof through upgrade/restart, and current T3 selected-source live content pass their independent checks. Earlier rejected captures and metadata gaps were localized and covered by regression; future unknown content remains scoped. |
| 3 | Pass current explicitly selected genuine T3 and GUI Codex sessions alongside CLI in the signed app, ordinary owned native hook verification, required-content attribution, one occurrence/alert per overlapping native location, and scoped missing-method/essential-format degradation. Current T3 live overlap, native grandchildren and genuine MCP subtype attribution remain unmeasured; native child's own prompt and long-running tool fragments remain unverified. Selected-source and historical T3 measurements do not satisfy concurrent acceptance. |
| 4 | Break the executable/required format during signed monitoring, expose controlled scoped failure, restore it and recover quiet eligible omissions without duplicate occurrences/alerts while another host of the same provider remains active. Measure signed review/obsolete-state preservation, cursor/parser continuation and omission/health receipts; implement and measure GUI app/embedded producer update detection. Genuine signed CLI 2.1.293→2.1.295 upgrade and process restart, saved proof/registration, exact encrypted pending work, native identities, inventory/alert/source receipts, checkpoint identity loading and settled automatic audits pass. |
| 5, signed concurrency | Run all six local host/provider combinations concurrently, including independent sessions and one shared native session across overlapping hosts. Pass all five types, correct attribution, bounded queue settlement, exact-location duplicate suppression, encrypted inspection, restart/upgrade recovery and one scoped GUI degradation notification while unaffected routes of both providers continue. |
| 5, normal use | Verify normal owned hooks, synthetic credentials, actual masked notifications and authenticated viewing with the current installed agents; test sleep/lock masking while revealed, restart/catch-up and post-upgrade Coverage. Earlier sleep/lock events while already masked do not satisfy this trial. |
| 5, source opening | Validate native commands/deep links against disposable GUI sessions and intended conversation identity. Enable only evidenced routes and retain authenticated context fallback. Source opening is currently disabled and cannot substitute for collection acceptance. |

Earlier failed signed startup reports retain their original `cleanupPending`
field. A bounded follow-up found private retry diagnostics but no protected
store, database or demonstrated durable manifest at its exact configured path.
The first attempt's exact root is unavailable; its artifact/ownership check and
actual Keychain item absence remain unverified. The queue-add failure precedes
later key creation and store opening in the fresh-start code path; this is not
a Keychain absence query. No broad filesystem or Keychain cleanup was performed.
[Startup artifact follow-up](app-claude-harness-compatibility-startup-artifact-followup-2026-10-09.json)

Release-only macOS 14, hardware without Touch ID, distribution/notarization and Developer ID
update/key-persistence gates remain as previously recorded and are not closed by
this work.
