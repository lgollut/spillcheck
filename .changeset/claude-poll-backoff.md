---
"spillcheck": patch
---

Spillcheck uses less processing time while it watches Claude conversations. It checked every conversation it had seen since it started four times a second, including each one's subagent folder, even when the conversation had been idle for hours, so the work grew the longer it ran. A conversation is still checked on every pass while it changes, and then less often as it stays unchanged, down to every 30 seconds. Any change, or a hook from that conversation, makes it current again.
