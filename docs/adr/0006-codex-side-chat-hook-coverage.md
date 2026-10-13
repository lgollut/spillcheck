# Collect available Codex side-chat hook content

Decision date: 2026-10-11. Status: beta support target superseded by
[ADR 0007](0007-codex-beta-scope.md).

Automatic Codex side-chat support is deferred from the first beta. The earlier
intermediate-message exception below does not establish a current support
promise. The source identity and collection integrity constraints still apply
to any experimental collection.

The user accepts unavailable intermediate assistant messages as a beta limitation
for Codex side chats. Collect the remaining text that the available hooks expose:
user prompts, final assistant replies, tool results and tool errors. This is a
scoped exception to the five-content-type target, not evidence that intermediate
messages were observed.

The exception applies only to Codex side chats. Main Codex conversations, native
subagents, T3 sessions and Claude retain their existing requirements. A hook
session is not identified as a side chat merely because its ID differs from the
main thread, its history is absent, or its project path matches. The source
authority must still be selected explicitly for the exact session before
admission, and it must remain stable through replay and restart.

Use `UserPromptSubmit.prompt`, `Stop.last_assistant_message` and
`PostToolUse.tool_response` as observed hook content. Each tool result needs its
own tool-call identity within the turn. Delivery IDs and matching text are not
source identities. Repeated delivery must not create additional appearances;
conflicting content for an already-bound identity stays visible as a gap.

The accepted limitation does not waive missing tool results, interrupted final
messages, hook opt-outs, hosted tools that bypass hooks, unavailable delivery,
truncation, or identity ambiguity. Scan readable returned text even if the hook
does not provide a reliable success/failure status. Classifying that text as tool
output does not assert that the tool succeeded. Raw hook envelopes and tool-input
arguments are not substitutes for returned tool content.

Keep coverage truthful. Intermediate replies unavailable from this route must
not be marked collected, recovered or validated. A scope decision is separate
from runtime health and acceptance. Expanding support would require genuine
side-chat tool dispatch, encrypted ingestion, duplicate suppression and signed-app
acceptance on the candidate. Prompt/final-only observation cannot satisfy those
checks.

See [current Codex scope](../CODEX_BETA.md),
[`CodexHookContentAdapter`](../../Sources/SpillcheckCore/CodexHookContentAdapter.swift)
and [Codex hook documentation](https://learn.chatgpt.com/docs/hooks).
