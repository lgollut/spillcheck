# Test and acceptance tooling

Run the core Swift suite from the repository root with `make test`. Prepare the
scanner on a fresh checkout with `make scanner-dependencies` first. CI runs the
same suite with `swift test --no-parallel` so that test cases with short process
and socket deadlines don't compete for the hosted runner. Use that command to
reproduce a CI timing failure locally.

Run the offline Python suite from the repository root:

```sh
python3 Tests/Tooling/run-python-tests.py
```

This checks the acceptance scripts, evidence rules, trial logs, process cleanup,
scanner bundling and release packaging with temporary fixtures and mocked app
and provider operations. It requires Python 3.9 or later, Git and zsh on POSIX,
with no pip dependencies. Use a non-root account to exercise the permission
checks. It does not launch a provider or signed app, request Keychain
authentication, or require old `.build` evidence.

Each directory runs in a separate Python process so repeated module names cannot
interfere. The runner discovers unittest cases even in files without a main
block, checks that every Python test script has a declared scope, reports skipped
checks, and exits nonzero if any suite fails.

Use `--list` to inspect the scope or `--suite AppAcceptance` to run one directory.
CI uses the same command. This entrypoint runs Python only. Checks requiring
compiled Core libraries or the hook helper remain separate and are listed before
the run; the compiled hook-helper checks also run in CI. Permission tests report
skips when invoked as root.

The directories also contain checks that need a separate executable, a signed
app, or a provider session:

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
- `CodexHookDeliveryProbe/`: unattended real helper/socket/encrypted-store/scanner
  reliability checks with fake hook content, process kills, replay and pause/resume.
- `CodexReviewProbe/`: one genuine fake-only inline review, with exact null-phase
  assistant text, original time and stable native identity through two passive
  reads. Presentation warnings remain separate; no signed or child claim.
- `CodexPlanProbe/`: the genuine fake-only Plan producer used by shared signed
  native-content acceptance. Direct Swift tests cover parsing and recovery.
- `CodexMCPSourceProbe/`: the fixed native MCP producer and its original protocol
  text and structured business JSON, used by signed and pipeline acceptance.
- `CodexHookPromptProbe/`: one normally reviewed, one-shot Stop hook in a disposable
  CLI session, followed by original native-fragment reads and replay. No vault or
  signed-app runtime is involved.
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
