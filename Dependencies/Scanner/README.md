# Application scanner dependency

`dependencies.json` pins the Betterleaks executable, rules, and MIT license used
by the application. Each downloaded artifact is verified against its SHA256.
Only the selected application scanner is included. Downloaded binaries are kept
under `.build/` and are not committed.

From the repository root, install and prepare the scanner before the first build
or test run:

```sh
make scanner-dependencies
make test
make app
```

`scripts/install-scanner.py` downloads the pinned release into
`.build/dependencies/scanner/betterleaks/`. Use `--offline` to verify and unpack
an already cached archive without downloading anything.
`scripts/prepare-scanner.py` verifies the binary, rules, and license, then copies
them into `.build/scanner/` for core tests and app bundling. Preparation and app
builds use no network access.

The Xcode build signs the bundled scanner and records its final hash in the app's
scanner manifest. The installed app reads only its bundled files.

Scanner updates require updating the lock and validating the production detector
against `Tests/Fixtures/Scanner/corpus.json`, the core tests, and app bundling.
