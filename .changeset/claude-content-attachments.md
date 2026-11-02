---
"spillcheck": patch
---

Spillcheck now checks the text that Claude Code attaches to a conversation: files you mention in a prompt, edited-file snippets, context added by hooks, hook errors, background task results and IDE diagnostics. These were reported as "Some content wasn't in a supported format" and left unchecked. File paths, hook commands and the duplicate copy that newer Claude Code versions save of each attachment are not checked.
