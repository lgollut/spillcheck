These opt-in runners create disposable synthetic Codex sessions and exercise the production collection pipeline. They copy existing authentication into a private temporary Codex home and remove it with the disposable session. Run them explicitly when validating the supported Codex CLI; they are outside the default core test run.

Prepare scanner resources and build `spillcheck-storage-acceptance` first. Run commands from the repository root:

```sh
python3 scripts/prepare-scanner.py
swift build --product spillcheck-storage-acceptance
python3 Tests/CodexLive/run.py --executable "$(command -v codex)"
python3 Tests/CodexLive/measure-latency.py --executable "$(command -v codex)" \
  --acceptance-executable .build/debug/spillcheck-storage-acceptance
```

`run.py` starts a standalone producer, reads only its original public history through the opt-in `CodexPublicLiveTests`, records sanitized fixtures, then checks the encrypted pipeline and replay. `--executable` selects the validated Codex executable; the example resolves it from `PATH`. `--fixtures` defaults to `Tests/Fixtures/Codex`, so this run can add regression recordings there. Its acceptance executable is `.build/out/Products/Debug/spillcheck-storage-acceptance`; its report defaults to `.build/implementation/codex-cli-live.json`.

Direct opt-in use of `CodexPublicLiveTests` requires `SPILLCHECK_CODEX_PROBE_EXECUTABLE` alongside the selected home, thread IDs, and report path. The runner sets these explicitly; the Swift probe has no default executable path.

`measure-latency.py` starts the observer on the producer's `thread.started` event and measures canonical read-start to commit observation while the producer runs. It requires Codex 0.161.0 and the eight established typed markers, including a native child's own final response. Child-prompt coverage, T3 latency, and hook-delivery latency remain unverified. `--executable` selects the validated Codex executable; `--acceptance-executable` defaults to `.build/out/Products/Debug/spillcheck-storage-acceptance`. The report defaults to `.build/implementation/codex-observation-latency.json`; `--report` selects another output without changing historical evidence.

The interactive runner checks genuine hook review and trust:

```sh
python3 Tests/CodexLive/interactive.py
```

It requires the signed app helper at `.build/app/Build/Products/Debug/Spillcheck.app/Contents/Helpers/spillcheck-hook`, the acceptance executable at `.build/out/Products/Debug/spillcheck-storage-acceptance`, the pinned scanner, and Codex at the executable location configured in `interactive.py`. This runner does not expose an executable override. Follow the command and `/hooks` review instructions in `.build/implementation/codex-interactive-ready.json`. Submit the one-use verification prompt and synthetic task, quit Codex, then touch the reported `finishFile`. The report is `.build/implementation/codex-interactive-live.json`; `--ready`, `--report`, and `--duration` select other outputs or a bounded duration. The runner never bypasses hook trust or modifies existing hook settings.
