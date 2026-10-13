# Codex beta scope

The first beta targets saved Codex main conversations and readable native-subagent
replies and tool results. CLI, official Desktop and T3 each require passing host
checks before being advertised as verified. [Beta readiness](BETA_READINESS.md)
tracks the remaining work.

## Accepted limits

- Automatic ephemeral Desktop side chats, their hosted-tool results and recovery
  after missed callbacks are deferred.
- Encrypted original instructions delivered to native subagents are excluded.
  Readable child replies and tool results can still collect; parent text must
  not substitute for the child's original input.
- General hook-injected context without an exposed original content source is
  excluded. Supported native Stop-hook continuation is a separate included path.
- Binary image and audio analysis is excluded. Accompanying image text needs its
  own signed check. Local audio and `partial_answer` remain runtime-unverified.
- One-click Desktop/T3 navigation is deferred. Use authenticated encrypted retained
  context where available; do not guess conversation mappings.

Coverage may remain partial. Gaps and exclusions stay visible, and accepting a
limit does not mean missing content was analyzed. Delivery errors, scanner
failures, identity conflicts and other omissions in included content still need
investigation.

## Enroll a fresh installation

The compatibility promise begins with beta 1. Future beta updates must preserve
data. Migration from unpublished development versions and repair of their old
media warnings are not first-beta release gates; existing migration code and
regressions remain. Current persistence, encrypted work recovery, reviews,
revocation, deletion and provider-upgrade behavior are still required.

Check for existing Spillcheck or legacy Leakret data before enrolling a tester.
Preserve and review it separately; do not delete or reset it to qualify as fresh.
Startup can adopt an old directory, so controlled enrollment must perform this
check rather than relying on automatic rejection.

Complete the [entry checks](BETA_READINESS.md#before-starting-a-trial) on the chosen
signed build, including review/null-phase behavior, accompanying image text,
advertised hosts and visible notifications. Use the
[trial logger](../Tests/BetaTrial/README.md) with `--scope codex-beta-v1`, bind it to
the candidate's bundle digest, and observe at least five working days. Keep misses
in included content in the counts; excluded sources cannot count as verified.
Counts alone never grant acceptance.

[Claude](CLAUDE_BETA.md) has its own scope and checks. Codex results do not establish
Claude support or parity.
