# Claude beta scope

The beta covers readable text in saved local Claude Code main conversations and
their native Agent children: user prompts, intermediate and final responses,
tool output and tool errors, including shell and MCP results. CLI, official
Desktop Local Code and T3 require their own host checks before being advertised
as verified. [Beta readiness](BETA_READINESS.md) tracks the remaining work.

## Setup

1. In Settings, choose **Configure…** for Claude Code and select the executable
   and profile directory to analyze.
2. To include saved local Desktop Code conversations, turn on **Enable desktop
   support (partial)**. Existing authorizations do not expand automatically;
   opt-in preserves the profile, registration and connection proof.
3. Follow the connection check using a fresh session. Review provider hook and
   folder-trust prompts normally. This establishes delivery for that profile,
   not complete content coverage.

CLI, Desktop and T3 can share one profile and hook registration. Collection status
identifies the provider/profile and configured transport. It cannot reliably
identify the producing app or filter shared-profile sessions by originating host.
Host-specific verification therefore needs independent host evidence.

The observed `permission-mode` setup record with `permissionMode: "dontAsk"`
contains session settings rather than conversation text. The reader recognizes
that exact shape and rereads eligible checkpoints after a parser update to
recover its previous format warnings. Changed records with additional payloads
remain visible for investigation.

## Accepted limits

- Desktop side questions and their replies are unsupported.
- Claude Chat, Cowork and remote Code are outside beta scope.
- Binary media analysis is excluded; the promise covers readable text.

Missing or malformed included content, delivery errors, scanner failures and
identity conflicts must remain visible and need investigation. The
[unresolved warnings and cleanup](BETA_READINESS.md#unresolved-warnings-and-cleanup)
from earlier controlled runs are not accepted exclusions.

## Run a controlled trial

Preserve existing Spillcheck and legacy Leakret data; never reset it to qualify
as a fresh installation. Complete the [entry checks](BETA_READINESS.md#before-starting-a-trial)
on the chosen signed build before starting real-world measurement.

Use the [trial logger](../Tests/BetaTrial/README.md) with `--scope claude-beta-v1`.
Bind a new log to the candidate's bundle SHA-256 and use the same digest and
`--provider claude` for each daily entry. Scope and candidate cannot be changed in
an existing log.

Cover all five text types on CLI, Desktop and T3, in both saved main conversations
and native children, including child prompts. Keep misses in the denominators.
The operator must establish host and source-class membership; shared hooks and
counts cannot infer either. Observe at least five working days, then review the
results against the readiness criteria. Counts alone do not grant acceptance,
and Claude verification does not establish Codex support.
