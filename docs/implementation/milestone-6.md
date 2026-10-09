# Milestone 6: local acceptance and release checks

The local acceptance checks passed within their recorded scopes on an Apple Silicon test environment running macOS 26.6.2, including the signed restart and cooperative offline workflow. The full release gate remains open, and the app is not release-ready. Distribution was explicitly deferred. The earlier deferral of macOS 14 execution and hardware without Touch ID also remains in force. These decisions permit local development to finish; they do not establish the missing acceptance results. [The machine-readable report](milestone-6.json) records both states.

The final package run passed 212 tests across 30 suites in 10.308 seconds, including the actual signed-scanner bundle check. The build took 5.20 seconds. [Full-suite evidence](m6-full-tests.json) records the corrected telemetry compile failure. The [native controller probe](m5-native-workflow-probe.json) passed 21 checks with injected authorization and notification backends. The [setup probe](m5-agent-setup-probe.json) passed seven disposable-profile scenarios. Neither probe substitutes for real macOS interaction.

## Native app and tested versions

The rebuilt, signature-verified development installation passed the final native regression. Revealed retained context became masked immediately when another occurrence's Open conversation action was selected. A unique review control saved only its selected occurrence. With Spillcheck's notification permission restored to denied, a different synthetic value remained visible with the disabled-notifications indicator and a durable `permissionDenied` receipt. Normal Quit left an empty queue, no raw caches or diagnostics, clean ciphertext, and successful cleanup of the disposable store and newly created vault rights. [The shutdown report](m5-final-app-workflow.json) has that automated pass scope; [the development-install observations](m6-development-install.json) record the manual UI checks.

The earlier [native walkthrough](milestone-5.md) separately covered real authentication and cancellation, retained value/context after source deletion, reversible review, acknowledgement/removal/forgetting, allowed notification delivery and navigation to masked details, denied notifications, window close, pause/resume, and Quit. Its event record has five authentication requests, four completed reveals, and one cancellation. Login registration and unregistration succeeded in the installed development copy and ended off. Actual logout/login launch remains untested. This development installation is not a Gatekeeper or Developer ID installation test.

The [signed restart and offline report](m6-signed-restart-offline.json) passed 27 checks across four normal Quit-and-reopen runs of the unchanged installed app using the same protected-store manifest. Ordinary removal made all three remembered value/excerpt/source-metadata payload references inaccessible, and the old source did not restore them after restart. A genuinely new appearance was detected normally. A later rotation acknowledgement and removal persisted its marker through restart. In the fourth run, a new original-value appearance remained metadata-only and silent; a different replacement in the same conversation was retained and alerted normally. Confirming its occurrence changed only that review. Forgetting the marker removed the acknowledgement, and a later original-value appearance returned to ordinary retention and evaluation.

Run four also exercised actual collection, the unchanged production scanner, inventory, native review, and visible masked OS notifications under the test-only parent network-denying policy. The user confirmed clicking a visible notification and opening a masked Token entry. Native accessibility showed the matching reviewed replacement occurrence selected with value and context masked; the app recorded two notification-navigation events. Notification-text masking is supported by controlled production text construction and the user's response. The banner text was not independently read through accessibility. A delivered receipt alone establishes UserNotifications request acceptance or an existing request; visible presentation and navigation have the separate evidence above.

The parent allowed the exact owned local capture socket and trusted `/usr/bin/sandbox-exec` bootstrap so the scanner could apply its unchanged network/fork-denying policy. That exception does not constrain arguments and is a generic bootstrap escape. This is a cooperative test, without a claim of secure denial for every descendant or system-wide offline operation. Its source was one disposable synthetic Claude 2.1.293 user-prompt transcript; no provider generation or Codex/T3 offline session ran.

All four app reports ended with queue zero, masked caches and normal exit. Manifest checks and ciphertext inspections passed. The original owner process removed only the newly-created vault protection, then removed its owned files; it performed no private-value decryption. Additional sleep/lock events occurred while already masked and establish no new authenticated-reveal invalidation result. Spillcheck notifications were restored off after testing, and launch at login remained off.

