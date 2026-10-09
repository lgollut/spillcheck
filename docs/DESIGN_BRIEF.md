# Spillcheck design brief

Working reference for UI design and UX review. Updated October 8, 2026.

This document contains the product context needed to design Spillcheck without reading the repository. Product behavior and current limitations are established facts. Recommendations and open design questions are labeled separately so a proposed layout cannot silently become a product requirement.

## What we are building

Spillcheck is a native macOS app that finds secrets in agentic development sessions and collects their appearances in a local inventory. It monitors Codex and Claude Code workflows, alerts the user to strong detections, and helps them inspect the evidence and record what they have addressed.

A developer can accidentally expose a credential when an agent reads a configuration file, runs a command, or receives a pasted message. The credential may appear only in a tool result. The model does not need to repeat it for Spillcheck to detect it.

The main user question is "Which secrets appeared, where did they appear, and what still needs my attention?" A successful workflow ends with the user understanding an appearance and making a deliberate review or acknowledgement decision. A detection does not establish that a credential still works or that anyone else accessed it.

The audience is developers using coding agents on their own Mac. Familiarity with developer tools is reasonable; familiarity with scanner rules or Spillcheck's collection mechanisms is not.

## Product baseline and scope

The local development MVP already exists. Design iteration can reshape its presentation and interaction while preserving the behavior below. Release validation and distribution remain unfinished. The target is macOS 14 or later on Apple Silicon.

- Analysis, detection, and inventory storage happen on the Mac. Spillcheck sends no session content, secrets, or detection results to an external service.
- The scope includes API keys, tokens, passwords, private keys, and credentials in connection strings.
- Collection targets Codex and Claude Code through T3, an app that hosts coding-agent conversations, and their standalone CLIs. Support depends on the validated interface and agent version. Desktop collection and direct conversation opening remain unverified.
- Collection includes user messages, intermediate and final model responses, successful tool output, and tool errors where the adapter supports them. Coverage is bounded and must be described honestly.
- Monitoring is asynchronous. A delay of tens of seconds to a few minutes is acceptable. Spillcheck discovers appearances after content becomes available; it does not block a secret from entering an agent session.
- Exact values and context excerpts are retained encrypted until explicitly removed. They remain available if the original conversation disappears.
- The first version supports review and acknowledgements of rotation or revocation. The user changes credentials at the relevant service themselves.

General personal-data detection, full-history scans, automatic credential changes, service-side validity checks, cloud sync, migration recovery, and additional agents are outside this version. Service-console links, remediation instructions, and a dedicated copy control are possible later additions.

## The mental model

Use these terms consistently in labels, counts, and discussions:

- A **value** is the exact text detected as a possible secret. The inventory groups the same value across conversations and agents. A replacement credential is a different value.
- An **occurrence** is one appearance of that value in a message or tool result. One value can have many occurrences.
- A **session** or **conversation** is a development conversation with an agent. A project can contain several conversations.
- A **detection** is the scanner's signal and evidence for an occurrence.
- **Monitoring** observes new session content. A **historical audit** analyzes eligible retained content from the last seven days.
- **Coverage** describes what was actually observed and analyzed, including gaps. A connected agent proves a working collection route, not complete coverage.

Three independent kinds of status must remain understandable:

1. Detector signal is strong or ambiguous. Ambiguous, unreviewed occurrences need review. A strong signal can also remain unreviewed.
2. User review belongs to an occurrence. It can be unreviewed, confirmed as a secret, or marked as a false positive. Review is reversible. One value can have mixed reviews across its occurrences; a false positive does not create a blanket exclusion for future appearances.
3. Rotation or revocation acknowledgement belongs to the exact value. The user reports that they replaced and invalidated it, or invalidated it without a replacement. Spillcheck treats later appearances of that value as obsolete. It does not verify the acknowledgement with the service.

Counts must name what they count. "3 values in 12 occurrences" is meaningful. An undifferentiated "12 secrets" can exaggerate the amount of work.

## The main workflows

### Connect an agent

The user discovers available agents, chooses a profile and interface, installs Spillcheck's hooks, and verifies delivery from a fresh agent session. A profile identifies the agent configuration and histories the user wants analyzed; the interface is T3 or standalone CLI. Codex's normal hook trust review remains part of setup. Existing agent configuration is preserved, and removal affects only Spillcheck's owned hooks.

Setup must distinguish an executable found, hooks installed but unverified, a verified connection, and an unsupported or unavailable configuration. An unsupported agent update can invalidate a previous connection. Each incomplete state needs an explanation and the appropriate next action, such as verify, repair, or select a supported version.

The current settings expose executable paths, profile directories, and versions. A design opportunity is to make the normal detected configuration easy to accept while keeping manual configuration available. A newly installed app needs a useful setup state before it has any inventory data.

