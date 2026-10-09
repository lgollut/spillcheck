# Milestone 3: Claude collection and detection

Milestone 3 passed, including actual signed-app acceptance with production Keychain keys on the unlocked Mac. The current build contains the Claude Code collector, owned hook setup/removal, selected-conversation monitoring, local detection, and durable encrypted inventory processing. Milestone 4 is in progress for Codex and bounded catch-up; milestones 5–6 remain pending. [The machine-readable report](milestone-3.json) records the scoped checks; [the implementation review](milestone-3-review.md) records defects and fixes.

Claude Code 2.1.293 is the validated version. Canonical transcript item IDs identify occurrences; hooks trigger bounded canonical reads. Model-visible batch results are used only when exact tool IDs and decoded components reconcile. Unproven overlap produces a coverage gap. Native children are read only beneath a selected conversation's own subagent directory, with their own source context. Selected paths join monitoring after a successful canonical read. Setup is connected only after a one-use synthetic event reaches durable ingestion.

The adapter reads at most 8 MiB, 8,192 physical rows, and 1 MiB per row in a pass. Partial rows remain pending. Unsupported bookkeeping and content generate explicit gaps. These bounds do not establish fair, incremental seven-day discovery across large histories; that is milestone 4. The app currently accepts explicit development collection arguments. Persisted setup preferences and inventory workflows remain milestone 5.

The pipeline commits individual source receipts and encrypted payloads before atomically completing the capture and all its checkpoints. Capture admission preserves the live/history boundary across restarts. Degraded detection remains retryable and never receives a full analysis receipt. Pause, deletion, and quit invalidate stale work. Newly retained values and their queued raw capture are linked in the same transaction, so deletion cannot leave an unassociated capture that recreates content.

## Signed scanner correction

The original Apple Development signed, hardened Betterleaks executable passed signature and version checks but was killed with signal 9 when scanning. Its default regex engine lazily invokes the Go/re2 WebAssembly compiler. The pinned implementation maps writable anonymous memory and changes it to executable memory. The failure reproduced outside the app sandbox and in freshly signed copies. An allow-JIT entitlement alone still failed; allowing unsigned executable memory made that experiment succeed.

Betterleaks 1.9.0 also supplies a stock Go standard-library regex engine. The production worker now fixes `--regex-engine=stdlib`, and the sealed app manifest requires that engine. No scanner runtime-exception entitlement ships. The detector version includes `stdlib-1`, so prior analysis receipts cannot suppress reanalysis under the changed engine. Original download, rules, and license hashes are verified before signing; runtime verifies the final executable hash recorded inside the signed app bundle.

The full annotated corpus still recovers all 36 expected exact findings across 47 cases with zero additional or unlocated findings and no coverage gaps. The focused stdlib run took 9.961 seconds; the final package run's corpus test took 9.985 seconds. These are synthetic detector measurements, not end-to-end production latency quantiles.

The final opt-in package run passed 132 tests in 14 suites in 10.153 seconds, including an actual network-denied scan through the signed bundled executable. That signed scan passed in 1.319 seconds. Tests also exercise cancellation, pipe limits, malformed mappings, exact UTF-8 extraction, URI password decoding, confidence, replay, deletion, and bounded retries.

