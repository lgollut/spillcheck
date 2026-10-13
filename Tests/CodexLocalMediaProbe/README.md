# Native local-image input check

This opt-in probe sends one ordinary fake-only local-image turn through standalone
Codex 0.162.1, then reads that exact original user item twice through Spillcheck's
production history client and parser. The test owns its home, workspace and image.
It does not change personal settings, trust records or history.

The producer must finish normally with the exact final reply and no tools. The
runner removes its authorized authentication copy and verifies and removes the
fake image before starting the passive reader. Both reads must retain the original
text, identity, pointer, timestamp and revision, with only the expected binary
exclusion and constrained local-media proof. This proves collection does not
require the original image file to remain available. A live notification ID is
compared separately with the persistent native ID, without inventing a mapping.

Build first, with fresh output paths:

```sh
python3 Tests/CodexLocalMediaProbe/run.py build --scratch-path .build --build-binding /absolute/owned/build.json
python3 Tests/CodexLocalMediaProbe/run.py run --scratch-path .build --build-binding /absolute/owned/build.json --report /absolute/owned/result.json --private-control /absolute/owned/control
```

Running requires existing authorization to copy only `~/.codex/auth.json`
into the disposable home. Import, build and boundary tests do not read that file
or launch a provider. Provider and reader process groups must stop before cleanup;
uncertainty preserves a private handoff. Public reports contain fixed checks,
counts and hashes, never raw content, source identities or authentication.

This is original-source acceptance for local images. It does not measure image
content scanning, local audio, detector receipts, historical warning recovery,
signed Keychain access, desktop/T3 behavior or full Codex support.
