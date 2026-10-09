# Owned Claude GUI Mod probe

This is a passive dispatch experiment. It does not implement a collector or establish canonical side-chat identity. `prepare.py` only copies and statically validates files, with an isolated disposable `CLAUDE_CONFIG_DIR`; it starts no provider session. `install.py collect` performs the separately authorized owned local installation, keeps initial settings snapshots only in memory during its bounded wait, and automatically removes only its exact plugin and marketplace. It writes controlled evidence rather than raw settings.

The unprepared template observes nothing. A prepared copy contains a private exact native session ID and comparison key. Every event checks `$.session.id()` before accessing prompt text, command arguments, response text, render props, or native event fields. A missing, mismatched, or failed session lookup skips observation and passes through. The module records at most 256 summaries in a one MiB private journal. The writer accepts only controlled labels, counts, marker names, and HMAC comparisons. It rejects raw text, paths, IDs, unknown fields, symlinks, and non-private files. Provider text exists only transiently in memory.

The module observes `prompt.submit`, `/btw` command dispatch, main/agent turn start, step completion, turn completion, and the three documented message render sites. `next(e)` receives the original object; `yield* next(e)` forwards original chunks and returns the original result. It does not call the model, rewrite a prompt, override permissions, alter render results, append a message, read session history, or export source text. Diagnostic subprocess calls use an argument vector, controlled stdin, and a 750 ms timeout. Helper failure is contained. The provider's own failures propagate normally.

The pinned public declaration file was written by 2.1.277, so these fields are candidate observations. Static validation under the actual 2.1.293 binary confirms registration and API-call recognition, not their side-chat dispatch or exact semantics. Generated 2.1.293 declarations must be inspected if the subsequent authorized load creates them. A turn ID, agent ID, render request ID, text match, or timestamp does not by itself authorize merging a side conversation into a transcript source.

Prepare a new private copy using the actual GUI-bundled executable and the selected native session ID. Pass private paths directly; do not include them in a public report:

```sh
python3 Tests/ClaudeGUIModProbe/prepare.py \
  --session SELECTED_NATIVE_UUID \
  --directory /private/tmp/OWNED_PROBE_DIRECTORY \
  --claude-executable EXACT_EMBEDDED_EXECUTABLE \
  --expected-version 2.1.293 \
  --output .build/harness-compatibility/claude-gui-mod-static-validation.json
node --experimental-vm-modules Tests/ClaudeGUIModProbe/test-pass-through.mjs
python3 -m unittest discover -s Tests/ClaudeGUIModProbe -p 'test_*.py'
```

The prepared directory includes a uniquely named local marketplace. A local-path marketplace reads its plugin in place. Registering the marketplace creates an owned entry in user settings even when plugin enablement is local. Before any authorized installation, preserve settings in memory and verify this marketplace and plugin identity are absent. Do not restore an entire old settings file over concurrent provider or user changes. [Official local marketplace creation and removal](https://code.claude.com/docs/en/plugins/create-marketplace#remove-the-marketplace-to-start-over), [Installation scopes](https://code.claude.com/docs/en/plugins/install#choose-an-install-scope)

For the later authorized manual step, use the selected disposable project and actual embedded executable. The commands below are instructions, not actions taken by this harness:

1. Register only the prepared marketplace with `claude plugin marketplace add OWNED_PROBE_DIRECTORY`, then install only `spillcheck-side-probe@OWNED_MARKETPLACE_NAME --scope local` from the disposable GUI project directory.
2. In that same selected GUI conversation, open `+ > Plugins > Manage plugins`. Confirm the owned mod and local-only scope; run `/reload-plugins` if required. If the app refuses it, stop and report that gate. A successful reload does not send a provider turn. A `session.start` entry can provide a dispatch observation, but the main control marker below is required to measure content dispatch after load.
3. Send the main control prompt `LEAKRET_PHASE0_MODMAIN_PROMPT. Respond exactly LEAKRET_PHASE0_MODMAIN_FINAL. Do not use tools.` Verify the controlled journal observes the selected session, then open the side composer with Cmd+; and submit `LEAKRET_PHASE0_MODSIDE_PROMPT. Respond exactly LEAKRET_PHASE0_MODSIDE_FINAL. Do not use tools.` Wait no more than 90 seconds for the visible final response.
4. Remove only `spillcheck-side-probe@OWNED_MARKETPLACE_NAME --scope local`, then remove that exact owned marketplace with `claude plugin marketplace remove OWNED_MARKETPLACE_NAME`. Reload the selected GUI plugins. Verify owned entries are absent and current unowned settings remain semantically preserved before removing the private probe directory.

The main marker is a positive control for actual module dispatch, not a required-content fixture. The side prompt intentionally contains no credential. Public evidence should report marker/event counts, native field presence, keyed identity equality, render/turn relationships, truncation or journal limits, and scoped removal. Preserve missing affiliation or absent side dispatch as an unmet gate. Do not forward any Mod text to the analysis queue until exact authority, prompt/final identity, and stable duplicate handling have been established. [Official Desktop plugin controls](https://code.claude.com/docs/en/plugins/install#install-a-plugin), [Mods static validation and per-version types](https://code.claude.com/docs/en/plugins/mods/create#check-what-claude-code-reads-from-your-mod)

The automated local installer takes `--directory`, `--project`, `--claude-executable`, `--expected-version`, `--output`, and `--duration` between 30 and 900 seconds. It refuses pre-existing owned names and requires every unowned field in five bounded known settings/registry files to survive installation. It verifies a local enablement and exact local project record with no user or shared-project enablement. `install.py finish --directory OWNED_PROBE_DIRECTORY` ends the wait. Removal compares the current pre-removal configuration, so concurrent user/provider changes are preserved without restoring an old file. The private probe directory remains until the controlled journal is summarized and GUI unloading is confirmed.

Use `summarize.py --journal OWNED_PROBE_DIRECTORY/mod-summary.jsonl --output REDACTED_REPORT` to export only counts and keyed-equality results. Its shared prompt/final turn-ID count is an observation, not a canonical side identity or parent affiliation claim.
