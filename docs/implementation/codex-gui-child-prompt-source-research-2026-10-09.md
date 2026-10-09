# Codex GUI native child prompt source investigation

Measured on 2026-10-09. The genuine R3 local GUI fixture used official host
`26.930.61225` build `13232`, native producer `0.160.1`, and passive reader
`0.161.0`. Its observer committed fourteen occurrences across the exact original
parent and native child: all five parent content types and four child types,
with nine typed fixture markers observed live. Replay, reader restart, encrypted
retention, empty queue and bounded shutdown passed. The child prompt gate did
not pass. [Live partial evidence](harness-compatibility-codex-gui-live-r3-2026-10-09.json).

The fixture did not submit its requested child prompt marker. A bounded,
read-only diagnostic of the exact public-verified original sources found the
marker in the parent user prompt but absent from the actual native spawn call's
otherwise valid message/task arguments. It was also absent from recognized
user, developer and assistant records in the child source. This is fixture
noncompliance, not evidence that the provider cannot expose a correctly
submitted child prompt. The native spawn call ID matched the parent's public
linked-child item ID. All six child original response-message records had native
IDs; their presence alone does not prove correspondence with every public item.
[Input compliance and source evidence](harness-compatibility-codex-gui-native-child-source-r3-2026-10-09.json).

## Passive public alternatives

The official App Server documentation describes `thread/read` with
`includeTurns: true` as a stored read without resuming or subscribing. It also
documents experimental `thread/turns/list` with `itemsView: "full"` and
experimental persisted `thread/items/list`; item pagination requires store
support. These are passive alternatives within the public-history authority.
[App Server contract](https://learn.chatgpt.com/docs/app-server).

A separate bounded diagnostic revalidated only the R3 parent's own runtime
identity, authorized store, original project and native link to the exact child.
It then compared those three public methods on the child. They returned the
same native item-ID sets: two assistant messages, three command items and one
reasoning item, with no user-message item or requested prompt marker. All pages
were complete. The owned reader was network/fork denied, stopped cleanly, and
its private workspace was removed. No provider turn, settings change, discovery
or raw archive occurred. This establishes method equivalence on this fixture,
not coverage of a correctly submitted child prompt.
[Full-history evidence](harness-compatibility-codex-gui-passive-full-history-r3-2026-10-09.json),
[bounded diagnostic](../../Tests/CodexGUIProbe/passive-full-history-diagnostic.py).

## Hooks and original-source authority

The official hook contract gives subagent hooks the parent's `session_id` and
separate `agent_id`. `SubagentStart` documents no prompt field.
`UserPromptSubmit` supplies prompt text and a turn ID, but documents no native
item ID or guarantee for the child's follow-up input. `PreToolUse` includes
tool-call ID and arguments; specialized paths can opt out. The transcript path
is a convenience, not a stable format contract. Ordinary hook review and trust
are required. These fields do not authorize assigning parent arguments to a
child item. No hooks were installed or trust bypassed for this investigation.
[Hook contract](https://learn.chatgpt.com/docs/hooks).

The existing Core native-rollout alternative is explicitly selected for T3 and
uses a different exclusive raw authority. Its tool identity uses a
`tool:` prefix around the native call ID, whereas public history uses its native
item ID. Existing authority selection and encrypted identities therefore cannot
be silently switched or combined because a sibling format contains useful
text. A production change would need an explicit supported route, measured
native ID and content-range correspondence, and migration/overlap acceptance.
The bounded original-source diagnostic added no collection fallback.
[Authority and native import](../../Sources/SpillcheckCore/CodexAdapter.swift).

## Next genuine fixture

R4 is prepared and compiled against a matched current Core snapshot; its three
scope/artifact regressions passed using that exact executable. No session is
created by preparation. It creates one identity-only native child, waits for its
READY response, then sends the exact literal prompt marker and content
instructions as a separate `send_input` to that same native child ID. Public
history must expose the marker as a true child user-prompt item; parent tool
arguments cannot substitute. The official subagent documentation describes
steering an existing native agent thread, while actual tool availability and
input fields remain part of this genuine GUI test.
[Subagent documentation](https://learn.chatgpt.com/docs/agent-configuration/subagents),
[manual probe](../../Tests/CodexGUIProbe/README.md).

In the genuine R4 manual run, the user reported unavailable native `send_input`
after the parent steps and native child bootstrap completed. The fixture
stopped before submitting the separate child content input. The collector
finished cleanly with ten occurrences and four parent typed markers live;
parent final items and child bootstrap items were readable, but no child
content fixture marker committed. Exact-source replay added no occurrences.
[R4 stopped-fixture evidence](harness-compatibility-codex-gui-live-r4-2026-10-09.json).

This unavailable input step does not establish a general child-prompt collection
limitation. No further provider turn was requested. The native child prompt gate
remains open. Production
Desktop collection, signed GUI setup/collection, owned native hooks, native
opening, six-way concurrency, upgrade recovery and scoped degradation are not
established by these source-format diagnostics.

## Original spawn input and public child identity comparison

A subsequent bounded read compared only the exact R3 and R4 parent spawn
arguments and their own public-verified child sources. Both actual spawn calls
used `message`, `fork_turns: "none"` and `task_name`. Neither recorded message
matched the complete quoted fixture literal. The R3 message lacked the required
child prompt marker; the R4 message lacked the literal bootstrap READY/helper
text. This establishes an omitted or rewritten literal in the recorded parent
call, not the mechanism by which the child received its operative instructions.
It must be kept separate from the operator's report that R4 native `send_input`
was unavailable.

Each original child had one user-message ID and three developer-message IDs;
none appeared in any of the three complete public-history reads. Both original
assistant-message IDs matched the public assistant items. Recognized original
user/developer text blocks contained neither the recorded parent spawn message
nor the expected fixture/bootstrap markers. R4's READY marker appeared in its
assistant result only. A completed bootstrap therefore does not prove that its
instruction was stored as a native child user-prompt item. These observations
do not establish inability to expose a correctly submitted prompt through every
supported route.
[R3 original/public comparison](harness-compatibility-codex-gui-spawn-prompt-contract-r3-2026-10-09.json),
[R4 original/public comparison](harness-compatibility-codex-gui-spawn-prompt-contract-r4-2026-10-09.json).

A one-shot candidate could set the actual spawn `message` to a complete literal
starting with the child prompt marker, requiring a child self-check before any
content work. A self-reported manifest would still not establish native prompt
authority: the exact public child user item must independently expose that
input. Given the observed initial user-item omission and unresolved task delivery
contract, no further fixture was prepared or requested. No original sources,
authority selection or canonical identities were changed.
