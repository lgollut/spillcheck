# Retained Codex desktop output beta check

This check reuses the two original fake sessions produced in the official Codex
desktop app on October 10. It creates no provider conversation, copies no
authentication, installs no hooks and requests no GUI action. It never modifies
or removes the original provider home. These are runner behaviors; the check does
not measure every filesystem read or write performed by the passive app-server.

The fixed fixture's identity records, prompt, helper and historical reports are
pinned by SHA-256. Missing or changed proofs fail before an app is launched. The
runner cannot accept a replacement source directory or copied personal history.
Original host provenance remains `26.930.61225`, with producer `0.160.1` and reader
`0.162.1`. A new candidate's result does not relabel the historical live evidence.

After building and freezing a candidate containing `DesktopBetaAcceptance.swift`,
run from the repository root with fresh output paths:

```sh
python3 Tests/AppAcceptance/run-app-codex-desktop-beta.py \
  --app /absolute/path/to/frozen/Spillcheck.app \
  --candidate-manifest /absolute/path/to/candidate-build.json \
  --expected-bundle-sha256 FROZEN_BUNDLE_SHA256 \
  --executable ~/.local/bin/codex \
  --authorized-home ~/.codex \
  --output /absolute/private/new-desktop-beta-report.json \
  --private-control /absolute/private/new-desktop-beta-control.json
```

The original signed vault owner retains cleanup authority across two loaded
workers. Both use the bundled production scanner, production normalizer,
`DetectionPipeline.processNext`, encrypted store and full current-detector
receipts. Automatic app routing is held inactive during this explicit coordinator.

The first worker independently binds the original native rows, verifies the
parent's native creation link, and admits one exact-parent historical audit.
Child traversal must follow that link. All five parent markers and four readable
child output markers must reach their original source identities and locations.
The complete fixture must retain one fake value and 15 appearances; no parent
copy can replace a child source. Every normalized original needs a full receipt.

Exactly one durable omission is permitted: the canonical child incoming-input
requirement, with its exact child session, reserved item identity, current parser
contract, `userPrompt` type and `nativeChildInputUnavailable` diagnostic. It stays
unresolved and visible. Other omissions, including unsupported content at another
item, scanner failure or uncertain delivery, fail the check.

This required omission keeps the initial traversal and exact child retry partial.
The coverage UI derives one unread-history `budgetExhausted` summary for each.
The runner requires exactly one such summary after the first scan and exactly
two after replay, alongside the same single durable omission. The separate parent
retry completes, so replay must contain three total audits and two unread audits.
It checks the exact historical-read counts, scoped counts and unread-audit
counts, an empty queue and no truncated coverage report. The report records
`acceptedBetaLimitationProducesUnreadAuditSummary` with these measured counts.
The warning remains visible. An actual adapter budget gap, another operation,
another omission or an additional summary still fails the check.

Before reading native content, the second worker must restore the same full
inventory commitments, complete receipts, consumed captures and exact omission.
Two exact selected-source retries then reread the bound parent and child with
distinct audits. They use the production retry API to bypass the normal unchanged
parent shortcut. Both admissions must complete and be consumed, and both original
sources must actually be read. Native rows, all inventory state and receipts stay
identical; no additional detector scan, appearance or alert is permitted. The
durable omission must remain exactly identical, including its original observation
time. Separately, the normalizer must emit exactly one fresh canonical child gap
whose observation time advances within the bounded replay interval. Repeating a
blocked omission preserves its stored record; the fresh emitted event proves the
new observation. A warm cursor or successful process exit cannot pass.

Normal worker shutdown and positive passive-reader shutdown evidence are required
before the original owner can remove its disposable keys. Unknown cleanup retains
the private handoff. No loaded worker gains key-deletion authority. Successful
runs remove only their disposable test root, preserving the original fake sources.

A passing report establishes retained desktop parent/readable-child output
collection, signed persistence and exact reread under the accepted beta scope.
It does not establish live desktop hook dispatch, automatic setup, side chats,
encrypted incoming child input, source navigation, notifications or full Codex
support. Existing strict child/full-support gates remain unchanged.

The boundary suite launches no app or provider and touches no system protection:

```sh
python3 -m unittest discover -s Tests/AppAcceptance \
  -p 'test_codex_desktop_beta_boundary.py'
```
