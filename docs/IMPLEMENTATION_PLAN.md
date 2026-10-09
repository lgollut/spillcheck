# Spillcheck implementation plan

Status: milestones 1–5 passed their implementation gates. Milestone 0 passed on the available Mac; the user explicitly deferred macOS 14 and hardware without Touch ID until before release. The local development MVP is runnable. Milestone 6 records passing local acceptance, measured resources and a four-run signed restart/cooperative offline GUI check; the full release gate remains open. The user explicitly deferred distribution. Developer ID packaging, notarization and upgrade acceptance remain unverified. [Execution status](implementation/milestones.json), [acceptance evidence](implementation/milestone-6.md), and each milestone's report record the exact tested scopes and open checks.

Reviewed: October 8, 2026.

## Assessment of the current documentation

The four existing documents agree on the product boundary. [CONTEXT.md](../CONTEXT.md) defines the domain vocabulary, [SPEC.md](SPEC.md) defines workflows and acceptance criteria, and [ADR 0001](adr/0001-local-analysis.md) and [ADR 0002](adr/0002-retain-encrypted-values.md) fix local processing and protected retention.

The implementation establishes versioned collection paths through T3 and standalone CLI, uses Betterleaks 1.9.0 with three fixture-justified Swift rules, and has signed-app evidence for encrypted retention and system-authorized revelation. [Acceptance evidence](implementation/milestone-6.md) distinguishes the app's measured behavior from unverified lifecycle and workload scopes. The required macOS 14 and non-Touch ID hardware checks remain unverified and must run before release under the user's explicit deferral, retained in [release checks](implementation/release-checks.json). Native source-opening routes remain unverified, with authenticated retained-context viewing exercised separately. Tool hooks alone do not establish complete coverage, and a seven-day date filter alone does not establish bounded historical reads.

The recommended stack is Swift 6, SwiftUI and AppKit, GRDB/SQLite, CryptoKit, Keychain and LocalAuthentication, a compiled Swift hook helper, and bundled Betterleaks with reviewed local rules. Add native detector rules only for gaps demonstrated by fixtures. [The stack proposal](adr/0003-native-macos-stack.md) explains the choices and alternatives.

The implementation acceptance runs used macOS 26.6.2 arm64, Xcode 27.0, Swift 6.4, Codex CLI 0.161.0, Claude Code 2.1.293, and T3 0.0.46-nightly.20261007.2761. [The supported matrix](implementation/supported-matrix.md) defines the tested content paths and limitations. Minimum supported agent versions and Desktop collection remain unverified.

The app must support installation and updates beyond a development checkout. Keep a stable application identity, owned hook entries, migrations, signing, and install/update validation in the first implementation. Recovery or migration of the inventory after loss or replacement of the Mac is not required. Device-bound vault keys are acceptable within that boundary; missing keys must still produce an explicit unavailable state.

The confirmed release baseline is macOS 14 or later, Apple Silicon first, and direct signed/notarized distribution. T3 with Codex or Claude Code and their standalone CLI workflows are the required initial interfaces. Desktop support follows validated coverage; Intel support follows a validated build. Adapter and agent-version compatibility are still measured capabilities, not established by these product choices.

## Integration facts that affect the plan

