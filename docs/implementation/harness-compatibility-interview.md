# Harness compatibility design interview

Status: rounds 1 through 3 answered; local GUI support required;
decision frontier empty; final
shared-understanding confirmation pending, October 9, 2026. The
[implementation plan](../HARNESS_COMPATIBILITY_PLAN.md) contains the sequence;
[ADR 0005](../adr/0005-observed-collection-compatibility.md) records the accepted
compatibility, recovery, and verification policy.

## Existing requirements

Keep background collection bounded, secret-bearing data encrypted, source
identities stable, and coverage limits visible. Connection proves a delivered
route; it does not prove that every required content type was analyzed. Preserve
confirmed authenticated viewing, deletion, review, obsolete-value recognition,
and live versus historical notification behavior.

The current review asks about compatibility policy, recovery, operating scope,
failure notification, remembering route verification, and concurrent GUI support.
Engineering details
that can be resolved from code and these requirements are not user questions.

## Findings that change the plan

### Reading progress is not analysis completeness

Claude advances a checkpoint past malformed and unsupported records.
[The adapter](../../Sources/SpillcheckCore/ClaudeAdapter.swift) records gaps but
still returns the advanced offset. [The incremental reader](../../Sources/SpillcheckCore/ClaudeIncrementalReader.swift)
can then return zero bytes for the unchanged file. Codex can mark a thread audit
finished after skipping unknown items, and subsequent audits skip an unchanged
thread using that completion marker. See [Codex history work](../../Sources/SpillcheckCore/CodexHistoryWork.swift).

A parser update therefore needs explicit recovery of affected sources or ranges.
Invalidating only the executable compatibility cache is insufficient. Recovery
must preserve existing processed-source receipts so previously analyzed content
does not recreate deleted inventory or duplicate occurrences and alerts.

### Existing queue limits constrain recovery

Defaults are a 100 MiB queue, 8 MiB per event, 24-hour queue age, and three retries.
The fourth thrown processing failure drops the capture and records a gap. A
returned gap-only batch settles without retaining a retryable capture. See
[limits](../../Sources/SpillcheckCore/StorageContracts.swift),
[retry handling](../../Sources/SpillcheckCore/ProtectedStore.swift), and
[pipeline settlement](../../Sources/SpillcheckCore/DetectionPipeline.swift).

The plan's promise to preserve work must distinguish transient failure, blocked
compatibility, partially analyzed content, expired captures, and rereadable
original history. Prevent an incompatible source from blocking other usable
sources. A gap record alone is not a recovery task.

### Connection proof needs a persistence contract

The hook command does not contain the harness version, so changing that version
does not inherently require reinstalling the command. Provider hook trust and
Spillcheck's connection proof are different facts. Spillcheck currently keeps its
connected state and challenge in actor memory; rebuilding a setup with intact
hooks returns it to installed-unverified. See
[setup controller](../../Spillcheck/App/AgentSetupController.swift) and
[Codex hook setup](../../Sources/SpillcheckCore/CodexHookConfiguration.swift).

Remembering connection proof requires specifying what registration and
configuration it covers, when it becomes stale, and how to distinguish remembered
proof from current collection activity.

### Simultaneous routes are not uniformly supported

Saved configuration permits one profile per provider. Claude runtime registers
both CLI and T3 collection routes against the same configured transcript roots.
Codex runtime registers one configured interface and reader. Simultaneous
standalone and T3 collection can therefore require more than removing version
checks. See [runtime configuration](../../Spillcheck/App/AppRuntime.swift).

Multiple authorized homes or accounts are a separate scope choice from multiple
interfaces sharing one authorized home.

### Desktop collection has explicit blockers

The `desktopCode` interface exists, but
[setup](../../Spillcheck/App/AgentSetupController.swift) rejects it,
[Settings](../../Spillcheck/App/SettingsView.swift) offers only CLI and T3, and both
[Claude](../../Sources/SpillcheckCore/ClaudeActiveTranscriptMonitor.swift) and
[Codex](../../Sources/SpillcheckCore/CodexActiveHistoryMonitor.swift) active-source
types reject it. The adapters also exclude Desktop. Enabling a picker alone
cannot establish working GUI collection.

Saved profiles and setup state are keyed by provider and permit one executable
and interface per provider. The
[router](../../Sources/SpillcheckCore/CollectionRouter.swift) already permits
multiple configured routes, but app setup and runtime need to represent all
required hosts concurrently. Preserve the existing
[native identities](../../Sources/SpillcheckCore/SourceContracts.swift) across
overlapping routes rather than assigning a new conversation identity per host.

The [measured matrix](supported-matrix.md) records GUI collection and native GUI
opening as unverified. Existing deep-link or resume commands are separate from
evidence that a session created inside a GUI is passively collected.

### GUI mode and execution location are separate boundaries

