This probe compiles the app's saved-profile model, setup controller, collection configuration, and view dependencies against an already-built `SpillcheckCore` library. It checks disposable Codex and Claude profiles, owned-hook preservation/removal, compatible executable upgrades, and durable verification. Provider fixtures accept only `--version`; the probe uses ephemeral testing keys and starts no provider sessions.

Schema 1 and 2 fixtures omit the new host field. Both providers and both legacy transport interfaces must migrate to schema 3 with the same home, profile, registration, proof, hooks, and encrypted pending packet body. CLI/T3 host authorization is separate from the immutable owned hook transport; authorization changes preserve the proof and provider settings. Desktop remains unauthorized, and a damaged schema 3 record cannot infer broader authorization. Failed encrypted writes must leave the old configuration and in-memory status intact.

The probe also checks scoped CLI/T3 status, canonical Claude replay receipts, and sole-host historical request routing without changing its frozen audit or cursor. Shared registration verification does not establish the actual producer host. These are constructed contract checks; genuine signed migration and host runs require separate evidence.

Run from the repository root after building the core package:

```sh
python3 Tests/AgentSetupProbe/run.py --products-path .build/out/Products/Debug
```

`--products-path` reuses existing products without invoking SwiftPM. Without it, the runner discovers cached products with `swift build --show-bin-path`. It requires `libSpillcheckCore.a`, its module, and the GRDB SQLite module map, and compiles for Apple Silicon and macOS 14. The report is `.build/implementation/agent-setup-probe.json`.
