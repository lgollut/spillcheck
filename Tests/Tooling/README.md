# Build-tool checks

Run from the repository root:

```sh
python3 Tests/Tooling/check-scanner-bundling.py
python3 Tests/Tooling/check-release-policy.py
```

These tests use disposable fixtures and fake signing tools to check incremental
scanner bundling and release rejection/staging behavior. They do not launch the
app or contact providers, and they do not establish genuine Developer ID signing,
notarization, or installation. Production build and packaging tools remain in
`scripts/`.
