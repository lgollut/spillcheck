# Test and acceptance tooling

Run the core Swift suite from the repository root with `make test`. Prepare the
scanner on a fresh checkout with `make scanner-dependencies` first.

The remaining directories contain checks that need a separate executable, a
signed app, or a provider session:

- `SpillcheckCoreTests/` and `Fixtures/`: core regression tests and synthetic inputs.
- `Tooling/`: scanner bundling and release packaging tests using fake tools.
- `AgentSetupProbe/` and `NativeWorkflowProbe/`: app controller tests using disposable
  profiles and injected authentication/notification backends.
- `AppAcceptance/`: signed-app ingestion and interactive native workflow checks.
- `ProtectionSignedProbe/`: production vault authentication, restart, and cleanup checks.
- `ClaudeLive/` and `CodexLive/`: genuine provider collection, fixture recording,
  and latency checks using disposable sessions.
- `ResourceAcceptance/`: synthetic resource measurements and offline workflow checks.
- `HookHelper/`: delivery-helper checks.
- `Support/`: shared Python process cleanup and disposable acceptance-artifact handling.

Each runner's README or `--help` explains its prerequisites. Run genuine-provider
and interactive signed-app checks explicitly. Core and build-tool tests do not
need provider sessions or macOS authentication. Build and packaging tools live
in `scripts/`.
