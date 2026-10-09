# Codex compatibility implementation and measured scope

Recorded October 9, 2026. This work establishes current standalone CLI collection
and selected-source content from one T3 delegated task through the production
passive reader, while preserving existing Codex source
identities. It does not satisfy the official GUI route or the all-six-host exit
gate in the [compatibility plan](../HARNESS_COMPATIBILITY_PLAN.md).

## Actual producer, store, reader, and identity

Both standalone runs used the selected Codex CLI executable at
`<HOME>/.local/bin/codex`. Independent bounded version probes and the production
reader reported `0.161.0`. The provider-created thread metadata also reported
producer `0.161.0`; the configured reader version was not substituted for source
provenance. No T3 or GUI host version was supplied or inferred.

Each run created its own private `CODEX_HOME` and work directory. Authentication
was copied into that authorized disposable home with mode `0600`, then removed
with the home. The genuine `codex exec` producer created a native parent and child
there. The collector read that same authorized home through bounded public
app-server operations. It did not ingest stdout or substitute hook payload text
for canonical content. The public-read probe recorded zero session-resume and
turn-start calls, with network and fork denied in the passive reader.

Canonical identity remains the provider/profile/native thread/native item and
exact normalized component range. Version strings do not enter source revision
framing or occurrence identity. Existing persisted authority IDs remain
`codex-public-native-v1` and `codex-t3-transcript-v1`; the latter is now also named
`nativeRolloutTranscript` internally because it parses Codex-native JSONL.

