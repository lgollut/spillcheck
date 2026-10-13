This runner exercises `spillcheck-resource-acceptance` with synthetic histories, the production scanner, and ephemeral testing keys. It samples the owned process tree's RSS, inspects transient files for synthetic plaintext, and separately checks the local workflow under network denial. It creates no production Keychain items or provider sessions. Failed runs retain their disposable store and private recovery manifest through `Tests/Support/acceptance_artifacts.py`.

Run from the repository root:

```sh
python3 scripts/prepare-scanner.py
python3 Tests/ResourceAcceptance/run.py
```

The runner builds `spillcheck-resource-acceptance` unless `--skip-build` is supplied. Its executable is `.build/debug/spillcheck-resource-acceptance`; scanner resources are `.build/scanner/betterleaks` and `.build/scanner/betterleaks.toml`. The report defaults to `.build/implementation/m6-resources.json`. Use `--output` for a separate report or `--history-period-only` for the isolated cold, warm, and append history measurement.

The history fixture uses current Claude message envelopes, including matching message roles. Its generated prefix has monotonically old timestamps outside the selected seven-day window. Cold selection must retain all nine in-window occurrences, warm reuse must read zero payload bytes, and the append must add exactly two occurrences within the byte budget. Each phase must finish without unread in-window content. The report separates final unread status from temporary unread progress. This fixture-specific window check does not establish completeness for arbitrary histories. Failed history assertions have controlled `history.*` labels without source text or paths.

The unsandboxed resource parent runs the production scanner under its own network and fork denial profile. A separate sandboxed parent checks the local workflow using annotated fixture detections. These are component checks, and they do not establish a network boundary around the combined process tree. Short RSS peaks can fall between samples.
