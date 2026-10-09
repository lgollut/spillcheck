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

`measure-latency.py` starts the observer on the producer's `thread.started` event and measures canonical read-start to commit observation while the producer runs. It observes the actual producer and reader versions and requires the eight established typed markers, including a native child's own final response. Child-prompt coverage, T3 latency, and hook-delivery latency remain unverified. `--executable` selects the producer, `--reader-executable` optionally selects the passive reader, and `--acceptance-executable` defaults to `.build/out/Products/Debug/spillcheck-storage-acceptance`. The report defaults to `.build/implementation/codex-observation-latency.json`; `--report` selects another output without changing historical evidence.

The interactive runner checks genuine hook review and trust:

```sh
python3 Tests/CodexLive/interactive.py
```

It requires the signed app helper at `.build/app/Build/Products/Debug/Spillcheck.app/Contents/Helpers/spillcheck-hook`, the acceptance executable at `.build/out/Products/Debug/spillcheck-storage-acceptance`, the pinned scanner, and Codex at the executable location configured in `interactive.py`. `--executable` selects another executable; `--expect-version` optionally pins this acceptance run to a baseline. Follow the command and `/hooks` review instructions in `.build/implementation/codex-interactive-ready.json`. Submit the one-use verification prompt and synthetic task, quit Codex, then touch the reported `finishFile`. The report is `.build/implementation/codex-interactive-live.json`; `--ready`, `--report`, and `--duration` select other outputs or a bounded duration. The runner never bypasses hook trust or modifies existing hook settings.

Runtime method and format recognition permits unfamiliar versions without promoting them to measured acceptance evidence. Every runner retains the content, encrypted-storage, replay, and cleanup assertions. An unavailable passive method remains a failed or partial run. These CLI runners establish no official GUI coverage.

For a direct selected-source probe, set `SPILLCHECK_CODEX_PROBE_INTERFACE` and, for T3, `SPILLCHECK_CODEX_PROBE_HOST_VERSION` from the observed host. The probe never infers a host from a producer version. The signed-app runner `Tests/AppAcceptance/run-app-codex-pipeline.py` likewise requires `--host-version` for T3 and accepts optional strict reader/producer baselines.
