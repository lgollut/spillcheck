---
"spillcheck": patch
---

Spillcheck now checks the transcripts of agents that Claude Code runs inside workflows. They're stored two folders deeper than other subagents, in `subagents/workflows/<run>/`, so catch-up and live reads both skipped them. When a session has more than 32 subagents, live reads now follow the most recently active ones.
