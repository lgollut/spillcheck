# Build-tool checks

Run from the repository root:

```sh
python3 Tests/Tooling/check-scanner-bundling.py
python3 Tests/Tooling/check-release-policy.py
npm ci
npm run test:release
npm run release:check
```

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
