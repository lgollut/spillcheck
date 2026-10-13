The live test records the selected Claude Code executable and version and uses the production `spillcheck-hook`, the Claude adapter, Betterleaks, and the protected store. It creates fresh configs and sessions containing one synthetic credential. Existing Claude hook settings and histories remain untouched. Only authentication is reused. Successful runs remove the disposable directory. Failed runs remove authentication and configuration material, then retain the private fake source artifacts for diagnosis; a sibling `*.private-artifacts.json` file records their exact owned directory. Use a fresh output name when that pointer already exists. Reports contain safe counts and checks.

The runner uses the shared process cleanup helper in `Tests/Support`. Recorded synthetic Claude sessions for adapter tests live in `Tests/Fixtures/Claude`.

Build and run from the repository root:

```sh
swift build --product spillcheck-storage-acceptance
swift build --product spillcheck-hook
python3 scripts/prepare-scanner.py
python3 Tests/ClaudeLive/run.py --output .build/implementation/claude-live.json
```

The test first verifies a one-use synthetic prompt through a durable receiver receipt. It then exercises prompts, intermediate/final replies, shell/MCP success and errors, and all five required content types in a native Agent child's own transcript: prompt, intermediate response, final response, tool output, and tool error. A second conversation checks repeated-value alert eligibility. Helper and socket paths contain spaces, apostrophes, dollar signs, and backticks to exercise Claude's direct `command` plus `args` form. The report requires committed typed occurrences for the known fingerprint, two eligible conversations/alerts, unchanged replay counts, an empty queue, and no synthetic plaintext marker in database/WAL/SHM or scanner work files. The credentials are deliberately synthetic and are never used for authentication.

The strict role gate requires seven parent markers and five child markers from one exact parent/own-child source pair. It uses the original native session/item identities and the provider's own child directory relationship; a child may share its parent's native session ID. Parent mirrors, unrelated children, or markers scattered across several children cannot establish one complete child. Each committed marker needs the exact content revision's full detector receipt and the fake-value occurrence with matching type and content time. Original source inspection independently verifies a complete pair, including one pair per producer in mixed-history runs. Reports contain counts, never native IDs or transcript text.

Acceptance also requires explicit empty required-content gap evidence and a non-truncated coverage report. Supported media exclusions remain separate. Missing fields from an older driver cannot pass. Provider timeouts retain controlled failure counts and clean up their owned process groups; setup failures still remove temporary authentication.

Failed provider runs include a fixed `failureCategory`, such as `sessionLimit`,
`authenticationUnavailable`, `rateLimit`, `fixtureBudgetLimit` or `providerTimedOut`.
The classifier inspects bounded stream-JSON error fields and reports truncation;
unrecognized or conflicting evidence remains `providerFailed`. Ordinary model or
tool text cannot establish an account failure. Reports never include error text,
reset times, credentials or native identities. The signed live and recovery
runners share these labels. A failed live provider invocation stops later fixture
sessions. These labels do not retrospectively classify older reports whose
provider stdout was not retained.

Cleanup errors fail acceptance and remain visible in the count-only report. If the normal private artifact pointer cannot be written, the runner tries one exclusive `*.private-artifacts.recovery.json` sibling. If both writes fail, the exact retained directory goes to private stderr; neither pointer is overwritten. A failed authentication cleanup is reported as incomplete.

The boundary tests use no real credentials or providers:

```sh
python3 -m unittest discover -s Tests/ClaudeLive -p 'test_*.py'
python3 -m unittest discover -s Tests/Support -p 'test_claude_native_evidence.py'
python3 Tests/ClaudeLive/test-evidence.py
```

`--executable` selects the Claude Code executable used by live provider runs. Pass `--expected-version 2.1.295` when checking that specific acceptance baseline. Without it, the same behavioral assertions apply to the observed release. The report records the resolved executable path and verifies that its version stays unchanged during the run. `--acceptance-executable` selects newly built SwiftPM products when they are outside the default Xcode package-products directory. Neither option changes an existing installation.

`--historical-producer-executable` optionally selects another installed producer for one genuine full-content session before the driver starts. Its version is independently probed, and `--expected-historical-version` can assert a particular acceptance baseline. The historical session uses the same disposable provider home and copied authentication. After the driver starts, the runner delivers a frozen seven-day production history request through the helper and encrypted queue. All live runs still use `--executable`.

The disposable receiver binds that validated frozen audit to its encrypted queue admission. Mixed acceptance requires complete persisted historical progress as well as committed typed markers and an empty queue. Controlled diagnostic counts localize receiver, normalization, and pipeline stages without exporting content, paths, or native identities. Native envelope and block labels outside the fixed diagnostic vocabulary become `other`.

