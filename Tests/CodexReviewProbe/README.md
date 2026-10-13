# Native review assistant source

This opt-in check creates one fresh Codex `0.162.1` parent thread and starts an
inline review of a self-contained fictional addition function. The model and
review model are explicitly selected. The disposable home has no personal
settings, hooks, history or MCP servers. Shell tools and web search are disabled,
environment access is empty, and unexpected tool activity fails the check.
Codex internally delegates the review. This check does not collect or attest
that child's sources, and does not claim that every tool is disabled.

The live review presentation and its null-phase assistant message must contain
identical complete bytes. After the producer stops, temporary authentication is
removed before the production passive client runs. The client reads only the
owned parent through `thread/read`, `thread/items/list` and `thread/turns/list`,
twice each. It does not list, resume or fork conversations and runs with network
access denied.

Saved native item IDs can differ from live IDs. The passive check selects exactly
one original null-phase assistant message in the requested review turn by full
live byte hash and length. Entered/exited review markers must attest that same
turn, and the exited review text must match. The second read must preserve the
saved item identity, timestamp, bytes and normalized revision. The original
`/text` location and intermediate-response category remain unchanged.

The input witness requires the complete original native user message to match
the entered-review instructions. Its actual native turn must either be the
review turn or carry an explicit public `rootTurnId` pointing to that review.
The review turn must also identify itself as its root. A complete, bounded turn
list must contain unique IDs and exactly one record for each selected turn.
The second read must preserve this relationship as well as the original input
identity, timestamp, bytes and normalized revision. A delegated turn need not
have a completed interval when its original item has a valid timestamp.

R4 correctly failed its older same-turn gate. R5 verified the explicit root
relationship with `inputTurnMatchesReviewTurn=false`, all 561 input bytes and
77 reply bytes across two passive reads. Both reports remain retained with
their original inputs. Closed diagnostics do not export source text or native
IDs. Matching text alone never establishes the relationship.

An internal review turn-start notification can appear on the parent thread.
Only that informational event may be ignored, with a bounded counter. It cannot
admit content, change the selected turn or count as review completion. Every
item event and completed turn must still match the requested parent review turn.

Review presentation warnings are reported separately. A passing target-source
check does not imply a warning-free session, signed detector receipts, desktop,
T3, subagent or full Codex acceptance. It also does not prove genuine
`partial_answer` production.

Run the offline boundaries first:

```sh
python3 -m unittest discover -s Tests/CodexReviewProbe -p test_boundary.py -v
swift test --scratch-path .build/codex-review-probe-2026-10-12 \
  --filter 'CodexReviewLiveTests|CodexUnphasedMessageTests'
```

With explicit authorization to copy the selected authentication into the fake
home, run from the repository root using fresh report/control paths:

```sh
python3 Tests/CodexReviewProbe/run.py \
  --executable /absolute/codex --auth-file /absolute/authorized/auth.json \
  --model gpt-6-astra \
  --scratch-path /absolute/spillcheck/.build/codex-review-probe-2026-10-12 \
  --report /absolute/private-results/native-review-report.json \
  --private-control /absolute/private-results/native-review-control
```

Only explicitly supplied authentication is copied. Cleanup waits for confirmed
producer, reader and version-process teardown. If teardown is uncertain, the
exact private cleanup handoff is retained. Original authentication must remain
unchanged. Public reports contain fixed diagnostics, counts and content hashes,
without source text, conversation IDs or credential data. Importing the runner,
`--help` and offline boundaries launch no provider or signed app.
