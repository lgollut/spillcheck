# Concurrent Claude hosts

`run-app-claude-concurrent-hooks.py` prepares one fake CLI session, one official
Desktop Local Code conversation and one genuine T3 delegate. All three send
their original hooks to one fresh signed collector and shared profile. This
guide describes a test to run. Offline tests do not establish host dispatch.

The collector authorizes the shared `~/.claude/projects` root because the frozen
candidate's role evidence accepts one root. Profile catch-up is disabled and no
active source, session, history request or replay is supplied. Each workspace's
gate admits only its own runtime-bound session, exact original cwd and derived
parent path. An explicit child selector must remain beneath that parent's own
`subagents` directory. The native inspector reads only those three parents and
their own bounded child directories. The common root grants this test no
permission to enumerate or inspect other projects or sibling parents.

## Prepare and start the producers

Choose a fresh, short path with an existing private parent. The complete socket
path must fit in 103 UTF-8 bytes. Use the actual inherited T3 workspace.

```sh
python3 Tests/AppAcceptance/run-app-claude-concurrent-hooks.py prepare \
  --directory .build/cch-r1 \
  --workspace "$PWD" \
  --app /absolute/frozen/Spillcheck.app \
  --configuration-executable .build/out/Products/Debug/spillcheck-storage-acceptance \
  --candidate-manifest /absolute/candidate-build.json \
  --expected-bundle-sha256 FROZEN_BUNDLE_SHA256 \
  --cli-executable /absolute/claude/version/binary \
  --cli-version OBSERVED_CLI_VERSION \
  --desktop-version OBSERVED_EMBEDDED_VERSION \
  --desktop-host-version OBSERVED_DESKTOP_VERSION \
  --t3-host-version OBSERVED_T3_VERSION
```

Preparation creates original Git projects under `cli/work` and `desktop/work`,
with a fake MCP server. It adds one owned nine-event local hook registration to
each project, including the inherited T3 workspace. It preserves other local
settings and permissions. It changes no user configuration and copies no
authentication. It starts no provider or signed app.

1. In the official Claude Desktop app, start a fresh **Local Code** conversation
   in `<directory>/desktop/work`, using that original folder. Complete normal
   workspace, hook and fake MCP review. Paste `desktop/PROMPT.txt` as text in one
   message. Stop on unavailable runtime identity, hook loading, Agent or MCP
   tools. Do not substitute a CLI session or promote a side question.
2. Use T3's actual `delegate_task` with a Claude provider, the full
   `t3/PROMPT.txt`, and the inherited workspace. Save its real identity fields
   `taskId`, `childThreadId`, `childRunId`, `providerInstanceId`, and `model` to
   a private task-start JSON file. This receipt is external host evidence.
3. Start the CLI producer in a separate terminal job:

   ```sh
   python3 Tests/AppAcceptance/run-app-claude-concurrent-hooks.py produce-cli \
     --directory .build/cch-r1 --duration 1200
   ```

   This explicit command launches the hash-bound CLI executable once, with an
   owned UUID and isolated fake cwd. It uses the provider's normal shared-home
   authentication. The harness reads no credentials. Project/local settings
   load the prepared hooks, and strict MCP configuration selects only the fake
   server. Raw provider output stays private. CLI completion comes from its
   owned subprocess, never an operator-authored success receipt.

Each producer records only its own `CLAUDE_CODE_SESSION_ID` and waits for the
collector. Each helper call lasts at most 40 seconds; the total wait budget is
800 seconds. Do not manually create readiness, admission or final-release files.
Persisted wait budgets and heartbeats use `clock_gettime(CLOCK_MONOTONIC)` so
independent Python processes share the same clock origin. Preparation fails if
that clock is unavailable; old budget files without its convention label are
rejected. Local command deadlines still use the process's monotonic timer.

## Observe and finish

Once all three `runtime-identity-private.json` files exist, start observation:

