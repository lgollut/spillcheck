# Codex hook delivery reliability

Run from the repository root:

```sh
python3 Tests/CodexHookDeliveryProbe/run.py
```

This unattended probe builds the real `spillcheck-hook` and a test-only receiver.
It requires the existing pinned artifacts in `.build/scanner`; it does not download
or replace them. The production Betterleaks wrapper verifies their pinned hashes
and runs the scanner with its normal network denial and in-memory input/output.
`--skip-build` reuses products already built from the current source.
`--products-path .build/out/Products/Debug` additionally avoids invoking SwiftPM
while another task is using its build lock.

The receiver uses `LocalCaptureServer`, `ProtectedStore`,
`CodexEnrolledSessionRouter`, `CodexHookContentAdapter`, `DetectionPipeline`, and
`BetterleaksSecretDetector`. The native route is a rejecting guard: any accidental
native routing fails the check. Each fixture explicitly enrolls exactly one fake
session before capture. This tests enrolled routing, not automatic side-chat
enrollment or genuine provider hook dispatch.

The Python parent feeds generated fake hook packets to the real helper's stdin.
The helper connects directly to the real server's Unix socket. The receiver has a
separate stdin/stdout control pipe that reports only counts, closed labels, and an
opaque inventory digest used to compare replay outcomes. No payload is echoed.

Checks cover:

- Prompt, final reply, successful tool output, failed tool output, distinct call
  identities, out-of-order delivery, duplicate delivery, and restart replay.
- Paused admission, paused processing of already encrypted work, and resume.
- SIGKILL after encrypted admission commits but before the server can ACK, followed
  by receiver restart and a new helper delivery of the same event.
- SIGKILL after immutable hook identity binding but before scanning; restart reclaims
  the encrypted capture after a test-only three-second claim lease.
- Oversized hook content producing an explicit gap while later valid tools proceed.
- A changed tool slot retaining its original occurrence and required conflict gap.
- An absent receiver returning the helper's empty success reply without a local
  spool; restarting the receiver does not invent recovery for that missed event.
- No fake value, profile/session identity, content marker, or test key seed in plain
  bytes or base64 in any generated file, including final close/checkpoint output;
  generated files have private permissions.

The parent holds a fresh random testing seed in memory and sends it with a fresh
manifest over the control pipe so killed receivers can reopen the same disposable
encrypted fixture. It is never written to disk, argv, environment, or a report.
The receiver uses only the existing `deterministicForTesting` factory. No Keychain,
GUI, installed app, personal history/settings, or provider process is used.

Fixtures live in private `/tmp/spillcheck-hook-e2e-*` directories and are removed
even on test failure. Receiver and helper processes are tracked immediately after
launch, including failed startup, and their pipes are closed during cleanup.
The content-free report and build logs go to
`.build/implementation/codex-hook-delivery/`. The report records executable/rule
hashes and explicitly leaves signed acceptance, genuine hook dispatch and
automatic enrollment false. Passing is evidence for the compiled local delivery
path with synthetic provider inputs, not a full desktop beta acceptance result.