Relevant primary sources are the pinned [Betterleaks CLI engine selector](https://raw.githubusercontent.com/betterleaks/betterleaks/v1.9.0/cmd/root.go), [stdlib engine](https://raw.githubusercontent.com/betterleaks/betterleaks/v1.9.0/regexp/stdlib.go), [Go/re2 compiler selection](https://raw.githubusercontent.com/betterleaks/go-re2/v1.11.0-betterleaks.3/internal/re2_wazero.go), and wazero's [anonymous memory mapping](https://raw.githubusercontent.com/tetratelabs/wazero/v1.12.0/internal/platform/mmap_other.go) and [memory protection](https://raw.githubusercontent.com/tetratelabs/wazero/v1.12.0/internal/platform/mmap_unix.go). Apple's [unsigned executable memory entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.cs.allow-unsigned-executable-memory) describes the tested runtime exception.

## Reproduce the current checks

Run from the repository root with the pinned scanner downloads cached, Xcode 27, and the provisioned development team. Do not rebuild the app while a signed-scanner test is using its bundle.

```sh
make scanner-dependencies
make app
SPILLCHECK_SIGNED_SCANNER_APP="$PWD/.build/app/Build/Products/Debug/Spillcheck.app" swift test
python3 Tests/ClaudeLive/run.py --output .build/implementation/claude-live-repeat.json
```

The Claude runner uses disposable settings, project, transcripts, helper paths, and an isolated encrypted store with ephemeral testing keys. It reuses available authentication without copying existing hooks or history. It removes its owned processes and temporary configuration afterward. The scanner runs with network access denied; the real Claude provider necessarily uses its ordinary network connection. Reports contain counts and controlled status only.

On an unlocked Mac, repeat the production Keychain and signed-app integration check:

```sh
python3 Tests/AppAcceptance/run-app-pipeline.py --output docs/implementation/app-pipeline.json
```

This launches the actual signed app with a disposable synthetic transcript and private store, processes all five content types, and checks encrypted persistence using production keys and the bundled scanner. It does not require a reveal prompt. The [unlocked run](app-pipeline.json) passed: the app exited 0 without timeout, stdout, or diagnostics; storage and collection were ready; one encrypted value had five occurrences, one per required content type; the queue and gap list were empty; ciphertext inspection passed. Zero alert decisions are expected for the historical synthetic source.

The [earlier locked attempt](app-pipeline-locked.json) terminated normally after its bounded acceptance interval and reported `key-unavailable-queue--25308`, `storageReady=false`, and `passed=false`. Store bootstrap did not complete, so its failed marker-inspection flag does not establish a plaintext leak. That failure is preserved. No fallback key or weaker storage mode was introduced.

## Live evidence and limits

The earlier [standalone CLI report](claude-cli-live-re2.json) records all nine synthetic markers across the five required content types, one synthetic value, 20 occurrences, two sessions, two eligible synthetic alert decisions, an empty queue, clean ciphertext/work files, and stable replay. Its earlier failed replay attempt is preserved [separately](claude-cli-live-initial.json). The [T3 report](claude-t3-live.json) records all nine committed markers, including actual native-child content observed before parent completion, stable replay, and clean ciphertext. Attachment followed its first prompt, so its zero live alerts do not establish a fresh-session alert check. One extra ambiguous generic candidate captured the synthetic token plus sentence punctuation; [its classification](claude-t3-candidate-classification.json) is recorded without inventing value normalization.

The current [stdlib CLI report](claude-cli-live-stdlib.json) passed all three real provider runs, all nine typed cases, and all five required content types. It records 44 durable deliveries, one synthetic value, 20 occurrences, two sessions, two synthetic alert decisions, an empty queue, stable replay, zero new final-catch-up occurrences, and clean ciphertext/work files. Unsupported content remains a visible gap. An initial stdlib run had three provider exits of 1; its cause remains undiagnosed, and [that failure](claude-cli-live-stdlib-initial.json) is preserved. Subsequent disposable authentication, invocation, and hook probes succeeded, followed by the full successful rerun. No authentication refresh or existing item modification was performed. [Cleanup](claude-cli-live-cleanup.json) found no remaining test configuration directories or owned temporary/MCP processes.

The earlier CLI/T3 reports used the original staged executable's default regex engine; the current CLI run uses stdlib. All use ephemeral testing keys. Neither harness substitutes for successful signed-app acceptance with production Keychain keys. Hook verification, encrypted inventory processing, and alert decisions are exercised; final OS notification delivery, source navigation, and release packaging remain later milestones.

macOS 14 runtime and hardware without Touch ID remain required before release under the user's existing deferral. The development build is not notarized. Native source-opening routes and production observation/application latency quantiles remain unverified.
