# T3 Claude ordinary-hook acceptance

`run-app-claude-t3-hooks.py` coordinates one genuine T3-owned Claude task and an
immutable signed Spillcheck candidate. It does not launch a provider or create a
thread. These instructions describe a test to run; the offline boundary tests
do not establish that T3 loads project hooks.

T3 delegates inherit their parent workspace. Prepare the current original
workspace, then delegate from that same workspace without a worktree. Changing
the shell's directory does not change the provider's settings root.

## Workflow

1. Choose a fresh, short directory outside `/tmp`, with an existing canonical
   parent. The complete `<directory>/store/capture.sock` path must be shorter
   than 104 UTF-8 bytes. No other Spillcheck process may be running during
   observation.

   ```sh
   python3 Tests/AppAcceptance/run-app-claude-t3-hooks.py prepare \
     --directory .build/cth-r1 \
     --workspace "$PWD" \
     --app /absolute/path/to/Spillcheck.app \
     --configuration-executable .build/out/Products/Debug/spillcheck-storage-acceptance \
     --producer-version OBSERVED_CLAUDE_CODE_VERSION \
     --host-version OBSERVED_T3_VERSION \
     --candidate-manifest /absolute/path/to/candidate-build.json \
     --expected-bundle-sha256 FROZEN_BUNDLE_SHA256
   ```

   Preparation uses the production configuration editor to add one owned
   nine-event registration to the bound workspace's `.claude/settings.local.json`.
   Existing unowned JSON and file permissions are preserved. It installs no MCP
   server and changes no user settings. Diagnostic files retain only hashes,
   modes and comparison results from these settings, never copies of unowned
   JSON or environment values. Preparation failure attempts removal of
   its registration and any newly created empty settings directory whose
   creation identity is known.

2. Use the actual T3 `delegate_task` tool with the **full text** from
   `<directory>/TASK_PROMPT.txt` as its message and a Claude provider. Keep the
   task in this existing bound workspace. The fake task records only its own
   `CLAUDE_CODE_SESSION_ID`, then waits up to six minutes for the collector.
   Stop on missing runtime identity, unavailable native Agent/MCP tools, or a
   hook-loading error. Do not work around these failures with a source injection
   or another provider process.

   Save the tool's task identity to a private JSON file, using the actual values
   returned by T3: `taskId`, `childThreadId`, `childRunId`, `providerInstanceId`,
   and `model`. Do not print the native Claude UUID. This receipt is external
   operator evidence of T3 origin; the runner cannot independently verify its
   origin from native transcript or transport metadata.

3. Once `<directory>/runtime-identity-private.json` exists, start observation in
   a background terminal task. The output path must also be fresh.

   ```sh
   python3 Tests/AppAcceptance/run-app-claude-t3-hooks.py observe \
     --directory .build/cth-r1 \
     --task-record /absolute/private/path/task-start.json \
     --output .build/acceptance/claude-t3-hooks-r1.json \
     --duration 600
   ```

   The observer derives one source path from the bound runtime UUID and
   workspace, then verifies its native workspace, version and incomplete fake
   prompt. This mapping constrains the hook gate and native evidence inspector;
   it is never supplied as an active source or session to the collector.

   The signed collector starts with zero values, occurrences, alerts, synthetic
   sessions, queued work, gaps and rejections. Profile catch-up is disabled.
   Only after this baseline does the gate accept the exact fake session's
   original ordinary hooks. The gate forwards the original JSON bytes through
   the candidate's bundled production helper without constructing captures.
   All other sessions are discarded without retention. The callback journal
   contains only event names and helper exit codes.

   The task uses fake shell success/error results, the actual T3 preview MCP
   tools on one newly created blank tab, and the native Claude Agent tool. It
   closes only its own tab and waits thirty seconds before its final marker.
   Original parent subagent hooks and production polling discover its native
   child; the gate never assigns the parent identity to a child callback.

4. Use `task_status` for the same delegated task. When it is terminal with no
   pending child runs, save its actual identity fields plus `status`,
   `workState`, and `hasPendingChildRuns` to a second private JSON file. Success
   requires `status: "completed"`, `workState: "result_available"` and
   `hasPendingChildRuns: false`.

   ```sh
   python3 Tests/AppAcceptance/run-app-claude-t3-hooks.py finish \
     --directory .build/cth-r1 \
     --task-result /absolute/private/path/task-finish.json
   ```

   A terminal failed/cancelled/interrupted receipt can end the observation, but
   cannot pass. The producer must not write this receipt or completion signal.
   A late operator signal cannot substitute for live collection: a new native
   marker must have been committed while the native final marker was absent.

5. Wait for `observe` to exit and inspect its report. Before freezing proof, it
   acquires an exclusive callback lock while the collector remains alive,
   drains admitted hooks and closes admission. Each callback and its helper
   hold a shared lock through delivery and the controlled journal append; the
   helper inherits the lock descriptor if its Python parent is cancelled.
   Failure to drain prevents a pass.

   Passing requires twelve native typed markers, all five content types in
   each of the exact parent and child, live commits, zero gaps/rejections/queue,
   unchanged candidate/source/gate/task receipts, normal shutdown, encrypted
   storage and creator-confirmed new-vault cleanup. The final app report must
   independently preserve this coverage and the frozen value, occurrence,
   alert and synthetic-session counts. No history request or replay can rescue
   a failed ordinary-hook run.

## Cleanup and claim boundaries

Observation removes only its owned hook registration and preserves current
unowned settings and permissions. A settings file that becomes empty is retained
so a concurrent later user write cannot be deleted from a stale snapshot.
Private diagnostic artifacts remain. If
preparation or observation preflight fails, explicit configuration cleanup is:

```sh
python3 Tests/AppAcceptance/run-app-claude-t3-hooks.py cleanup \
  --directory .build/cth-r1
```

This closes admission and removes the owned local hooks. It does **not** stop
an already-running signed observer, delete a vault, or reconstruct authority to
delete Keychain keys. Preserve an unfinished observer's lifecycle evidence and
let that observer perform its own controlled shutdown. After a crash or reboot,
configuration cleanup alone does not establish successful vault cleanup.

The externally attested source host is **T3**. The production-generated hook
transport is **standalone-cli**, shared with other Claude hosts; that metadata
is not host attribution. This run does not measure the Settings UI, remembered
connection verification, Desktop side questions, broad history discovery,
upgrade/restart recovery, or source opening. If the installed T3 SDK does not
load the local hooks, record that unmet boundary without broadening collection.

Run the fake-only boundary tests without an app, provider or Keychain access:

```sh
python3 -m unittest discover -s Tests/AppAcceptance \
  -p test_claude_t3_hooks_boundary.py
```