- Codex exposes tool and prompt hooks plus a final-message stop hook. Hosted tools do not use its local hook path. Test tool failures and intermediate responses independently. [Codex hooks](https://learn.chatgpt.com/docs/hooks).
- Codex offers passive stored-thread reads and experimental paginated history. That does not prove an independent process can subscribe to sessions owned by Desktop or another CLI process. Test stored-content visibility and tool-output completeness before choosing it for catch-up. [App-server protocol](https://learn.chatgpt.com/docs/app-server).
- Claude's batch tool event exposes serialized model-visible results. Its displayed-message event uses streamed batches and identifiers that cannot be directly correlated with transcript message IDs. Choose collection authority per content type and validate reconciliation instead of assuming hook and transcript IDs match. [Claude hooks](https://code.claude.com/docs/en/hooks).
- Claude's documented Desktop-opening command has version, sign-in, and active-session restrictions. Source opening remains a capability with an encrypted-context fallback. [Claude Desktop workflow](https://code.claude.com/docs/en/desktop#coming-from-the-cli).

Public interfaces are preferable. Version-specific transcript readers are acceptable only as isolated fallback adapters with fixture tests and visible limits. Do not make undocumented transcripts the app's domain model. No session may be resumed merely to collect it.

The [session reader guidance](SESSION_READER_REUSE.md) records requirements for bounded reads, JSONL framing, checkpoints, cancellation, and replay. Readers must preserve assistant and tool output, exact secret bytes, and source ranges. Warm-read tests support incremental recovery, but do not prove bounded first-pass seven-day discovery or hook/history correlation.

## Product decisions and proposed defaults

Historical summaries, manual confirmation of secret occurrences, and recognition of obsolete values are confirmed. Other defaults below remain proposals unless already specified in [SPEC.md](SPEC.md).

| Question | Proposed behavior |
| --- | --- |
| Review and confidence aggregation | Store reversible review on each occurrence and show review counts separately from detector confidence. Derive the signal from non-dismissed evidence: strong if any strong occurrence remains, otherwise ambiguous if any ambiguous occurrence remains. Only unreviewed ambiguous occurrences need review; positive confirmation clears that requirement without changing detector evidence. Show total, confirmed, unreviewed, and false-positive counts. |
| Ambiguous then strong | Notify when the first eligible strong occurrence appears for that value/session pair, even if an ambiguous occurrence was already present. |
| Undoing review | Restore the occurrence's prior evidence-based state without generating a notification for that manual action. New occurrences still undergo normal evaluation. |
| Historical alerts | Confirmed: first launch, restart catch-up, and pause catch-up produce a masked summary rather than individual alerts. Events captured while monitoring is active follow the live alert matrix. Persist this provenance. |
| Positive review | Confirmed: a user may confirm that an occurrence contains a secret. Keep this separate from detector confidence and current credential validity. |
| Value grouping | Group exact extracted UTF-8 value bytes with a keyed fingerprint across agents and services. Do not lowercase, trim, or fuzzily merge values. Parse transport escaping and declared credential fields before extraction; retain the source mapping. |
| Deletion and backfill | Proposed source-receipt mechanics: delete inventory payloads and occurrences; retain minimal processed-source identities and checkpoints independently of values. Already processed history cannot recreate a deleted record. Confirmed: obsolete-value fingerprints and acknowledgements survive content deletion until explicitly forgotten or reset. Deletion alone does not mark a value obsolete. |
| Pause | Stop accepting new payloads, processing, and alerts. Cancel or finish in-flight work under a generation check that prevents post-pause commits and alerts. Retain already queued encrypted data until its stated expiry. |
| Source actions | Open only a validated route after a user action. Where retention policy keeps context, make it available after authentication. Obsolete reappearances after content deletion retain only source/time/label and have no retained-context fallback. A terminal resume action, if later added, must be distinct and explicit. |
| Rotation or revocation acknowledgement | Confirmed: the MVP tracks a user's acknowledgement per exact value and quietly records new appearances of that value as obsolete. After content deletion, these appearances retain only source/time/label, without new value or excerpt payloads. A different replacement value undergoes normal detection and alerts. Rotation instructions, service-console links, and automatic remediation remain later work. |

Keep review decisions when rules are reevaluated. Scanned instructions and inline ignore comments never change app rules, mark false positives, execute commands, or affect configuration.

## Architecture and data contracts

The app owns the socket receiver, encrypted durable queue, detector worker, persistence, notifications, and UI. The short-lived hook helper reads stdin, sends a framed event to the running app, and exits. It does not scan, spool plaintext, start the app, or run as a service. Return a minimal no-effect response where the agent event requires JSON; never echo captured content to stdout or stderr.

The processing path is:

`agent → hook helper / history adapter → normalized event → encrypted queue → local detector → transactional inventory and alert decision → masked UI`

### Push delivery and historical pull

Live hook delivery is push. During adapter setup, register the bundled `spillcheck-hook` command in the agent's user-level hook configuration, preserving existing entries. Codex supports `~/.codex/hooks.json` or inline hooks in `config.toml`; Claude Code supports `~/.claude/settings.json`. Verify configuration loading and a synthetic event for each supported interface before declaring it connected. [Codex hook configuration](https://learn.chatgpt.com/docs/hooks), [Claude hook configuration](https://code.claude.com/docs/en/hooks).

When a supported event fires, the agent starts the helper and supplies event JSON on stdin. The helper sends it to the running app's Unix-domain socket. The app acknowledges only after durable encrypted queue insertion; the helper returns without waiting for Betterleaks. Detection runs separately in the app. A timeout can leave delivery uncertain, so retries must retain stable event identity.

The app does not poll to discover hook invocations. Historical recovery is a separate bounded pull at first launch, restart, and resume, using checkpoints and the seven-day window. If a content type lacks a usable hook, milestone 0 may select a version-specific history poller or file watcher as a supplementary adapter. That is a coverage decision, not an implicit promise of complete push coverage.

When paused, reject capture; when quit, the socket is unavailable. The helper returns promptly without retaining content or starting the app. Recent missed content is recoverable only through a validated history route. Queue rejection and delivery failures can lose data; show known gaps without claiming an exact count of hook invocations that occurred while the app was absent.

### Core modules

Use one Swift package for core modules initially. Keep these boundaries clear without creating a framework for every type:

- Collection owns upstream payload parsing, supported versions, historical checkpoints, and source-opening capabilities.
- Detection owns rule execution, exact-value extraction, source ranges, evidence, and confidence classification.
- Storage owns migrations, encrypted payloads, unique identities, transactions, and queue claims.
- The vault owns keys, authenticated decryption, and viewing-session invalidation.
- Inventory services own grouping, occurrence review, deletion, and alert eligibility. SwiftUI consumes masked summaries and explicit reveal results.

Define these records before implementation:

| Record | Required information |
| --- | --- |
| Session | Agent, source installation/interface, source session ID, optional encrypted title/project reference, source-opening capability. |
| Source item | Canonical session and item identity, content kind, source timestamp, observation timestamp, source locator, adapter version, live/history provenance. |
| Queued event | Stable ingestion identity, encrypted payload, capture time, expiry, processing state, retry count. |
| Secret inventory record | UUID, keyed exact-value fingerprint, encrypted value when retained, approved masked label, suspected categories/services, first/last occurrence times, user-asserted rotation/revocation acknowledgement. |
| Obsolete-value marker | Exact-value keyed fingerprint, user-asserted rotation/revocation state, acknowledgement time. Survives removal of retained content until explicit forgetting or reset; contains no old payload or occurrence history. |
| Occurrence | Value identity, canonical source item, mapped range or component ranges, encrypted excerpt when retained, timestamp, reversible review state. |
| Detection evidence | Occurrence, rule ID/version, signal classification, reason. Several rules can support one occurrence. |
| Unlocated result | Source reference and evidence without a fabricated value; separate from a revealable inventory record. |
| Alert decision | Inventory ID and canonical session, durable eligibility/delivery state, opaque notification identifier. |
| Coverage/checkpoint | Adapter capability matrix, actual covered interval, source cursor/file identity/offset, dropped-content counters and reasons. |

Do not use a payload hash alone as an event identity. Identical text can occur in two legitimate source items. An occurrence identity combines the canonical source item and exact range, while a value fingerprint groups appearances of the same value. Merge evidence from overlapping rules at the same range. Keep separate ranges as separate occurrences.

Prefer upstream IDs and tool-call IDs. Reconcile alternate collectors through an explicit mapping. Where reliable correlation is unavailable, choose one authoritative collector for that content type and limit overlapping imports; label unresolved coverage rather than guessing. Claude display chunks need ordered reassembly, duplicate-chunk handling, and incomplete-message limits before scanning a complete message.

Atomic processing commits inventory changes, occurrence/evidence inserts, the alert decision, and source progress together, then removes the processed queue payload. Use unique constraints to survive retries and crashes. A notification outbox with a deterministic opaque identifier prevents application retries from issuing fresh alerts; test macOS delivery behavior rather than promising exactly-once OS presentation.

### Shared identity for hooks and history

History is another input to the same ingestion pipeline, not an independent scanner whose findings are appended to the inventory. Both collectors must resolve their observations to a canonical source item before creating occurrences.

Use separate identities for three separate purposes:

- The exact-value HMAC groups the secret inventory record across all appearances.
- A canonical source item identifies an originating message or tool result within an agent profile and session. Hook/history provenance and CLI/Desktop presentation are attributes, not additional identity components when they refer to the same underlying item.
- An occurrence identifies the extracted value at a mapped location in a canonical content segment. Enforce its uniqueness in SQLite. Several matching rules attach evidence to that occurrence rather than each creating an occurrence.

Prefer shared upstream message/tool-call IDs and prove their hook-to-history mapping in fixtures. Hook JSON ranges and transcript ranges are not interchangeable. Each adapter must parse transport escaping and presentation wrappers, select canonical segments, and map exact values to those segments. A payload hash or arrival timestamp alone cannot distinguish a replay from a legitimate second output containing identical text.

Store the keyed content-revision fingerprint and detector/rule version for each analyzed item. An identical revision with the same detector version can be skipped. If history supplies more complete content, analyze the additional content and reconcile existing occurrences and review decisions transactionally. Do not skip a richer item solely because its source ID was seen before. If offsets shift, the adapter must provide a verified range mapping or defer to its authoritative representation; do not append a second set of occurrences using unrelated coordinates.

Source receipts and deletion markers must distinguish processed ranges from subsequently appended content. Retain them independently of deleted inventory payloads, with no plaintext values or excerpts. New content remains eligible even if another range in the same source item was processed or deleted. Checkpoints bound reads; they are not proof that two observations are the same occurrence.

Obsolete-value markers have a different purpose from source receipts. After extracting a value, its exact-value HMAC can match an acknowledgement even after its old inventory payload has been deleted. Record the genuinely new occurrence as obsolete and suppress notifications for it. A different replacement value has a different fingerprint and follows normal rules, including within the same conversation. Keep detector evidence, occurrence review, user acknowledgement, and payload-retention state separate. [ADR 0004](adr/0004-remember-obsolete-values.md).

Once an obsolete value's retained content is removed, subsequent appearances keep only the protected source reference, time, and obsolete classification. Do not create new retained-value or excerpt ciphertext for them. Normal captured-content queues remain temporary and are removed after processing. Exact-value extraction and the fingerprint lookup occur in memory; this policy does not skip detection of other values in the same source item.

Check the current acknowledgement in the transaction that records the occurrence and alert decision, rather than relying on state captured before scanning. Obsolete occurrences cannot trigger a historical-summary notification by themselves; their count may appear in the in-app audit summary.

Claude's `MessageDisplay.message_id` is explicitly distinct from transcript message IDs. For content without a proven shared identity or lossless mapping, select one authoritative collector. Prefer a validated history reader for canonical occurrences and use the hook to trigger a bounded read. If that reader is unavailable or incomplete, keep hook ownership and disable overlapping history imports for that content type, showing the resulting historical gap. Do not use text/time similarity to silently merge or append overlapping observations. [Claude displayed-message identifiers](https://code.claude.com/docs/en/hooks#messagedisplay-input).

Acceptance examples for a distinctive test value:

- Hook observes tool call A, then history observes A: one inventory record, one occurrence, one alert decision.
- Tool call B in the same session prints the same value: the same inventory record, a second occurrence, no second alert.
- A new session prints the same value: the same inventory record, a new occurrence, one new alert decision for that session.

Test history-first and hook-first arrival, concurrent ingestion, restart/retry, rule upgrades, truncated hook/full history pairs, shifted offsets, repeated values at different ranges, and deletion followed by catch-up and genuinely appended content. An adapter cannot claim both live and historical coverage until its identity and reconciliation tests pass.

## Implementation milestones

### 0. Prove collection, detection, and vault feasibility

Use synthetic data only. Create disposable sessions and agent configurations, not modifications to the user's existing hook settings.

This milestone was exploratory work and its separate projects and reports have been removed. Production [agent and scanner fixtures](../Tests/Fixtures/README.md), signed-app acceptance tooling, and [implementation reports](implementation/milestones.json) remain. The following gates record the original feasibility requirements; the [release checks](implementation/release-checks.json) preserve the outstanding platform requirements and the user's authorization to continue implementation.

- Test Codex through T3 and the standalone CLI for successful shell/MCP outputs, errors, prompts, intermediate responses, final responses, and subagent content. Verify what is absent. Treat Desktop as an additional capability to add after validation.
- Test the same content types for Claude Code through T3 and the standalone CLI. Compare batch results, individual results, failures, and display-message collection. Validate local Desktop Code sessions separately before adding support. Ordinary Claude Chat is outside the initial Code adapter.
- Test read-only history access, an old session with a recent message, timestamps, pagination/checkpoints, source deletion, file rotation, and partial writes. Measure bytes read rather than only elapsed scan time.
- Consult the session reader guidance for framing and synthetic recovery scenarios. Preserve all supported roles, scan before clipping, use keyed content fingerprints, and distinguish canonical conversations. Test compressed histories and relocated stores as explicit capabilities rather than assuming existing support.
- Test source opening for available, active, unavailable, and deleted sessions. Establish the fallback behavior for each interface.
- Run pinned stable Betterleaks against the annotated corpus with network access blocked, using Gitleaks as a baseline and TruffleHog as an optional comparison. Evaluate any Betterleaks v2 prerelease separately. Measure category precision/recall, exact extraction, distinct occurrence recovery, runtime, and memory. Include low-confidence results, contextual passwords, credential URIs, malicious ignore comments, and output presented as instructions. Add Swift rules only if this reveals specific coverage gaps.
- In a signed minimal Mac app, prototype `LAPersistedRight` first and Security.framework access-controlled keys if needed. Prove locked background encryption, authenticated private-key use, password fallback, canceled authentication, lock/sleep invalidation, and restart/key availability. Test macOS 14 as well as the development Mac, including hardware without Touch ID.

Exit gate: choose a documented collection path for every intended content type, or explicitly narrow supported coverage; prove retained values can be written while locked and read only through the authenticated workflow; select the scanner from measured results. No broad UI build before these gates.

### 1. Establish the app and core contracts

Create the Xcode application and compiled hook-helper targets, the core Swift package, and test-fixture layout. Add the menu bar and main-window lifecycle with synthetic masked data. Define normalized source records, extraction/range contracts, adapter capabilities, and monitoring state.

Monitoring enabled/paused, queue activity, and partial coverage are separate state dimensions. The menu bar summarizes them without discarding information.

Exit gate: closing the window leaves the process running, quitting shuts it down, and replay/occurrence/alert contract tests pass without an agent installed.

### 2. Build protected ingestion and persistence

Implement framed local IPC, same-user checks, payload/deadline limits, encrypted queue insertion before acknowledgment, GRDB migrations, keyed fingerprints, the inventory vault, and masked diagnostics. Add worker cancellation, bounded retries, crash recovery, and deletion.

Checkpoint advancement must follow durable processing. It must not run past data that was dropped or rejected without recording a coverage gap. Keep processed-source identities free of retained values and excerpts, including after deletion.

Exit gate: inject a crash before and after commit, restart without duplicate occurrences, inspect database/WAL/temp files for synthetic plaintext markers, reveal a retained value after deleting its source, and delete it from active app storage. Test missing or unusable Keychain keys as an explicit recovery state, never a silent empty database.

### 3. Deliver one complete agent path

Start with Claude Code unless milestone 0 finds Codex materially simpler. Implement the validated collector, normalization, versioned Betterleaks report parser, any fixture-justified supplemental rules, and occurrence grouping. Prefer Claude's model-visible batch result for tool-output authority when validated. Add individual failure events only where they supply missing coverage.

Add safe adapter setup and removal. Merge only Spillcheck's owned hook entries, preserve unrelated configuration, write changes atomically, and verify a synthetic event before reporting connected. Resolve executable paths explicitly and invoke source commands with argument arrays, never source-derived shell text.

Exit gate: a synthetic secret flows from each supported content type into one encrypted inventory record with correct occurrences and evidence. A repeated value in a new session creates the specified alert decision; a replay adds nothing. Scanner failure produces visible partial coverage and bounded retries.

### 4. Add the second agent and bounded catch-up

Implement the remaining agent adapter and its capability-specific fallback selected in milestone 0. Add catch-up on first launch, restart, and resume with a rolling seven-day cutoff based on source content time. Live collection continues through a fair queue while historical work is bounded.

Use independent source checkpoints and a budgeted history enumerator. Stop when the time/byte budget is reached, retain progress, and show the period actually covered. An unavailable history route means some paused/stopped content may be unrecoverable; show that gap. Never silently expand to a full-history scan.

Exit gate: find a recent message in an old session, exclude older content, avoid reprocessing unchanged sources, preserve deletion across backfill, and reconcile overlapping collectors without merging legitimate repeated appearances.

### 5. Complete the user workflow

Implement inventory filtering, detail/occurrence views, reversible review, rotation/revocation acknowledgement, content removal, explicit forgetting of obsolete markers, authenticated reveal and immediate masking, source-opening/fallback states, notification navigation, pause/resume, and optional launch at login. Raw excerpts remain hidden before authentication. Notification text uses controlled agent/type labels and an approved masked conversation label.

Exit gate: the full viewing and lifecycle workflow works with notifications allowed or denied, source sessions unavailable, authentication canceled, and monitoring paused. Quitting ends worker/helper activity owned by the app. Hooks invoked after quit or during pause return promptly without storing payloads.

### 6. Validate and package the MVP

Run all acceptance criteria from [SPEC.md](SPEC.md#prototype-acceptance-criteria) against the supported matrix. Add large-history, queue saturation, repeated-output, malformed JSON, Unicode, multiline private-key, and agent-update fixtures. Test acknowledgement and deletion while capture is in flight, forgotten obsolete markers, and a different replacement value in the same conversation. Verify collection, scanning, inventory, review, and alerts with external services blocked.

Sign and notarize the app and bundled executables. Test install, update, configuration repair/removal, key persistence across upgrades, and unsupported-version messaging. Publish actual coverage, limits, source-observation latency, application latency, losses, and known gaps.

Exit gate: the supported behaviors meet the declared budgets; every remaining gap is visible and documented. Do not claim exhaustive secret detection or coverage of unvalidated interfaces.

## Initial budgets for the prototype

These are proposed starting limits, not measurements or release promises. Change them from milestone 0 results and record why.

| Area | Initial target or limit |
| --- | --- |
| Hook delivery | At most 200 ms per helper delivery attempt, including IPC acknowledgment; measure process startup separately. Use background hook mode only where its behavior is validated. Never wait for detection. |
| Detection latency | Below two minutes at the 95th percentile after content becomes observable, as proposed in the spec. Report upstream observation delay separately. |
| Durable queue | 100 MiB total encrypted payload budget, 24-hour payload expiry, 8 MiB maximum single event. Oversize/drop/expiry cases increment a coverage gap; no silent truncation. |
| History work | Rolling seven days, an initial 100 MiB or 30-second read budget per pass, then yield and preserve progress. Benchmark unchanged and changed histories separately. |
| Retained excerpts | At most 4 KiB of context around each occurrence, with visible clipping. Preserve the exact value separately even when it exceeds the excerpt bound. |
| Concurrency | One scanner worker initially, with capture prioritized over historical work. Bound retries and message reassembly by age and size. |

No inventory entry expires automatically. Pending-event expiry and the source audit window are separate from retained-secret lifetime. Track metadata overhead, storage growth, and actual memory usage; set release limits after profiling. A scanner must finish an accepted event within the processing budget or report failure and partial coverage.

## Deviations recorded after the implementation review

The inventory ledger is one sealed snapshot row, replaced on every commit under a revision check, rather than per-occurrence SQLite rows. Occurrence, receipt and alert uniqueness are ledger invariants validated on load, not SQLite unique constraints. Ledger growth is bounded: the pipeline never analyzes content older than the seven-day window plus the one-day queue expiry, and processed-source receipts are compacted a day beyond that while the worker is idle. The 64 MiB state limit therefore applies to retained inventory, not to analyzed history.

Other bookkeeping is bounded too. Capture receipts are kept for 48 hours, as they only deduplicate retried deliveries of pending captures. Coverage-gap rows are kept for 30 days. The menu bar reports partial coverage for gaps recorded in the last 24 hours and for unread content in each profile's latest audit.

Codex public history is polled only while a thread is active: every second for two minutes, then backing off, and stopping after an hour until the next hook. Every hook capture still reads its thread. An audit skips a Codex thread whose metadata shows no change since an earlier audit fully read it, provided its last update preceded that audit's end. Claude audits reread only rows that the previous audit left to live collection.

Retained excerpts replace other detected values in their window, so deleting or acknowledging one value cannot leave it revealable through a neighbour's context. An alert withdrawn before delivery releases its value/conversation eligibility, so the next strong occurrence in that conversation notifies.

App integration is checked by compiled controller probes and scripted signed-app runs rather than an XCTest target. Release builds ignore the test-only launch arguments. Direct source opening stays disabled until a route is validated.

## Completion and remaining release work

The local development implementation and native workflow are complete under the recorded deferrals. [Execution status](implementation/milestones.json) retains the original release gate as open. Use `make scanner-dependencies`, `make test`, and `make app` for the production build and core checks. Live-provider and signed-app acceptance commands remain with their implementation reports and test runners. Published evidence uses the [sanitization conventions](implementation/README.md). Open the development bundle at `.build/app/Build/Products/Debug/Spillcheck.app` after building.

Genuine standalone CLI latency is measured for [Claude 2.1.293](implementation/m6-claude-observation-latency.json) and [Codex 0.161.0](implementation/m6-codex-observation-latency.json). Their read-start-to-commit-observation p95 values were 340.2 ms across 12 live revisions and 785.1 ms across eight live revisions. These small fixtures exclude replay and final catch-up; provider timestamps do not prove first-byte publication, and T3 and historical latency remain unmeasured. Codex native child prompt coverage remains unverified.

The selected collection authorities and scanner are documented in the reports. The vault uses a persisted LocalAuthentication right, per-payload AES-GCM keys wrapped by its public key, and separate queue encryption. The production history reader has measured bounded cold, unchanged and append passes; unstable/replaced sources expose gaps. macOS 14 runtime and hardware without Touch ID remain required open checks. No release baseline or authentication requirement has been narrowed.

The [signed restart/cooperative offline sequence](implementation/m6-signed-restart-offline.json) passed 27 checks across four normal app runs, covering deletion, obsolete-marker persistence, new appearances, replacement, forgetting, native review and masked notification navigation. Its trusted scanner-bootstrap exception is a generic escape, so no secure all-descendant or system-wide network-denial claim is made. All measurement categories required by SPEC criterion 10 have results; unmeasured workload/interface distributions and physical first-byte publication remain documented limits.

Before release, provision Developer ID distribution and notarization, validate install/update and vault access across that upgrade, and test the two deferred platform environments and actual login launch. Broader resource and offline matrix checks can expand the recorded evidence without changing its current scope. Claude 2.1.294 remains unsupported until validated. The confirmed ADR decisions remain in force. Automatic remediation, secret validity checks, cloud sync, OpenCode, and full-history auditing remain outside the MVP.