### Investigate a new appearance

For a new value with a strong signal, the user receives a masked macOS notification. Opening it selects the corresponding inventory detail while protected content remains masked. The detail should let the user establish what was detected, how often it appeared, and which occurrence to inspect before revealing anything.

The user can authenticate, inspect the exact value and retained context, review the selected occurrence, and access its source when a validated route is available. Tool output and tool error must remain visible as source types, even if the assistant never mentioned the value.

Alert behavior limits interruption:

- A strong new value alerts once. Its first appearance in another conversation alerts again and joins the existing value record.
- Repeated appearances in the same conversation add occurrences without repeated alerts.
- Replaying already processed content adds no occurrences or alerts.
- Ambiguous detections enter the inventory for review without an immediate notification.
- If macOS notifications are disabled, detections remain visible in the inventory and app indicator.

### Inspect an unavailable source

Direct conversation opening is a capability with known limits, not a guaranteed outcome. Show an unavailable or unverified route clearly and offer authenticated retained context when it exists. A transcript file path is not a conversation deep link.

The existing app can separately prepare an authenticated terminal resume command. It displays the command for the user to run. Resuming can cause new provider requests, so the interaction must explain that effect and remain distinct from simply inspecting retained evidence.

A detector result whose exact source range could not be located has its own state. Show the available evidence and source information, with an explicit explanation that there is no exact value to reveal.

### Record that a credential was addressed

After changing the credential at its service, the user can acknowledge the old exact value as rotated or revoked. Later new appearances of it remain visible as obsolete and produce no notification. A different replacement value receives ordinary detection and alerts.

There are three separate actions with different consequences:

- **Acknowledge rotated or revoked** records the user's report and changes treatment of future appearances. It does not change the credential at its service.
- **Remove retained content** removes the exact value, excerpts, and occurrence history from active Spillcheck storage. It leaves agent histories alone. If the value was acknowledged obsolete, its recognition marker remains; otherwise a later new appearance can be detected normally.
- **Forget obsolete recognition** removes that marker and acknowledgement. Future new appearances return to ordinary evaluation and may alert. Already processed history is still prevented from recreating removed occurrences.

The recognition marker holds no retained value, excerpt, or old occurrence history. A new obsolete appearance after removal stores only its source reference, time, and obsolete label. It has nothing to reveal and no context fallback if its source disappears. This state must look different from protected content that is merely locked.

Confirmation text should name the affected value and scope through safe labels, explain the relevant consequence, and use an action-specific button. A generic "Delete" or "Resolved" would conceal distinctions the user needs.

### Leave, pause, and return

Closing the inventory window masks protected content and keeps monitoring running in the menu bar. Pause suspends collection, analysis, and alerts. Quit stops monitoring. Launch at login is optional and off by default.

First launch, restart, and resume trigger bounded catch-up for the last seven days of content. Recent messages in an older conversation can qualify. Inventory entries themselves do not expire after seven days.

Catch-up produces a masked summary instead of individual notifications for every historical occurrence. An audit containing only obsolete appearances sends no summary notification. Show the requested period, observed content, progress, and any unread history or gaps. The earliest and latest observed timestamps do not prove continuous coverage between them.

## Information the UI needs to present

The following is a recommended hierarchy. Screen structure and navigation remain open.

### Inventory

Make comparison and selection easy while values stay masked. Each entry needs a suspected type, agents, occurrence count, last observation time, and a useful summary of review and acknowledgement status. Provide agent, conversation, and review filters. Obsolete values and unlocated detections need recognizable entry types.

An empty state must distinguish setup still needed, no detections in analyzed content, a scan still underway, and filters matching nothing. An empty inventory alone is insufficient evidence for "Everything is safe."

A design question is how users recognize several masked values of the same type. Safe, stable labels and occurrence metadata can help; raw value fragments are not an assumed solution.

### Value and occurrence detail

The user should be able to answer these questions in order:

1. What kind of value is this, and what did the detector conclude?
2. Which occurrences remain unreviewed, and has the value been acknowledged obsolete?
3. Where and when did a specific appearance happen, and was it a prompt, model response, tool output, or error?
4. What retained value and context can I inspect after authentication?
5. What review, source, acknowledgement, or removal action is appropriate here?

Keep occurrence review controls attached to the occurrence they change. Show mixed reviews at the value level. Explain evidence in plain language, with rule identifiers available as secondary detail. Retained excerpts can be clipped and must be identified as excerpts rather than complete conversations.

### Monitoring, history, and settings

The menu bar needs a quick route to the inventory, understandable monitoring status, pause or resume, and quit. The main window also needs persistent access to coverage and recent-history results.

