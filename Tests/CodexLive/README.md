These opt-in runners create disposable synthetic Codex sessions and exercise the production collection pipeline. They copy existing authentication into a private temporary Codex home and remove it with the disposable session. Run them explicitly when validating the supported Codex CLI; they are outside the default core test run.

Prepare scanner resources and build `spillcheck-storage-acceptance` first. Run commands from the repository root:

```sh
python3 scripts/prepare-scanner.py
swift build --product spillcheck-storage-acceptance
python3 Tests/CodexLive/run.py --executable "$(command -v codex)"
python3 Tests/CodexLive/measure-latency.py --executable "$(command -v codex)" \
  --acceptance-executable .build/debug/spillcheck-storage-acceptance
```

`run.py` starts a standalone producer, reads only its original public history through the opt-in `CodexPublicLiveTests`, records sanitized fixtures, then checks the encrypted pipeline and replay. `--executable` selects the actual producer; the example resolves it from `PATH`. `--reader-executable` selects a different passive reader when needed. Both actual executable versions and source producer versions enter the report. Optional `--expect-producer-version` and `--expect-reader-version` pin a particular acceptance baseline without changing product eligibility. `--fixtures` defaults to `Tests/Fixtures/Codex`, so this run can add regression recordings there. Its acceptance executable is `.build/out/Products/Debug/spillcheck-storage-acceptance`; its report defaults to `.build/implementation/codex-cli-live.json`.

Direct opt-in use of `CodexPublicLiveTests` requires `SPILLCHECK_CODEX_PROBE_EXECUTABLE` alongside the selected home, thread IDs, and report path. The runner sets these explicitly; the Swift probe has no default executable path.

The three CLI runners now require twelve typed markers: seven in the parent's own source (the five content types, including separate shell and MCP results/errors), and five in its one native child's own source. The child's prompt, intermediate response, final response, tool output and tool error must each be present exactly once. Parent spawn arguments and mirrored child summaries cannot fill missing child content. Passive native metadata and recognized parent links establish the two source roles. A committed marker requires its exact revision's analysis receipt and the fake token's retained occurrence with matching content time and type. A prior receipt for the same item cannot credit an uncommitted revision.

`measure-latency.py` starts the observer on the producer's `thread.started` event and measures canonical read-start to commit observation while the producer runs. The same twelve-marker gate must pass before final catch-up as well as afterward. T3 latency and hook-delivery latency remain outside this measurement. `--executable` selects the producer, `--reader-executable` optionally selects the passive reader, and `--acceptance-executable` defaults to `.build/out/Products/Debug/spillcheck-storage-acceptance`. The report defaults to `.build/implementation/codex-observation-latency.json`; `--report` selects another output without changing historical evidence. Historical eight-marker reports retain their original, narrower meaning; changing this gate does not retroactively establish child prompt or child tool coverage.

The interactive runner checks genuine hook review and trust:

```sh
python3 Tests/CodexLive/interactive.py
```

It requires the signed app helper at `.build/app/Build/Products/Debug/Spillcheck.app/Contents/Helpers/spillcheck-hook`, the acceptance executable at `.build/out/Products/Debug/spillcheck-storage-acceptance`, the pinned scanner, and Codex at the executable location configured in `interactive.py`. `--executable` selects another executable; `--expect-version` optionally pins this acceptance run to a baseline. Follow the command and `/hooks` review instructions in `.build/implementation/codex-interactive-ready.json`. Submit the one-use verification prompt and synthetic task, quit Codex, then touch the reported `finishFile`. The report is `.build/implementation/codex-interactive-live.json`; `--ready`, `--report`, and `--duration` select other outputs or a bounded duration. The runner never bypasses hook trust or modifies existing hook settings.

Runtime method and format recognition permits unfamiliar versions without promoting them to measured acceptance evidence. Every runner retains the content, encrypted-storage, replay, and cleanup assertions. An unavailable passive method remains a failed or partial run. These CLI runners establish no official GUI coverage.

For a direct selected-source probe, set `SPILLCHECK_CODEX_PROBE_INTERFACE` and, for T3, `SPILLCHECK_CODEX_PROBE_HOST_VERSION` from the observed host. The probe never infers a host from a producer version. The signed-app runner `Tests/AppAcceptance/run-app-codex-pipeline.py` likewise requires `--host-version` for T3 and accepts optional strict reader/producer baselines.

Pass `--signed-app /absolute/path/to/Spillcheck.app` to `run.py` to additionally read the exact new standalone parent and its one native child through that signed app before the disposable provider home is removed. The runner first requires a complete passive public read with matching parent identity, producer version and reader version. It derives the child only from recognized native activity or collaboration links in that parent's bounded fixture, then passes both exact identities and strict parent/child expectations to the signed runner. Missing, malformed, self-referencing or multiple child identities fail the run. The signed run must independently verify those native links and all twelve committed typed markers, alongside the empty queue, encryption and vault cleanup. Aggregate content counts alone cannot pass the strict gate. This establishes no live collection, GUI or T3 coverage.

When `run.py` fails before acceptance, it retains at most sixteen original fake rollout files and 32 MiB from its disposable provider home's `sessions` directory beside the chosen report, in `<report stem>.failed-native-sources`. The directory is private and must not already exist; symlinks and special files are rejected. Only `.jsonl` rollout files are eligible; authentication, config and unrelated provider files are excluded. Temporary authentication is still removed. Unreadable nested directories fail retention rather than being silently skipped. The controlled `failedSourceRetention` status reports an incomplete retention without claiming that causal evidence was preserved. Use a fresh report path for each attempt so old failed sources and reports remain intact. Synthetic public fixtures continue to use the selected `--fixtures` directory. The CLI exits `0` only when its final acceptance gate passes; an unmet gate exits `1`, even if the passive public read itself completed.

The selection boundary can be checked without providers, authentication or Keychain access:

```sh
python3 -m unittest discover -s Tests/CodexLive -p 'test_*.py'
python3 Tests/CodexLive/test-evidence.py
```

The Swift evidence checks compile against a snapshot of the existing Core build products and invoke no provider, scanner, vault or Keychain. They cover rejected parent mirrors, unlinked or mismatched sources, absent/wrong revision receipts and occurrence times, legitimate provider prefixes, replay and extra native children. Python tests cover the strict role gate, the original parent-link selection boundary and bounded failed-source retention.
