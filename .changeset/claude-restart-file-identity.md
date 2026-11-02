---
"spillcheck": patch
---

Fix Spillcheck reading every Claude Code conversation again after the Mac restarts. It treated the disk's device number, which macOS can change at each startup, as part of a file's identity. After a restart it therefore reported each conversation as changed and read its history again. It now recognizes a conversation file by the file's own identity, and reports a change only when the file was really rewritten or replaced.
