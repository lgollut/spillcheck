---
"spillcheck": minor
---

Collect Claude Code and Codex sessions from releases Spillcheck has not been tested
with, as long as their content can still be read, instead of stopping at an
unsupported version. CLI and T3 sessions in the same home are collected side by
side, and Coverage shows each host separately. Desktop app collection stays off.

When some content can't be read, the rest keeps being analyzed: Coverage reports
partial coverage, unread content is retried for up to seven days, and required
content that stops being collected triggers a masked notification. Prompts typed while Claude
is still working are now checked too.
