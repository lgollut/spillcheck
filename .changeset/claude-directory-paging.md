---
"spillcheck": patch
---

Claude Code catch-up no longer gets stuck on a folder with more than about 125 transcripts, such as a busy session's subagents folder. It used to restart that folder on every pass, so catch-up never finished, kept a processor core busy and never reached the older history queued behind it.
