The live test uses Claude Code 2.1.293, the production `spillcheck-hook`, the Claude adapter, Betterleaks, and the protected store. It creates fresh configs and sessions containing one synthetic credential. Existing Claude hook settings and histories remain untouched. Only authentication is reused; copied auth and provider-generated transcripts are removed with the disposable directory. Reports contain safe counts and checks.

The runner uses the shared process cleanup helper in `Tests/Support`. Recorded synthetic Claude sessions for adapter tests live in `Tests/Fixtures/Claude`.

Build and run from the repository root:

```sh
swift build --product spillcheck-storage-acceptance
swift build --product spillcheck-hook
python3 scripts/prepare-scanner.py
python3 Tests/ClaudeLive/run.py --output .build/implementation/claude-live.json
```

The test first verifies a one-use synthetic prompt through a durable receiver receipt. It then exercises prompts, intermediate/final replies, shell/MCP success and errors, and a native Agent child's own prompt/response. A second conversation checks repeated-value alert eligibility. Helper and socket paths contain spaces, apostrophes, dollar signs, and backticks to exercise Claude's direct `command` plus `args` form. The report requires committed typed occurrences for the known fingerprint, two eligible conversations/alerts, unchanged replay counts, an empty queue, and no synthetic plaintext marker in database/WAL/SHM or scanner work files. The credentials are deliberately synthetic and are never used for authentication.

`--executable` selects a validated Claude Code 2.1.293 executable. For a validated version on `PATH`, pass `--executable "$(command -v claude)"`. `--acceptance-executable` selects newly built SwiftPM products when they are outside the default Xcode package-products directory. Neither option changes an existing installation.

`result.sourceLatency` reports counts, nearest-rank p50/p95, and maxima in milliseconds for unique committed synthetic source revisions. It separates provider transcript timestamp to canonical read-start observation, durable queue capture to completion observation, and canonical observation to completion observation. Live and historical populations remain separate; an empty population is unmeasured. Completion observation follows the enclosing capture's pipeline work and is an upper bound on per-source commit. Provider timestamps do not establish when a tool physically printed its first byte. Canonical read-start timestamps precede asynchronous reads, so an append can yield a negative provider delta even without clock skew; each leg excludes and counts negative deltas independently. Final catch-up and replay do not contribute samples. This CLI fixture does not measure T3 latency.

An explicitly selected active T3 provider transcript can be monitored independently of hook loading:

```sh
.build/out/Products/Debug/spillcheck-storage-acceptance --claude-observe \
  --directory /absolute/disposable/owner-only-directory \
  --scanner .build/scanner/betterleaks --rules .build/scanner/betterleaks.toml \
  --source /absolute/selected-provider-session.jsonl --session SELECTED_PROVIDER_UUID \
  --source-root /absolute/selected-project-directory --duration 120
```

The observer checks file metadata, enqueues changes durably, and reads bounded canonical records through the normal adapter/pipeline. It also discovers at most 32 native Agent files within the selected conversation's own `subagents` directory. It does not enumerate the profile's other conversations or resume a session. Touch `provider-finished` inside the disposable directory after the test task finishes; the observer drains its queue and performs a real source replay. `firstObservedAt` timestamps can be compared with the provider's independently observed final publication time. A task attached after its prompt is historical for alert eligibility, so this observer alone does not prove a fresh-conversation alert.

Version-specific unknown content produces visible coverage gaps. Adapter v2 uses persisted, encrypted checkpoints: unchanged sources need no payload read, append reads resume at accepted boundaries, and partial writes remain pending. Cold selection starts at the bounded tail, so a recent message in an old, large conversation is immediately eligible. File replacement, shrinkage, equal-size rewrites, and changed keyed boundaries restart bounded selection with a visible gap. Arbitrary growing-file edits outside those boundaries remain uncertified.

Historical discovery uses the source timestamp and an immutable rolling seven-day audit. Metadata discovery is paged; each source gets a two-MiB quantum within the 100-MiB, 30-second, 256-source pass limits. Continuations preserve the audit and commit with source checkpoints. Live and historical checkpoint identities differ. The historical file extent is frozen for each audit so continuous future append cannot starve older eligible pages. An older timestamp boundary stops further old-prefix traversal, but the unread prefix remains explicitly partial; it is never inferred to contain only old content. Compressed histories are explicitly unsupported. Relocation requires an explicitly configured root and reconciles exact native session/item IDs.

Run the disposable large-history measurement separately:

```sh
swift test --filter benchmarkColdWarmAnd78ByteAppendOnDisposableLargeHistory
```

Its safe report is `.build/implementation/claude-history-benchmark.json`; it measures cold selection, a stat-only unchanged read, and a 78-byte append including keyed boundary reads. Keep active observer directories outside `.build` when rebuilding or cleaning the package. Desktop collection and native source-opening success remain unverified.
