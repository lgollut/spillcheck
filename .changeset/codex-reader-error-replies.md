---
"spillcheck": patch
---

Spillcheck no longer restarts its Codex reader each time Codex answers a request with an error, such as "thread not loaded" for a deleted thread. Polling a deleted thread had started a new `codex app-server` about once a second, which slowed every other capture.
