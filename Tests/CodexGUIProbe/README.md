# Manual official Codex GUI phase 0 probe

This is a disposable source-contract investigation. It creates no provider session,
does not control the GUI, and never enables production Desktop collection. Computer
Use explicitly denied control of the installed official Codex GUI; this probe keeps
that boundary and leaves session creation to the user.

Prepare and compile against existing debug Core products:

```sh
python3 Tests/CodexGUIProbe/run.py prepare
python3 -m unittest discover -s Tests/CodexGUIProbe -p 'test_scope.py'
```

The prepared project and fake-only prompt are below
`.build/harness-compatibility/manual-codex-gui-2026-10-09/`. Preparation initializes
Git only inside the owned project, copies no provider credentials/configuration,
and does not invoke Codex. Use a fresh `--directory` for every subsequent run.

Before asking the user to start a chat, record the official GUI host version and
explicitly authorize the native provider store to investigate. Store authorization
is an input, not inferred from the selected CLI. Start the collector before the
user posts the fixture prompt:

```sh
python3 Tests/CodexGUIProbe/run.py observe --reuse-probe \
  --authorized-home /absolute/authorized/gui/provider/store \
  --host-version ACTUAL_OFFICIAL_GUI_VERSION
```

The host-version evidence defaults to `operatorAbout`. When the version was read
from the official installed app's bundle metadata, add
`--host-version-evidence officialBundleMetadata`; the report preserves that
distinction. Neither host evidence source supplies the native producer version.

