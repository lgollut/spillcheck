# Bound the first Codex beta

Decision date: 2026-10-12. Status: accepted scope decision. Current acceptance and
outstanding work are tracked in [beta readiness](../BETA_READINESS.md).

The beta targets saved Codex main conversations and readable native-subagent
replies and tool results in CLI, desktop and T3. A host is advertised only after
its current signed acceptance passes. This decision covers Codex;
[Claude's scope](../CLAUDE_BETA.md) is tracked separately. This is a scoped beta,
not full Codex content coverage.

## Accepted limits

- Original encrypted instructions delivered to native subagents are outside the
  beta promise. Readable child replies and tool results still collect. Parent
  text must not stand in for the child's original incoming item.
- Automatic ephemeral desktop side-chat collection is deferred. Its trusted
  identity, hosted-tool results and recovery are not promised. Experimental
  hook collection must not be enabled using
  guessed identities or advertised as automatic coverage. This supersedes the
  side-chat beta target in decision 0006; its identity and integrity constraints
  still apply to any experimental collection.
- General hook-added context without an established original native source is
  outside the beta promise. Supported native Stop-hook continuation remains in
  scope and requires its own signed acceptance.
- One-click desktop/T3 navigation is deferred. Encrypted retained context is the
  available fallback; no guessed application/provider ID mapping is allowed.
- Binary-media analysis remains excluded. Accompanying image text needs signed
  acceptance before being advertised. Local audio and `partial_answer` have
  implemented parsing but unverified genuine runtime support. Synthetic data
  must not be treated as live evidence.

Keep omissions and coverage limits visible. Acceptance of a limit does not
prove collection or recovery, remove stored incidents, or turn partial coverage
into complete coverage. Required scanning failures, ambiguous identity, lost
deliveries, truncation and duplicate prevention remain unchanged for admitted
content. A supported main-session result is not evidence for an ephemeral side.

## Compatibility starts with the beta

Do not gate the first beta on genuine migration from unpublished development
versions or signed repair of their historical media warnings. Keep existing
migration code and regression tests. Current persistence, encrypted work recovery,
reviews, revocation, deletion and provider-upgrade behavior remain required.
Preserving user data across future beta app releases is part of the beta promise.

Enroll fresh beta vaults through a controlled process. Existing development data
must be identified and preserved, never silently reset. Current app startup can
adopt a legacy Leakret directory and older profiles, so fresh enrollment is a
support policy, not an implemented automatic rejection of old installations.

## Acceptance requirements

The beta requires signed review/null-phase acceptance, signed accompanying-image-
text acceptance, and current retained-source acceptance for advertised desktop/T3
hosts. It also requires visible macOS notification verification and at least five
working days of candidate-bound Codex measurements after controlled entry checks
pass. [Beta readiness](../BETA_READINESS.md) identifies which gates remain open.

The trial must identify this scope and its exclusions explicitly. It must not
count excluded sources as verified, hide misses in included sources, or imply
that the full two-provider matrix passed. No trial or beta acceptance is granted
by this decision alone.
