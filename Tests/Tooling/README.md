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
and changelog publication. They require Node 24 and the locked npm dependencies;
they do not publish releases or use GitHub credentials.

CI also runs the provider-free vault-owner evidence tests and delivery-helper
tests. To repeat them locally after building the Swift package:

```sh
python3 Tests/ProtectionSignedProbe/test_vault_owner_evidence.py
SPILLCHECK_HOOK_TEST_EXECUTABLE="$(swift build --show-bin-path)/spillcheck-hook" \
  python3 Tests/HookHelper/test_delivery.py
```
