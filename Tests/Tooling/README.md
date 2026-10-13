# Build-tool checks

Run from the repository root:

```sh
python3 Tests/Tooling/run-python-tests.py
npm ci
npm run test:release
npm run release:check
```

The Python entrypoint includes the scanner-bundling and release-policy checks
along with the offline acceptance boundary suites. Use `--suite Tooling` to run
only this directory, or `--list` to see the scope and separate compiled checks.
The entrypoint runs Python only. See the [test guide](../README.md) for
prerequisites and the separate compiled checks.

These tests use disposable fixtures and fake signing tools to check incremental
scanner bundling and release rejection/staging behavior. They do not launch the
app or contact providers, and they do not establish genuine Developer ID signing,
notarization, or installation. Production build and packaging tools remain in
`scripts/`.

The Node tests use temporary Git repositories and mocked GitHub responses to
check changeset policy, version generation, release provenance, immutable tags,
and changelog publication. They require Node 26 and the locked npm dependencies;
they do not publish releases or use GitHub credentials. `release-fixtures.mjs`
holds their shared repository and `Info.plist` fixtures.