Discovery showed Codex 0.161.0 as found but not connected. The installed Claude CLI is now 2.1.294 and appears unsupported because that version has not been validated. The new real-provider measurement explicitly used the available pinned Claude 2.1.293 executable. Finding an executable does not establish a connection. These checks installed no hooks in the user's existing profiles.

[The supported matrix](supported-matrix.md) retains the measured tuples: Codex CLI producer/reader 0.161.0; Codex through T3 producer 0.160.1, reader 0.161.0, and T3 0.0.46-nightly.20261007.2761; Claude CLI and T3 2.1.293. All five required parent content types have real evidence on those tuples. Claude's native child's own prompt and final response are verified. Codex's child's own final response is verified, but its own prompt appearance is not. Desktop collection, direct Desktop conversation opening, newer tuples, and Intel coverage have no support claim.

## Acceptance criteria

The numbers below correspond to [SPEC.md](../SPEC.md#prototype-acceptance-criteria). An exercised scope means the cited checks passed; it does not fill an unverified interface or platform result.

| Criterion | Exercised scope and evidence | Remaining limit |
| --- | --- | --- |
| 1. Separate annotated content types | The 47-case scanner corpus recovered all 36 expected exact occurrences with no extras. Real CLI/T3 parent fixtures cover user, intermediate, final, successful tool output, and tool error, including shell/MCP cases. [M3](milestone-3.json), [M4](milestone-4.json), [new Claude CLI run](m6-claude-observation-latency.json), [new Codex CLI run](m6-codex-observation-latency.json). | Measured version/interface tuples only. Codex child prompt and Desktop collection remain unverified. |
| 2. Recent content in an old conversation and seven-day cutoff | Versioned Claude/Codex history tests, durable checkpoints, and cold/warm/append fixtures find recent content, exclude older source timestamps, and avoid unchanged payload reads. [M4 history evidence](milestone-4.json), [128-MiB fixture](m6-resources.json). | Bounded selection reports its unread prefix as partial. It does not certify an exhaustive seven-day history. |
| 3. Replay, real new appearance, and alert matrix | Core inventory tests and real provider runs preserve canonical replay counts while retaining new source/range appearances. Fresh CLI conversations produce eligible strong-signal alerts. [M4](milestone-4.json), [full suite](m6-full-tests.json), [new Claude CLI run](m6-claude-observation-latency.json), [new Codex CLI run](m6-codex-observation-latency.json). | A selected T3 source attached after its prompt is historical and does not prove a fresh-session live alert. |
| 4. Strong/ambiguous signals and scoped reversible review | Inventory tests distinguish confidence from user review and preserve per-occurrence scope. Native false-positive/confirmed review and filtering passed; rebuilt controls update the exact selected occurrence. [M5](milestone-5.json), [full suite](m6-full-tests.json). | Synthetic detection examples do not establish exhaustive secret detection or credential validity. |
| 5. Protection, masking, and safe notifications/diagnostics | Production Keychain/LocalAuthentication checks, signed native viewing/cancellation, lifecycle guards, controlled notification text, and protected-file marker inspections passed. [Production vault](production-vault-interactive.json), [M5](milestone-5.json), [final app](m5-final-app-workflow.json). | Tested environment only. The macOS 14 and hardware-without-Touch-ID checks are deferred before release. Marker inspection is not a forensic erasure claim. |
| 6. Retained value/context and source fallback | Real authenticated retained value/excerpt access after owned source deletion and the explicit unavailable/unverified opening fallback passed. Terminal resume is prepared separately without execution. [Production vault](production-vault-interactive.json), [native workflow](milestone-5.md). | Direct Desktop opening success remains unverified. Metadata-only obsolete appearances retain no value/excerpt fallback. |
| 7. Close, pause, resume, and Quit | Native lifecycle checks passed. Five paused helper attempts took 15.7–30.1 ms including startup; five after Quit took 18.7–20.4 ms and exited with stdin still open. Both returned only controlled empty JSON and stored nothing. [Paused](m5-paused-hook.json), [after Quit](m5-after-quit-hook.json), [final shutdown](m5-final-app-workflow.json). | These samples do not measure every active helper invocation or the delay before an agent publishes output. Actual login launch is untested. |
| 8. Delete, restart, inaccessible content, and new appearance | The exact signed GUI removal, normal Quit and reopen sequence passed. Three remembered protected references became inaccessible; old-source replay restored nothing, while a genuinely new appearance remained detectable. [Signed restart](m6-signed-restart-offline.json), [M2](milestone-2.json), [in-flight tests](m6-inflight-tests.json). | Active-storage accessibility only; no forensic-erasure claim. Synthetic source on the tested environment and unchanged development signing identity. |
| 9. Local workflow with external services blocked | One signed GUI run exercised synthetic collection, actual production scanning, encrypted inventory, occurrence review, visible masked notifications and clicks into masked inventory under a cooperative parent network-denying profile. [Signed offline workflow](m6-signed-restart-offline.json), [policy controls](m6-parent-sandbox-bootstrap.json). | Exact local-socket permission and trusted generic scanner-bootstrap escape. No all-descendant/system-wide denial or all-interface offline claim; OS notification services run outside the app process. |
| 10. Latency, memory, temporary storage, and large history | The required measurement categories are reported: actual scanner/CLI latency, sampled resource/GUI memory, protected and temporary storage, large-history bytes read, limits/losses, and audit/content bounds. [Resources](m6-resources.json), [Claude timing](m6-claude-observation-latency.json), [Codex timing](m6-codex-observation-latency.json), [signed GUI](m6-signed-app-memory.json), [history period](m6-resource-history-period.json). | These measured workloads pass with published scope limits. T3/history distributions, larger authenticated GUI workloads and physical first-byte publication remain unmeasured; no full-matrix performance promise or complete historical window is made. |
| 11. Obsolete retention, replacement, and forgetting | The exact signed GUI rotation acknowledgement, content removal, normal Quit/reopen, metadata-only silent rediscovery, same-conversation replacement and forgetting sequence passed. [Signed restart/offline workflow](m6-signed-restart-offline.json), [in-flight tests](m6-inflight-tests.json), [M2](milestone-2.json). | Native acknowledgement tested rotation; shared core semantics cover revocation separately. Forgetting restores ordinary evaluation; existing per-session alert receipts may still suppress another notification. |

Three new blocking-detector tests use the real encrypted store. Acknowledgement during scanning applies the current marker and cancels pending alerts. Acknowledged removal rejects stale work; after reopening, a fresh permit retains a new appearance as metadata-only obsolete content. Deletion during rule reanalysis prevents removed ranges from returning while a genuinely new source still gets ordinary detection. All nine detection-pipeline tests passed in 0.099 seconds. This does not suppress every future appearance after ordinary deletion.

Historical notification settlement has a separate 1,000-progress-row limit. The [six storage checks](m6-notification-limit-tests.json) with 1,001 rows withheld the summary without decrypting over-limit progress and persisted one deduplicated `notificationBudgetExhausted` gap across polling and restart. A 1,000-row summary remained eligible. Pending work above that limit is visibly partial.

## Measurements and budgets

The [resource run](m6-resources.json) used synthetic inputs and ephemeral testing keys, created no production Keychain items, and removed its owned files. Forty sequential samples processed 4,229,351 input bytes through queue encryption, normalization, actual Betterleaks processes, value/context encryption, and inventory commit. The p50 was 240.7 ms, p95 548.3 ms, and maximum 814.7 ms. These samples exclude provider observation delay, helper startup/IPC, worker idle polling, GUI work, and OS notification display. The local sample p95 is below the proposed 120-second target; it is not a full application or interface-matrix latency result.

The [real Claude CLI run](m6-claude-observation-latency.json) used three disposable authenticated provider invocations and committed all nine typed marker cases. It produced one value, 19 occurrences, two conversations, two synthetic alert decisions, 42 durable deliveries, an empty queue, stable replay, and clean protected-file inspection. Unknown provider content remained an explicit `unsupportedContent` gap. Its copied authentication, provider transcripts, and owned process groups were removed; existing hooks and histories remained untouched.

| Claude 2.1.293 CLI live metric | Samples | p50 | p95 / maximum |
| --- | ---: | ---: | ---: |
| Provider transcript timestamp to canonical read-start observation | 12 | 271.1 ms | 1,165.4 ms |
| Enclosing durable queue capture to commit observation | 12 | 501.1 ms | 703.4 ms |
| Canonical read-start observation to commit observation | 12 | 175.7 ms | 340.2 ms |

These nearest-rank quantiles have only 12 samples, so p95 equals the maximum. Provider timestamps do not measure physical first output byte or publication, and timestamp-to-read delay can include local polling and queue waiting. Read-start precedes asynchronous reads; an append can create a negative delta without clock skew. Each leg counts and excludes negative/nonfinite deltas independently; none occurred here. Queue capture can precede a source row's publication. Commit observation follows the enclosing capture's work and upper-bounds the per-source durable commit. Final catch-up and replay are excluded. Historical and T3 populations are unmeasured.

The [real Codex CLI run](m6-codex-observation-latency.json) used one disposable Codex 0.161.0 producer and the same validated reader version. Its `exec --json` thread-start event launched an exact-ID public-history observer while the producer was still running. All eight established typed marker cases committed before catch-up, including the separate native child's own final response. The run retained one value, 14 occurrences and two conversations, recorded two synthetic alert decisions and 33 durable poll deliveries, drained its queue, and added no occurrences in final catch-up or replay. Protected-file inspection and removal of copied authentication, owned process groups and disposable files passed. It installed no hooks, bypassed no trust checks and modified no existing profiles or histories.

| Codex 0.161.0 CLI live metric | Samples | p50 | p95 / maximum |
| --- | ---: | ---: | ---: |
| Public item timestamp to canonical read start | 8 | 606.0 ms | 999.1 ms |
| Enclosing durable queue capture to commit observation | 8 | 401.9 ms | 2,605.2 ms |
| Canonical read start to commit observation | 8 | 322.3 ms | 785.1 ms |

These nearest-rank quantiles have eight samples, so p95 equals the maximum. Codex read start is a separate acceptance timestamp captured immediately before awaiting the adapter. Product `observedAt` remains the queue-capture timestamp and is not used as read start. Public item time uses completion time when available, otherwise start or turn time; it does not prove physical first-byte publication or history availability. Commit observation follows the enclosing capture and upper-bounds exact durable commit. Negative/nonfinite deltas are counted and excluded per leg; none occurred. Final catch-up and replay are excluded. Historical latency, T3 latency, hook-delivery latency and the native child's own prompt remain unverified.

The [first Codex assertion report](m6-codex-observation-latency-extra-child-prompt-assertion-r1.json) failed because it added a child-prompt requirement beyond the established eight-marker Codex fixture. The final report reuses that genuine run's unchanged measurements and cleanup evidence with the corrected gate. No provider rerun or new child-prompt coverage is claimed.

| Resource or limit | Measured result or configured bound |
| --- | --- |
| Large synthetic Claude history | 134,253,008 source bytes before append; recent content in an old conversation found; source-time cutoff passed. |
| Cold / unchanged / append bytes read | 2,097,152 / 0 / 6,698 bytes, including boundary verification. The append added 554 logical bytes and two occurrences. |
| Cold / unchanged / append queue-to-inventory time | 2,232.4 / 8.8 / 2,135.5 ms, one bounded pass each. These are individual measurements, not latency distributions. |
| Historical work | Rolling seven-day audit; 100 MiB, 30 seconds, and 256 sources per pass; 2-MiB source quantum. The old unread prefix remains explicitly partial. |
| Durable queue | 100-MiB encrypted payload cap, 8-MiB event cap, 24-hour expiry. Ten 7-MiB synthetic payloads reached 99,398,249 encrypted bytes before rejection; oversize input changed no queue state. All ten expired while paused, with visible loss gaps and zero final queued bytes. |
| Protected storage / scanner work | Peak logical store size 101,601,280 bytes including journals; 100,552,704 bytes after close. Scanner work directory held zero bytes. Queue payload limits do not cap metadata or physical database size. |
| Resource acceptance process memory | Processing/replay cumulative peak 89,587,712 bytes. Whole-probe high-water mark 340,590,592 bytes after saturation and repeated inspections; scanner-child high-water mark 30,965,760 bytes. These are separate maxima, not simultaneous total RSS or GUI memory. |
| Sampled resource process tree | 319,700,992-byte sampled peak across 117 samples. Nominal delay 100 ms; short peaks can fall between samples. |
| Signed GUI process | [71 owned-PID samples](m6-signed-app-memory.json), nominal 100-ms delay plus `ps` execution overhead, over 8.972 seconds. Sampled peak 159,973,376 bytes, last sample 157,761,536 bytes; protected store 192,512 bytes after Quit. |
| Signed GUI memory scope | Startup, five-content synthetic ingestion, and idle. All five types committed once; queue zero, no errors/gaps, clean ciphertext and scoped cleanup. Scanner/helper children, large inventory, authenticated rendering, and exact high-water mark are excluded. |
| Retained context / processing | Excerpts bounded at 4 KiB; exact value retained separately. One scanner worker, a 110-second accepted-work deadline, and bounded retries/gaps. |

No automatic inventory expiry was introduced. Queue expiry is loss of pending work and produces coverage gaps. Deletion checks remove active protected payload access and preserve replay suppression; they make no forensic-erasure promise. The large-history benchmark tests a monotonic synthetic transcript, not arbitrary growing-file rewrites or compressed histories.

The [history-period supplement](m6-resource-history-period.json) is a separate fresh run of the same 134,253,008-byte fixture with the same pinned scanner, rules and corpus. It passed in 2.859 seconds using ephemeral keys, with no production Keychain, provider or GUI operations. Original resource timings and bytes remain unchanged; their exact dates were not recoverable after the disposable source was removed. These dates belong to the new repeat:

| History pass | Inclusive audit window, UTC | Adapter/new retained content bounds, UTC | Payload bytes read |
| --- | --- | --- | ---: |
| Cold | October 1, 2026 10:59:30 to October 8, 2026 10:59:30 | October 1 10:59:30 to October 8 10:59:20; nine retained occurrences | 2,097,152 |
| Unchanged | October 1, 2026 10:59:31 to October 8, 2026 10:59:31 | No newly emitted or retained content; reused newest checkpoint October 8 10:59:20 | 0 |
| Append | October 1, 2026 10:59:31.936 to October 8, 2026 10:59:31.936 | October 8 10:59:30.935; two new occurrences | 6,698 |

Adapter bounds describe emitted sources and the newest checkpoint, and retained bounds describe new detections in each pass. They do not enumerate timestamps in unread bytes or prove continuous coverage between the endpoints. All three passes still report unread content and partial coverage.

Criterion 10 requires measurements of latency, memory, temporary storage and large-history read volume, with limits, losses and period coverage documented. Those categories now have recorded results. The proposed p95 target is met by the stated scanner and standalone CLI workloads. The specification does not require a separate latency distribution for every interface or a physical first-byte measurement. Those unmeasured dimensions remain published limits, rather than extra gates or broader performance claims. The implementation plan's requirement to document gaps remains in force, as do every explicit release and platform check.

## Signing and deferred work

[Two consecutive development builds](m6-incremental-signing.json) verified signatures and left scanner/manifest bytes and modification times unchanged. The [five scanner-bundling checks](m6-scanner-bundling.json) and [14 release-policy checks](m6-release-policy.json) passed. Those policy tests use synthetic signatures/profiles and perform no signing or notarization upload. Release tooling requires an explicit Developer ID identity matching the configured vault access identity and rejects Debug/preview executables, unreviewed code, changed scanner provenance, and release entitlement/version mismatches. Actual Developer ID release signing has not run.

The earlier [resource-seal failure](m6-incremental-signing-failure.json), [cache-miss measurement](m6-incremental-signing-cache-miss.json), and [nested-sandbox failure](m6-resources-nested-sandbox-failed-r1.json) remain preserved. Later evidence corrects their local checks rather than turning the original attempts into passes. [Scoped recovery](m6-resources-nested-sandbox-cleanup.json) removed only the verified failed ephemeral run and performed zero Keychain deletion operations.

The recorded local behavioral and measurement checks now pass within their declared scopes. Codex native child prompt coverage and the broader measurement dimensions remain unverified limits. Developer ID signing, notarization/stapling, Gatekeeper installation, distribution update and upgrade key persistence remain deferred and unverified. Actual login launch remains untested before release. macOS 14 and hardware without Touch ID still need their explicitly deferred tests before release. The full release gate remains open; no distribution package or release acceptance is claimed.

## Reproduce

Run from the repository root. Preserve reports from failed attempts. Do not rebuild a bundle while its acceptance run is live. Real provider runs need existing provider authentication; native vault checks need an unlocked Mac and authorization only in macOS prompts.

```sh
scripts/build-app.sh
SPILLCHECK_SIGNED_SCANNER_APP="$PWD/.build/app/Build/Products/Debug/Spillcheck.app" swift test
swift test --filter DetectionPipelineTests
swift test --filter WorkflowStorageTests
python3 Tests/NativeWorkflowProbe/run.py --products-path .build/out/Products/Debug --output-directory .build/native-workflow
python3 Tests/AgentSetupProbe/run.py
python3 Tests/Tooling/check-scanner-bundling.py
python3 Tests/Tooling/check-release-policy.py
swift build --product spillcheck-resource-acceptance
python3 scripts/prepare-scanner.py
python3 Tests/ResourceAcceptance/run.py --skip-build --output .build/implementation/m6-resources-repeat.json
python3 Tests/ResourceAcceptance/run.py --skip-build --history-period-only \
  --output .build/implementation/m6-resource-history-period-repeat.json
swift build --product spillcheck-storage-acceptance
python3 Tests/ClaudeLive/run.py \
  --executable "<CLAUDE_EXECUTABLE>" \
  --acceptance-executable .build/out/Products/Debug/spillcheck-storage-acceptance \
  --output .build/implementation/m6-claude-observation-latency-repeat.json
swift build --scratch-path .build/codex-latency --product spillcheck-storage-acceptance
python3 Tests/CodexLive/measure-latency.py \
  --acceptance-executable .build/codex-latency/debug/spillcheck-storage-acceptance \
  --report .build/implementation/m6-codex-observation-latency-repeat.json
python3 Tests/AppAcceptance/run-app-pipeline.py \
  --app .build/app/Build/Products/Debug/Spillcheck.app \
  --output .build/implementation/m6-signed-app-memory-repeat.json
```

Replace `<CLAUDE_EXECUTABLE>` with the path to a validated Claude Code 2.1.293
executable. App commands above use the development bundle built from this checkout.

[The signed-owner instructions](../../Tests/ProtectionSignedProbe/VaultOwner.md) reproduce the four-run GUI restart/offline sequence and final evidence checks with fresh private paths and normal Quit. [The M5 reproduction steps](milestone-5.md#reproduce) cover the manual viewing, review, notification, and lifecycle walkthrough. [The supported matrix](supported-matrix.md) links the existing real Codex/Claude T3 and CLI evidence and their separate reproduction tools. The recorded development installation was left with launch at login off and no newly configured real-agent hooks.