Compilation takes a private snapshot of the Core Swift module and static library
and rejects artifacts that change while copying or linking. `--reuse-probe` checks
both those artifact hashes and the probe source hash before the manual handoff.
Wait for shared Core builds to finish; a probe compiled while those artifacts were
being replaced can have an incompatible Swift class layout despite linking.
Owned reader shutdown signals only its live `Process` once, polls its status for
at most 250 ms, and reports whether termination completed within that bound.
Foundation owns reaping; the collector does not compete through `waitpid`.
Apple documents that [`waitUntilExit`](https://developer.apple.com/documentation/foundation/process/waituntilexit())
polls a run loop until completion without a deadline, while
[`isRunning`](https://developer.apple.com/documentation/foundation/process/isrunning)
reports whether the process has terminated.

To prepare another lease without starting an observer, run `prepare --directory`
with a fresh directory. For example, the second prepared project is below
`.build/harness-compatibility/manual-codex-gui-r2-2026-10-09/`. Pass the same
directory to `observe` when the user is ready; preparation starts no lease.

After its `ready` line, the one manual action is: **create a new Local Codex chat in
the official GUI, select the prepared `work` folder as its local project, and paste
the entire `GUI_PROMPT.txt`.** Use a fresh GUI chat in the original Local checkout.
An imported CLI chat, managed worktree, remote task, or app delegated task does not
satisfy this fixture's host gate. Preserve ordinary approval/trust review for this
owned project.

The GUI parent and its one native child run the owned `fixture.py` helper. Each
helper reads only its own `CODEX_THREAD_ID`, `CODEX_HOME`, and `HOME` environment
entries and writes identity metadata in the project. A missing native ID produces
a controlled unmet gate; it never triggers a provider-history search. An unset
`CODEX_HOME` yields a candidate from the official native default contract, which
still must match explicit store authorization and the exact source path returned
by passive `thread/read`. It is not accepted as GUI store evidence on its own.

The revised content fixture uses two native inputs. `spawn_agent` creates only
the identity bootstrap; the parent waits for the registered child's READY reply.
It then uses native `send_input` on that same child ID with the literal prompt
marker and content instructions. This avoids mistaking spawn-only context or a
paraphrased instruction for a measured native child prompt. The collector still
requires the prompt marker on a native child `userPrompt` source; it never copies
the parent's tool arguments into child authority. The official
[subagent documentation](https://learn.chatgpt.com/docs/agent-configuration/subagents)
describes native agent threads and steering an existing subagent. Actual tool
availability and the submitted child-input fields must be measured in the GUI.

During a shared Core build, `prepare --prepare-only --directory NEW_DIRECTORY`
writes only the owned project and prompt. Run ordinary `prepare` in that same
unstarted directory after Core products stabilize to compile its collector before
the manual handoff.

The collector rejects a mismatched store, project, changed native ID, or shared
parent/child ID before releasing the fixture. A native collaboration item in the
exact selected parent must link the child's own native ID before that child is
read or released; a second task in the same project cannot substitute for it.
It requests only each supplied
native ID's `thread/read` and `thread/items/list`. It never calls `thread/list`,
resume, turn-start, fork, tools, or model requests, and never reads native rollout
files directly. The production passive reader is network/fork denied. Reads are
bounded to sixteen pages, 8 MiB, and fifteen seconds per selected-source pass.

Each admitted role produces a prompt, commentary, final answer, successful tool
output, and failed tool output carrying a fake marker. The probe checks the typed
marker once per native source, including the child's own prompt, using the existing
provider parser and detector with an ephemeral encrypted store. The parser is
invoked in its enabled CLI eligibility context solely to test whether the actual
GUI source format matches. Reports label this explicitly; they cannot establish
Desktop adapter behavior, app setup, owned hooks, source opening, signed app
acceptance, six-way concurrency, upgrade recovery, or degradation notifications.

Live commitments must have production `.live` provenance relative to the observer's
start, and all ten role/type markers must commit before observation ends. This
proves bounded ongoing exact-ID collection; it does not measure first publication
latency or hook delivery. After observation, the reader is stopped and restarted
for a seven-day audit restricted to the exact selected sources. Replay must add no
occurrences or alerts. No unrelated history is enumerated. In-progress tool gaps
are recorded separately; other gaps prevent the format-probe pass.

The report contains controlled versions/counts/gaps, never native IDs, source paths,
or provider content. Observer processes and the ephemeral encrypted store are
removed. The fake-only original GUI chats and owned project remain for review;
archive/delete only these sessions through ordinary native GUI controls after the
user confirms the displayed sessions. On a failed collector, the helper receives
`collector-failed`; otherwise its wait expires after ten minutes. A tool's expected
exit 7 must remain a native failed tool item; if the GUI wraps it as success, tool
error coverage stays unmet and no substitute is manufactured.

After a failed live run, `catchup` can inspect only that prepared project's existing
native identities. It uses historical provenance from the first pass, writes a
separate report, and never releases a fixture or establishes a live boundary:

```sh
python3 Tests/CodexGUIProbe/run.py catchup --reuse-probe \
  --directory .build/harness-compatibility/manual-codex-gui-r2-2026-10-09 \
  --authorized-home /absolute/authorized/gui/provider/store \
  --host-version ACTUAL_OFFICIAL_GUI_VERSION --duration 10
```

`diagnose-native-child.py` is a separate source-contract investigation. It first
revalidates the two exact public thread identities, owned project, authorized
store, and original parent collaboration item linking the child. It then reads
only the public-verified original parent and child JSONL paths, each bounded to
8 MiB, verifies their native session metadata, and checks the actual parent
spawn arguments and recognized child message roles for the requested marker.
It reports controlled record kinds and fake-marker presence. It publishes no IDs or source text and implements no
rollout collection fallback. For example:

```sh
python3 Tests/CodexGUIProbe/diagnose-native-child.py \
  --project .build/harness-compatibility/manual-codex-gui-r2-2026-10-09/work \
  --authorized-home /absolute/authorized/gui/provider/store
```

`passive-full-history-diagnostic.py` compares `thread/read` with full turns,
`thread/turns/list` with full items, and `thread/items/list` for the exact child
after revalidating its original parent link. It requires the same owned project
and explicit authorized store, uses a network/fork-denied reader and a bounded
read budget, and reports only item kinds, marker presence and native-ID equality.
It does not discover sessions, create a provider turn or implement a fallback.
The [R3 source investigation](../../docs/implementation/codex-gui-child-prompt-source-research-2026-10-09.md)
records both fixture compliance and the limits of these passive alternatives.

The official [Local environments](https://learn.chatgpt.com/docs/environments/local-environment)
and [Projects and chats](https://learn.chatgpt.com/docs/projects) documentation
describe original local project association. The official
[App Server contract](https://learn.chatgpt.com/docs/app-server) describes passive
reads and experimental item pagination. The native
[home-directory implementation](https://github.com/openai/codex/blob/main/codex-rs/utils/home-dir/src/lib.rs)
provides the default-home contract; it does not prove an individual GUI session's
store or its required content coverage.
