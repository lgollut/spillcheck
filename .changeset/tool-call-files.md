---
"spillcheck": minor
---

Show which file a tool output came from. When an agent printed a value by reading a file, such as `sed` on a test fixture or `cat` on `.env.local`, the appearance now names that file above its excerpt, with the program or tool that read it. Output that didn't come from a file names the program instead, such as `printenv`. Spillcheck keeps only the tool, the program and the file paths with the appearance, never the command's other arguments, so removing a value's retained content can't leave a copy of it inside a stored command. Appearances found before this version have no stored file: while unlocked, Spillcheck looks it up in the agent's own history if that history still exists, and doesn't store it.