Claude Desktop has Chat, Cowork, and Code tabs. Code sessions can run locally,
in the cloud, or over SSH. Its documented shared local settings include hooks.
These facts support investigating reuse of native Code collection; they do not
establish coverage for Chat, Cowork, or remote sessions. The app does not save
Code side chats to disk, so transcript replay alone cannot establish their
coverage. Validate live observability and disclose unavailable history.
[Claude Desktop reference](https://code.claude.com/docs/en/desktop).

Codex documents passive stored-history operations through app-server. Validate
their access to the original GUI-created sessions and required content before
selecting that collection route. An available CLI reader does not establish
that it sees a GUI's store, configuration, or embedded producer.
[Codex app-server reference](https://learn.chatgpt.com/docs/app-server).

### Coverage incidents need attribution and lifecycle

Current gaps have a reason, optional capability ID, and interval, but no recovery
state or record locator. The app derives its current global status from gaps in
the last 24 hours and unread latest audits. An old omission can leave the current
status even when it was never recovered. See
[coverage contracts](../../Sources/SpillcheckCore/Monitoring.swift) and
[refresh](../../Spillcheck/App/AppRuntime.swift).

The design must distinguish a currently operating route from an unresolved loss
within the displayed coverage period. A new version with no full acceptance
evidence is different from a demonstrated content omission.

### Envelope metadata and content are different

Both adapters recursively scan string leaves inside recognized structured tool
results. Extra payload fields can contain secrets and affect the canonical source
revision. Tolerating additional envelope metadata must not discard additional
model-visible tool-result text. The plan now states this distinction explicitly.
Unknown top-level items and blocks remain a separate format-recognition problem.

## Confirmed decisions from round 1

- **Q1:** Automatically collect on untested releases after required compatibility
  checks pass. Missing acceptance evidence alone does not require opt-in.
- **Q2:** Recover from available original history within seven days, with the
  existing bounded encrypted queue and no additional long-lived raw archive.
  Backward source compatibility beyond the seven-day window is not required.
- **Q4:** Notify when a new format prevents correct functioning. An unfamiliar
  release alone is insufficient. Q7 confirms that loss of any required content
  type qualifies even when other collection works.
- **Q5:** Persist applicable connection verification across app restarts and
  compatible harness upgrades; automatically recheck and repeat a challenge when
  repair or invalid proof requires it.

### Q3 factual clarification

The current collector does not parse a distinct T3-owned conversation format.
Claude CLI and T3 sessions use the same native Claude transcript parser. Normal
Codex CLI and T3 collection uses one native public-history importer.
`t3VersionedTranscript` is an older explicit alternative that parses native Codex
rollout JSONL with `session_meta` and `response_item`, not T3 database or UI rows.
The signed T3 acceptance runner selects native public history. Its name and exact
host-version gate reflect earlier exploratory work, not another required parser.

T3 can use a different native executable, producer version, authorized home,
hook path, or session mapping. Test those behaviors and preserve source identity
without choosing a parser by the host's name. The parser follows provider format;
the host remains provenance and acceptance metadata. The same native session
seen through multiple routes is one conversation, consistent with existing
source-identity requirements. Q6 confirms simultaneous CLI/T3 collection.

## Confirmed decisions from round 2

- **Q6:** Native CLI and T3 sessions may be used concurrently within the same
  explicitly authorized provider home, without selecting one interface in
  Settings. Both use the provider parser for the applicable source format.
  Multiple homes or accounts remain later scope.
- **Q7:** Loss of a required content type is incorrect functioning even if other
  collection works. Continue unaffected routes and content, identify the missing
  scope, and notify once per confirmed format incident when enabled. The user
  called this graceful degradation; the glossary records the specific domain
  term as collection degradation.

## Confirmed scope addition and round 3

The user requires official support of the Codex and Claude GUI apps, with
everything working in parallel. Desktop support is now a completion requirement;
the existing unverified matrix remains accurate until acceptance runs pass.

- **Q8:** Required Claude GUI support covers the Code tab first. Ordinary Chat
  and Cowork remain outside this release's scope.
- **Q9:** Required sessions execute on this Mac. Cloud and SSH execution remain
  outside this release's scope, even when their sessions appear in a local GUI.

The required host/provider combinations are Codex CLI, Codex through T3, Codex
GUI, Claude Code CLI, Claude Code through T3, and Claude GUI Code. All six must
operate concurrently. GUI app versions, embedded producers, and external readers
are separate provenance. A native store shared across hosts must retain its
canonical profile and source identities.

The product decision frontier is empty. GUI collection feasibility and exact
implementation remain engineering work. The implementation plan contains the
concrete behavior and gates for final shared-understanding confirmation before
coding, as required by the invoked grilling skill. The user has not yet given
that final confirmation.

The plan's [fresh-session entry point](../HARNESS_COMPATIBILITY_PLAN.md#start-a-fresh-implementation-session)
lists the documents and baseline needed for implementation. An explicit new
instruction to implement that agreed plan supplies the final start confirmation.

## Engineering implications of the settled requirements

Recovered older content is historical audit and uses the existing masked summary
behavior, with replay and obsolete-value suppression preserved. Recovery
references remain distinct from analyzed receipts; queue expiration and vanished
original sources produce explicit unrecoverable omissions within the displayed
period. Neither reading completion nor elapsed time proves recovery.

Remembered proof must cover the owned registration and authorized configuration,
preserve provider-owned trust, and remain separate from recent activity. Scope
validation and compatible executable upgrades do not themselves require another
challenge. Explain invalid proof or needed repair with controlled reasons.

Health incident identity and duplicate suppression must survive restart. Current
status should reflect recovery; avoid a second system notification simply to
announce recovery unless that becomes a separate product requirement.

For simultaneous routes, retain provider/profile/native-session/native-item
identity and one canonical source authority. Trace host mapping independently;
compatibility of a native reader does not prove that host mapping.

Record resolved glossary terms in `CONTEXT.md`. Record an ADR only for an agreed
decision with a substantial reversal cost, a non-obvious rationale, and a real
trade-off. Keep unresolved recommendations out of accepted ADRs.
