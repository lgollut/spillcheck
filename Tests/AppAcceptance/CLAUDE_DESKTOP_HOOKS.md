# Claude Desktop ordinary-hook acceptance

`run-app-claude-desktop-hooks.py` coordinates a fresh fake-only **Desktop Local
Code** conversation with an immutable signed Spillcheck candidate. The runner
never launches Claude or drives its UI. Preparation and observation are separate,
so the operator can complete the normal workspace, hook, and MCP reviews first.
The commands below describe the workflow; they do not record a completed test.

## Lifecycle

1. Prepare a new, short directory outside `/tmp`. The entire socket path
   `<directory>/store/capture.sock` must be shorter than 104 UTF-8 bytes.

   ```sh
   python3 Tests/AppAcceptance/run-app-claude-desktop-hooks.py prepare \
     --directory .build/cdh-r1 \
     --app /absolute/path/to/Spillcheck.app \
     --configuration-executable .build/out/Products/Debug/spillcheck-storage-acceptance \
     --producer-version EMBEDDED_CLAUDE_CODE_VERSION \
     --candidate-manifest /absolute/path/to/candidate-build.json \
     --expected-bundle-sha256 FROZEN_BUNDLE_SHA256
   ```

   This creates an independent Git project at `<directory>/work`, an identity-only
   bootstrap, fake MCP configuration, and one owned nine-event registration in
   `.claude/settings.local.json`. It uses the production configuration editor and
   the selected app's bundled helper. It does not start Spillcheck or copy
   authentication. Existing directories and excessive socket paths are rejected.

2. In the official Claude app, create a fresh **Local Code** conversation using
   that original `work` folder, without a worktree. Paste `REGISTER_MAIN.txt` and
   run `/status`. The bootstrap must report `recorded: true`, and the embedded
   version must match `--producer-version`. Stop on a workspace, hook, MCP, or
   identity error. Record the observed Desktop host version:

   ```sh
   python3 Tests/AppAcceptance/run-app-claude-desktop-hooks.py register \
     --directory .build/cdh-r1 --host-version OBSERVED_DESKTOP_VERSION
   ```

   Registration derives one native transcript from the bootstrap's own runtime
   identity and verifies its workspace/version/prefix. It does not search other
   conversations. Only the bootstrap marker may have been completed at this point.

3. Start observation in a background terminal task:

   ```sh
   python3 Tests/AppAcceptance/run-app-claude-desktop-hooks.py observe \
     --directory .build/cdh-r1 \
     --output .build/acceptance/claude-desktop-hooks-r1.json \
     --duration 600
   ```

   Wait for `<directory>/ready.json` before submitting `MAIN.txt` in the same
   conversation. Readiness requires zero queued captures, values, occurrences,
   alerts, synthetic sessions, and gaps, with no coverage truncation. The collector has no preselected session or
   active source, profile catch-up is disabled, and the runner injects no poll or
   historical request. The first ordinary hook must discover the session.

4. Complete the fake main/native-child fixture once. Keep intentional command
   and MCP failures as errors. After its final reply, signal completion:

   ```sh
   python3 Tests/AppAcceptance/run-app-claude-desktop-hooks.py finish \
     --directory .build/cdh-r1 --outcome complete
   ```

   Use `--outcome limit` for a provider quota error or `--outcome error` for another
   failure. Neither can pass acceptance. `--duration` is bounded to 30–1800
   seconds; expiry also fails the run. A delayed operator signal cannot establish
   live collection: a new native marker must have been committed while the
   fixture's native final marker was still absent.

5. Wait for `observe` to exit and inspect its report. The runner freezes
   `ordinary-hook-proof.json` before normal signed-app shutdown, then requires
   creator-confirmed new-vault cleanup, removal of its exact hook registration,
   and removal of the unchanged owned MCP configuration. It preserves unrelated
   settings and later permission additions. If MCP configuration changed, it is
   preserved and cleanup fails. Private artifacts remain in the owned directory
   for review; no cleanup authority is reconstructed after a crash or reboot.
   The final app report must independently retain complete role evidence, no
   gaps/rejections/queued work, and the same value, occurrence, alert, and
   synthetic-session counts as the frozen proof. A late shutdown warning fails
   the run even if the earlier proof passed.

Preparation failure automatically attempts both owned configuration removals.
If registration or observation preflight fails before the collector starts, or
if preparation was interrupted, run explicit cleanup without launching an app
or provider:

```sh
python3 Tests/AppAcceptance/run-app-claude-desktop-hooks.py cleanup \
  --directory .build/cdh-r1
```

This removes the exact owned hook registration and the unchanged owned MCP
configuration. It preserves changed/unowned data and reports incomplete cleanup.
`remove-hooks` remains available for hook removal alone. Neither command removes
vault keys or claims a completed run. Each new attempt needs a fresh directory
and output path.

## What passes and what remains separate

Passing requires twelve typed markers and all five content types in one exact
native parent and its own child, collection before native completion, zero
remaining gaps/rejections/queue, unchanged candidate and source registration,
encrypted storage, normal exit, and confirmed owned cleanup. No manual replay is
performed; later replay cannot rescue failed ordinary-hook evidence.

The source host is attended **Desktop Code**. The production-generated hook
transport is **standalone-cli**, shared by Claude hosts. These fields remain
separate; hook metadata does not independently identify the originating app.
Active polling can collect later rows after a real hook discovers the session.

This does not measure Settings UI installation, remembered connection
verification, side questions, broad history discovery, upgrade/restart recovery,
or source opening. It does not resolve an earlier warning whose source was lost.

Run the coordinator's synthetic boundary checks without an app, provider, or
Keychain access:

```sh
python3 -m unittest discover -s Tests/AppAcceptance \
  -p test_claude_desktop_hooks_boundary.py
```
