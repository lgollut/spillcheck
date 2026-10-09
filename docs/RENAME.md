# Spillcheck rename

The product is Spillcheck. The repository directory is `spillcheck`, the macOS
application and Xcode scheme are `Spillcheck`, and the Swift package exposes
`SpillcheckCore`. The bundled delivery helper is `spillcheck-hook`; the disposable
acceptance executables use the same prefix. Development environment variables
use `SPILLCHECK_`.

## Existing installations

Spillcheck keeps `com.leakret.app` as its provisioned bundle identifier, Keychain
access group, and production key-service prefix. These identify the existing
application and its keys. Changing them during a branding rename would separate
the app from its encrypted vault and macOS registrations.

The app moves the user's `Application Support/Leakret` directory to
`Application Support/Spillcheck` before opening the vault. It moves the whole
directory, including SQLite sidecars. It refuses symbolic links, unowned
directories, and two simultaneous store directories. An explicit development
`--store-directory` skips this migration.

The `leakret.sqlite` database filename, version-1 ciphertext authentication and
HMAC domains, persisted native rule IDs, historical queue discriminators, and
notification IDs remain stable. These strings are storage contracts, not product
labels.

Hook installation and removal recognize both names only when the registration
UUID matches the protected settings. Repair replaces the owned legacy handler
with a Spillcheck handler and its current helper/socket paths. Other registrations
remain untouched. The agent's verification and trust flow still applies.

## Recorded evidence

Published acceptance reports preserve historical product names and measured
results. Personal metadata has been sanitized according to the
[evidence notes](implementation/README.md). `LEAKRET_M3_`, `LEAKRET_M4_`,
`LEAKRET_SYNTHETIC_`, and `LEAKRET_T3_` synthetic markers remain compatible with
these fixtures. Current prose and runnable build commands use Spillcheck. The
separate exploratory projects and their reports have been removed; historical
references within retained reports do not identify current build inputs.
