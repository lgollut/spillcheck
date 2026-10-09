# Build and packaging tools

This directory contains the tools needed to prepare dependencies, build the app,
and package a release. Acceptance runners and build-tool tests live under `Tests/`.

From the repository root:

```sh
make scanner-dependencies
make test
make app
```

- `install-scanner.py` installs checksum-verified pinned scanner artifacts.
- `prepare-scanner.py` copies verified cached artifacts for tests and app bundling.
- `build-app.sh` generates the Xcode project when needed and builds the app.
- `bundle-scanner.py` is called by Xcode to bundle and sign the scanner.
- `package-release.py` inspects and stages release bundles and supports explicit
  notarization. Use `--help` for commands and required signing options.
- `release_policy.py` contains the checks shared by the release packager and its tests.

The Node scripts version the app and automate GitHub releases. They need Node 26
and `npm ci`; the app does not use them. See the [release guide](../docs/RELEASING.md).

- `release-metadata.mjs` checks that `package.json`, the lockfile, and `Info.plist`
  agree on the version (`npm run release:check`).
- `check-changesets.mjs` enforces the PR changeset policy and validates the generated
  release PR (`npm run changeset:check`).
- `version-release.mjs` consumes pending changesets and synchronizes the app version
  and build number (`npm run version:release`).
- `github-release.mjs` describes the release PR, tags its tested merge, and publishes
  the GitHub Release. Only the release workflows run it.

The scanner-bundling, release-policy, and release-automation checks are in `Tests/Tooling/`.
