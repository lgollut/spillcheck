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

The scanner-bundling and release-policy checks are in `Tests/Tooling/`.
