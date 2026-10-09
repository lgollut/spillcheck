This probe compiles the app's `AppModel`, `AgentSetupController`, and their view dependencies against an already-built `SpillcheckCore` library. It checks disposable Codex and Claude profiles, preservation and removal of owned hook settings, and rejection of unsupported or changed executables during verification. Provider fixtures accept only `--version`; the probe uses ephemeral testing keys and starts no provider sessions.

Run from the repository root after building the core package:

```sh
python3 Tests/AgentSetupProbe/run.py --products-path .build/out/Products/Debug
```

`--products-path` reuses existing products without invoking SwiftPM. Without it, the runner discovers cached products with `swift build --show-bin-path`. It requires `libSpillcheckCore.a`, its module, and the GRDB SQLite module map, and compiles for Apple Silicon and macOS 14. The report is `.build/implementation/agent-setup-probe.json`.
