# Five-working-day beta trial log

`trial.py` records counts for an owned local beta trial. It does not inspect the
vault or conversations, seed credentials, run a provider, or claim acceptance.
Begin the trial after the current signed candidate passes the controlled entry
gates in [beta readiness](../../docs/BETA_READINESS.md).

For the accepted [Codex beta scope](../../docs/adr/0007-codex-beta-scope.md),
initialize a fresh log with `--scope codex-beta-v1`. This schema-3 log requires
Codex observations for CLI, desktop and T3, with all five content types in the
included sources. It names the saved-main/readable-child scope and its exclusions
in every summary. Claude records are rejected. The existing default remains the
full two-provider matrix; existing logs cannot be narrowed by another `init`.

```sh
python3 Tests/BetaTrial/trial.py --log .build/beta-readiness/codex-trial-counts.json init \
  --candidate-bundle-sha256 RECORDED_CURRENT_CANDIDATE_SHA256 \
  --scope codex-beta-v1
```

Use the same record commands below. The operator must independently establish
that measured items belong to the declared scope. The count log does not verify
native source class or infer which host emitted a shared hook. Excluded side
sessions and encrypted child input must not be reported as verified collection;
misses in included content must remain in the denominators. Accompanying audio
text and `partial_answer` remain runtime-unverified, separate from known exclusions.

The scoped summary reports `allRequiredRoutesHaveSeededObservations` for the
three Codex routes. `allSixRoutesHaveSeededObservations` remains false, and
`trialAcceptanceEstablished` remains false even with complete counts. Actual
five-working-day observation and review of the controlled entry gates are still
required. This command prepares a log, not evidence that a trial has begun.

For the accepted [Claude beta scope](../../docs/CLAUDE_BETA.md), use a fresh
`claude-beta-v1` schema-3 log instead:

```sh
python3 Tests/BetaTrial/trial.py --log .build/beta-readiness/claude-trial-counts.json init \
  --candidate-bundle-sha256 RECORDED_CURRENT_CANDIDATE_SHA256 \
  --scope claude-beta-v1
```

This scope requires Claude observations for CLI, desktop and T3, with all five
readable text types in saved main conversations and their native Agent children,
including child prompts. Its fifteen required host/content combinations exclude
Desktop side questions, Claude Chat, Cowork, remote Code and binary media analysis.
The Codex encrypted-child-input exclusion does not apply to this Claude scope.
Codex records are rejected. Use `--provider claude` with the record commands below.
The operator must establish both host and source-class membership; the summary
reports `hostAttribution: "operatorDeclaredPerSnapshot"` and
`sourceClassMembershipVerified: false`. Counts do not establish either identity.

The Claude summary uses its three routes for
`allRequiredRoutesHaveSeededObservations`; the full-matrix and acceptance flags
remain false even after all fifteen combinations have observations for five
working days. Scope and candidate digest cannot be changed through `init` or
`record`: use a new destination for a different scope or candidate. The default
remains the full two-provider matrix, and existing Codex and legacy logs keep
their previous behavior. Adding this scope has not initialized a real trial log
or started a real-world trial.

Use one private log per candidate build and trial. Keep the candidate's signed
acceptance report alongside it. Initialize the log with that candidate's bundle
SHA-256 and supply the same digest with every recording command. A different
digest is rejected without changing the log; a rebuild needs a new trial log.
Initialization never overwrites an existing file or binds old measurements to a
candidate after the fact.

The log accepts only a 64-character lowercase hexadecimal candidate digest,
fixed provider, host and content-type labels, calendar dates, bounded counts,
latency samples and resource measurements. It has no fields for notes,
credentials, excerpts, native IDs or source paths. The CLI's `--log` destination
is never stored in the data.

