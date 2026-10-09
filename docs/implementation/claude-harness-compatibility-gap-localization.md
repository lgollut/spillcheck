# Claude native gap localization

Measured October 9, 2026 with genuine Claude producers 2.1.293 and 2.1.295 in
owned disposable CLI sessions. The before and after runs used separate native
corpora. This establishes the two fixes below, not an in-place upgrade, GUI host
collection, or signed-app acceptance. The [sanitized measured report](claude-harness-compatibility-gap-localization-2026-10-09.json)
contains controlled counts without source text, authentication, personal paths,
or native identity values.

## Native metadata envelopes

The diagnostic run before the fix produced 135 unique `unsupportedContent`
omissions, all unconfirmed and without a required content type. Its native
files contained exactly 135 additional non-message envelopes:

| Envelope type | Count | Observed shape |
| --- | ---: | --- |
| `attachment` | 102 | No top-level `message` or `content` |
| `ai-title` | 7 | No top-level `message` or `content` |
| `atis-latch` | 12 | No top-level `message` or `content` |
| `cost-state` | 4 | No top-level `message` or `content` |
| `last-prompt` | 10 | No top-level `message` or `content` |

There were no malformed JSONL rows or unfamiliar message block types in that
corpus. Its message blocks were text, thinking, tool use, and tool result.
Unknown attachment subtypes remain the controlled diagnostic label `other`.
No unknown subtype string is exported.

Anthropic documents that native transcript entries include metadata and that
the format can change between releases. Its official SDK's session reader
returns user and assistant entries as message content, excluding other envelope
types. That distinction, together with the measured shapes, supports treating
these five envelopes as session metadata rather than missing required content.
[Claude session documentation](https://code.claude.com/docs/en/sessions#where-transcripts-are-stored),
[official session reader at the inspected commit](https://github.com/anthropics/claude-agent-sdk-python/blob/588905686e40dffa32e2f889ce7164df01ff7c8b/src/claude_agent_sdk/_internal/sessions.py#L924)

The adapter recognizes these five types only when top-level `message` and
`content` fields are absent. Unfamiliar envelope types, changed content-bearing
shapes, and unsupported message blocks still produce gaps. Readable required
sibling blocks continue collecting. Parser contract `claude-transcript-3`
allows a bounded reread under this distinction. Native source identities,
canonical content revisions, and processed receipts are unchanged. A complete
recognized metadata row can settle its exact former omission; other rows cannot
settle it.

## Historical fixture admission

The same pre-fix run recorded four pipeline failures with the closed diagnostic
labels `captureRejected/completeCapture/storageInvalidPayload`. The normalizer
successfully read the historical request four times. The receiver reported no
frame or admission failure.

The fixture generated a frozen historical request, then admitted it without
binding that audit to the encrypted queue envelope. Source commits happened
before completion. The store correctly rejected historical progress whose audit
did not match the queue's audit. After bounded retry exhaustion the queue was
empty, so required marker counts and an empty queue alone had incorrectly
satisfied the old fixture gate. They established readable source commitment,
but did not establish historical progress settlement.

The shared Testing SPI decoder validates the existing historical request kind,
version, cursor bounds, finite audit end, and exact seven-day window. The
disposable core acceptance receiver now binds that validated audit on admission.
Ordinary hooks return no audit; malformed reserved requests are rejected. The
production store's strict completion guard is unchanged. The mixed CLI fixture
now requires an admitted audit to reach persisted complete historical progress.
The signed DEBUG receiver uses the same helper only behind its explicit owned
disposable acceptance flag; that environment requires its own rerun.

The pipeline observer is Testing SPI and defaults to absent. It reports only
closed stage, error category, and coverage reason enums. It exports no error
description, event content, path, or native identity.

## Verification and limits

All 42 tests in the Claude adapter and bounded-history suites passed. New
regressions verify unchanged canonical messages around recognized metadata,
continued gaps for unfamiliar content shapes, invalid frozen request rejection,
and ordinary hook admission. An encrypted pipeline regression reproduces the
unbound completion failure, then verifies that a correctly bound audit settles
progress and the emitted checkpoint while draining its queue.

The genuine follow-up run exercised 136 metadata envelopes and committed all
nine typed markers from both genuine producers. `FINAL` had three distinct
source identities; each other marker had two. One audit was admitted, one
complete historical progress record persisted, and the queue drained. No
`captureRejected` or `unsupportedContent` gap remained. One transient
`awaitingTranscript` normalization retry succeeded before completion. Replay,
encrypted marker inspection, original historical source identity/content
preservation, and disposable source/authentication/process cleanup passed.

These results do not establish signed-app behavior after rebuilding, saved
setup or upgrade recovery, GUI live-only source identity, actual macOS health
notification delivery, or concurrent collection from all six required hosts.
The [compatibility plan](../HARNESS_COMPATIBILITY_PLAN.md) and
[measured matrix](supported-matrix.md) retain the authoritative remaining gates.
