# Session reader guidance

Session readers must preserve the content and identities needed for secret
detection while bounding history work. This guidance covers transcript framing,
checkpoint persistence, recovery, and occurrence reconciliation. The
[supported matrix](implementation/supported-matrix.md) records which provider
interfaces and versions have passed genuine collection checks.

## Reading and framing

Discover sources only beneath explicitly configured profiles and roots. Check
file ownership and type, bound metadata traversal, and retain cancellation
points. Treat compressed histories and relocated stores as separate capabilities
that need versioned fixtures and visible status.

Preserve user messages, assistant messages, tool results, errors, and supported
native-child content. A prompt-only reader cannot satisfy Spillcheck's coverage.
Decode transport escaping without discarding generated context or normalizing
the exact value bytes. Scan complete supported content before clipping retained
excerpts, and keep a lossless mapping to canonical UTF-8 ranges.

Leave incomplete trailing JSON pending until it can be read completely. Oversized
records must drain within a bounded budget, produce a coverage gap, and allow
later records to proceed. Recovery diagnostics must contain controlled metadata
rather than raw source text. The [Claude incremental reader](../Sources/SpillcheckCore/ClaudeIncrementalReader.swift)
and [adapter](../Sources/SpillcheckCore/ClaudeAdapter.swift) implement these
boundaries for the validated transcript format.

## Progress and identity

Use keyed fingerprints for secret-bearing checkpoint boundaries. Persist
checkpoints, continuations, findings, source receipts, and alert decisions
together after durable processing. A failed transaction leaves progress behind
the source, never ahead of it. See the [history contracts](../Sources/SpillcheckCore/HistoryContracts.swift)
and [protected store](../Sources/SpillcheckCore/ProtectedStore.swift).

Distinguish the originating event from its appearance in a canonical
conversation. Copies of one conversation are replays; a different conversation
containing the same value is a new occurrence. Preserve upstream IDs and prove
hook/history mappings independently. Matching text or timestamps cannot establish
shared identity. Keep exact-value grouping separate from occurrence identity.

Bound cold discovery independently of warm and append reads. A seven-day date
filter does not establish a bounded first audit. Yield at the byte/time limit,
persist continuation state, and show the unread period as partial coverage.
Observed timestamp endpoints do not prove continuous coverage between them.

## Regression scenarios

- Complete an interrupted trailing record and resume after restart without
  duplicate findings or alerts.
- Detect replacement, shrinkage, equal-size rewrites, changed keyed boundaries,
  and truncate/regrow sequences.
- Bound bytes and rows per pass; read no historical payload for unchanged,
  caught-up sources.
- Retry failed commits and lost acknowledgements without advancing progress or
  creating new occurrences.
- Drain oversized records, record one controlled gap, and continue with later
  content.
- Cancel stalled work and reject stale completions after pause, quit, or a
  generation change.
- Reconcile alternate collectors without merging legitimate repeated
  appearances in different conversations or source ranges.

[Claude history tests](../Tests/SpillcheckCoreTests/ClaudeHistoryTests.swift),
[Codex history tests](../Tests/SpillcheckCoreTests/CodexHistoryTests.swift), and
[capture completion tests](../Tests/SpillcheckCoreTests/CaptureCompletionTests.swift)
exercise the current contracts. Their synthetic fixtures do not establish new
live-provider, Desktop, or subagent-format coverage.

The supported file-mutation contract is append with stable native identities.
Arbitrary growing-file edits outside certified boundaries remain unverified.
Compressed histories are visibly unsupported; relocation requires an explicitly
configured root. These limits remain in the implementation reports.