The digest is recorded attribution supplied by the operator. This tool does not
inspect an app bundle, verify its signature, check which app is running, or
establish that its entry gates passed. Summaries expose this distinction through
`candidateAttribution: "recordedDigest"`, `candidateArtifactVerified: false` and
`trialAcceptanceEstablished: false`. Keep the digest's build evidence with the
signed acceptance report and confirm it identifies the candidate being measured.

For the prepared candidate, the bundle digest is in
`.build/beta-readiness/candidate-build.json`. That metadata must be regenerated
after a rebuild; reusing it does not verify the rebuilt app. Once its controlled
entry gates pass, create a fresh log:

```sh
trial_bundle_sha256="$(python3 -c 'import json; from pathlib import Path; print(json.loads(Path(".build/beta-readiness/candidate-build.json").read_text())["bundleSHA256"])')"
python3 Tests/BetaTrial/trial.py --log .build/beta-readiness/trial-counts.json init \
  --candidate-bundle-sha256 "$trial_bundle_sha256"
```

## Check a candidate before attributing new results

`preflight.py` independently reads a recorded candidate, its actual app bundle and
its recorded source inputs. It checks the bundle and executable digests, runs
read-only strict signature verification, and compares every Swift source plus the
fixed build inputs used by the existing schema-1 candidate manifest. Added and
removed source files count as mismatches too. It launches no app and reads no vault
or provider history.

For example, inspect the last recorded signed candidate:

```sh
python3 Tests/BetaTrial/preflight.py \
  --manifest .build/beta-readiness/candidate-build-r2.json \
  --app .build/beta-readiness/app-signed-r2/Build/Products/Debug/Spillcheck.app
```

Exit 0 means the recorded checks match; exit 1 means a mismatch or failed signature
check; exit 2 means an input was unreadable or rejected. The old r2 bundle is intact,
but its source inputs predate the adversarial-review fixes, so it currently returns
1. Rebuild and record a new candidate before attributing those fixes to signed
results. Keep the old manifest and results unchanged.

Add `--trial-log PATH` to compare a log's immutable candidate digest with the
measured bundle. A different digest or an unbound legacy log fails that check;
no log is rewritten. The report includes only controlled states, counts and
hashes, not input paths or raw tool errors. Symlinked or special inputs, changed
files during inspection, unsupported digest formats and oversized inputs are
rejected. The current legacy digest format does not describe symlinks.

This is a consistency check against a supplied record, not a trusted build
attestation. It does not establish which app is running, the expected signing
identity, complete build provenance, signed acceptance or beta readiness. Resource
files and every compiler input are outside the recorded source-input scope. Those
limits are explicit in its JSON output; the trial logger's acceptance flags remain
false. The checker supports the existing candidate manifest format only and does
not generate or retroactively update candidate metadata.

## Record daily counts

This fake example has 10 expected native items containing 20 annotated fake values.
Eight complete items reached collection. They contain 16 expected values; 14
reached normalized scanner input, 11 were detected, and 10 appeared in the app.
The ordinary findings reviewed for this daily group were three confirmed secrets,
one false positive and five still unreviewed.

```sh
python3 Tests/BetaTrial/trial.py --log .build/beta-readiness/trial-counts.json record \
  --candidate-bundle-sha256 "$trial_bundle_sha256" \
  --date 2026-10-12 --provider codex --host cli --content-type toolOutput \
  --expected-items 10 --collected-items 8 \
  --expected-values 20 --collected-values 16 --normalized-values 14 \
  --detected-values 11 --visible-values 10 \
  --confirmed-findings 3 --false-positive-findings 1 --unreviewed-findings 5 \
  --duplicate-occurrences 0 --duplicate-alerts 0 \
  --latency-ms 450 --latency-ms 900 --queue-depth 0 \
  --oldest-pending-seconds 0 --cpu-percent 2.3 --rss-mib 120 --storage-mib 14

python3 Tests/BetaTrial/trial.py --log .build/beta-readiness/trial-counts.json summary
```

