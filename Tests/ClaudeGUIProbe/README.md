# Manual Claude local Code GUI probe

This probe exercises an existing disposable session created directly in the official local Code GUI. It does not launch a provider, control the GUI, start the signed app, or enable the Desktop collector. The existing native transcript remains the canonical authority. Its selected source and own child files must already be authorized.

The probe starts the core acceptance receiver with a production owned registration in the disposable project's `.claude/settings.local.json`. A short wrapper records controlled hook metadata and forwards the original event to the production helper and encrypted queue. It never stores raw hook content or changes display text. Native IDs and display deltas become keyed private comparison values; the public report contains only counts and equality results.

Use current built acceptance, helper, and scanner products. Run from the checkout, replacing each placeholder with the independently observed value:

```sh
python3 Tests/ClaudeGUIProbe/run.py collect \
  --source /absolute/authorized/project/SELECTED_NATIVE_SESSION.jsonl \
  --source-root /absolute/authorized/project \
  --session SELECTED_NATIVE_SESSION \
  --settings /absolute/disposable/gui-project/.claude/settings.local.json \
  --producer-version OBSERVED_EMBEDDED_PRODUCER \
  --host-version OBSERVED_GUI_VERSION \
  --duration 900 \
  --private-control .build/harness-compatibility/claude-gui-control-private.json \
  --output .build/harness-compatibility/claude-gui-manual-probe.json
```

Wait for the JSON containing `ready=true`. It supplies three exact synthetic prompts and a finish command. The private control file contains temporary machine paths and must not be published. The wait has a maximum of 900 seconds; it can be ended earlier with the finish command.

1. Open the same existing disposable local Code GUI conversation. Confirm its `/status` producer and selected native mapping. Do not create a CLI session and open it in the GUI as a substitute.
2. Inspect `/hooks` if available and confirm that the owned local registration is loaded. Keep provider workspace trust and permissions intact. Hook edits are normally picked up automatically by the provider's file watcher.
3. Submit `verificationPrompt` alone in the main conversation. This tests the owned route's durable challenge receipt.
4. Submit `mainPrompt` in the main conversation. Approve the requested shell and built-in Agent actions. The prompt covers a user prompt, intermediate text, a successful shell result, an intentional shell error, a final response, and the native child's own prompt and response. Tool-only markers must not be repeated in assistant text.
5. After the main final response, press Cmd+; to open a side chat. Send `sideChatPrompt` there and wait for its final marker on screen. Keep that prompt separate from the main prompt so persisted-history checks remain meaningful.
6. Run the emitted finish command. Include `--side-chat-submitted` and `--side-response-visible` only if those manual steps occurred. These assertions are reported separately from measured hooks.

The collector removes only its exact owned registration. It preserves other settings and deletes a newly created settings file only when removal leaves it empty. If owned removal fails, it retains its exact private probe directory and control file for cleanup. It never deletes original provider transcripts.

After live collection ends, a second receiver with a fresh encrypted store imports a frozen seven-day audit containing the exact selected main transcript and at most 32 child files. This measures cold catch-up separately from replay of the live store. Both receivers perform their ordinary native replay and encrypted marker checks. The public report separates native source observations, committed content, helper delivery, cold catch-up, and unresolved gaps.

The cold gate requires a positive admitted audit count, a matching settled-admission count, complete persisted historical progress, positive required type and child marker counts, successful exact-source delivery, stable encrypted replay, and an empty queue without capture rejection. Source commitment followed by rejection of an unbound audit cannot pass this gate. Reports retain the observed content separately from the stricter historical settlement result.

Settings equality is measured against the initial configuration. Later probes also compare unowned settings immediately after install, immediately before owned removal, and after removal. This distinguishes permission additions during the provider interval, empty hook-container normalization, and unowned changes caused by an owned edit. It does not attribute the external change to a particular process. Snapshots remain in memory; no raw settings archive is added. The earlier R2 report recorded a mismatch without these intermediate comparisons, so its cause remains unmeasured.

`MessageDisplay` observations retain the stable message and turn grouping, batch index, final flag, and keyed delta comparison. Identical replayed batches can be collapsed; conflicting batches prevent a complete-group claim. The probe checks whether the side-chat final arrived, whether its session matches the selected source, and whether its marker exists in persisted native history. It does not merge display messages with transcript API messages or claim that observed display deltas were canonically analyzed.

`SubagentStart` and `SubagentStop` observations preserve keyed comparisons of the agent ID and transcript path. They record only whether the agent type is empty, nonempty, missing, or invalid. The wrapper checks `SubagentStop.last_assistant_message` for the controlled side final. The report separately counts callbacks whose session and main transcript both match the selected source, successful helper delivery, duplicate events, conflicting finals, matching start IDs, and exact existing own-child files. It never publishes agent names, paths, IDs, or message text. An assistant echo of the prompt marker does not establish `UserPromptSubmit` capture.

For a focused side-chat follow-up, add `--side-only` to the same `collect` command with new private control and output paths. Wait for readiness, submit `verificationPrompt` alone in the main conversation, then submit the emitted `sideChatCommand` beginning with `/btw`. Alternatively, open Cmd+; and use `sideChatPrompt`. This mode uses separate `SIDEPROBE` markers and omits the main fixture, so an earlier full-content run is not mistaken for new side evidence. Finish only after the final response is visible. Cold catch-up still measures the exact existing main and own-child sources separately.

Anthropic documents shared local settings and side chats in the [Desktop reference](https://code.claude.com/docs/en/desktop). Its [hook reference](https://code.claude.com/docs/en/hooks#subagentstop) says internal `/btw` agents trigger `SubagentStop`, which includes final assistant text, and may use an empty agent type. An omitted matcher, empty matcher, or `*` includes those events. `MessageDisplay` identifiers cannot be correlated with transcript API identifiers. Side-chat prompt capture, a canonical live authority, unavailable-history accounting, and full production GUI acceptance remain gates even when the main transcript probe passes. `phase0Passed` stays false in this preparatory probe.

Run `python3 Tests/ClaudeGUIProbe/test_hook_evidence.py` and `python3 Tests/ClaudeGUIProbe/test_probe_gates.py` for constructed privacy, identity, duplication, field-boundary, settings-preservation, and historical settlement checks. These checks do not establish genuine provider coverage.

`cold.py` reruns only available catch-up for the explicit original parent and its own children using a fresh encrypted store. Pass the same authorized `--source`, `--source-root`, `--producer-version`, and `--host-version`, plus a new `--output`. It changes no GUI project settings and launches no provider or signed app. Its exit gate additionally requires zero coverage gaps, scoped process/store cleanup, and unchanged retained originals. It does not claim recovery of a previous genuine probe store, which has already been removed.