Keep monitoring choice, processing activity, and coverage separate. "Monitoring enabled, processing recent history, partial coverage" is a valid combined state. So is enabled and idle. Scanner failures, unreadable sources, unsupported versions, and dropped or expired captures need visible consequences and relevant recovery actions.

Settings cover agent discovery and connection management, notification permission, launch at login, and an explanation of protection and collection limits. Detailed setup information can be disclosed when needed; failures affecting current monitoring deserve visibility outside Settings.

## Protection is part of the interaction

Exact values, raw context, conversation titles and identifiers, and project paths stay protected until macOS authentication authorizes a viewing session. Locked views and notifications use app-controlled conversation labels such as "Conversation 4". Arbitrary session text must not leak through a title, tooltip, preview, or accessibility label.

Support masked, authenticating, revealed, cancelled, failed, and unavailable-content states. Cancelling or failing authentication leaves protected content masked and lets the user retry. Use the system Touch ID or password prompt.

A viewing session locks after five minutes of inactivity, when the window closes, when the Mac sleeps or locks, and when the user chooses Mask. Selection changes clear revealed content; authentication finishing for an old selection must not reveal it in a new detail view. Monitoring can continue while viewing is locked.

Masked content, removed content, and an unlocated value have different meanings. Their explanations and available controls must match what the app can actually show.

## Design direction to explore

The recommended posture is a quiet native utility that makes evidence and next actions easy to read. Developers may keep it running all day and open it only when interrupted by a detection.

Prioritize readable lists, clear selection, stable layout during background updates, and a restrained distinction between ordinary activity and conditions requiring attention. Use text and icons alongside status color. Keyboard navigation, visible focus, accessible labels, and readable contrast matter for the inventory and all its actions.

Visual style is unsettled. This brief does not select branding, colors, typography, density, or a particular window layout. Mockups should use synthetic values and fictional context that still exercise the real privacy and state rules.

## Questions for the first design iterations

- Should opening the app prioritize all recent values or the work awaiting review? How does the user move between them without losing context?
- Does a two-column inventory and detail view give enough room for occurrence review, or should occurrences have their own navigation level?
- How should a value with strong signals, mixed reviews, and a rotation acknowledgement summarize its status without collapsing those facts?
- How prominent should remembered obsolete markers be after their retained content is removed?
- How can setup make the chosen profile, interface, and verification step clear without making every user edit filesystem paths?
- Where should coverage gaps and historical progress appear so the user understands an empty inventory and can act on incomplete monitoring?
- How should source-opening limitations be presented before the user commits to that action?

Resolve these through concrete flows and state examples, and record the accepted choices.

## Review scenarios and completion criteria

Use these fictional scenarios to evaluate an iteration:

1. A fresh install finds Codex, but delivery is unverified. The user can identify the next setup action and understands that monitoring is not yet proven.
2. A token appears twice in one tool output and once in another conversation. The UI represents one value and three occurrences, with an alert for each conversation's first strong appearance.
3. One occurrence is confirmed and another is a false positive. The value summary communicates mixed reviews, and changing either occurrence leaves the other unchanged.
4. The user cancels authentication, then retries successfully. The cancelled state exposes no protected content; the successful state offers an obvious way to mask it.
5. The source conversation disappears. A retained occurrence still offers authenticated context. An obsolete appearance recorded after content removal accurately shows that no context was retained.
6. The user acknowledges rotation, removes retained content, and later sees the old value again. It appears obsolete without an alert or reconstructed secret. A replacement value receives ordinary treatment.
7. The user resumes after several days with notifications disabled and unread history remaining. The UI explains the catch-up result, remaining gap, and notification limitation without claiming complete coverage.

An iteration is ready for review when its affected flows include the relevant empty, loading, masked, success, and failure states; each action has a clear scope and consequence; and every scenario it touches can be understood without a verbal explanation from the designer. Record which open question the iteration answers and what remains undecided.

## Basis and maintenance

This brief synthesizes the confirmed product specification, domain vocabulary, obsolete-value retention decision, implemented app workflows, and current acceptance evidence. Its content is self-contained. Repository references are provided for checking or updating a decision:

- [Product specification](SPEC.md) and [domain vocabulary](../CONTEXT.md).
- [Obsolete-value retention decision](adr/0004-remember-obsolete-values.md).
- [Validated collection scope and limitations](implementation/supported-matrix.md).
- [Native workflow acceptance](implementation/milestone-5.md) and [release limitations](implementation/milestone-6.md).
- Current presentation and interactions in `Spillcheck/App/InventoryView.swift`, `InventoryDetailView.swift`, `SettingsView.swift`, and `Sources/SpillcheckCore/InventoryPresentation.swift`.

Revise the relevant section when a product decision changes or a limitation is validated. Keep proposed UI choices labeled until they are accepted.
