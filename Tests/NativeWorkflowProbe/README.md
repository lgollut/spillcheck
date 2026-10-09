This probe compiles the app's viewing, notification, source-opening, and selection controllers with their view dependencies against an already-built `SpillcheckCore` library. It checks delayed authentication, masking and selection changes, notification permission and cancellation races, and bounded source-command cancellation. Authentication and notification backends are injected; no real macOS prompts or provider sessions occur.

Run from the repository root with cached core products:

```sh
python3 Tests/NativeWorkflowProbe/run.py --products-path .build/out/Products/Debug
```

Without `--products-path`, the runner discovers products with `swift build --show-bin-path`. It requires `libSpillcheckCore.a`, its module, and the GRDB SQLite module map, and compiles for Apple Silicon and macOS 14. `--output-directory` selects the binary and report directory; the default report is `.build/implementation/native-workflow-probe.json`. This contract probe does not establish real system authentication, notification delivery, or source-opening compatibility.
