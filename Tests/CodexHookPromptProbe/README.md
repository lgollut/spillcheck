# Genuine native hook-prompt probe

This opt-in probe uses Codex CLI 0.162.1, a fresh private home and workspace, and one normally reviewed `Stop` command hook. It creates no vault and makes no Keychain or signed-app call. Importing the runner or running its Python boundaries does not start Codex or read authentication.

After the parent has built the current Swift tests, run once with fresh output paths:

```sh
python3 Tests/CodexHookPromptProbe/run.py \
  --executable ~/.local/bin/codex \
  --auth-file ~/.codex/auth.json \
  --model gpt-6-astra \
  --scratch-path .build \
  --report .build/beta-readiness/codex-hook-prompt-2026-10-12/native-hook-r1-report.json \
  --private-control .build/beta-readiness/codex-hook-prompt-2026-10-12/native-hook-r1-private
```

The output parent directory must already exist. The report and private-control directory must not exist. The runner uses `swift test --skip-build`; it never builds the witness. A missing or stale witness fails the run. Version and runner/helper/witness hashes are checked before and after collection.

The bounded PTY driver accepts folder trust only when that initial prompt is observed, then selects `1. Review hooks`, requires the normal trust-all footer, presses `t`, observes the post-trust details footer, and closes the browser with Escape. The singular count comes from the pinned [startup review source](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/tui/src/startup_hooks_review.rs#L215). `1` is immediate; it needs no extra Enter. A single hook still starts on the browser's Events page. The driver waits for the same observed action labels for 1.1 seconds before sending a key, because Codex draws the protected menu before [draining queued input for up to one second](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/tui/src/tui/input_boundary.rs#L25). No key is repeated. Initial menu observation has a 40-second budget; browser and trust acknowledgement stages each have 20 seconds. Closed progress files record the stage, actions, UI flags and byte counts. It does not write trust settings directly or bypass review.

The first turn runs only the fixed workspace helper to record its own runtime `CODEX_THREAD_ID`, home, and working directory privately. Its successful Stop callback must finish before the runner arms the hook. A second harmless prompt requests a fixed final answer without tools. Only the exact owned session, working directory, expected answer, and inactive Stop state can consume the atomic one-shot guard. The hook returns exit-zero `decision: block` with a harmless reason that appears in neither human input. The next active Stop must observe the requested continuation answer and return an empty object. The hook definition and script stay unchanged after review. This uses the documented [Stop continuation contract](https://learn.chatgpt.com/docs/hooks#stop), not general `additionalContext`.

The fresh fixture uses LF line endings and Unicode. Codex passes the trimmed Stop reason without a prose prefix, then serializes and parses its native fragment through XML. Its pinned quick-xml 0.41.0 [serializer leaves CRLF in text](https://github.com/tafia/quick-xml/blob/v0.41.0/src/se/simple_type.rs#L488), while the [XML text decoder normalizes line endings](https://github.com/tafia/quick-xml/blob/v0.41.0/src/events/mod.rs#L670). The fixture avoids that producer transformation; the witness still compares the actual native fragment bytes exactly and never normalizes them. Earlier run artifacts remain unchanged.

Each callback records its actual PID, parent, process group, and a bounded measured ancestry ending at the exact owned CLI PID. Independent callback process groups are allowed, but every recorded PID and group must be absent before auth or home cleanup. The provider exits normally through bracketed `/quit` and a separate Enter. Teardown always stops the owned provider group before closing the PTY. Output is bounded; terminal content is discarded, and failure diagnostics retain only stages, UI flags, callback shapes, and outcome counts.

After authentication is removed, the production passive reader reads only that exact native session twice, with bounded item and turn pages and no discovery or resume. It measures the actual native `hookPrompt` item and turn; it does not assume the callback turn is the native item's turn. The witness requires exactly the original decoded fragment bytes, `/fragments/0/text`, the native item identity, `userPrompt` classification, current parser provenance, no gaps, and stable replay. `hookRunId` is checked only as metadata. Both exact human inputs and the sole allowed identity command are also checked, so an assistant echo or another tool cannot supply the proof. Original turn timestamps come from the production turn-read fallback, never the observation clock.

The public report contains closed booleans, counts, pointers, versions, and digests. Native IDs, source text, terminal output, and auth bytes remain private. A failed original-auth integrity check still attempts removal of the confirmed owned copy once all processes stop. Unconfirmed process or path ownership retains the private cleanup handoff. This is native source/read/parser/replay evidence only: no detector receipt, secret recall, signed-app, desktop, T3, general hook-context, or full-host acceptance is claimed.

Pure boundaries:

```sh
python3 -m unittest discover -s Tests/CodexHookPromptProbe -p test_boundary.py
```
