# Beta readiness

## Current status

Updated October 13, 2026. Controlled signed runs established the accepted
[Codex](CODEX_BETA.md) and [Claude](CLAUDE_BETA.md) scopes on their tested builds.
The subsequent tooling cleanup has not had fresh signed acceptance. Full beta
acceptance remains open, and neither five-working-day real-world trial has begun.

A passing run applies to its exact signed candidate and measured host/provider
versions. A changed build needs its own verification. Unit tests, an unsigned
build, a signature check or a prepared count log do not establish runtime
acceptance. Keep the candidate's signed report with its private trial log,
including the bundle digest, tested versions, date, results and remaining limits.

## Before starting a trial

1. Select one signed candidate and the applicable provider scope. Preserve any
   existing Spillcheck or legacy Leakret data. Startup can adopt an old directory;
   controlled fresh enrollment must identify existing data without resetting it.
2. Verify included content on every advertised host: CLI, official Desktop and
   T3. Establish host origin independently of shared hook transport, which cannot
   identify the application that produced a session.
3. Check exact source identity and text, required scanner receipts, bounded
   catch-up, stable replay, encrypted persistence, review/obsolete state, deletion
   and pending-work recovery across restart. An unaffected source must progress
   while another source fails. Required omissions must remain visible.
4. Verify authenticated viewing, masking and reauthentication after sleep, screen
   lock and inactivity while a value is actually revealed. Exercise ordinary
   launch, quit, pause/resume and catch-up.
5. Check visible masked notifications and their navigation on the chosen build.
   A stored delivery receipt does not establish a visible banner. Earlier checks
   did not establish notification text readback, OS alert removal or all click
   behavior; those results must not be inferred from successful submission.
6. Initialize a new [scoped trial log](../Tests/BetaTrial/README.md) bound to that
   candidate's bundle digest. Use a new log for another candidate or scope.

Accepted exclusions are listed in the provider guides. They do not excuse missing
included text, lost deliveries, scanner failures or identity conflicts. Do not
start representative measurement with unexplained required-content loss in the
chosen candidate's entry checks.

## Unresolved warnings and cleanup

These observations from earlier controlled Claude runs remain unresolved:

| Observation | What remains open |
| --- | --- |
| Two `hookDelivery` / `captureRejected` warnings | The responsible callback and failure branch are unknown. |
| Recovery interrupted by reboot after a `liveRead` / `unsupportedContent` gap | The original source was lost. Both the content cause and disposable-vault key cleanup are unconfirmed. |
| Two `liveRead` / `sourceUnavailable` warnings during a Desktop fixture | All fixture markers arrived and owned cleanup passed; the warnings remain unexplained. |
| Inventory startup failed with Keychain `-25308` before owner readiness | Disposable-vault cleanup is unconfirmed. |

There are two cleanup-unconfirmed attempts above. Later clean runs settle neither
those keys nor the causes of earlier warnings. These gaps are not accepted beta
exclusions. Do not reset a vault to work around a recurring startup failure.

Further identical reruns are not planned. If a failure recurs, capture bounded
fake-only diagnostics: hook kind, field shape, outcome branch, attempt count and
an opaque callback link. Report truncation and preserve the attempt's cleanup
status. Warning reason or age alone proves neither retry exhaustion nor which
hook failed. Keep secret content and sensitive native identities out of exports.

## Measure five working days

Use ordinary development work and fake annotated seeds in disposable sessions
covering the accepted scope's required hosts and content types. Review findings
in the existing inventory; log counts without secret values or excerpts.

Record by provider, host and content type:

- Collection recall: expected seeded native items analyzed / expected items.
- Seeded detection recall: expected values detected / expected values in collected
  content. Classify misses as collection, normalization, detection or presentation.
- Reviewed precision: confirmed / (confirmed + false positives), with unreviewed
  counts and the sampling rule. Unknown real secrets have no measured recall.
- Duplicate occurrences or alerts after overlapping routes, replay, restart and
  upgrade.
- Source-publication-to-inventory latency, separating polling and scanning where
  measurable, with sample counts and p50/p95.
- Queue depth/age, catch-up completion, CPU, RSS and storage growth during ordinary
  work and a large-history run.

Five complete daily logs do not themselves establish acceptance. Review misses,
duplicates, performance, authentication and coverage limits against the chosen
scope. A single-Mac trial does not establish public distribution readiness; the
[release gates](RELEASING.md#before-distributing-an-app) remain separate.
