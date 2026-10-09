# Implementation maintenance

The Spillcheck local development MVP is implemented. Milestones 1–5 passed and milestone 6 has scoped local acceptance; its release gate remains open. Continue work from the current app, core modules, and acceptance tooling.

Before coding, read the applicable repository instructions and these documents:

- `CONTEXT.md` for domain vocabulary.
- `docs/SPEC.md` for confirmed behavior and acceptance criteria.
- `docs/IMPLEMENTATION_PLAN.md` for architecture, milestone gates, and initial resource budgets.
- Every ADR in `docs/adr/`, including the obsolete-value retention decision.
- `docs/implementation/milestones.json` for completed gates and `docs/implementation/release-checks.json` for outstanding checks and the user's recorded deferrals.

Preserve confirmed behavior when revising technical choices. Verify current agent interfaces and dependency versions against local tools and official sources before extending the [supported matrix](implementation/supported-matrix.md).

The exploratory milestone-0 projects and their reports have been removed. Production dependency metadata belongs in `Dependencies/Scanner/` and build and release tooling in `scripts/`. App acceptance runners, provider and controller probes, fixtures, and shared support belong in `Tests/`; tests of build and release tooling live in `Tests/Tooling/`. Keep app behavior in `Spillcheck/` and core code in `Sources/`.

Use `make scanner-dependencies` for the first scanner setup, `make test` for core checks, and `make app` for the signed development bundle. Signed-app and genuine-provider acceptance commands are documented with the relevant implementation reports and test runners. Use synthetic values, disposable sessions, and isolated configurations for these checks.

For changes to collection, extend the versioned adapter fixtures and verify genuine provider coverage before claiming a new interface or version. For scanner changes, verify exact extracted values and source ranges against the annotated corpus and the signed bundled executable. For vault changes, verify locked writes and authenticated revelation through production Keychain keys. Request a product decision if a change requires narrowing confirmed coverage or weakening authentication.

Consult `docs/SESSION_READER_REUSE.md` when changing transcript framing, bounded reads, checkpoints, or recovery. It records the required reader behavior and regression scenarios.

Record implementation deviations and acceptance results in `docs/implementation/`. Keep the runnable commands, supported matrix, and release status consistent with the measured scope. Preserve measured results and publish evidence using the [sanitization conventions](implementation/README.md).

An unavailable provider, signing identity, target OS, or authentication test remains an unverified check. Keep its gate open, state the concrete limitation and needed input, and continue independent work that can still be completed.

Release completion requires the open checks in `docs/implementation/release-checks.json` to pass, including notarized install/update, production-vault access across upgrades, actual login launch, macOS 14 runtime, and hardware without Touch ID. The deferrals authorize local development; the release baseline and authentication requirements remain in force.