The collector follows the provider's documented separation between reading a
thread and starting or resuming one. A successful initialization is not evidence
that a required item-listing method is available. [Official app-server
documentation](https://learn.chatgpt.com/docs/app-server).

## Genuine standalone results

| Run | Measured result | Evidence |
| --- | --- | --- |
| Catch-up after the producer exited | All five required content types, successful/failed shell and MCP results, and native child's own final; 14 occurrences across two native sessions | [Catch-up report](harness-compatibility-codex-cli-catchup-2026-10-09.json) |
| Reader launched on `thread.started` while producer ran | All five required content types and eight required typed markers committed before final catch-up; eight unique live source revisions | [Active live report](harness-compatibility-codex-cli-active-live-2026-10-09.json) |

Both reports passed: each required typed marker had exactly one canonical
occurrence, native locations were unique, replay added no duplicate occurrence,
final catch-up added none, the encrypted queue was empty, and ciphertext marker
inspection passed. The catch-up run produced no live alert. The active run
produced two live synthetic alerts. Both removed the disposable home and
authentication and stopped every owned producer, observer, and version-probe
process group. Existing histories, global hook settings, and trust records were
not changed. No hook trust was bypassed.

One additional genuine T3-owned delegated task passed selected-source collection
after its producer completed. The live composer catalog selected provider
`codex`, model `gpt-6.1-sol`; `t3_environment_read` reported server version
`0.0.46-nightly.20261008.2833`. The child's own runtime supplied its exact native
`CODEX_THREAD_ID`. T3 task metadata itself exposed no native mapping field.
`CODEX_HOME` was unset, so the reader used the provider's documented
[default home](https://raw.githubusercontent.com/openai/codex/main/codex-rs/utils/home-dir/src/lib.rs)
and confirmed that exact original session through the production passive reader.
It did not enumerate history or infer identity from a title, marker, or T3 ID.
[T3 delegated report](harness-compatibility-codex-t3-delegated-2026-10-09.json).

That source recorded producer `0.161.0`, independently of reader `0.161.0`.
It committed nine occurrences in one native session across all five required
types, with zero gaps, unique locations, empty queue, stable replay, no final
catch-up additions, and encrypted marker inspection. A nonzero shell exit was
wrapped as a successful tool response; a real controlled failed tool script
provided the error case. This does not prove a failed native shell subtype or
MCP fixture. No native grandchild was created or measured. The observer's process
group stopped and its ephemeral encrypted store was removed. The completed
delegated task had no pending runs and was archived through T3's normal lifecycle;
its original provider source remains in the original store. No extra raw archive,
configuration edit, trust bypass, or top-level thread was introduced. This run
does not establish T3 live overlap, signed ingestion, or concurrent operation.

The available supported T3 task/thread metadata APIs do not advertise an exact
native Claude session or transcript mapper. A child-owned Claude runtime mapper
was not established, so no additional Claude task was launched and no transcript
search by marker was attempted. [Mapping investigation](harness-compatibility-t3-mapping-2026-10-09.json)
records that remaining capability without claiming the Claude provider cannot run.

For the active run, canonical read-start to commit observation had a measured
p95 and maximum of 495.14 ms across eight unique source revisions. Provider
timestamp to canonical read-start had p95 and maximum 997.44 ms. These timestamps
do not measure first-byte publication or when the public history first exposed
an item. The report retains the clock, attribution, and sample limitations.

The native child's own final passed. Its prompt remains an explicit unverified
content case; seeing the parent's spawn arguments is not proof that the child's
native prompt was collected.

## Compatibility and recovery changes

Executable recognition and required operation contracts replace exact-version
eligibility for CLI and T3. The passive client probes the actual selected
executable, checks response shapes, requested thread identity, bounded pages and
cursors, and distinguishes missing methods, rejected parameters, malformed
replies, and temporary failures. Successful metadata, item, and discovery
operations establish separate live-read and historical-read assessments. A failed
method revokes its previous successful receipt until a fresh validated response.
An unavailable turn-timestamp fallback marks both operations partial while dated
items remain readable; a fresh success on an unrelated method cannot clear that
fallback failure. Confirmed method failures carry a controlled live or historical
operation on their scoped gap. An
executable replacement or selected symlink retarget reaps the owned reader,
clears its operation assessment, and reprobes without replacing source identity.

Public items and native rollout rows tolerate additive envelope fields and
record each actual producer version, including explicit `unknown` metadata.
Required field or content-block failures produce scoped omissions while readable
siblings continue. Additional supported strings in recognized tool results are
scanned with stable component paths. Completion checkpoints now carry a parser
contract independently of authority and source revision, so old completion
receipts cannot hide a row needing reparse.

Omission recovery matches the exact native item or transcript row. A successful
sibling cannot resolve another skipped item. A session-wide operation omission
can resolve only after a complete pass without gaps; a final readable page or
warm live cursor suffix does not establish complete-session recovery.

The final focused Codex run passed 50 tests across seven suites, including unfamiliar
reader and producer versions, all-five native rollout content, missing operation
contracts, replay, source-range stability, replacement, selected symlink retarget,
overlapping CLI/T3 monitoring, method failure/recovery, and conditional timestamp
fallback degradation. After the two final session-recovery guards,
the focused history suite passed all 17 tests, including regressions for an
earlier-page omission, a warm suffix, and failed discovery without a native
session and recovery after a missing native item ID is restored. Missing,
oversized, and invalid native item identifiers become session-level omissions
instead of invalid exact-item references. Discovery failures remain scoped
operation gaps; no recovery identity is invented for a source whose native
session has not been discovered. The
genuine active report follows all identifier and session-recovery guards; the
catch-up report precedes those final guards. Both precede the operation health
contract extension. Their `evidenceScope` records these implementation boundaries.
Native identifiers are replaced with consistent tokens in the published reports;
source text, authentication, and personal paths are excluded. The final complete signed
regression suite is recorded separately by the overall implementation evidence.

## Remaining Codex gates

The [manual GUI fixture](../../Tests/CodexGUIProbe/README.md) and standalone
collector now have three passing scope and artifact regressions. They wait for the created parent and child's own
runtime identities, verifies the explicitly authorized original store and project,
and requires an original parent collaboration item linking the exact child ID.
The initial [preparation report](harness-compatibility-codex-gui-manual-2026-10-09.json)
remains preparatory. The user subsequently created the R2 fixture directly in the
official Local GUI. Its host was `26.930.61225` build `13232`; the exact original
sources record native producer `0.160.1`, independently of reader `0.161.0`.

R2's live observer crashed because its compiled module and linked Core library had
incompatible Swift layouts. A matched rebuild processed the exact original sources;
a subsequent shutdown hang in Foundation `waitUntilExit` was corrected with bounded,
idempotent termination of only the owned reader. Eleven focused process tests pass.
Module/library snapshots and source/artifact hashes now guard compilation and reuse.
The repaired historical-only retry verified both native identities, authorized
original store, owned project and native parent-child link. It committed ten
occurrences, including each parent required-type marker once, with zero gaps,
stable replay, empty queue, clean encrypted retention and clean reader shutdown.
The child registered after the original crash and stopped on collector failure,
so its requested markers were never established. A bounded diagnostic of only its
public-verified original JSONL also found none of those child markers. Neither
retry establishes live coverage or a native child prompt contract.
[R2 partial evidence](harness-compatibility-codex-gui-native-partial-2026-10-09.json),
[exact child source diagnostic](harness-compatibility-codex-gui-native-child-source-2026-10-09.json).

The genuine R3 observer subsequently ran its full bounded lease. It committed
fourteen occurrences across the two exact native sessions: all five parent types
and the child's intermediate/final responses, successful tool output and failed
tool output, with each of nine requested typed markers committed once during
live observation. Reader restart, exact-source catch-up/replay, unique locations,
empty queue, zero parser gaps, encrypted retention and both bounded reader
shutdown checks passed. The native child prompt remains unestablished.

The original parent user prompt requested the child marker, but its one actual
native spawn call omitted it from otherwise parseable message/task arguments.
The child's original JSONL also lacked that marker, including recognized user,
developer and assistant roles. This is fixture noncompliance; it does not prove
that the provider cannot expose a correctly submitted child prompt.
[R3 live partial evidence](harness-compatibility-codex-gui-live-r3-2026-10-09.json),
[R3 native input compliance](harness-compatibility-codex-gui-native-child-source-r3-2026-10-09.json).

Three supported passive public methods returned the same native item IDs on
this noncompliant child; a full-history read did not recover the unsubmitted
marker. [Passive full-history evidence](harness-compatibility-codex-gui-passive-full-history-r3-2026-10-09.json).
R4 is prepared with an identity-only child bootstrap followed by a separate
literal native `send_input` to the same child. Its matched collector compilation
and three scope/artifact regressions passed. In the genuine manual run, the user
reported that native `send_input` was unavailable: parent steps and the child
bootstrap completed, and the task stopped before the child content fixture.
The bounded observer verified both original identities/store/project and their
native parent-child link. It committed ten occurrences and four parent typed
markers live. Parent final-response items were readable, but the required final
marker was not committed. Child bootstrap response/tool items were readable;
none establishes the unsubmitted child content fixture. Exact-source restart
and seven-day replay added no occurrences; encryption, queue/gap checks and both
bounded shutdown checks passed.
[R4 stopped-fixture evidence](harness-compatibility-codex-gui-live-r4-2026-10-09.json).

R4 establishes the unavailable native input step in this actual GUI task, not a
general inability to collect child prompts. Full parent/child required content
remains unestablished. A bounded original/public comparison additionally found
that its recorded spawn message differed from the complete fixture literal;
the original child user/developer message IDs were absent from all three public
methods, while both assistant IDs matched. The child's READY result does not
establish a native user-prompt input.
[R4 original/public prompt comparison](harness-compatibility-codex-gui-spawn-prompt-contract-r4-2026-10-09.json).
No further provider turn or prompt was requested, no
original source was changed, and no native-rollout authority switch or child
identity inferred from parent text was implemented.
[Primary contract investigation](codex-gui-child-prompt-source-research-2026-10-09.md).

This source-format probe invokes the existing parser in its enabled CLI eligibility
context and records the GUI host separately. It can measure exact-source required
content, ongoing collection, selected-source seven-day catch-up, replay and
encrypted retention without enabling Desktop collection. It cannot establish
production Desktop normalization/setup, signed operation, hooks, native opening,
six-way concurrency, or upgrade/degradation acceptance.

- Phase 0: a conversation created directly in the official Codex GUI still needs
  its actual embedded producer, authorized native store, passive route, native
  identity, all five content types, live observation, available catch-up, and
  native child behavior established. Opening a CLI conversation in the GUI does
  not satisfy this gate. Native control returned "Computer Use is not allowed
  for this app for safety reasons"; no alternate automation bypass was used.
  [Recorded phase 0 environment](harness-compatibility-phase0-2026-10-09.json).
  Desktop collection remains excluded.
- Phase 3: current genuine T3 and official GUI sessions must operate alongside
  the CLI in the signed app, with each actual producer and host measured. The
  previous T3 signed evidence remains historical. The new delegated T3 run proves
  current core content after its producer completed, not signed or live
  concurrent operation, native grandchildren, or genuine MCP subtype coverage.
- Phase 3: this run did not verify an ordinary owned native `/hooks` connection
  challenge. A connected registration is separate from selected-thread polling
  and content compatibility. The ordinary trust flow remains required.
- Phases 4 and 5: genuine changed-format or missing-method degradation, an owned
  executable upgrade, restart recovery, and a scoped masked health notification
  need signed-app acceptance. Controlled fixture tests establish their core
  behavior, not genuine provider or signed-app acceptance.
- Phase 5: all six required local host/provider combinations must run
  concurrently with duplicate suppression, required content, encrypted storage,
  restart/upgrade recovery, and scoped degradation. These two standalone runs
  are independent runs, not proof of that concurrent gate.
- The native child's own prompt and publication of long-running tool fragments
  remain unverified. Available historical recovery is limited to the original
  store and the seven-day analysis window; no additional raw archive was added.

Reproduce using `Tests/CodexLive/run.py` for post-producer catch-up and
`Tests/CodexLive/measure-latency.py` for active observation. Pass the selected
producer and optional reader executable explicitly. Optional expected-version
arguments constrain an acceptance run without defining product eligibility.
