# macOS application for auditing secrets in agentic sessions

Status: consolidated product specification following the interview. Confirmed choices are distinguished from technical proposals and capabilities that require prototype validation. Updated: October 7, 2026.

## Problem and expected outcome

During an agentic development session, a confidential value may appear in a tool output or a message. The user wants to find these appearances in a central inventory, receive an alert, and track how they are addressed.

The application must retain the source of each occurrence. It must be able to detect a tool output containing a key even if the model does not repeat that key in its response.

The [glossary](../CONTEXT.md) defines the vocabulary for secrets, sessions, outputs, occurrences, and remediation actions. A detection represents an observable signal. It does not prove that the value is still usable or that a third party has accessed it.

## Decisions confirmed by the user

- Native macOS application, running locally. No service mode is requested for this version.
- The first implementation must support installation and updates beyond the development checkout.
- The release baseline is macOS 14 or later on Apple Silicon, distributed directly as a signed and notarized app. Advertise Intel support only after validating an Intel build.
- Codex and Claude are the initial target agents. OpenCode may be considered later.
- T3 workflows using Codex or Claude Code and their standalone CLI workflows are required first. Add local Desktop Code support as its coverage is validated. Ordinary Claude Chat is outside this initial scope.
- Central inventory of secrets observed in conversations and tool outputs, with a view to rotating or changing those secrets.
- Tool output hooks are the preferred approach to collection.
- Asynchronous processing. A delay of a few tens of seconds to a few minutes is acceptable. Analysis does not need to follow every output fragment in real time.
- A detection with a strong signal triggers an alert. An ambiguous case appears in the inventory as "needs review".
- The first version includes a user interface with a list of detected secrets. The inventory is a core application feature.
- The user must be able to view the exact value of the detected secret from the application.
- Each occurrence must offer a useful way to access its source conversation in Codex or Claude. Documented routes and their limitations are detailed below.
- Remediation assistance may arrive in a later version. The user's proposed examples are a link to the service console and instructions for changing the secret. The behavior remains to be defined.
- The MVP must let the user acknowledge that a value was rotated or revoked. A genuinely new appearance of that same value is classified as obsolete. A different replacement value is evaluated and alerted normally. This acknowledgement does not verify invalidation with a service.
- The MVP analyzes content entirely on the Mac. It does not send conversations, tool outputs, secrets, or detection results to an external service.
- The inventory retains a local encrypted copy of the exact value, available even if the source conversation disappears. The value stays masked by default and can be revealed on request.
- If the conversation cannot be opened directly, the detail view shows a retained context excerpt stored encrypted, along with the conversation title and identifier when available. The button opens the conversation when that route is available.
- When the application opens, the historical audit is limited to the last seven days. The volume of content to read and analyze must remain manageable. A full scan of the entire history is not requested.
- The scope covers API keys, tokens, passwords, private keys, and credentials in connection strings. Detection of general personal data is outside the MVP's scope.
- macOS authentication with Touch ID or a password protects value revelation for each viewing session.
- Retained secrets stay in the inventory until explicitly deleted. The seven-day source window does not determine their retention period.
- Recovery after loss of the Mac or migration to another Mac is not required for the MVP. This does not introduce automatic expiration of inventory entries.
- The user can mark a detection as a false positive.
- The user can also confirm that an occurrence contains a secret. Review does not assert current credential validity.
- A new value with a strong signal triggers an alert. Its first appearance in a new conversation also triggers an alert. Repeated appearances in the same conversation are grouped.
- Closing the window keeps monitoring running in the background. The menu bar shows its status and provides a pause command.
- Quitting the application stops monitoring. Launching at Mac login is a preference disabled by default.
- Historical audits at first launch, restart, and resume produce a summary rather than individual alerts for old occurrences.

These choices are recorded in the [local analysis](adr/0001-local-analysis.md) and [value retention](adr/0002-retain-encrypted-values.md) decisions.

## First-version workflow

The workflow implements the confirmed behaviors. Adapter mechanisms still need validation against the targeted interfaces and versions.

1. Receive session content through Codex and Claude Code adapters.
2. Place events in a protected local queue, then return control to the agent promptly.
3. Extract and analyze relevant text content in the background.
4. Create a detection with its reason and source, then group occurrences of the same value.
5. Present secrets in the inventory, allow the exact value to be revealed, and provide access to each source conversation.
6. Alert the user to strong signals, with masked content and access to context.
7. Present uncertain cases for review and allow them to be confirmed as secrets or marked as false positives.
8. Record the user's acknowledgement of rotation or revocation and classify later appearances of the same value as obsolete.

