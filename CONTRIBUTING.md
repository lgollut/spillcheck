# Contributing

Create a branch from current `main` for each change. Install the release tooling
with Node 24 and `npm ci`; Node is used for repository automation, not by the app.

Every PR targeting `main` must add its own changeset:

```sh
npm run changeset
```

Select `spillcheck`, choose a semver bump, and explain the change in terms a user
can understand. Use `patch` for fixes and `minor` for new functionality. Before
1.0, use `minor` for incompatible changes; reserve `major` for an intentional 1.0
release. Reviewers should check that the selected bump matches the change.

For a PR containing only documentation, tests, CI, or the named release-tooling
files, add an empty changeset and edit its body to explain why no app version bump
is needed:

```sh
npm run changeset -- --empty
```

An empty explanation does not pass validation. A changeset already on `main`
does not count for a new PR. Changes to app code, production dependencies, or
paths outside the allowed tooling and documentation paths require a bump. A
mixed PR needs a bump too. Ordinary PRs may add changesets but must not edit or
remove pending notes, edit `CHANGELOG.md`, or change version/build fields.

Run the relevant checks locally before opening a PR:

```sh
make scanner-dependencies
SPILLCHECK_TEST_PYTHON="$(python3 -c 'import sys; print(sys.executable)')" make test
npm run release:check
npm run test:release
```

The Swift tests and scanner installer require macOS on Apple Silicon. The
[tooling checks](Tests/Tooling/README.md) cover release policy and helper behavior.
CI also compiles the Debug app with signing disabled. Its `Required checks` job
combines changeset validation, core tests, tooling tests, and app compilation.
It runs for PRs targeting `main` and for every push to `main`.

CI does not exercise real provider sessions, production Keychain authentication,
the GUI, notarization, or installed-app acceptance. Follow the recorded
[release requirements](docs/implementation/release-checks.json) for that work.

Merge the feature PR after review and successful checks. Automation accumulates
pending bumps and notes in one release PR. The
[release guide](docs/RELEASING.md) describes that PR and the repository settings.
