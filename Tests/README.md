# Test and acceptance tooling

Run the core Swift suite from the repository root with `make test`. Prepare the
scanner on a fresh checkout with `make scanner-dependencies` first. CI runs the
same suite with `swift test --no-parallel` so that test cases with short process
and socket deadlines don't compete for the hosted runner. Use that command to
reproduce a CI timing failure locally.

The remaining directories contain checks that need a separate executable, a
signed app, or a provider session:

- `SpillcheckCoreTests/` and `Fixtures/`: core regression tests and synthetic inputs.
- `Tooling/`: scanner bundling and release packaging tests using fake tools, and
  changeset policy, versioning, and GitHub release tests using temporary repositories.
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

CI also runs the provider-free vault-owner evidence and delivery-helper tests.
To repeat them locally after building the Swift package:

```sh
python3 Tests/ProtectionSignedProbe/test_vault_owner_evidence.py
SPILLCHECK_HOOK_TEST_EXECUTABLE="$(swift build --show-bin-path)/spillcheck-hook" \
  python3 Tests/HookHelper/test_delivery.py
```