Analysis of the last seven days supplements event collection at first launch and during catch-up when the application reopens. The exact reading mechanism and its coverage still need validation.

The main window presents the inventory and its detail views. The menu bar provides access to the inventory and monitoring status.

## Collection and coverage

The intended coverage includes tool outputs, user messages, and intermediate or final model responses. Adapters must state which interfaces, versions, and content types have actually been validated. Any missing type remains a visible product limitation and an issue to resolve in the prototype.

Each event should include the originating agent, session identifier, message or tool call identifier when available, observation time, content type, and a location that allows the context to be found.

### Claude Code

The documentation exposes `PostToolUse` for successful results, `PostToolUseFailure` for execution errors, `UserPromptSubmit` for user messages, and `MessageDisplay` for model response text. The format of tool results depends on the tool. `PostToolBatch` also exposes the serialized content returned to the model after a batch of calls has completed. [Claude Code hooks reference](https://code.claude.com/docs/en/hooks).

`MessageDisplay` observes displayed response text. It does not cover tool outputs. Replacing the displayed text through this event does not replace the transcript content. Event availability and behavior must be tested on the targeted versions and interfaces.

### Codex

The documentation exposes `PostToolUse`, `UserPromptSubmit`, and `Stop`. `Stop` provides the last assistant message when available, which is insufficient to guarantee coverage of all intermediate messages. [Codex hooks reference](https://learn.chatgpt.com/docs/hooks).

The app-server protocol exposes `item/agentMessage/delta` and `item/completed`, among other events. `thread/read` can read history without resuming the thread or subscribing to its events. `thread/turns/list` offers experimental paginated reading. These capabilities do not establish that an independent application can observe all sessions already in use in the Codex app and CLI. This connection still needs validation. [App-server protocol](https://learn.chatgpt.com/docs/app-server).

Tool hooks do not cover every execution path. The Codex documentation distinguishes hosted tools in particular. Local transcripts are not a stable interface. The MVP must therefore not claim exhaustive coverage without measurement.

### Latency and interruptions

Total latency includes the time before the agent provides the content, time spent waiting in the queue, and detection time. A hook triggered at the end of a long-running command may observe a secret printed during execution only much later.

Replayed events must not create duplicate occurrences or alerts. A stable event identifier or a computed equivalent distinguishes a replay from an actual new appearance.

Temporary data containing outputs is encrypted at rest and deleted after processing. The queue has size and age limits to establish in the prototype. Queue saturation, an unavailable source, or lost content must appear in the coverage status and must not block the agent. Hooks do not return captured content in their own diagnostic outputs.

Proposed measurement: aim for latency below two minutes for 95% of available content under a representative workload, with the corpus and volumes stated in the prototype report. Measure separately the delay introduced by the agent before making content observable. This threshold is a technical target, not an observed performance result.

### Returning to the source conversation

Codex Desktop documents `codex://threads/<thread-id>` for opening a local chat. Support for jumping to a specific message has not been established. The availability of each CLI session in Desktop must be tested. The `codex resume <session-id>` command is another route, resuming the session in the terminal. [Desktop deep links](https://learn.chatgpt.com/docs/reference/commands), [CLI commands](https://learn.chatgpt.com/docs/developer-commands#codex-resume).

Claude Code documents `claude --desktop --resume <session-id>` for opening a local CLI session in Desktop and exiting the CLI process launched for that operation. This command is available from version 2.1.285 and rejects sessions open in another terminal or still active in the background. Public Claude Desktop deep links for Chat conversations do not establish a route to every existing local Code session. [CLI sessions in Desktop](https://code.claude.com/docs/en/desktop#coming-from-the-cli), [Claude Desktop deep links](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link).

The workflow distinguishes opening in the application, resuming in the terminal, and viewing retained context. An alert must not automatically execute a command that resumes or moves a session. The user confirmed the fallback: display the context excerpt stored encrypted and the retained title and identifier when direct opening is impossible. The button opens the conversation when that route is available. Deleting the source does not remove the encrypted value from the inventory.

### Historical window

The window applies to the date of the content to analyze. An old conversation that receives a recent message may therefore fall within scope. This rule is a technical proposal to validate against the available data, whose timestamps and reading mechanisms vary by agent.

The prototype must measure the cost of finding this content without reading gigabytes of history every time the application opens. A short detection window is insufficient if selecting its content requires rereading every source. An index, pagination, or a bounded read may support this selection, depending on the adapter.

Technical proposal: retain a read checkpoint for each source and reprocess only new or modified content, with catch-up limited to seven days. An older backlog must not silently trigger a full scan. Newly captured events continue to be analyzed in the background. The workflow must clearly indicate the period actually covered.

The depth of the source audit and the retention period for secrets in the inventory are separate parameters. The historical window does not set an automatic expiration for entries already detected.

## Detection

The engine uses local rules. The prototype will compare an existing scanner with the additional rules needed for conversations and tool outputs.

The confirmed categories are API keys, tokens, passwords, private keys, and credentials in connection strings. Possible signals include known formats, private key blocks, field names, and value entropy. A signal does not prove that the value is an active secret. Detection of a generic value without context remains uncertain. Choosing to cover a category does not guarantee detection of all its values.

The first version analyzes session content. It does not require importing a secret catalog or reading every project configuration file.

[Betterleaks](https://github.com/betterleaks/betterleaks) is the preferred prototype candidate, with a pinned stable version and reviewed rules. Compare it with [Gitleaks](https://github.com/gitleaks/gitleaks) as a baseline; [TruffleHog](https://github.com/trufflesecurity/trufflehog) is an optional comparison. The [stack proposal](adr/0003-native-macos-stack.md#scanner-choice-and-maintenance) records configuration, versioning, exact extraction, and local-only execution requirements. Service verification is disabled in the MVP.

### Signals and review

A strong signal comes from an explicit rule that is sufficiently distinctive, such as a complete known format or a recognized private key block. Field names and entropy can strengthen a signal, but they do not guarantee that a value is a secret. The precise classification of rules will be evaluated with annotated fixtures.

Ambiguous cases have the "needs review" status and do not generate an immediate notification. Each detection shows the rule and evidence that produced it. The user can confirm that an occurrence contains a secret or mark it as a false positive. Review remains reversible and applies to the occurrence. It does not turn a rule into a general exclusion or allow session text to define exclusions.

Detector confidence, occurrence review, and a value's rotation or revocation acknowledgement are separate information. A strong detector signal does not overrule a user's acknowledgement that the value is obsolete, and an obsolete value can still have a real secret occurrence.

Scanned content is data. An instruction in a conversation, output, or comment cannot change the detector configuration, run a command, or mark a detection as a false positive on its own.

## Inventory, alerts, and storage

The inventory groups each distinct value with its occurrences, suspected service, and detection reasons. The same value may be linked to several conversations, projects, or suspected services without being presented as proof of account identity.

The inventory retains an encrypted exact value, encrypted excerpts, and available references until explicitly deleted. Grouping must work without spreading plaintext values into indexes, logs, or diagnostics. The encryption and key protection mechanisms must support background capture and authenticated revelation.

Explicit deletion removes the value, its excerpts, and its occurrences from the application's active storage. It applies to this inventory's data. Histories held by agents retain their own lifecycle. A later new appearance remains detectable.

When retained content for an obsolete value is deleted, keep its keyed fingerprint and the user's rotation or revocation acknowledgement until the user explicitly forgets it or resets the app. The recognition marker retains no exact value, encrypted value, excerpt, or old occurrence history. A genuinely new appearance is recorded as obsolete without a notification. Retain only its source reference, occurrence time, and obsolete label, without saving a fresh value or excerpt. [ADR 0004](adr/0004-remember-obsolete-values.md) records this choice.

Deletion alone never marks a value as obsolete. Explicitly forgetting an obsolete value removes its recognition marker, so a later new appearance undergoes ordinary detection and alerts. Processed-source receipts serve a separate purpose: already analyzed history must not recreate deleted occurrences.

### Viewing workflow

The main window displays the list of detected secrets with a masked value, suspected type, originating agent, occurrence count, last observation date, and review status. Proposed filters: agent, conversation, and review status.

A detail view allows the exact value to be revealed after macOS authentication and presents occurrences with their source, date, and context excerpt stored encrypted. It also retains the conversation title and identifier when available. An action provides access to the corresponding conversation. If that is impossible, the detail view remains accessible with those references.

An obsolete reappearance after content deletion has no retained value or excerpt to reveal. Its detail view shows the source reference, timestamp, and obsolete label and offers source opening when available. If the source disappears, no context fallback exists for that metadata-only occurrence.

Proposed unlocking behavior: a viewing session expires after five minutes of inactivity and locks when the window closes, the Mac sleeps, or the macOS session locks. An action immediately masks values. Before authentication, the value and raw excerpts stay masked. Canceled or failed authentication reveals no protected content. A dedicated copy function may be added later. It is not required for the MVP workflow.

Detections that could not be located must be presented as such, without inventing a value. Conversation opening methods need validation for each agent and interface. A path to a transcript file is not equivalent to a direct link in the agent's application.

### Alerts

The macOS notification for a strong signal identifies the agent, conversation, and suspected type without displaying the value or raw excerpt. Opening it leads to the corresponding detail view. If system notifications are disabled, the new detection remains visible in the inventory and the application's indicator.

| Situation | Behavior |
| --- | --- |
| New value with a strong signal, without an obsolete marker | One alert and one inventory record. |
| Same value in a new conversation, without an obsolete marker | A new alert linked to the same record. |
| Same value repeated in the same conversation | Grouped occurrences, without repeated alerts. |
| Replay of an event already received | No duplicate occurrence or alert. |
| Ambiguous value | A "needs review" entry, without an immediate notification. |
| Occurrence marked as a false positive | The status is retained for that occurrence. Its replay does not create another alert. New occurrences are still evaluated. |
| Historical audit at first launch, restart, or resume | A masked summary instead of a notification for each old occurrence. |
| Previously rotated or revoked value in new content | A new occurrence classified as obsolete, without a notification. |
| A different replacement value | Normal evaluation and alerts; it is a different inventory value. |

An audit containing only obsolete appearances does not send a summary notification. Those appearances remain visible in the application and may be counted in its audit summary.

### Background monitoring

Closing the window keeps collection and analysis running. The menu bar displays a clear status: monitoring active, paused, processing, or partial coverage. A pause command suspends collection, analysis, and alerts until monitoring resumes.

Quitting the application stops monitoring. A hook called while monitoring is stopped or paused returns control promptly, without copying content into its outputs or establishing hidden ongoing collection. Data captured before shutdown and still pending is protected at rest. Resuming processes items that are still eligible and catches up on recent content within the seven-day window.

Launching at Mac login is a preference disabled by default. Initial setup shows which agents are detected and which are actually connected. The presence of an agent executable is insufficient to declare its monitoring active.

## Prototype acceptance criteria

These criteria will be used to validate a future implementation. No application tests were run while writing this specification.

1. Using annotated fixtures, test successful tool outputs, errors, user messages, and intermediate or final responses separately. Document coverage by agent and interface.
2. Find recent content in an old conversation, exclude content older than seven days during the historical audit, and avoid rereading everything each time the application reopens.
3. Verify that a replay adds nothing, that an actual new occurrence is retained, and that the alert matrix is followed.
4. Verify that a strong signal triggers an alert, that an ambiguous case remains marked as needing review, and that marking a false positive is reversible and limited to its scope.
5. Verify that values and excerpts are encrypted at rest, remain masked before authentication, and do not appear in notifications or diagnostics.
6. After deleting a source, reveal the retained value and view its excerpt. Display the fallback if direct opening fails.
7. Close the window, pause, resume, and quit. Check the expected captures, alerts, and monitoring states, without noticeably slowing down the agent.
8. Delete an entry, restart the application, and verify that its protected data is no longer accessible in active storage. A new appearance must remain detectable.
9. With external services blocked, verify that local collection, scanning, the inventory, review, and alerts continue to work.
10. Measure latency, memory, temporary storage, and the volume actually read from a large history. Document limits, any losses, and the period covered.
11. Mark a value as rotated or revoked, delete its retained content, and restart. A replay adds no occurrence; a genuinely new appearance of the same value is obsolete and silent, with no newly retained value or excerpt; a different replacement value in the same conversation follows normal alerts. Explicitly forgetting the marker restores ordinary evaluation for later new appearances.

## Technical issues to resolve before promising coverage

- Passive connection to Codex sessions already in use in Desktop and the CLI, or a validated supplementary collection strategy.
- Coverage of intermediate messages and tool execution paths that do not trigger generic hooks.
- Availability of Claude Code events by interface and version, including error results.
- Actual cost of selecting the last seven days, delays in writing histories, and incremental catch-up.
- Opening conversations from an independent application, especially Claude sessions that are still active.
- Scanner selection, rule validation, performance, and configuration without network verification.
- Encryption mechanism, key protection, authentication, and local queue limits.

The next technical step is a collection and scanning prototype using test data. The expected result is a coverage and performance matrix to guide adapter selection. The interview produced the specification and decisions. No application or hook has yet been installed or implemented.
