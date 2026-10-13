This probe compiles the app's saved-profile model, setup controller, collection configuration, and view dependencies against an already-built `SpillcheckCore` library. It checks disposable Codex and Claude profiles, owned-hook preservation/removal, compatible executable upgrades, and durable verification. Provider fixtures accept only `--version`; the probe uses ephemeral testing keys and starts no provider sessions.

Schema 1 and 2 fixtures omit the new host field. Both providers and both legacy transport interfaces must migrate to schema 3 with the same home, profile, registration, proof, hooks, and encrypted pending packet body. CLI/T3 host authorization is separate from the immutable owned hook transport; authorization changes preserve the proof and provider settings. Defaults and migrated records never add desktop authorization. Both providers require explicit opt-in to partial Desktop support, and a damaged schema 3 record cannot infer broader authorization. Both authorization updates and the Configure installation path preserve the existing registration, hooks and connection proof through reload. Failed encrypted writes must leave the old configuration and in-memory status intact.

The Claude checks cover explicitly selected Desktop native sources, Desktop-only history routing, and shared CLI/Desktop history without retagging the audit. Support is limited to saved local Desktop Code conversations and readable native children; Desktop side questions are unsupported. Fresh owned role evidence may include Desktop, while recovery evidence admission remains CLI/T3. Constructed role receipts do not establish genuine Desktop hook dispatch or full host acceptance.

The Codex desktop checks cover explicit opt-in without changing an existing shared registration, a legacy desktop registration that stays disabled until the user authorizes it, durable delivery verification, restart, and removal that preserves unrelated hooks. Runtime configuration must explicitly authorize `desktop-code`; transcript authority remains T3-only. Collection stays host-neutral and partial, with automatic side-chat collection unavailable. Constructed native reads and registration proof do not establish desktop acceptance.

Source-opening checks prepare commands without launching a provider or app. Codex terminal resume must match the finding's profile identity and carry that configured native home's explicit `CODEX_HOME`. Changing the home or profile identity invalidates the cached controller configuration; missing and replacement profiles cannot fall back to the default home. Claude's existing command is unchanged. The separate Core test executes an owned shell stub to check argument quoting and override of an unrelated ambient `CODEX_HOME`.

All eight migration combinations also persist constructed findings through real encrypted store transactions, close and reopen the store before migration, then reopen again after replay. Confirmed and false-positive reviews, a revoked value whose retained content was removed, delivered and pending alert decisions, stable labels, encrypted payloads, source receipts, and consumed capture receipts must survive. Replaying the same sources through the other authorized host must preserve those exact dispositions and create no occurrences, alerts, or redundant payloads. These checks use ephemeral keys and constructed detector output; they do not establish signed app migration, scanner accuracy, or macOS notification delivery.

The probe also checks scoped CLI/T3 status, canonical Claude replay receipts, and sole-host historical request routing without changing its frozen audit or cursor. Both providers present one shared-profile status because the configured transport does not identify the producing host. Underlying scopes, failures and retries remain distinct, and actual live reads still establish provider-level collection. Shared registration verification does not establish the actual producer host. These are constructed contract checks; genuine signed migration and host runs require separate evidence.

Coverage diagnostics schema 4 records both providers' `configuredInterface` and any `configuredHostVersion`, marks `hostAttribution` as `unverified`, and omits `host` and `hostVersion`. The real admission/restart fixture checks routes, work, successful reads and gaps against that rule. Configured transport labels do not establish which host produced a session. These fields retain transport and version diagnostics without claiming host attribution.

Startup diagnostics checks cover opening and unavailable inventory states, all six bootstrap errors, controlled key and store failures, and export before a vault or coverage report is available. An unknown error containing private sentinel text must export only its generic classification. Startup exports explicitly mark coverage unavailable and omit counts, even if a partial startup produced a report. Normal opened-but-paused storage keeps its existing behavior. These tests exercise pure model and encoding paths; they do not open a save panel, access device keys, or run native startup.

Coverage assertions keep encrypted required Codex input unresolved, distinguish it from excluded media, export its controlled diagnostic code, and avoid offering a reread as a remedy for unavailable plaintext.

A separate missing native-child-input diagnostic reports unavailable original
instructions without claiming that public history exposed an encrypted record.
It stays required, offers diagnostics instead of an ineffective reread, and keeps
native session and item identities out of the exported report.

Capacity checks cover count and encrypted-byte headroom, the 80% warning threshold, full storage and lowered limits. Near-capacity warnings do not create content gaps or disable a working route. The diagnostic export contains aggregate usage and configured limits only. Admission-capacity failures retain their configured route and offer diagnostics rather than an ineffective history retry. Paused and unavailable storage retain their own status.

Run from the repository root after building the core package:

```sh
python3 Tests/AgentSetupProbe/run.py --products-path .build/out/Products/Debug
```

`--products-path` reuses existing products without invoking SwiftPM. Without it, the runner discovers cached products with `swift build --show-bin-path`. It requires `libSpillcheckCore.a`, its module, and the GRDB SQLite module map, and compiles for Apple Silicon and macOS 14. The report is `.build/implementation/agent-setup-probe.json`.

The native-content acceptance assertions exercise two fixed harmless fixtures: a native MCP result with eleven exact text segments and a 191-byte native HookPrompt. They require same-response native type, item, turn and original timestamp before linking the normalized source revision to a full current-detector receipt. An empty store, cold reopen and reread compare complete receipt, source-kind, source-time and conversation-label commitments. Assistant echoes, altered fragments, missing MCP leaves, reduced receipts and wrong revisions fail. The checks use constructed native responses and ephemeral encrypted stores; they do not launch Codex, the signed app, a Keychain-backed vault or a provider session. They do not establish genuine signed acceptance.

For the current SwiftPM products, the offline app assertions can be run with:

```sh
python3 Tests/AgentSetupProbe/run.py --products-path .build/debug
```

The opt-in HookPrompt witness can additionally export its verified native descriptor to the exact private root's `native-content-descriptor.json` when `SPILLCHECK_HOOK_PROBE_DESCRIPTOR` is set. Export happens only after two matching native reads and successful reader shutdown. The file is created exclusively with mode 0600; the public report contains no native identifiers. Its path boundary is checked without running the live witness by `swift test --scratch-path .build --filter CodexHookPromptLiveTests` when the live environment variables are unset.