```sh
python3 Tests/ClaudeLive/run.py --output .build/implementation/claude-mixed-history.json \
  --executable /absolute/current/claude --expected-version 2.1.295 \
  --historical-producer-executable /absolute/older/claude --expected-historical-version 2.1.293
```

The mixed-history run requires both actual producer versions in normalized evidence, committed historical samples, a complete committed parent/own-child pair for each producer, and at least two distinct committed identities for each required typed marker across the old and current corpora. It also checks that the historical files' native identities and content remain unchanged, and retains the ordinary replay, queue, encryption, and cleanup assertions. Native identity values and content hashes stay private. The report distinguishes genuine provider source from the test-generated history-delivery request. Invoking a GUI-bundled producer as a CLI does not establish collection from the GUI host. A failed old-provider run or missing required native content stops before the live driver launches and records the unmet gate.

`result.sourceLatency` reports counts, nearest-rank p50/p95, and maxima in milliseconds for unique committed synthetic source revisions. It separates provider transcript timestamp to canonical read-start observation, durable queue capture to completion observation, and canonical observation to completion observation. Live and historical populations remain separate; an empty population is unmeasured. Completion observation follows the enclosing capture's pipeline work and is an upper bound on per-source commit. Provider timestamps do not establish when a tool physically printed its first byte. Canonical read-start timestamps precede asynchronous reads, so an append can yield a negative provider delta even without clock skew; each leg excludes and counts negative deltas independently. Final catch-up and replay do not contribute samples. This CLI fixture does not measure T3 latency.

An explicitly selected active T3 provider transcript can be monitored independently of hook loading:

```sh
.build/out/Products/Debug/spillcheck-storage-acceptance --claude-observe \
  --directory /absolute/disposable/owner-only-directory \
  --scanner .build/scanner/betterleaks --rules .build/scanner/betterleaks.toml \
  --source /absolute/selected-provider-session.jsonl --session SELECTED_PROVIDER_UUID \
  --source-root /absolute/selected-project-directory --version OBSERVED_PRODUCER_VERSION --duration 120
```

The observer checks file metadata, enqueues changes durably, and reads bounded canonical records through the normal adapter/pipeline. It also discovers at most 32 native Agent files within the selected conversation's own `subagents` directory. It does not enumerate the profile's other conversations or resume a session. Touch `provider-finished` inside the disposable directory after the test task finishes; the observer drains its queue and performs a real source replay. `firstObservedAt` timestamps can be compared with the provider's independently observed final publication time. A task attached after its prompt is historical for alert eligibility, so this observer alone does not prove a fresh-conversation alert.

Unknown content and malformed essential fields produce visible coverage gaps. Producer versions remain provenance; missing producer metadata is recorded as `unknown`. Adapter v2 uses persisted, encrypted checkpoints with a separate parser contract generation: unchanged sources need no payload read after assessment by the current parser contract, append reads resume at accepted boundaries, and partial writes remain pending. Cold selection starts at the bounded tail, so a recent message in an old, large conversation is immediately eligible. File replacement, shrinkage, equal-size rewrites, and changed keyed boundaries restart bounded selection with a visible gap. Arbitrary growing-file edits outside those boundaries remain uncertified.

Historical discovery uses the source timestamp and an immutable rolling seven-day audit. Metadata discovery is paged; each source gets a two-MiB quantum within the 100-MiB, 30-second, 256-source pass limits. Continuations preserve the audit and commit with source checkpoints. Live and historical checkpoint identities differ. The historical file extent is frozen for each audit so continuous future append cannot starve older eligible pages. An older timestamp boundary stops further old-prefix traversal, but the unread prefix remains explicitly partial; it is never inferred to contain only old content. Compressed histories are explicitly unsupported. Relocation requires an explicitly configured root and reconciles exact native session/item IDs.

Run the disposable large-history measurement separately:

```sh
swift test --filter benchmarkColdWarmAnd78ByteAppendOnDisposableLargeHistory
```

Its safe report is `.build/implementation/claude-history-benchmark.json`; it measures cold selection, a stat-only unchanged read, and a 78-byte append including keyed boundary reads. Keep active observer directories outside `.build` when rebuilding or cleaning the package. Parser contract changes restart bounded source selection without changing native identities or canonical content revisions. Existing analyzed receipts suppress replay. The mixed-producer fixture exercises 2.1.293, 2.1.295, and missing metadata; it is synthetic regression evidence. Signed-app, GUI collection, and native source-opening acceptance remain separate gates.