Providers are `codex` and `claude`. Hosts are `cli`, `t3` and `desktop`. Content
types are `userPrompt`, `intermediateResponse`, `finalResponse`, `toolOutput` and
`toolError`. These are separate routes; observing a shared hook does not determine
which host produced its content.

Each record replaces the complete snapshot for its date, provider, host and
content type. Re-running a command cannot add the same measurements twice.
Supply all counts again when updating a snapshot. All seven seeded item/value
counts must be supplied together; an unknown stage cannot silently become a
classified miss. Omit the whole seeded group for a review-only snapshot. Other
omitted counts are zero.
Attribute a finding to the date it was first observed; update that original day's
snapshot when reviewing it later. Do not count the same finding again on its
review date. Use one writer at a time.

Schema-1 logs remain readable with `summary`, which labels them
`candidateAttribution: "legacyUnbound"` and returns a null candidate digest. They
are read-only: `record` refuses them, and `init` refuses to replace them. Keep
those files as historical measurements and initialize a different destination
for new measurements. There is no automatic migration or retroactive assignment
of a candidate to old counts. Schema-2 summaries also remain measurements rather
than acceptance evidence.

Keep seeded values separate from ordinary findings when computing precision.
Use distinct inventory value entries as the review unit. Attribute each entry to
the provider, host and content type of its first observed occurrence, and count it
once even if it appears in other routes. Record extra occurrences in the seeded
and duplicate measurements, rather than counting the same reviewed value again.
Review all ordinary findings if practical. If sampling, follow a fixed rule such
as every fifth newly observed finding in each route and report that rule alongside
the count-only export. `unreviewedFindings` exposes the unreviewed remainder; it
never enters the precision denominator. Counts cannot establish the quality of an
unstated or biased sample.

## Measure and classify

- Item collection recall is complete collected seeded native items divided by
  expected seeded native items. Count each canonical native item once.
- Seeded detection recall is detected expected values divided by expected values
  in those collected items. It includes normalization failures in that denominator.
  It does not estimate recall over unknown real secrets.
- End-to-end seeded recall is visible expected values divided by all expected
  values. The miss counts partition the missing values by their first failing
  stage: collection, normalization, detection or presentation.
- Precision is confirmed ordinary findings divided by confirmed plus false
  positives. A zero denominator is `null`, not a perfect result.
- Record one latency sample per measured item, from source publication to visible
  inventory. This includes polling delay. Samples stay separate from resource
  readings. The report gives sample count and nearest-rank p50/p95; sparse samples
  do not establish typical tail latency.

The counts require independent observation of each stage. A missing finding
alone cannot distinguish collection, normalization or detection failure. Leave a
daily scope unrecorded until its stage counts are known, rather than assigning the
miss to the scanner by assumption. The supplied GUI and signed acceptance probes
can help establish controlled seeded observations.

Optional queue depth, oldest pending age, CPU percent, resident memory in MiB and
storage in MiB are individual daily observations. Their min/max summary does not
measure sustained CPU, peak memory, complete queue settlement or storage growth
between unobserved periods. Retain a separate controlled benchmark report for
large-history and resource acceptance.

Across five working days, cover all six provider/host combinations and all five
content types with annotated fake credentials in disposable native sessions.
For a `codex-beta-v1` or `claude-beta-v1` log, cover its three declared provider
routes instead; do not represent that result as completing the full two-provider
matrix. In a Claude log, cover all five text types in both main conversations and
native children within those fifteen required combinations.
Include overlap, replay, restart and recovery trials, counting duplicate
occurrences and alerts. The summary lists unseeded required scopes, distinguishes
weekdays from weekends, and always keeps `trialAcceptanceEstablished` false.
Five logged days and complete counts still need review against the signed build's
coverage, recovery and authenticated-viewing gates.

Run the metric/privacy regressions with:

```sh
python3 -m unittest discover -s Tests/BetaTrial -p 'test_*.py'
```
