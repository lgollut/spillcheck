---
"spillcheck": patch
---

Tool activity from agents that Claude Code runs inside workflows is no longer reported as not analyzed. Their hooks name the agent but not its workflow folder, so Spillcheck looked for the transcript in the wrong place, retried, and recorded the capture as lost even though live reads checked the same content.