```sh
python3 Tests/AppAcceptance/run-app-claude-concurrent-hooks.py observe \
  --directory .build/cch-r1 \
  --task-record /absolute/private/task-start.json \
  --output .build/acceptance/claude-concurrent-r1.json --duration 1200
```

Observation requires no other Spillcheck process. It verifies the immutable
candidate and exact native source prefixes, starts one disposable vault, and
requires a zero-value, zero-occurrence, zero-alert, zero-session, zero-queue
baseline without gaps or transport rejections. Only then does it open all three
hook gates. The production helper receives each admitted packet unchanged.

Each producer emits fake shell/MCP success and error content plus one native
child. All three then wait at a final barrier. Runtime-bound helper heartbeats,
append-only native growth and absent final markers prove that all three remain
active. The collector must show new commitments during this common live period.
This does not assert independent receipt-backed pre-final timing for each host.

The observer releases final replies in the order Desktop, CLI, T3. It requires
the native completed-host set and receipt-backed complete-pair count to advance
by exactly that host's producer version at each stage. Final native inspection
permits exactly one child per parent. This prevents extra CLI children from
standing in for missing T3 coverage when their versions match.
An abort signal, failed producer, or producer completion before its final release
stops observation immediately and records a fixed failure code and host.

After observing Desktop's final response, write a private JSON receipt with
exactly these fields, using the observed versions supplied during preparation:

```json
{
  "sourceHost": "official-claude-desktop",
  "originalLocalWorkspace": true,
  "normalHookReviewCompleted": true,
  "finalResponseObserved": true,
  "producerVersion": "OBSERVED_EMBEDDED_VERSION",
  "hostVersion": "OBSERVED_DESKTOP_VERSION"
}
```

```sh
python3 Tests/AppAcceptance/run-app-claude-concurrent-hooks.py finish \
  --directory .build/cch-r1 --host desktop --receipt /absolute/private/desktop-finish.json
```

For T3, call `task_status` on the same real delegate. Save the original identity
fields plus `status: "completed"`, `workState: "result_available"`, and
`hasPendingChildRuns: false`. Then:

```sh
python3 Tests/AppAcceptance/run-app-claude-concurrent-hooks.py finish \
  --directory .build/cch-r1 --host t3 --receipt /absolute/private/task-finish.json
```

The observer drains all three callback locks while the app is still alive,
settles the queue, and freezes proof before requesting normal app shutdown.
The final report must preserve the exact pair counts and inventory, with zero
gaps/rejections/queue, unchanged original source bytes and candidate, encrypted
storage, and creator-confirmed vault cleanup. A final shutdown warning fails
the run even if the frozen proof had passed.

## Failure cleanup and limits

Preparation and observation attempt independent owned configuration cleanup.
After a preflight, registration, or interrupted command failure, run:

```sh
python3 Tests/AppAcceptance/run-app-claude-concurrent-hooks.py cleanup \
  --directory .build/cch-r1
```

Cleanup closes admission and removes only the three owned registrations and
unchanged fake MCP configurations. Changed/unowned content stays intact.
Cleanup does not grant authority to stop an independently running Desktop or
T3 task, remove a loaded vault's keys, or declare a failed run complete. The
explicit CLI producer owns its process cleanup. Observe records an abort signal
on failure so that the CLI producer can stop its own process group. Preserve
private failure artifacts and let the signed observer finish its own lifecycle.

The shared hook transport is `standalone-cli`; it does not identify the host.
Host proof comes from the owned CLI invocation and external Desktop/T3 receipts.
This test does not cover Desktop side questions, broad history, Settings UI
installation, saved-profile verification, upgrades or restart recovery.

Run the offline boundaries without an app, provider or Keychain access:

```sh
python3 -m unittest discover -s Tests/AppAcceptance -p test_claude_concurrent_hooks_boundary.py
python3 -m unittest discover -s Tests/Support -p test_claude_concurrent_evidence.py
```
