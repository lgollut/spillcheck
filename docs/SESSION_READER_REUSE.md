# Session reader guidance for Leakret

Reviewed October 7, 2026. This note records reader patterns and proposed recovery
checks for the feasibility work. No private session histories were read, readers
run, or tests executed for this assessment. The repository contains documentation
only; these patterns do not establish collection coverage.

Bounded file readers, JSONL framing, checkpoints, and recovery contracts are
candidates for reuse when they fit Leakret without unnecessary dependencies or
adaptation. Implement independently where the application's needs differ.
Leakret needs a role-neutral transcript decoder and exact content extraction;
prompt-only parsing cannot provide the required assistant and tool-output
coverage. See the [implementation plan](IMPLEMENTATION_PLAN.md) for the
feasibility gates and [specification](SPEC.md) for required behavior.

## Reader patterns and required adaptations

| Pattern | Required Leakret behavior |
| --- | --- |
| Source discovery and bounded reads | Check regular files, support explicit agent profiles and roots, retain cancellation points, and use keyed fingerprints for secret-bearing boundary bytes. Standard roots include `.claude/projects`, `.codex/sessions`, and `.codex/archived_sessions`; compressed histories require separate validation. |
| JSONL framing | Preserve complete supported message and tool content, leave incomplete trailing records pending, and report gaps when a limit is exceeded. Recovery classification must handle every supported role. |
| Prepare and commit | Separate reading from durable processing. Commit encrypted findings, source receipts, progress, and alert decisions together under the seven-day window and declared adapter coverage. |
| Session metadata and event identity | Preserve upstream session/item IDs, timestamps, originating-thread relationships, and source context. Prove hook/history mappings independently rather than treating a format clue as content coverage. |

A narrow reader adaptation may save work. A package tied to another application's
observation or journal domain can bring unrelated behavior; compare that cost
with implementing Leakret's smaller requirements directly.

## Content and occurrence identity

Readers must retain user prompts, assistant messages, tool results, errors, and
supported subagent content. Removing generated context, joining text blocks,
stripping controls, or clipping at 4 KiB before scanning can lose exact secret
bytes and ranges. Scan before excerpt clipping and preserve a lossless mapping
to canonical source segments. A secret can appear beyond the first 4 KiB.

Distinguish an originating event from its appearance in a canonical conversation.
Copies of the same conversation are replays; a different conversation containing
the same value is a new occurrence and may require a new alert. Fork-wide UUID
deduplication, unkeyed content digests, and text similarity are insufficient.
Keep value grouping separate from occurrence identity.

## Proposed regression scenarios

- Leave incomplete trailing JSON unread; resume after completion or restart
  without duplicate occurrences.
- Detect replacement files, truncation, changed keyed boundaries, and
  truncate/regrow sequences where size alone cannot prove unchanged content.
- Bound bytes and rows per step, restart halfway, and avoid historical payload
  reads on unchanged caught-up passes.
- Inject checkpoint/commit failures and lost acknowledgements; retry without
  advancing progress or creating new findings or alerts.
- Drain oversized records within bounds, retain no raw recovery text, report
  one controlled gap, and continue with later records.
- Cancel stalled work and reject stale completions after pause, quit, or a
  generation change.
- Verify canonical-conversation identity instead of merging appearances across
  forks; retain exact-value grouping separately.

## Limits to prove

Local transcript-reader behavior does not establish hook or Codex app-server
coverage for CLI, Desktop, or T3 workflows. The collection prototype must add
complete tool-result/error and assistant-message fixtures and validate overlap.

Cold discovery may need body reads before eligible records can be found in mixed
histories. Warm passes that avoid historical payload reads do not establish a
bounded first seven-day audit. Measure cold selection separately, preserve
progress at the budget, and display incomplete coverage.

Compressed histories, relocated/profile stores, subagent formats, and exact
detection ranges remain capabilities to validate in versioned adapter fixtures.
None is established by these reader patterns alone.
