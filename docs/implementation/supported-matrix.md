# Measured interface and version matrix

Measured October 7–8, 2026 on an Apple Silicon test environment running macOS 26.6.2. The deployment baseline remains macOS 14; execution there and hardware without Touch ID are still required before release. These checks were explicitly deferred until before release; local implementation continued while the environments were unavailable.

| Agent and interface | Measured versions | Collection authority | Required content types | Evidence |
| --- | --- | --- | --- | --- |
| Codex standalone CLI | Producer and public reader 0.161.0 | Provider hook delivery plus selected native public history; one encrypted authority per conversation | User, intermediate, final, successful tool output, tool error; shell and MCP cases, native child | [CLI](codex-cli-live.json), [ordinary native hook trust and live fixture](codex-interactive-live.json) |
| Codex through T3 | Producer 0.160.1, public reader 0.161.0, T3 0.0.46-nightly.20261007.2761 | Original public history through the production passive client; explicitly selected disposable parent and native child | All five types in parent; child's own final response | [Original history](codex-t3-public-read.json), [signed ingestion](app-codex-t3-pipeline.json) |
| Claude Code standalone CLI | 2.1.293 | Selected transcript is the canonical authority, with native IDs and exact component ranges. Hooks trigger bounded transcript reads; batch tool payloads are compared with the transcript, not ingested | All five types, including successful and failed shell/MCP results | [Current CLI](claude-m4-cli-live.json), [signed ingestion](app-pipeline-m4.json) |
| Claude Code through T3 | 2.1.293 | Bounded observation of explicitly mapped, owned native session transcript; mapping discovery is experiment-only | All five types, nine typed markers, native child | [Owned T3 observation](claude-m4-t3-live.json) |
| Codex Desktop / Claude Desktop collection | Unverified | No coverage claim | Unverified | Visible unsupported/unverified states |

Codex source authority is stable across overlapping collectors and restarts. A transcript route is an explicit, versioned alternative, not a silent switch when public history fails. Exact source identities and UTF-8 ranges reconcile repeated content without merging legitimate new appearances.

Native Desktop conversation dispatch remains unverified, and direct opening is disabled in code until a route is validated. The signed user workflow has verified authenticated retained-context viewing after the source was deleted, an explicit direct-opening fallback, and separately prepared terminal resume commands. The commands are shown rather than executed. Notification clicks open masked inventory details.

The selected scanner is pinned Betterleaks 1.9.0 with the stdlib regex engine, disabled network validation and decoding, plus three annotation-justified supplemental rules. The synthetic corpus measures exact-value extraction and source ranges; it does not establish exhaustive detection or service validity. GRDB is pinned to 7.11.1. The [production scanner fixtures](../../Tests/Fixtures/Scanner/README.md) describe the retained corpus, measured behavior, and limitations; [signed-scanner acceptance](milestone-3.md#signed-scanner-correction) records the production engine choice.

Unknown executable versions invalidate connection/challenge state and show unsupported status. Safe removal remains available for previously owned registrations after an upgrade. Merely finding an executable never means connected. Native Codex hook trust is completed through ordinary `/hooks` review; no trust bypass establishes acceptance.

The final native discovery check found Codex 0.161.0 and Claude 2.1.294. Codex was shown as found but unconnected; Claude 2.1.294 was shown as unsupported. The latter is outside the tested 2.1.293 tuple. A separately selected 2.1.293 executable was used for the final genuine CLI fixture. No existing user hook settings were edited during this check.

A single transcript row or Codex history item larger than 1 MiB is not analyzed. It records a visible budget gap; the hook payload is not used as a fallback. The 8 MiB queue limit applies to a whole captured event.

Codex public history has no change signal, so each thread selected by a hook is polled while it is active: every second for two minutes, every 5 seconds up to ten minutes, every 30 seconds up to an hour, then not until its next hook. Each hook capture reads its thread directly, so a quiet thread loses no content; only discovery latency changes.

The matrix describes tested paths and tuples. It does not extend those results to newer versions, hosted tool paths, arbitrary T3 releases, Intel, unavailable histories, or a validated source-message deep link. Bounded history, queue limits, retries, and unlocated results have visible partial-coverage states.
